import { Database } from "bun:sqlite";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

export const OWNER = "owner";
/** Slugs name folders, Linux users (`nuo-<slug>`) and sudoers files: short, lowercase, no dots. */
export const PROFILE_SLUG = /^[a-z][a-z0-9-]{1,23}$/;

export interface Profile {
  id: string;
  name: string;
  createdAt: string;
  disabledAt?: string;
  /** Command tasks run as the profile's Linux user; off unless the owner turns them on. */
  allowCommands: boolean;
}

export interface PairFailure {
  at: number;
  ip: string;
  /** Normalized profile name as typed, existing or not. */
  key: string;
}

/** What the person types at pairing: case, accents and spacing do not matter. */
export function profileKey(typed: string): string {
  return typed
    .normalize("NFKD")
    .replace(/\p{M}/gu, "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 64);
}

type Row = Record<string, any>;
const toProfile = (r: Row): Profile => ({
  id: r.id,
  name: r.name,
  createdAt: r.created_at,
  ...(r.disabled_at ? { disabledAt: r.disabled_at } : {}),
  allowCommands: !!r.allow_commands,
});

/**
 * The list of profiles and the pairing failures of all of them (lockouts count across profiles, by IP and by
 * typed name). Separate from the profiles' own databases, which never reference each other.
 */
export class Registry {
  readonly db: Database;

  constructor(path: string) {
    mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    this.db = new Database(path, { create: true, strict: true });
    this.db.exec("PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000;");
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS profiles (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        created_at TEXT NOT NULL,
        disabled_at TEXT,
        allow_commands INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS pair_failures (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        at INTEGER NOT NULL,
        ip TEXT NOT NULL,
        key TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS pair_failures_at ON pair_failures(at);
    `);
  }

  close() {
    this.db.close();
  }

  list(): Profile[] {
    return (this.db.query("SELECT * FROM profiles ORDER BY created_at, id").all() as Row[]).map(toProfile);
  }

  get(id: string): Profile | undefined {
    const r = this.db.query("SELECT * FROM profiles WHERE id = ?").get(id) as Row | null;
    return r ? toProfile(r) : undefined;
  }

  /** The profile a typed name designates (its slug or its display name), enabled or not. */
  find(typed: string): Profile | undefined {
    const key = profileKey(typed);
    if (!key) return undefined;
    return this.list().find((p) => p.id === key || profileKey(p.name) === key);
  }

  create(id: string, name: string): Profile {
    if (!PROFILE_SLUG.test(id)) throw new Error(`invalid profile id "${id}": 2-24 characters, a-z, 0-9 and "-", starting with a letter`);
    const clean = name.trim().slice(0, 60) || id;
    const clash = this.find(clean) ?? this.find(id);
    if (clash) throw new Error(`profile "${clash.id}" already uses this id or name`);
    this.db.query("INSERT INTO profiles (id, name, created_at) VALUES (?, ?, ?)").run(id, clean, new Date().toISOString());
    return this.get(id)!;
  }

  /** The owner row is created once, by the layout migration; its name can be changed like any other. */
  ensureOwner(name = "Owner"): Profile {
    this.db.query("INSERT OR IGNORE INTO profiles (id, name, created_at) VALUES (?, ?, ?)").run(OWNER, name, new Date().toISOString());
    return this.get(OWNER)!;
  }

  rename(id: string, name: string) {
    const clean = name.trim().slice(0, 60);
    if (!clean) throw new Error("name is empty");
    const clash = this.find(clean);
    if (clash && clash.id !== id) throw new Error(`profile "${clash.id}" already uses this name`);
    this.db.query("UPDATE profiles SET name = ? WHERE id = ?").run(clean, id);
  }

  setDisabled(id: string, disabled: boolean) {
    if (id === OWNER && disabled) throw new Error("the owner profile cannot be disabled");
    this.db.query("UPDATE profiles SET disabled_at = ? WHERE id = ?").run(disabled ? new Date().toISOString() : null, id);
  }

  setAllowCommands(id: string, allow: boolean) {
    this.db.query("UPDATE profiles SET allow_commands = ? WHERE id = ?").run(allow ? 1 : 0, id);
  }

  remove(id: string) {
    if (id === OWNER) throw new Error("the owner profile cannot be deleted");
    this.db.query("DELETE FROM profiles WHERE id = ?").run(id);
  }

  recordPairFailure(f: PairFailure) {
    this.db.query("INSERT INTO pair_failures (at, ip, key) VALUES (?, ?, ?)").run(f.at, f.ip, f.key);
    this.db.query("DELETE FROM pair_failures WHERE at < ?").run(f.at - 24 * 3600 * 1000);
  }

  pairFailures(since: number): PairFailure[] {
    return this.db.query("SELECT at, ip, key FROM pair_failures WHERE at > ? ORDER BY at").all(since) as PairFailure[];
  }
}
