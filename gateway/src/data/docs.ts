import { createHash } from "node:crypto";
import { existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, realpathSync, renameSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join, sep } from "node:path";
import { HttpError } from "../bots/service";
import type { DocNode } from "./types";

export const DOCS_AUTHOR = { name: "Nuo", email: "nuo@dev" };
const TRASH = ".trash";
/** Git does not track empty folders: a folder created from the app holds this hidden file. */
export const FOLDER_KEEP = ".keep";
const MAX_SEARCH = 50;
const MAX_FILE_BYTES = 5 * 1024 * 1024;
export const MAX_UPLOAD_BYTES = 50 * 1024 * 1024;
const MAX_PINS = 200;

/** Same id as `git hash-object`, so agents and the app agree on versions. */
export function blobSha(content: string | Buffer): string {
  const buf = typeof content === "string" ? Buffer.from(content) : content;
  return createHash("sha1").update(`blob ${buf.length}\0`).update(buf).digest("hex");
}

const gitEnv = () => ({
  ...process.env,
  GIT_AUTHOR_NAME: DOCS_AUTHOR.name,
  GIT_AUTHOR_EMAIL: DOCS_AUTHOR.email,
  GIT_COMMITTER_NAME: DOCS_AUTHOR.name,
  GIT_COMMITTER_EMAIL: DOCS_AUTHOR.email,
});

export function gitSync(dir: string, args: string[]): { ok: boolean; out: string } {
  const r = Bun.spawnSync(["git", ...args], { cwd: dir, env: gitEnv(), stdout: "pipe", stderr: "pipe" });
  return { ok: r.exitCode === 0, out: r.stdout.toString() + r.stderr.toString() };
}

/** Makes `dir` a git repository with a first commit (existing files included) when it is not one yet. */
export function initDocsRepo(dir: string): boolean {
  mkdirSync(dir, { recursive: true });
  if (existsSync(join(dir, ".git"))) return false;
  gitSync(dir, ["init", "-q", "-b", "main"]);
  const ignore = join(dir, ".gitignore");
  if (!existsSync(ignore)) writeFileSync(ignore, `${TRASH}/\n`);
  gitSync(dir, ["add", "-A"]);
  gitSync(dir, ["commit", "-q", "--allow-empty", "-m", "docs: Initial commit"]);
  return true;
}

/**
 * Copies an exported tree of Markdown pages and their media into the docs repo (never deletes) and commits
 * the result as one "docs(import)" commit.
 */
export function importDocsTree(src: string, docsDir: string, o: { dryRun?: boolean } = {}): { added: number; changed: number; unchanged: number; committed: boolean } {
  const out = { added: 0, changed: 0, unchanged: 0, committed: false };
  const walk = (rel: string) => {
    for (const name of readdirSync(join(src, rel)).sort()) {
      if (name === ".git" || name === TRASH || name === ".DS_Store") continue;
      const r = rel ? join(rel, name) : name;
      const st = lstatSync(join(src, r));
      if (st.isSymbolicLink()) continue;
      if (st.isDirectory()) {
        walk(r);
        continue;
      }
      const dest = join(docsDir, r);
      const data = readFileSync(join(src, r));
      if (existsSync(dest)) {
        if (readFileSync(dest).equals(data)) {
          out.unchanged++;
          continue;
        }
        out.changed++;
      } else out.added++;
      if (o.dryRun) continue;
      mkdirSync(dirname(dest), { recursive: true });
      writeFileSync(dest, data);
    }
  };
  walk("");
  if (!o.dryRun && out.added + out.changed > 0) {
    gitSync(docsDir, ["add", "-A"]);
    out.committed = gitSync(docsDir, ["commit", "-q", "-m", "docs(import): Import Notion pages"]).ok;
  }
  return out;
}

export class Docs {
  private queue: Promise<unknown> = Promise.resolve();

  /** Pinned paths live next to the repo, not in it: pinning is a preference of the apps, not a change of the docs. */
  readonly pinsFile: string;

  constructor(
    readonly dir: string,
    pinsFile?: string,
  ) {
    this.pinsFile = pinsFile ?? join(dirname(dir), "docs-pins.json");
  }

