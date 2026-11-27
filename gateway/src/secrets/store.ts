import { randomBytes } from "node:crypto";
import { chmodSync, closeSync, existsSync, fsyncSync, lstatSync, openSync, readdirSync, readFileSync, realpathSync, renameSync, rmSync, writeSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";
import { HttpError } from "../bots/service";
import { deleteEntry, KEY_PATTERN, lastEntry, parseEnv, renderEnv, setEntry, type EnvDoc } from "./envfile";

export interface SecretsOptions {
  /** The folder of `KEY=value` files the machine's tools and services read (dev: ~/.secrets). */
  dir: string;
  /** Shown as `~` in paths. */
  home?: string;
  /**
   * Files the app may not see nor change: the gateway's own configuration (its auth key, its Cloudflare Access
   * secret, its local token). Names in the folder, and the files these paths resolve to (`~/nuo/config/env`).
   */
  exclude?: { names?: string[]; paths?: string[] };
}

export function secretsOptionsFromEnv(env: Record<string, string | undefined> = process.env, gatewayEnvFile?: string): SecretsOptions {
  const names = (env.NUO_SECRETS_EXCLUDE ?? "nuo.env").split(",").map((s) => s.trim()).filter(Boolean);
  return { dir: env.NUO_SECRETS_DIR || join(homedir(), ".secrets"), home: homedir(), exclude: { names, paths: gatewayEnvFile ? [gatewayEnvFile] : [] } };
}

/** One file, with the names of its variables only: values leave the gateway through `reveal` alone. */
export interface SecretSource {
  id: string;
  path: string;
  modifiedAt: string;
  /** Octal permissions; anything readable by group or others is flagged. */
  mode: string;
  insecure: boolean;
  /** From the folder's README table: the old path that links here and who reads the file. */
  link?: string;
  usedBy?: string;
  entries: { key: string; exported: boolean }[];
}

export interface SecretsList {
  configured: boolean;
  root: string;
  sources: SecretSource[];
}

const ENV_FILE = /(^\.env$|\.env$|\.env\.[A-Za-z0-9_-]+$|\.vars$)/;
const NEW_SOURCE = /^(?:([A-Za-z0-9][A-Za-z0-9_-]{0,40})\/)?([A-Za-z0-9][A-Za-z0-9_.-]{0,60}\.env)$/;
const MAX_FILE = 1024 * 1024;
export const MAX_VALUE = 16 * 1024;

function checkKey(key: unknown): string {
  if (typeof key !== "string" || key.length > 128 || !KEY_PATTERN.test(key)) throw new HttpError(400, "key must be a variable name (letters, digits and _, not starting with a digit)");
  return key;
}

/**
 * Variables that change how programs start rather than what they call: a value set here runs code in every
 * service that loads the file (dynamic loader, interpreters, shells) or redirects the gateway itself.
 */
const DANGEROUS_KEY = /^(LD_|DYLD_|BUN_|NODE_|GIT_|PYTHON|PERL|RUBY|NUO_)|^(BASH_ENV|ENV|PATH|PROMPT_COMMAND|SHELLOPTS|BASHOPTS|IFS|HOME|SHELL|USER|TMPDIR|ZDOTDIR|EDITOR|VISUAL|PAGER|SSL_CERT_FILE|SSL_CERT_DIR|HTTPS_PROXY|HTTP_PROXY|ALL_PROXY|NO_PROXY|https_proxy|http_proxy|all_proxy|no_proxy)$/;

function checkWritableKey(key: unknown): string {
  const k = checkKey(key);
  if (DANGEROUS_KEY.test(k)) throw new HttpError(400, "this variable changes how programs start: edit it on the machine itself");
  return k;
}

function checkValue(value: unknown): string {
  if (typeof value !== "string") throw new HttpError(400, "value must be a string");
  if (value.length > MAX_VALUE) throw new HttpError(400, "value is too long");
  if (/[\r\n\0]/.test(value)) throw new HttpError(400, "value must fit on one line");
  // Escape sequences and other control characters would be printed raw by every tool that shows the file.
  if (/[\x00-\x1f\x7f]/.test(value)) throw new HttpError(400, "value must not contain control characters");
  return value;
}

/**
 * The machine's secret files, edited in place. Only regular files found inside the folder are reachable (no
 * symlink, no path from the client), and every write replaces the file atomically with its permissions kept,
 * so a service reading it never sees half a file.
 */
export class SecretStore {
  constructor(private o: SecretsOptions) {}

  get root(): string {
    return this.o.dir;
  }

  get configured(): boolean {
    try {
      return lstatSync(this.o.dir).isDirectory();
    } catch {
      return false;
    }
  }

  private display(p: string): string {
    const home = this.o.home;
    return home && (p === home || p.startsWith(home + "/")) ? "~" + p.slice(home.length) : p;
  }

  /** Relative paths of the env files, in the folder and one level of subfolders, the excluded ones left out. */
  private sourceIds(): string[] {
    return this.allSourceIds().filter((id) => !this.excluded(id));
  }

  /** Every env file, the gateway's own included: the bots' output is masked against all of them. */
  allSourceIds(): string[] {
    if (!this.configured) return [];
    const files = (d: string) => readdirSync(d, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name));
    const top = files(this.o.dir);
    const ids = top.filter((d) => d.isFile() && ENV_FILE.test(d.name)).map((d) => d.name);
    for (const d of top) {
      if (!d.isDirectory() || d.name.startsWith(".")) continue;
      for (const f of files(join(this.o.dir, d.name))) if (f.isFile() && ENV_FILE.test(f.name)) ids.push(`${d.name}/${f.name}`);
    }
    return ids;
  }

  private excluded(id: string): boolean {
    const ex = this.o.exclude;
    if (!ex) return false;
    if (ex.names?.some((n) => n === id || n === basename(id))) return true;
    const real = (p: string) => {
      try {
        return realpathSync(p);
      } catch {
        return undefined;
      }
    };
    const here = real(join(this.o.dir, id));
    return !!here && !!ex.paths?.some((p) => real(p) === here);
  }

  /** The values of every file, for masking: never sent to a client. */
  allValues(): string[] {
    const out: string[] = [];
    for (const id of this.allSourceIds()) {
      try {
        for (const e of this.readDoc(join(this.o.dir, id)).entries) out.push(e.value);
      } catch {
        // unreadable file: nothing to mask from it
      }
    }
    return out;
  }

  private file(id: unknown): string {
    if (typeof id !== "string" || !this.sourceIds().includes(id)) throw new HttpError(404, "secret file not found");
    const p = join(this.o.dir, id);
    const st = lstatSync(p);
    if (!st.isFile()) throw new HttpError(404, "secret file not found");
    if (st.size > MAX_FILE) throw new HttpError(413, "secret file is too large");
    return p;
  }

  private readDoc(p: string): EnvDoc {
    return parseEnv(readFileSync(p, "utf8"));
  }

  private readme(): { pattern: RegExp; link?: string; usedBy?: string }[] {
    const p = join(this.o.dir, "README.md");
    try {
      if (!lstatSync(p).isFile()) return [];
      const rows: { pattern: RegExp; link?: string; usedBy?: string }[] = [];
      for (const line of readFileSync(p, "utf8").split("\n")) {
        if (!line.trim().startsWith("|")) continue;
        const cells = line.split("|").slice(1, -1).map((c) => c.trim().replace(/`/g, ""));
        const name = cells[0];
        if (!name || !/\.(env|vars)\b|\*/.test(name)) continue;
        const pattern = new RegExp("^" + name.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, "[^/]*") + "$");
        rows.push({ pattern, link: cells[1] || undefined, usedBy: cells[2] || undefined });
      }
      return rows;
    } catch {
      return [];
    }
  }

  private summary(id: string, notes = this.readme()): SecretSource {
    const p = join(this.o.dir, id);
    const st = lstatSync(p);
    const doc = this.readDoc(p);
    const seen = new Set<string>();
    const entries: SecretSource["entries"] = [];
    for (const e of doc.entries) {
      if (seen.has(e.key)) continue;
      seen.add(e.key);
      entries.push({ key: e.key, exported: lastEntry(doc, e.key)!.exported });
    }
    const note = notes.find((n) => n.pattern.test(id));
    const mode = st.mode & 0o777;
    return {
      id,
      path: this.display(p),
      modifiedAt: new Date(st.mtimeMs).toISOString(),
      mode: mode.toString(8).padStart(3, "0"),
      insecure: (mode & 0o077) !== 0,
      ...(note?.link ? { link: note.link } : {}),
      ...(note?.usedBy ? { usedBy: note.usedBy } : {}),
      entries,
    };
  }

  list(): SecretsList {
    const notes = this.readme();
    return { configured: this.configured, root: this.display(this.o.dir), sources: this.sourceIds().map((id) => this.summary(id, notes)) };
  }

  reveal(source: unknown, key: unknown): string {
    const entry = lastEntry(this.readDoc(this.file(source)), checkKey(key));
    if (!entry) throw new HttpError(404, "secret not found");
    return entry.value;
  }

  /** `createSource` makes a new empty file in the folder or one of its existing subfolders. */
  create(source: unknown, key: unknown, value: unknown, createSource = false): SecretSource {
    const k = checkWritableKey(key);
    const v = checkValue(value);
    if (createSource && typeof source === "string" && !this.sourceIds().includes(source)) {
      const p = this.newSourcePath(source);
      this.write(p, renderEnv(setEntry(parseEnv(""), k, v)), 0o600, true);
      return this.summary(source);
    }
    const p = this.file(source);
    const doc = this.readDoc(p);
    if (lastEntry(doc, k)) throw new HttpError(409, "this secret already exists in the file");
    this.write(p, renderEnv(setEntry(doc, k, v)), lstatSync(p).mode & 0o777);
    return this.summary(source as string);
  }

  update(source: unknown, key: unknown, value: unknown): SecretSource {
    const k = checkWritableKey(key);
    const v = checkValue(value);
    const p = this.file(source);
    const doc = this.readDoc(p);
    if (!lastEntry(doc, k)) throw new HttpError(404, "secret not found");
    this.write(p, renderEnv(setEntry(doc, k, v)), lstatSync(p).mode & 0o777);
    return this.summary(source as string);
  }

  delete(source: unknown, key: unknown): SecretSource {
    const k = checkKey(key);
    const p = this.file(source);
    const doc = this.readDoc(p);
    if (!lastEntry(doc, k)) throw new HttpError(404, "secret not found");
    this.write(p, renderEnv(deleteEntry(doc, k)), lstatSync(p).mode & 0o777);
    return this.summary(source as string);
  }

  private newSourcePath(id: string): string {
    if (!this.configured) throw new HttpError(503, "the secrets folder does not exist on the gateway");
    const m = id.match(NEW_SOURCE);
    if (!m) throw new HttpError(400, "file name must end in .env (letters, digits, . _ -), optionally in an existing subfolder");
    if (this.excluded(id)) throw new HttpError(400, "this file name is reserved for the gateway");
    if (m[1]) {
      const dir = join(this.o.dir, m[1]);
      if (!existsSync(dir) || !lstatSync(dir).isDirectory()) throw new HttpError(400, "subfolder not found");
    }
    const p = join(this.o.dir, id);
    if (existsSync(p)) throw new HttpError(409, "a file with this name already exists");
    return p;
  }

  private write(p: string, text: string, mode: number, fresh = false) {
    const tmp = join(dirname(p), `.${basename(p)}.${randomBytes(6).toString("hex")}.tmp`);
    try {
      const fd = openSync(tmp, "wx", mode);
      try {
        writeSync(fd, text);
        fsyncSync(fd);
      } finally {
        closeSync(fd);
      }
      // The umask may have narrowed the mode given to open.
      chmodSync(tmp, mode);
      if (fresh && existsSync(p)) throw new HttpError(409, "a file with this name already exists");
      renameSync(tmp, p);
    } catch (e) {
      rmSync(tmp, { force: true });
      throw e;
    }
  }
}
