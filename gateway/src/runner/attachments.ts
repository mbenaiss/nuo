import { existsSync, mkdirSync } from "node:fs";
import { extname, join, relative, resolve, sep } from "node:path";
import type { Attachment } from "../protocol";

export const MAX_IMAGE_BYTES = 10 * 1024 * 1024;
export const MAX_FILE_BYTES = 50 * 1024 * 1024;
export const IMAGE_MIMES = new Set(["image/jpeg", "image/png", "image/gif", "image/webp", "image/heic"]);
export const ATTACHMENTS_DIR = ".nuo/attachments";
const NAME_MAX = 120;

export interface DecodedAttachment {
  kind: "image" | "file";
  mime: string;
  name?: string;
  bytes: Buffer;
  dataBase64: string;
}

export interface SavedFile {
  path: string;
  mime: string;
  size: number;
}

/** Decodes and checks every attachment before anything is written, so a bad one rejects the whole prompt. */
export function decodeAttachments(list: unknown): DecodedAttachment[] {
  if (list === undefined || list === null) return [];
  if (!Array.isArray(list)) throw new Error("attachments must be an array");
  const out: DecodedAttachment[] = [];
  for (const raw of list as Partial<Attachment>[]) {
    if (!raw || (raw.kind !== "image" && raw.kind !== "file") || typeof raw.dataBase64 !== "string" || !raw.dataBase64) continue;
    const mime = typeof raw.mime === "string" && /^[\w.+-]+\/[\w.+-]+$/.test(raw.mime) ? raw.mime.toLowerCase() : "application/octet-stream";
    const name = typeof raw.name === "string" && raw.name.trim() ? raw.name.trim() : undefined;
    const bytes = Buffer.from(raw.dataBase64, "base64");
    if (bytes.length === 0) throw new Error("attachment is empty");
    if (raw.kind === "image") {
      if (!IMAGE_MIMES.has(mime)) throw new Error(`unsupported image type ${mime}`);
      if (bytes.length > MAX_IMAGE_BYTES) throw new Error("image is larger than 10 MB");
    } else if (bytes.length > MAX_FILE_BYTES) throw new Error("file is larger than 50 MB");
    out.push({ kind: raw.kind, mime, name, bytes, dataBase64: raw.dataBase64 });
  }
  return out;
}

/** A file name safe on any filesystem: no separators, control characters or leading dots. */
export function safeFileName(name: string | undefined): string {
  const base = (name ?? "").split(/[\\/]/).pop() ?? "";
  let clean = base
    .normalize("NFC")
    .replace(/[\u0000-\u001f\u007f<>:"|?*]/g, "_")
    .replace(/\s+/g, " ")
    .replace(/^[\s.]+/, "")
    .trim();
  if (!clean) clean = "fichier";
  if (clean.length > NAME_MAX) {
    const ext = extname(clean).slice(0, 12);
    clean = clean.slice(0, NAME_MAX - ext.length).trimEnd() + ext;
  }
  return clean;
}

const localDate = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;

/** Writes the file under `<workspace>/.nuo/attachments/<date>/`, adding " (2)", " (3)"… on collisions. */
export async function saveWorkspaceFile(workspace: string, name: string | undefined, bytes: Uint8Array, now = new Date()): Promise<string> {
  const root = resolve(workspace);
  const dir = join(root, ATTACHMENTS_DIR, localDate(now));
  mkdirSync(dir, { recursive: true });
  const safe = safeFileName(name);
  const ext = extname(safe);
  const stem = ext ? safe.slice(0, -ext.length) : safe;
  let path = join(dir, safe);
  for (let n = 2; existsSync(path); n++) path = join(dir, `${stem} (${n})${ext}`);
  const rel = relative(root, path);
  if (rel.startsWith("..") || rel.startsWith(sep)) throw new Error("invalid attachment name");
  await Bun.write(path, bytes);
  return path;
}

export function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

/** Appended to the agent's prompt only; the persisted message keeps the typed text. */
export function filesNote(files: SavedFile[]): string {
  if (!files.length) return "";
  const lines = files.map((f) => `- ${f.path} (${f.mime}, ${formatSize(f.size)})`);
  return `\n\n[Nuo] Files attached by the user, saved in your workspace (read them with your tools):\n${lines.join("\n")}`;
}