  /** Resolves a client path inside the docs folder; rejects traversal, .git and symlinks leaving the folder. */
  resolve(path: unknown, opts: { allowTrash?: boolean } = {}): { rel: string; abs: string } {
    if (typeof path !== "string" || !path.trim()) throw new HttpError(400, "path is required");
    if (/^[\\/]/.test(path)) throw new HttpError(400, "invalid path");
    const parts = path.replace(/\\/g, "/").split("/").filter((p) => p && p !== ".");
    if (!parts.length || parts.some((p) => p === ".." || p.includes("\0"))) throw new HttpError(400, "invalid path");
    if (parts[0] === ".git" || (!opts.allowTrash && parts[0] === TRASH)) throw new HttpError(400, "invalid path");
    const rel = parts.join("/");
    const abs = join(this.dir, ...parts);
    const root = realpathSync(this.dir);
    let probe = abs;
    while (!existsSync(probe)) probe = dirname(probe);
    const real = realpathSync(probe);
    if (real !== root && !real.startsWith(root + sep)) throw new HttpError(400, "invalid path");
    return { rel, abs };
  }

  private serial<T>(fn: () => Promise<T> | T): Promise<T> {
    const next = this.queue.then(fn, fn);
    this.queue = next.catch(() => {});
    return next;
  }

  private commit(paths: string[], message: string) {
    // A pathspec matching nothing (a folder that was never committed and is now gone) makes add and commit fail.
    const known = paths.filter((p) => existsSync(join(this.dir, p)) || gitSync(this.dir, ["ls-files", "--", p]).out.trim() !== "");
    if (!known.length) return;
    gitSync(this.dir, ["add", "-A", "--", ...known]);
    const r = gitSync(this.dir, ["commit", "-q", "-m", message, "--", ...known]);
    if (!r.ok && !/nothing (added )?to commit|no changes added/.test(r.out)) console.warn(`[docs] commit failed: ${r.out.trim()}`);
  }

  tree(): DocNode[] {
    const out: DocNode[] = [];
    const walk = (abs: string, rel: string) => {
      for (const name of readdirSync(abs).sort()) {
        if (name === ".git" || name === TRASH || name === ".gitignore" || name === FOLDER_KEEP) continue;
        const a = join(abs, name);
        const r = rel ? `${rel}/${name}` : name;
        const st = lstatSync(a);
        if (st.isSymbolicLink()) continue;
        if (st.isDirectory()) {
          out.push({ path: r, name, kind: "dir", updatedAt: st.mtime.toISOString(), size: 0 });
          walk(a, r);
        } else if (st.isFile()) {
          out.push({ path: r, name, kind: "file", updatedAt: st.mtime.toISOString(), size: st.size });
        }
      }
    };
    if (existsSync(this.dir)) walk(this.dir, "");
    return out;
  }

  read(path: unknown): { path: string; content: string; sha: string; updatedAt: string } {
    const { rel, abs } = this.resolve(path);
    if (!existsSync(abs) || !statSync(abs).isFile()) throw new HttpError(404, "document not found");
    const buf = readFileSync(abs);
    return { path: rel, content: buf.toString("utf8"), sha: blobSha(buf), updatedAt: statSync(abs).mtime.toISOString() };
  }

  /** Any file of the repo (images referenced by Markdown), streamed as is. */
  raw(path: unknown): { file: ReturnType<typeof Bun.file>; etag: string } {
    const { abs } = this.resolve(path);
    if (!existsSync(abs) || !statSync(abs).isFile()) throw new HttpError(404, "file not found");
    const st = statSync(abs);
    return { file: Bun.file(abs), etag: `"${st.size.toString(16)}-${Math.floor(st.mtimeMs).toString(16)}"` };
  }

  write(path: unknown, content: unknown, baseSha?: unknown): Promise<{ path: string; sha: string; updatedAt: string }> {
    if (typeof content !== "string") throw new HttpError(400, "content must be a string");
    if (Buffer.byteLength(content) > MAX_FILE_BYTES) throw new HttpError(413, "document too large");
    const { rel, abs } = this.resolve(path);
    return this.serial(() => {
      const exists = existsSync(abs);
      if (exists && !statSync(abs).isFile()) throw new HttpError(400, "path is a folder");
      if (typeof baseSha === "string" && baseSha) {
        const current = exists ? blobSha(readFileSync(abs)) : undefined;
        if (current !== baseSha) throw new HttpError(409, "the document changed since it was read");
      }
      mkdirSync(dirname(abs), { recursive: true });
      writeFileSync(abs, content);
      this.commit([rel], `docs(app): ${exists ? "Update" : "Create"} ${rel}`);
      return { path: rel, sha: blobSha(content), updatedAt: statSync(abs).mtime.toISOString() };
    });
  }

