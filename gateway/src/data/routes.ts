import { existsSync, mkdirSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, join, sep } from "node:path";
import { HttpError } from "../bots/service";
import { MAX_UPLOAD_BYTES } from "./docs";
import type { DataServices } from "./service";
import { isSafeRelative } from "./store";
import type { DataFile, DataRow } from "./types";

type Ctx = { req: Request; params: string[]; url: URL };
export type DataRoute = [string, RegExp, (ctx: Ctx) => unknown];

async function body(req: Request): Promise<Record<string, unknown>> {
  try {
    const b = await req.json();
    if (b && typeof b === "object" && !Array.isArray(b)) return b as Record<string, unknown>;
  } catch {}
  throw new HttpError(400, "invalid JSON body");
}

const noContent = () => new Response(null, { status: 204 });
const C = "/api/data/collections/([^/]+)";

/**
 * Stores the bytes under data/files/<collection>/<row>/<name> (a free name like `devis-2.pdf` when taken)
 * and appends the file to the row's `file` column.
 */
function attachFile(d: DataServices, collectionId: string, rowId: string, column: string, rawName: string | null, data: Uint8Array): DataRow {
  if (data.byteLength > MAX_UPLOAD_BYTES) throw new HttpError(413, "file too large");
  const col = d.store.collection(collectionId).columns.find((c) => c.name === column);
  if (!col || col.type !== "file") throw new HttpError(400, `"${column}" is not a file column`);
  const name = (rawName ?? "").split(/[\\/]/).pop()!.replace(/^\.+/, "").trim();
  if (!name || name.includes("\0")) throw new HttpError(400, "invalid file name");
  const current = d.store.row(collectionId, rowId).values[column];
  const dir = `${collectionId}/${rowId}`;
  if (!isSafeRelative(dir)) throw new HttpError(400, "invalid path");
  const dot = name.lastIndexOf(".");
  const [stem, ext] = dot > 0 ? [name.slice(0, dot), name.slice(dot)] : [name, ""];
  let stored = name;
  for (let n = 2; existsSync(join(d.filesDir, dir, stored)); n++) stored = `${stem}-${n}${ext}`;
  const path = `${dir}/${stored}`;
  mkdirSync(join(d.filesDir, dir), { recursive: true });
  writeFileSync(join(d.filesDir, path), data);
  try {
    return d.store.patch(collectionId, rowId, { [column]: [...(Array.isArray(current) ? (current as DataFile[]) : []), { name: stored, path }] });
  } catch (e) {
    rmSync(join(d.filesDir, path), { force: true });
    throw e;
  }
}

