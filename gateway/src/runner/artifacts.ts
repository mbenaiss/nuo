import { realpath, stat } from "node:fs/promises";
import { basename, extname, isAbsolute, resolve, sep } from "node:path";
import { MAX_MEDIA_BYTES } from "../store/media";

/** `::artifact {json}` on a line of its own: a file the bot wrote and wants the user to open, download or share. */
const ARTIFACT_LINE = /^::artifact[ \t]+(\{.*\})[ \t]*$/gm;

const MIME: Record<string, string> = {
  ".html": "text/html",
  ".htm": "text/html",
  ".svg": "image/svg+xml",
  ".pdf": "application/pdf",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".md": "text/markdown",
  ".txt": "text/plain",
  ".csv": "text/csv",
  ".json": "application/json",
  ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  ".zip": "application/zip",
};

export function artifactMime(name: string): string {
  return MIME[extname(name).toLowerCase()] ?? "application/octet-stream";
}

export interface ArtifactOptions {
  /** Where a relative path may be, in order: the agent's own folder, then the bot's configured working directory. */
  bases: string[];
  /** The only folders a published file may come from, symlinks resolved. */
  roots: string[];
  save: (mime: string, bytes: Uint8Array, name: string) => Promise<string>;
}

async function firstExisting(paths: string[]): Promise<string> {
  for (const p of paths.slice(0, -1)) {
    const found = await realpath(p).catch(() => undefined);
    if (found) return found;
  }
  return realpath(paths.at(-1)!);
}

/**
 * Copies every file named by an `::artifact {"path": …}` line into the media store and rewrites the line with its
 * `/api/media/…` url, so the app can show, download and share it without reaching the bot's folder. A file that
 * cannot be published keeps its card, with the reason in `error`.
 */
export async function publishArtifacts(text: string, o: ArtifactOptions): Promise<string> {
  const matches = [...text.matchAll(ARTIFACT_LINE)];
  if (!matches.length) return text;
  const roots = await Promise.all(o.roots.map((r) => realpath(r).catch(() => undefined)));
  const allowed = (p: string) => roots.some((r) => r && (p === r || p.startsWith(r + sep)));
  let out = text;
  for (const m of matches) {
    let card: Record<string, unknown>;
    try {
      card = JSON.parse(m[1]!);
    } catch {
      continue;
    }
    if (typeof card.path !== "string" || typeof card.url === "string") continue;
    const { path, ...rest } = card;
    const title = typeof rest.title === "string" && rest.title ? rest.title : basename(path);
    let published: Record<string, unknown>;
    try {
      const real = await firstExisting(isAbsolute(path) ? [path] : o.bases.map((b) => resolve(b, path)));
      if (!allowed(real)) throw new Error("hors de ton espace de travail");
      const info = await stat(real);
      if (!info.isFile()) throw new Error("introuvable");
      if (info.size > MAX_MEDIA_BYTES) throw new Error("trop lourd (plus de 20 Mo)");
      const name = basename(real);
      const mime = artifactMime(name);
      const id = await o.save(mime, new Uint8Array(await Bun.file(real).arrayBuffer()), name);
      published = { ...rest, title, name, mime, size: info.size, url: `/api/media/${id}` };
    } catch (e) {
      const reason = (e as NodeJS.ErrnoException)?.code === "ENOENT" ? "introuvable" : ((e as Error)?.message ?? String(e));
      published = { ...rest, title, name: basename(path), error: `Fichier ${reason}` };
    }
    out = out.replace(m[0], `::artifact ${JSON.stringify(published)}`);
  }
  return out;
}
