import { Database } from "bun:sqlite";
import { existsSync, mkdirSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";

export const SCHEMA_DIR = new URL("./schema", import.meta.url).pathname;
export const NOW_SQL = "strftime('%Y-%m-%dT%H:%M:%fZ','now')";
const IDENT = /^[a-z_][a-z0-9_]*$/;
/**
 * First line of a migration that creates the owner's own collections: another profile starts without them and
 * makes its own. Such files are not shipped; a private deployment adds them next to the shared ones.
 */
export const OWNER_ONLY_MARKER = "-- owner-only";

export function ident(name: string): string {
  if (!IDENT.test(name)) throw new Error(`invalid SQL identifier "${name}"`);
  return `"${name}"`;
}

/** Opens data.db and brings it to the latest schema; history triggers are regenerated every time. */
export function openDataDb(path: string, schemaDirs: SchemaDirs = SCHEMA_DIR, ownerCollections = true): Database {
  mkdirSync(dirname(path), { recursive: true });
  const db = new Database(path, { create: true, strict: true });
  // NORMAL in WAL mode only syncs at checkpoints: a power cut can lose the last commits, never corrupt the file.
  db.exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;");
  migrate(db, schemaDirs, ownerCollections);
  regenerateTriggers(db);
  return db;
}

/** One schema folder, or several whose files are applied together in name order. */
export type SchemaDirs = string | readonly string[];

function migrationFiles(schemaDirs: SchemaDirs): Map<string, string> {
  const files = new Map<string, string>();
  for (const dir of typeof schemaDirs === "string" ? [schemaDirs] : schemaDirs) {
    if (!existsSync(dir)) continue;
    for (const f of readdirSync(dir).filter((f) => f.endsWith(".sql"))) {
      if (files.has(f)) throw new Error(`migration ${f} found twice (${files.get(f)}, ${join(dir, f)})`);
      files.set(f, join(dir, f));
    }
  }
  return new Map([...files].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)));
}

/**
 * Applies the migrations not yet recorded in `_migrations`, by file name. A missing owner-only file is simply never
 * applied, and one already applied is skipped when it comes back, so a database keeps working with or without them.
 */
export function migrate(db: Database, schemaDirs: SchemaDirs = SCHEMA_DIR, ownerCollections = true): string[] {
  db.exec("CREATE TABLE IF NOT EXISTS _migrations (name TEXT PRIMARY KEY, applied_at TEXT NOT NULL)");
  const done = new Set((db.query("SELECT name FROM _migrations").all() as { name: string }[]).map((r) => r.name));
  const applied: string[] = [];
  for (const [file, path] of migrationFiles(schemaDirs)) {
    if (done.has(file)) continue;
    const sql = readFileSync(path, "utf8");
    if (!ownerCollections && sql.startsWith(OWNER_ONLY_MARKER)) continue;
    db.transaction(() => {
      db.exec(sql);
      db.query(`INSERT INTO _migrations (name, applied_at) VALUES (?, ${NOW_SQL})`).run(file);
    })();
    applied.push(file);
  }
  return applied;
}

export function tableColumns(db: Database, table: string): string[] {
  return (db.query(`PRAGMA table_info(${ident(table)})`).all() as { name: string }[]).map((r) => r.name);
}

const SUMMARY_SKIP = new Set(["_context", "_history", "_migrations"]);

/**
 * One line per table and view, for the bots' instructions: without it they spend a tool round trip or more
 * reading the schema before every data question. A `v_<table>` view lists only the columns it adds.
 */
export function schemaSummary(path: string): string {
  let db: Database;
  try {
    db = new Database(path, { readonly: true });
  } catch {
    return "";
  }
  try {
    const objects = db.query("SELECT type, name FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY name").all() as { type: string; name: string }[];
    const columns = new Map<string, string[]>();
    for (const o of objects) if (!SUMMARY_SKIP.has(o.name) && IDENT.test(o.name)) columns.set(o.name, tableColumns(db, o.name));
    const lines: string[] = [];
    for (const o of objects) {
      const cols = columns.get(o.name);
      if (!cols) continue;
      const base = o.type === "view" && o.name.startsWith("v_") ? columns.get(o.name.slice(2)) : undefined;
      if (base) {
        const added = cols.filter((c) => !base.includes(c));
        lines.push(`${o.name} = ${o.name.slice(2)}${added.length ? ` + ${added.join(", ")}` : ""}`);
      } else {
        lines.push(`${o.name}${o.type === "view" ? " (vue)" : ""} : ${cols.join(", ")}`);
      }
    }
    return lines.join("\n");
  } catch {
    return "";
  } finally {
    db.close();
  }
}

