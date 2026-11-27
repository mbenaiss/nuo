import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type { BotMemory } from "../protocol";
import { HttpError } from "./service";

export const MEMORY_FILE = "MEMORY.md";
export const MAX_MEMORY_BYTES = 64 * 1024;
export const MAX_FACT_CHARS = 500;
/** What goes into the instructions: the agent reads them on every session start. */
export const INJECTED_MEMORY_BYTES = 8 * 1024;

export class MemoryStore {
  constructor(private dir: string) {}

  path(slug: string) {
    return join(this.dir, slug, MEMORY_FILE);
  }

  read(slug: string): BotMemory {
    const p = this.path(slug);
    if (!existsSync(p)) return { content: "" };
    return { content: readFileSync(p, "utf8"), updatedAt: statSync(p).mtime.toISOString() };
  }

  write(slug: string, content: unknown): BotMemory {
    if (typeof content !== "string") throw new HttpError(400, "content must be a string");
    const text = content.trim() ? content.trimEnd() + "\n" : "";
    if (Buffer.byteLength(text) > MAX_MEMORY_BYTES) throw new HttpError(400, `memory is limited to ${MAX_MEMORY_BYTES / 1024} KB`);
    const p = this.path(slug);
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, text);
    return this.read(slug);
  }

  add(slug: string, fact: unknown, now = new Date()): BotMemory {
    const line = typeof fact === "string" ? fact.replace(/\s+/g, " ").trim() : "";
    if (!line) throw new HttpError(400, "fact must be a non-empty string");
    if (line.length > MAX_FACT_CHARS) throw new HttpError(400, `fact is limited to ${MAX_FACT_CHARS} characters`);
    const current = this.read(slug).content;
    const sep = current && !current.endsWith("\n") ? "\n" : "";
    return this.write(slug, `${current}${sep}- ${now.toISOString().slice(0, 10)} ${line}\n`);
  }
}

/** Keeps the newest lines (the end of the file) within the byte budget. */
export function memoryExcerpt(content: string, maxBytes = INJECTED_MEMORY_BYTES): string {
  const text = content.trim();
  if (Buffer.byteLength(text) <= maxBytes) return text;
  const lines = text.split("\n");
  const kept: string[] = [];
  let size = 0;
  for (let i = lines.length - 1; i >= 0; i--) {
    const n = Buffer.byteLength(lines[i]!) + 1;
    if (size + n > maxBytes) break;
    kept.unshift(lines[i]!);
    size += n;
  }
  return kept.join("\n");
}