/** REST routes of docs/data.md, served to paired devices. */
export function dataRoutes(d: DataServices): DataRoute[] {
  return [
    ["GET", /^\/api\/data\/collections$/, () => d.store.listCollections()],
    [
      "GET",
      new RegExp(`^${C}/rows$`),
      ({ params, url }) => {
        const s = url.searchParams;
        return d.store.rows(params[0]!, {
          q: s.get("q") ?? undefined,
          sort: s.getAll("sort").filter(Boolean),
          filter: s.getAll("filter").filter(Boolean),
          limit: s.has("limit") ? Number(s.get("limit")) : undefined,
          cursor: s.get("cursor"),
          archived: s.get("archived") === "1" || s.get("archived") === "true",
        });
      },
    ],
    [
      "GET",
      new RegExp(`^${C}/groups$`),
      ({ params, url }) => {
        const s = url.searchParams;
        const by = s.get("by");
        if (!by) throw new HttpError(400, "missing by");
        return d.store.groups(params[0]!, {
          by,
          q: s.get("q") ?? undefined,
          filter: s.getAll("filter").filter(Boolean),
          archived: s.get("archived") === "1" || s.get("archived") === "true",
        });
      },
    ],
    ["POST", new RegExp(`^${C}/rows$`), async ({ req, params }) => d.store.insert(params[0]!, (await body(req)).values)],
    ["GET", new RegExp(`^${C}/rows/([^/]+)$`), ({ params }) => d.store.rowWithHistory(params[0]!, params[1]!)],
    ["PATCH", new RegExp(`^${C}/rows/([^/]+)$`), async ({ req, params }) => d.store.patch(params[0]!, params[1]!, (await body(req)).values)],
    [
      "POST",
      new RegExp(`^${C}/rows/([^/]+)/files/([^/]+)$`),
      async ({ req, params, url }) =>
        Response.json(attachFile(d, params[0]!, params[1]!, params[2]!, url.searchParams.get("name"), new Uint8Array(await req.arrayBuffer())), { status: 201 }),
    ],
    ["POST", new RegExp(`^${C}/rows/([^/]+)/archive$`), ({ params }) => d.store.setArchived(params[0]!, params[1]!, true)],
    ["POST", new RegExp(`^${C}/rows/([^/]+)/unarchive$`), ({ params }) => d.store.setArchived(params[0]!, params[1]!, false)],
    [
      "GET",
      /^\/api\/data\/history$/,
      ({ url }) =>
        d.store.history({
          collection: url.searchParams.get("collection") || undefined,
          rowId: url.searchParams.get("rowId") || undefined,
          limit: url.searchParams.has("limit") ? Number(url.searchParams.get("limit")) : undefined,
        }),
    ],
    ["POST", /^\/api\/data\/history\/([^/]+)\/revert$/, ({ params }) => d.store.revert(params[0]!)],
    ["GET", /^\/api\/data\/search$/, ({ url }) => d.store.search(url.searchParams.get("q") ?? "")],
    [
      "GET",
      /^\/api\/data\/files$/,
      async ({ url }) => {
        const p = url.searchParams.get("path") ?? "";
        if (!isSafeRelative(p)) throw new HttpError(400, "invalid path");
        const abs = join(d.filesDir, p);
        if (!existsSync(abs) || !statSync(abs).isFile()) throw new HttpError(404, "file not found");
        const root = realpathSync(d.filesDir);
        if (!realpathSync(abs).startsWith(root + sep)) throw new HttpError(400, "invalid path");
        return new Response(Bun.file(abs), { headers: { "cache-control": "private, max-age=3600" } });
      },
    ],

    ["GET", /^\/api\/reminders\/lists$/, () => d.reminders.lists()],
    ["GET", /^\/api\/reminders$/, ({ url }) =>
      d.reminders.list(url.searchParams.get("scope") || "all", url.searchParams.get("list") || undefined, {
        project: url.searchParams.get("project") || undefined,
        area: url.searchParams.get("area") || undefined,
      }),
    ],
    [
      "GET",
      /^\/api\/reminders\/overview$/,
      () => {
        const projects = d.projects.projects();
        return {
          counts: d.reminders.counts(),
          areas: d.projects.areas().map((a) => ({ ...a, projects: projects.filter((p) => p.areaId === a.id) })),
          projects: projects.filter((p) => !p.areaId),
        };
      },
    ],

    ["GET", /^\/api\/areas$/, () => d.projects.areas()],
    ["POST", /^\/api\/areas$/, async ({ req }) => d.projects.createArea(await body(req))],
    ["PATCH", /^\/api\/areas\/([^/]+)$/, async ({ req, params }) => d.projects.patchArea(params[0]!, await body(req))],
    [
      "DELETE",
      /^\/api\/areas\/([^/]+)$/,
      ({ params }) => {
        d.projects.archiveArea(params[0]!);
        return noContent();
      },
    ],
    ["GET", /^\/api\/projects$/, ({ url }) => d.projects.projects({ status: url.searchParams.get("status") || undefined, area: url.searchParams.get("area") || undefined })],
    ["POST", /^\/api\/projects$/, async ({ req }) => d.projects.createProject(await body(req))],
    [
      "GET",
      /^\/api\/projects\/([^/]+)$/,
      ({ params }) => ({
        project: d.projects.project(params[0]!),
        headings: d.projects.headings(params[0]!),
        reminders: [...d.reminders.list("all", undefined, { project: params[0]! }), ...d.reminders.list("done", undefined, { project: params[0]! })],
      }),
    ],
    ["PATCH", /^\/api\/projects\/([^/]+)$/, async ({ req, params }) => d.projects.patchProject(params[0]!, await body(req))],
    ["POST", /^\/api\/projects\/([^/]+)\/done$/, async ({ req, params }) => d.projects.finishProject(params[0]!, await body(req), "done")],
    ["POST", /^\/api\/projects\/([^/]+)\/cancel$/, async ({ req, params }) => d.projects.finishProject(params[0]!, await body(req), "cancelled")],
    ["POST", /^\/api\/projects\/([^/]+)\/reopen$/, ({ params }) => d.projects.reopenProject(params[0]!)],
    [
      "DELETE",
      /^\/api\/projects\/([^/]+)$/,
      ({ params }) => {
        d.projects.archiveProject(params[0]!);
        return noContent();
      },
    ],
    ["POST", /^\/api\/projects\/([^/]+)\/headings$/, async ({ req, params }) => d.projects.createHeading(params[0]!, await body(req))],
    ["PATCH", /^\/api\/headings\/([^/]+)$/, async ({ req, params }) => d.projects.patchHeading(params[0]!, await body(req))],
    [
      "DELETE",
      /^\/api\/headings\/([^/]+)$/,
      ({ params }) => {
        d.projects.archiveHeading(params[0]!);
        return noContent();
      },
    ],
    ["POST", /^\/api\/reminders$/, async ({ req }) => d.reminders.create(await body(req))],
    ["PATCH", /^\/api\/reminders\/([^/]+)$/, async ({ req, params }) => d.reminders.patch(params[0]!, await body(req))],
    ["POST", /^\/api\/reminders\/([^/]+)\/done$/, ({ params }) => d.reminders.done(params[0]!)],
    ["POST", /^\/api\/reminders\/([^/]+)\/undone$/, ({ params }) => d.reminders.undone(params[0]!)],
    ["POST", /^\/api\/reminders\/([^/]+)\/snooze$/, async ({ req, params }) => d.reminders.snooze(params[0]!, await body(req))],
    [
      "DELETE",
      /^\/api\/reminders\/([^/]+)$/,
      ({ params }) => {
        d.reminders.archive(params[0]!);
        return noContent();
      },
    ],

    ["GET", /^\/api\/places$/, () => d.places.list()],
    ["POST", /^\/api\/places$/, async ({ req }) => d.places.create(await body(req))],
    ["PATCH", /^\/api\/places\/([^/]+)$/, async ({ req, params }) => d.places.patch(params[0]!, await body(req))],
    [
      "DELETE",
      /^\/api\/places\/([^/]+)$/,
      ({ params }) => {
        d.places.archive(params[0]!);
        return noContent();
      },
    ],

    ["GET", /^\/api\/dashboards$/, () => d.dashboards.list()],
    ["GET", /^\/api\/dashboards\/([^/]+)$/, ({ params }) => d.dashboards.get(params[0]!)],

    ["GET", /^\/api\/docs\/tree$/, () => d.docs.tree()],
    ["GET", /^\/api\/docs\/file$/, ({ url }) => d.docs.read(url.searchParams.get("path"))],
    [
      "PUT",
      /^\/api\/docs\/file$/,
      async ({ req }) => {
        const b = await body(req);
        return d.docs.write(b.path, b.content, b.baseSha);
      },
    ],
    [
      "POST",
      /^\/api\/docs\/file$/,
      async ({ req }) => {
        const b = await body(req);
        return Response.json(await d.docs.create(b.path, b.content), { status: 201 });
      },
    ],
    [
      "DELETE",
      /^\/api\/docs\/file$/,
      async ({ url }) => {
        await d.docs.remove(url.searchParams.get("path"));
        return noContent();
      },
    ],
    [
      "POST",
      /^\/api\/docs\/move$/,
      async ({ req }) => {
        const b = await body(req);
        return d.docs.move(b.from, b.to);
      },
    ],
    ["GET", /^\/api\/docs\/pins$/, () => d.docs.pins()],
    ["PUT", /^\/api\/docs\/pins$/, async ({ req }) => d.docs.setPins((await body(req)).paths)],
    [
      "POST",
      /^\/api\/docs\/folder$/,
      async ({ req }) => Response.json(await d.docs.createFolder((await body(req)).path), { status: 201 }),
    ],
    [
      "DELETE",
      /^\/api\/docs\/folder$/,
      async ({ url }) => {
        await d.docs.removeFolder(url.searchParams.get("path"));
        return noContent();
      },
    ],
    [
      "GET",
      /^\/api\/docs\/raw$/,
      ({ req, url }) => {
        const f = d.docs.raw(url.searchParams.get("path"));
        if (req.headers.get("if-none-match") === f.etag) return new Response(null, { status: 304, headers: { etag: f.etag } });
        return new Response(f.file, { headers: { "content-type": f.file.type, etag: f.etag, "cache-control": "private, max-age=300, must-revalidate" } });
      },
    ],
    [
      "POST",
      /^\/api\/docs\/upload$/,
      async ({ req, url }) => Response.json(await d.docs.upload(url.searchParams.get("path"), new Uint8Array(await req.arrayBuffer())), { status: 201 }),
    ],
    [
      "POST",
      /^\/api\/docs\/upload$/,
      async ({ req, url }) => Response.json(await d.docs.upload(url.searchParams.get("path"), new Uint8Array(await req.arrayBuffer())), { status: 201 }),
    ],
    [
      "POST",
      /^\/api\/docs\/drop$/,
      async ({ req }) => {
        if (!d.drop) throw new HttpError(404, "drop is not configured");
        const { path, ttl } = await body(req);
        return d.drop.publish(basename(String(path)), d.docs.raw(path).file, ttl);
      },
    ],
    ["GET", /^\/api\/docs\/search$/, ({ url }) => d.docs.search(url.searchParams.get("q") ?? "")],
  ];
}