  /**
   * Stores a binary file (image, PDF, any attachment) at `path`, or next to it under a free name
   * (`photo-2.png`) when the path is taken: an upload never overwrites.
   */
  upload(path: unknown, data: Uint8Array): Promise<{ path: string; size: number }> {
    if (data.byteLength > MAX_UPLOAD_BYTES) throw new HttpError(413, "file too large");
    const { rel } = this.resolve(path);
    if (/\.md$/i.test(rel)) throw new HttpError(400, "use /api/docs/file for Markdown documents");
    return this.serial(() => {
      const dot = rel.lastIndexOf(".");
      const slash = rel.lastIndexOf("/");
      const [stem, ext] = dot > slash + 1 ? [rel.slice(0, dot), rel.slice(dot)] : [rel, ""];
      let candidate = rel;
      for (let n = 2; existsSync(this.resolve(candidate).abs); n++) candidate = `${stem}-${n}${ext}`;
      const { abs } = this.resolve(candidate);
      mkdirSync(dirname(abs), { recursive: true });
      writeFileSync(abs, data);
      this.commit([candidate], `docs(app): Add ${candidate}`);
      return { path: candidate, size: data.byteLength };
    });
  }

  create(path: unknown, content: unknown): Promise<{ path: string; sha: string; updatedAt: string }> {
    const { abs } = this.resolve(path);
    if (existsSync(abs)) throw new HttpError(409, "a document already exists at this path");
    return this.write(path, content ?? "");
  }

  /** Moves the file to .trash/ (ignored by git); the deletion is committed, so history keeps the content. */
  remove(path: unknown): Promise<void> {
    const { rel, abs } = this.resolve(path);
    return this.serial(() => {
      if (!existsSync(abs) || !statSync(abs).isFile()) throw new HttpError(404, "document not found");
      let dest = join(this.dir, TRASH, rel);
      if (existsSync(dest)) dest = join(dirname(dest), `${Date.now()}-${basename(dest)}`);
      mkdirSync(dirname(dest), { recursive: true });
      renameSync(abs, dest);
      this.commit([rel], `docs(app): Delete ${rel}`);
      this.updatePins((p) => (p === rel ? undefined : p));
    });
  }

  /**
   * Moves (or renames) a file or a folder as is: relative links and media paths inside moved documents are not
   * rewritten. Never overwrites; missing parent folders are created.
   */
  move(from: unknown, to: unknown): Promise<{ path: string; kind: "dir" | "file" }> {
    const src = this.resolve(from);
    const dest = this.resolve(to);
    return this.serial(() => {
      if (!existsSync(src.abs)) throw new HttpError(404, "document not found");
      const kind = statSync(src.abs).isDirectory() ? "dir" : "file";
      if (dest.rel === src.rel) return { path: src.rel, kind };
      if (kind === "dir" && dest.rel.startsWith(src.rel + "/")) throw new HttpError(400, "cannot move a folder into itself");
      if (existsSync(dest.abs)) throw new HttpError(409, "an item already exists at this path");
      const parent = dirname(dest.abs);
      if (existsSync(parent) && !statSync(parent).isDirectory()) throw new HttpError(400, "the destination folder is a file");
      mkdirSync(parent, { recursive: true });
      renameSync(src.abs, dest.abs);
      const kept = this.keepIfEmpty(dirname(src.rel));
      this.commit([src.rel, dest.rel, ...kept], `docs(app): Move ${src.rel} → ${dest.rel}`);
      this.updatePins((p) => (p === src.rel ? dest.rel : p.startsWith(src.rel + "/") ? dest.rel + p.slice(src.rel.length) : p));
      return { path: dest.rel, kind };
    });
  }

  createFolder(path: unknown): Promise<{ path: string }> {
    const { rel, abs } = this.resolve(path);
    return this.serial(() => {
      if (existsSync(abs)) throw new HttpError(409, "an item already exists at this path");
      const parent = dirname(abs);
      if (existsSync(parent) && !statSync(parent).isDirectory()) throw new HttpError(400, "the parent folder is a file");
      mkdirSync(abs, { recursive: true });
      writeFileSync(join(abs, FOLDER_KEEP), "");
      this.commit([rel], `docs(app): Create folder ${rel}`);
      return { path: rel };
    });
  }

