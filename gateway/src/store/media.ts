import { mkdirSync } from "node:fs";
import { join } from "node:path";

const EXT: Record<string, string> = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/gif": "gif",
  "image/webp": "webp",
  "image/heic": "heic",
  "application/pdf": "pdf",
};

const ID_RE = /^[A-Za-z0-9_-]{1,128}\.[a-z0-9]{1,8}$/;
export const MAX_MEDIA_BYTES = 20 * 1024 * 1024;

export class MediaStore {
  constructor(readonly dir: string) {
    mkdirSync(dir, { recursive: true });
  }

  async saveBase64(mime: string, dataBase64: string): Promise<string> {
    const ext = EXT[mime];
    if (!ext) throw new Error(`unsupported attachment type ${mime}`);
    const bytes = Buffer.from(dataBase64, "base64");
    if (bytes.length === 0 || bytes.length > MAX_MEDIA_BYTES) throw new Error("attachment is empty or too large");
    const id = `${crypto.randomUUID()}.${ext}`;
    await Bun.write(join(this.dir, id), bytes);
    return id;
  }

  /** Any type of file; the extension comes from the mime type, else from the original name. */
  async saveBytes(mime: string, bytes: Uint8Array, name?: string): Promise<string> {
    const fromName = name?.match(/\.([A-Za-z0-9]{1,8})$/)?.[1]?.toLowerCase();
    const ext = EXT[mime] ?? fromName ?? "bin";
    const id = `${crypto.randomUUID()}.${ext}`;
    await Bun.write(join(this.dir, id), bytes);
    return id;
  }

  file(id: string) {
    return ID_RE.test(id) ? Bun.file(join(this.dir, id)) : undefined;
  }
}
