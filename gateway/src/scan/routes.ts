import { HttpError } from "../bots/service";
import { SCAN_KINDS, type ScanKind } from "./codes";
import { ParcelError } from "./parcels";
import { LookupError } from "./products";
import { ToolInputError, type ScanServices } from "./service";
import { SCAN_TOOL_NAMES } from "./tools";

type Ctx = { req: Request; params: string[]; url: URL };
export type ScanRoute = [string, RegExp, (ctx: Ctx) => unknown];

async function body(req: Request): Promise<Record<string, unknown>> {
  if (req.headers.get("content-length") === "0") return {};
  try {
    const b = await req.json();
    if (b && typeof b === "object" && !Array.isArray(b)) return b as Record<string, unknown>;
  } catch {}
  throw new HttpError(400, "invalid JSON body");
}

async function parcelCall<T>(fn: () => T | Promise<T>): Promise<T> {
  try {
    return await fn();
  } catch (e) {
    if (e instanceof ParcelError) throw new HttpError(e.status, e.message);
    throw e;
  }
}

/** Paired app: scanning and the parcels screen. */
export function scanRoutes(s: ScanServices): ScanRoute[] {
  const parcel = (id: string) => {
    const p = s.parcels.get(id);
    if (!p || p.archivedAt) throw new HttpError(404, "colis introuvable");
    return p;
  };
  return [
    [
      "GET",
      /^\/api\/scan\/([^/]+)$/,
      ({ params, url }) => {
        const kind = url.searchParams.get("kind");
        if (kind && !SCAN_KINDS.includes(kind as ScanKind)) throw new HttpError(400, `kind must be one of ${SCAN_KINDS.join(", ")}`);
        const code = params[0]!;
        if (code.length > 200) throw new HttpError(400, "code too long");
        return s.scanner.scan(code, { kind: (kind as ScanKind) || undefined, symbology: url.searchParams.get("symbology") ?? undefined });
      },
    ],
    [
      "POST",
      /^\/api\/scan\/([^/]+)\/ingredients$/,
      async ({ req, params }) => {
        const b = await body(req);
        const code = params[0]!;
        if (code.length > 200) throw new HttpError(400, "code too long");
        if (typeof b.ingredients !== "string" || !b.ingredients.trim() || b.ingredients.length > 20_000) throw new HttpError(400, "ingredients is required");
        const text = (k: string) => (typeof b[k] === "string" && (b[k] as string).trim() ? (b[k] as string).trim().slice(0, 200) : undefined);
        try {
          const cosmetic = s.products.rememberIngredients(code, { ingredients: b.ingredients, name: text("name"), brand: text("brand") });
          return { code, kind: "cosmetic", candidates: ["cosmetic"], cosmetic };
        } catch (e) {
          if (e instanceof LookupError) throw new HttpError(400, e.message);
          throw e;
        }
      },
    ],
    ["GET", /^\/api\/parcels$/, ({ url }) => ({ trackingConfigured: s.parcels.trackingConfigured, parcels: s.parcels.list({ includeDone: url.searchParams.get("all") === "1" }) })],
    [
      "POST",
      /^\/api\/parcels$/,
      async ({ req }) => {
        const b = await body(req);
        if (typeof b.number !== "string") throw new HttpError(400, "number is required");
        return parcelCall(() =>
          s.parcels.add({ number: b.number as string, label: typeof b.label === "string" ? b.label : undefined, carrier: typeof b.carrier === "string" ? b.carrier : undefined }),
        );
      },
    ],
    ["GET", /^\/api\/parcels\/([^/]+)$/, ({ params }) => parcel(params[0]!)],
    ["POST", /^\/api\/parcels\/([^/]+)\/refresh$/, async ({ params }) => (await s.parcels.refresh(parcel(params[0]!).id, { manual: true })) ?? parcel(params[0]!)],
    [
      "DELETE",
      /^\/api\/parcels\/([^/]+)$/,
      async ({ params }) => {
        await parcelCall(() => s.parcels.archive(parcel(params[0]!).id));
        return new Response(null, { status: 204 });
      },
    ],
  ];
}

/** For the profile's `nuo` MCP server (local token). */
export function scanLocalRoutes(s: ScanServices): ScanRoute[] {
  return [
    [
      "POST",
      /^\/api\/scan\/tools\/([a-z_]+)$/,
      async ({ req, params }) => {
        if (!SCAN_TOOL_NAMES.has(params[0]!)) throw new HttpError(404, `unknown scan tool ${params[0]}`);
        try {
          return { text: await s.tools.call(params[0]!, await body(req)) };
        } catch (e) {
          if (e instanceof ToolInputError || e instanceof ParcelError) throw new HttpError(400, e.message);
          throw e;
        }
      },
    ],
  ];
}