  /** Moves the whole folder to .trash/, like `remove` for a file. */
  removeFolder(path: unknown): Promise<void> {
    const { rel, abs } = this.resolve(path);
    return this.serial(() => {
      if (!existsSync(abs) || !statSync(abs).isDirectory()) throw new HttpError(404, "folder not found");
      let dest = join(this.dir, TRASH, rel);
      if (existsSync(dest)) dest = join(dirname(dest), `${Date.now()}-${basename(dest)}`);
      mkdirSync(dirname(dest), { recursive: true });
      renameSync(abs, dest);
      const kept = this.keepIfEmpty(dirname(rel));
      this.commit([rel, ...kept], `docs(app): Delete folder ${rel}`);
      this.updatePins((p) => (p === rel || p.startsWith(rel + "/") ? undefined : p));
    });
  }

  /** Pinned files and folders in the user's order; entries whose target vanished (an agent deleted it) are skipped. */
  pins(): { paths: string[] } {
    return { paths: this.readPins().filter((p) => existsSync(join(this.dir, p))) };
  }

  setPins(paths: unknown): Promise<{ paths: string[] }> {
    if (!Array.isArray(paths)) throw new HttpError(400, "paths must be an array");
    if (paths.length > MAX_PINS) throw new HttpError(400, `at most ${MAX_PINS} pins`);
    const rels = [...new Set(paths.map((p) => this.resolve(p).rel))];
    return this.serial(() => {
      this.writePins(rels);
      return this.pins();
    });
  }

  private readPins(): string[] {
    try {
      const v = JSON.parse(readFileSync(this.pinsFile, "utf8"));
      return Array.isArray(v?.paths) ? v.paths.filter((p: unknown): p is string => typeof p === "string") : [];
    } catch {
      return [];
    }
  }

  private writePins(paths: string[]) {
    mkdirSync(dirname(this.pinsFile), { recursive: true });
    const tmp = `${this.pinsFile}.tmp`;
    writeFileSync(tmp, JSON.stringify({ paths }, null, 2) + "\n");
    renameSync(tmp, this.pinsFile);
  }

  private updatePins(map: (path: string) => string | undefined) {
    const before = this.readPins();
    const after = [...new Set(before.map(map).filter((p): p is string => !!p))];
    if (after.join("\n") !== before.join("\n")) this.writePins(after);
  }

  /** A folder emptied by a move or a deletion stays in the tree, as in a file manager. */
  private keepIfEmpty(rel: string): string[] {
    if (rel === "." || rel === "") return [];
    const abs = join(this.dir, rel);
    if (!existsSync(abs) || readdirSync(abs).length) return [];
    writeFileSync(join(abs, FOLDER_KEEP), "");
    return [`${rel}/${FOLDER_KEEP}`];
  }

  async search(q: string): Promise<{ path: string; line: number; snippet: string }[]> {
    const term = q.trim();
    if (!term) return [];
    const rg = Bun.which("rg");
    if (rg) {
      const proc = Bun.spawn([rg, "--json", "-i", "-F", "--max-count", "5", "--glob", "!.git", "--glob", `!${TRASH}`, "--", term, "."], { cwd: this.dir, stdout: "pipe", stderr: "ignore" });
      const text = await new Response(proc.stdout).text();
      await proc.exited;
      const out: { path: string; line: number; snippet: string }[] = [];
      for (const l of text.split("\n")) {
        if (out.length >= MAX_SEARCH) break;
        if (!l.startsWith('{"type":"match"')) continue;
        const m = JSON.parse(l).data;
        const p = String(m.path?.text ?? "").replace(/^\.\//, "");
        out.push({ path: p, line: m.line_number, snippet: snippet(String(m.lines?.text ?? ""), term) });
      }
      return out;
    }
    const out: { path: string; line: number; snippet: string }[] = [];
    const lower = term.toLowerCase();
    for (const n of this.tree()) {
      if (n.kind !== "file" || n.size > MAX_FILE_BYTES) continue;
      const lines = readFileSync(join(this.dir, n.path), "utf8").split("\n");
      for (let i = 0; i < lines.length && out.length < MAX_SEARCH; i++) {
        if (lines[i]!.toLowerCase().includes(lower)) out.push({ path: n.path, line: i + 1, snippet: snippet(lines[i]!, term) });
      }
      if (out.length >= MAX_SEARCH) break;
    }
    return out;
  }
}

function snippet(line: string, term: string): string {
  const text = line.replace(/\s+$/, "");
  if (text.length <= 160) return text;
  const i = Math.max(0, text.toLowerCase().indexOf(term.toLowerCase()) - 60);
  return (i > 0 ? "…" : "") + text.slice(i, i + 160) + (i + 160 < text.length ? "…" : "");
}