/** Every table whose changes are recorded: collections, their link tables, reminders and what organises them. */
export function historyTables(db: Database): string[] {
  const rows = db.query("SELECT table_name FROM _collections ORDER BY position, id").all() as { table_name: string }[];
  const links = db.query("SELECT DISTINCT table_name FROM _links ORDER BY table_name").all() as { table_name: string }[];
  const extra = (db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('reminders', 'places', 'areas', 'projects', 'project_headings')").all() as { name: string }[]).map((r) => r.name);
  return [...new Set([...rows.map((r) => r.table_name), ...links.map((r) => r.table_name), ...extra])];
}

/**
 * (Re)creates, for every recorded table, the history triggers (insert/update/delete into _history with
 * old/new rows as JSON and the source from _context) and a trigger that bumps updated_at when a writer
 * (typically an agent with sqlite3) forgot it. Run again after adding a column or a collection.
 */
export function regenerateTriggers(db: Database): void {
  db.transaction(() => {
    const existing = db.query("SELECT name FROM sqlite_master WHERE type = 'trigger' AND (name LIKE '\\_h\\_%' ESCAPE '\\' OR name LIKE '\\_touch\\_%' ESCAPE '\\')").all() as {
      name: string;
    }[];
    for (const t of existing) db.exec(`DROP TRIGGER IF EXISTS "${t.name}"`);
    for (const table of historyTables(db)) {
      const cols = tableColumns(db, table);
      if (!cols.length) continue;
      const t = ident(table);
      const obj = (alias: "NEW" | "OLD") => `json_object(${cols.map((c) => `'${c}', ${alias}.${ident(c)}`).join(", ")})`;
      const changed = cols.filter((c) => c !== "updated_at").map((c) => `OLD.${ident(c)} IS NOT NEW.${ident(c)}`).join(" OR ") || "0";
      const source = "(SELECT coalesce(source, 'agent') FROM _context WHERE id = 1)";
      const ctxOp = "(SELECT op FROM _context WHERE id = 1)";
      const updateOp = cols.includes("archived_at")
        ? `coalesce(${ctxOp}, CASE WHEN OLD.archived_at IS NULL AND NEW.archived_at IS NOT NULL THEN 'archive' WHEN OLD.archived_at IS NOT NULL AND NEW.archived_at IS NULL THEN 'unarchive' ELSE 'update' END)`
        : `coalesce(${ctxOp}, 'update')`;
      db.exec(`CREATE TRIGGER "_h_${table}_insert" AFTER INSERT ON ${t} BEGIN
        INSERT INTO _history (table_name, row_id, op, old_json, new_json, source)
        VALUES ('${table}', NEW.id, coalesce(${ctxOp}, 'insert'), NULL, ${obj("NEW")}, ${source});
      END`);
      db.exec(`CREATE TRIGGER "_h_${table}_update" AFTER UPDATE ON ${t} WHEN ${changed} BEGIN
        INSERT INTO _history (table_name, row_id, op, old_json, new_json, source)
        VALUES ('${table}', NEW.id, ${updateOp}, ${obj("OLD")}, ${obj("NEW")}, ${source});
      END`);
      db.exec(`CREATE TRIGGER "_h_${table}_delete" AFTER DELETE ON ${t} BEGIN
        INSERT INTO _history (table_name, row_id, op, old_json, new_json, source)
        VALUES ('${table}', OLD.id, coalesce(${ctxOp}, 'delete'), ${obj("OLD")}, NULL, ${source});
      END`);
      if (cols.includes("updated_at")) {
        db.exec(`CREATE TRIGGER "_touch_${table}" AFTER UPDATE ON ${t} WHEN NEW.updated_at IS OLD.updated_at AND (${changed}) BEGIN
          UPDATE ${t} SET updated_at = ${NOW_SQL} WHERE id = NEW.id;
        END`);
      }
    }
  })();
}

/**
 * Moves on every commit, whoever made it: `total_changes()` counts this connection's writes and `data_version` the
 * commits of other connections (agents with sqlite3). Caches of data.db content are keyed on it.
 */
export function changeVersion(db: Database): string {
  return (db.query("SELECT (SELECT data_version FROM pragma_data_version) || ':' || total_changes() AS v").get() as { v: string }).v;
}

/** Runs `fn` in a transaction whose changes are recorded with source `app` (and `op` when given). */
export function asApp<T>(db: Database, fn: () => T, op?: "revert"): T {
  return db.transaction(() => {
    db.query("UPDATE _context SET source = 'app', op = ? WHERE id = 1").run(op ?? null);
    try {
      return fn();
    } finally {
      db.exec("UPDATE _context SET source = NULL, op = NULL WHERE id = 1");
    }
  })();
}
