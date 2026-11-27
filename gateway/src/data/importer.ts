import type { Database } from "bun:sqlite";
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { ident, NOW_SQL, regenerateTriggers, tableColumns } from "./db";
import { isSafeRelative, loadCollections, type CollectionMeta, type ColumnMeta } from "./store";
import type { ColumnType, SelectOption } from "./types";

/** One file of a Notion export. */
export interface ExportFile {
  slug: string;
  name: string;
  icon?: string | null;
  notion_id?: string;
  properties: { name: string; type: string; config?: Record<string, any> }[];
  rows: { notion_id: string; created_at?: string; updated_at?: string; properties: Record<string, unknown> }[];
}

export interface ImportOptions {
  /** Root that export file paths (`files/<slug>/…`) are relative to; defaults to `<dir>/..`. */
  filesRoot?: string;
  /** data/files of the layout. */
  filesDir: string;
  dryRun?: boolean;
  log?: (line: string) => void;
}

export interface ImportReport {
  collections: {
    slug: string;
    collection: string;
    created: boolean;
    rows: number;
    inserted: number;
    updated: number;
    unchanged: number;
    ignored: string[];
    files: number;
    missingFiles: number;
    /** relation values with several rows stored in a single foreign key (only the first is kept) */
    truncatedRelations: number;
    mismatches: { column: string; count: number; examples: string[] }[];
  }[];
  ddl: string[];
  links?: { table: string; added: number; removed: number }[];
}

const RESERVED = new Set(["id", "notion_id", "created_at", "updated_at", "archived_at"]);
const STANDARD_COLUMNS = `id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
  notion_id TEXT UNIQUE`;
const TIMESTAMPS = `created_at TEXT NOT NULL DEFAULT (${NOW_SQL}),
  updated_at TEXT NOT NULL DEFAULT (${NOW_SQL}),
  archived_at TEXT`;

class DryRun extends Error {}

export function snake(s: string): string {
  const out = s
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/€/g, "eur")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");
  if (!out) return "col";
  return /^[0-9]/.test(out) ? `c_${out}` : out;
}

export function readExportDir(dir: string): ExportFile[] {
  return readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .sort()
    .map((f) => {
      const raw = JSON.parse(readFileSync(join(dir, f), "utf8"));
      if (!raw || typeof raw.slug !== "string" || !Array.isArray(raw.properties) || !Array.isArray(raw.rows)) throw new Error(`${f}: not a database export`);
      return raw as ExportFile;
    });
}

const dateStart = (v: unknown): string | null => {
  if (v && typeof v === "object" && "start" in (v as object)) return ((v as { start?: string | null }).start ?? null) || null;
  return typeof v === "string" && v ? v : null;
};

const isPercentFormatted = (p: ExportFile["properties"][number]) => p.config?.format === "percent" || p.config?.number_format === "percent";

const dateEnd = (v: unknown): string | null =>
  v && typeof v === "object" && "end" in (v as object) ? ((v as { end?: string | null }).end ?? null) || null : null;

/** Column type for a Notion property of an export without a hand-written schema. */
function inferType(p: ExportFile["properties"][number], values: unknown[]): ColumnType | undefined {
  const fmt = p.config?.format;
  switch (p.type) {
    case "title":
      return "text";
    case "text":
      return values.some((v) => typeof v === "string" && (v.length > 200 || v.includes("\n"))) ? "longtext" : "text";
    case "number":
      return fmt === "euro" ? "money" : isPercentFormatted(p) ? "percent" : "number";
    case "select":
    case "status":
      return "select";
    case "multi_select":
      return "multiselect";
    case "date":
      return values.map(dateStart).some((s) => s && s.length > 10) ? "datetime" : "date";
    case "checkbox":
      return "bool";
    case "url":
      return "url";
    case "files":
      return "file";
    case "relation":
      return "ref";
    case "formula": {
      const v = values.find((x) => x !== null && x !== undefined && x !== "");
      if (typeof v === "number") return fmt === "euro" ? "money" : fmt === "percent" ? "percent" : "number";
      if (typeof v === "boolean") return "bool";
      if (v && typeof v === "object" && "start" in (v as object)) return "date";
      return "text";
    }
    default:
      return undefined;
  }
}

function sqlColumn(name: string, type: ColumnType, refTable?: string): string {
  const c = ident(name);
  switch (type) {
    case "number":
    case "money":
    case "percent":
      return `${c} REAL`;
    case "bool":
      return `${c} INTEGER NOT NULL DEFAULT 0 CHECK (${c} IN (0,1))`;
    case "date":
      return `${c} TEXT CHECK (${c} IS NULL OR date(${c}) IS ${c})`;
    case "datetime":
      return `${c} TEXT CHECK (${c} IS NULL OR julianday(${c}) IS NOT NULL)`;
    case "multiselect":
    case "file":
      return `${c} TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(${c}) AND json_type(${c}) = 'array')`;
    case "ref":
      return `${c} TEXT${refTable ? ` REFERENCES ${ident(refTable)}(id)` : ""}`;
    default:
      return `${c} TEXT`;
  }
}

interface LinkSide {
  collection_id: string;
  column_name: string;
  table_name: string;
  from_column: string;
  to_column: string;
  notion_name: string;
}

interface Plan {
  file: ExportFile;
  collection: CollectionMeta;
  created: boolean;
  /** [export property name, column, take the end of a date range] */
  mapping: [string, ColumnMeta, boolean][];
  links: LinkSide[];
  ignored: string[];
}

/** Designs a table, its view and its metadata for an export that has no hand-written schema. */
function autoSchema(db: Database, file: ExportFile, all: ExportFile[], existing: CollectionMeta[], position: number): { sql: string; table: string } {
  const taken = new Set((db.query("SELECT name FROM sqlite_master").all() as { name: string }[]).map((r) => r.name));
  let table = snake(file.slug);
  if (/^(_|v_|sqlite)/.test(table)) table = `t_${table}`;
  for (let i = 2; taken.has(table) || taken.has(`v_${table}`); i++) table = `${snake(file.slug)}_${i}`;
  const used = new Set(RESERVED);
  const defs: string[] = [];
  const meta: string[] = [];
  const q = (v: string | null | undefined) => (v === null || v === undefined ? "NULL" : `'${v.replace(/'/g, "''")}'`);
  let title = "";
  let pos = 0;
  for (const p of file.properties) {
    const values = file.rows.map((r) => r.properties[p.name]);
    let type = inferType(p, values);
    if (!type) continue;
    let refCollection: string | undefined;
    let refTable: string | undefined;
    if (type === "ref") {
      if (values.some((v) => Array.isArray(v) && v.length > 1)) continue;
      const slug = p.config?.database_slug as string | undefined;
      const target = existing.find((c) => c.notionSlug === slug);
      if (slug === file.slug) {
        refCollection = table;
        refTable = table;
      } else if (target) {
        refCollection = target.id;
        refTable = target.table;
      } else if (all.some((f) => f.slug === slug)) {
        const t = snake(slug!);
        refCollection = t;
        refTable = t;
      } else continue;
    }
    let name = snake(p.name);
    if (type === "ref" && !name.endsWith("_id")) name = `${name}_id`;
    for (let i = 2; used.has(name); i++) name = `${snake(p.name)}_${i}`;
    used.add(name);
    if (p.type === "title") title = name;
    const computed = p.type === "formula" || p.config?.notion_type === "rollup";
    const options =
      type === "select" || type === "multiselect" ? JSON.stringify(((p.config?.options ?? []) as SelectOption[]).map((o) => ({ name: o.name, ...(o.color ? { color: o.color } : {}) }))) : null;
    defs.push(sqlColumn(name, type, refTable));
    meta.push(
      `(${q(table)}, ${q(name)}, ${q(p.name)}, ${q(type)}, ${q(options)}, ${q(refCollection)}, ${computed ? 1 : 0}, 0, ${++pos}, ${q(p.name)})`,
    );
  }
  if (!title) {
    title = "titre";
    defs.unshift(`"titre" TEXT`);
    meta.unshift(`(${q(table)}, 'titre', 'Titre', 'text', NULL, NULL, 0, 0, 0, NULL)`);
  }
  const sql = `-- ${file.name} (Notion export "${file.slug}"); formulas and rollups are stored snapshots (computed = 1).
CREATE TABLE ${ident(table)} (
  ${STANDARD_COLUMNS},
  ${defs.join(",\n  ")},
  ${TIMESTAMPS}
);
CREATE VIEW ${ident(`v_${table}`)} AS SELECT * FROM ${ident(table)};
INSERT INTO _collections (id, label, emoji, table_name, view_name, title_column, default_sort, notion_slug, position)
  VALUES (${q(table)}, ${q(file.name)}, ${q(file.icon ?? null)}, ${q(table)}, ${q(`v_${table}`)}, ${q(title)}, 'updated_at:desc', ${q(file.slug)}, ${position});
INSERT INTO _columns (collection_id, name, label, type, options, ref_collection, computed, hidden, position, notion_name) VALUES
  ${meta.join(",\n  ")};
`;
  return { sql, table };
}

function plan(db: Database, files: ExportFile[], ddl: string[]): Plan[] {
  let collections = loadCollections(db);
  const created = new Set<string>();
  let position = Math.max(100, ...collections.map((c) => c.position + 1));
  for (const f of files) {
    if (collections.some((c) => c.notionSlug === f.slug)) continue;
    const { sql } = autoSchema(db, f, files, collections, position++);
    ddl.push(sql);
    db.exec(sql);
    created.add(f.slug);
    collections = loadCollections(db);
  }
  return files.map((file) => {
    const collection = collections.find((c) => c.notionSlug === file.slug)!;
    const props = new Set(file.properties.map((p) => p.name));
    const mapping: Plan["mapping"] = [];
    for (const col of collection.columns) {
      if (!col.notionName) continue;
      const end = col.notionName.endsWith("#end");
      const prop = end ? col.notionName.slice(0, -4) : col.notionName;
      if (props.has(prop)) mapping.push([prop, col, end]);
    }
    const links = (db.query("SELECT * FROM _links WHERE collection_id = ? AND notion_name IS NOT NULL").all(collection.id) as LinkSide[]).filter((l) => props.has(l.notion_name));
    const used = new Set([...mapping.map(([p]) => p), ...links.map((l) => l.notion_name)]);
    const ignored = file.properties.map((p) => p.name).filter((n) => !used.has(n));
    return { file, collection, created: created.has(file.slug), mapping, links, ignored };
  });
}

interface FileCopy {
  from: string;
  to: string;
}

export function importExport(db: Database, files: ExportFile[], o: ImportOptions): ImportReport {
  const log = o.log ?? (() => {});
  const report: ImportReport = { collections: [], ddl: [] };
  const copies: FileCopy[] = [];
  try {
    db.transaction(() => {
      db.exec("PRAGMA defer_foreign_keys = ON");
      db.exec("UPDATE _context SET source = 'import', op = NULL WHERE id = 1");
      const plans = plan(db, files, report.ddl);
      regenerateTriggers(db);

      // Every imported Notion id gets its row id up front, so relations resolve whatever the file order.
      const ids = new Map<string, string>();
      for (const c of loadCollections(db)) {
        if (!tableColumns(db, c.table).includes("notion_id")) continue;
        for (const r of db.query(`SELECT id, notion_id FROM ${ident(c.table)} WHERE notion_id IS NOT NULL`).all() as { id: string; notion_id: string }[]) ids.set(r.notion_id, r.id);
      }
      for (const p of plans) for (const r of p.file.rows) if (!ids.has(r.notion_id)) ids.set(r.notion_id, crypto.randomUUID());

      const before = (db.query("SELECT coalesce(max(id), 0) AS id FROM _history").get() as { id: number }).id;
      for (const p of plans) {
        const entry = { slug: p.file.slug, collection: p.collection.id, created: p.created, rows: p.file.rows.length, inserted: 0, updated: 0, unchanged: 0, ignored: p.ignored, files: 0, missingFiles: 0, truncatedRelations: 0, mismatches: [] as ImportReport["collections"][number]["mismatches"] };
        report.collections.push(entry);
        const info = db.query(`PRAGMA table_info(${ident(p.collection.table)})`).all() as { name: string; notnull: number; dflt_value: string | null }[];
        const notNull = new Set(info.filter((c) => c.notnull).map((c) => c.name));
        const writable = [...p.mapping].filter(([, col]) => info.some((i) => i.name === col.name));
        const percentFormatted = new Set(p.file.properties.filter(isPercentFormatted).map((x) => x.name));
        const optionsSeen = new Map<string, Set<string>>();
        for (const row of p.file.rows) {
          const values: (string | number | null)[] = [];
          for (const [prop, col, end] of writable) {
            let v = convert(col, row.properties[prop], { ids, notionId: row.notion_id, slug: p.file.slug, o, copies, entry, optionsSeen, percentFormatted: percentFormatted.has(prop), end });
            if (v === null && notNull.has(col.name)) v = col.type === "bool" ? 0 : col.type === "multiselect" || col.type === "file" ? "[]" : "";
            values.push(v);
          }
          const names = writable.map(([, c]) => c.name);
          const created = row.created_at ? new Date(row.created_at).toISOString() : new Date().toISOString();
          const updated = row.updated_at ? new Date(row.updated_at).toISOString() : created;
          db.query(
            `INSERT INTO ${ident(p.collection.table)} (id, notion_id, created_at, updated_at${names.map((n) => `, ${ident(n)}`).join("")})
             VALUES (?, ?, ?, ?${names.map(() => ", ?").join("")})
             ON CONFLICT(notion_id) DO UPDATE SET ${[...names.map((n) => `${ident(n)} = excluded.${ident(n)}`), "updated_at = excluded.updated_at"].join(", ")}`,
          ).run(ids.get(row.notion_id)!, row.notion_id, created, updated, ...values);
        }
        mergeOptions(db, p, optionsSeen);
      }
      const linkStats = importLinks(db, plans, ids);
      const counts = db.query("SELECT table_name, op, count(*) AS n FROM _history WHERE id > ? GROUP BY table_name, op").all(before) as { table_name: string; op: string; n: number }[];
      for (const e of report.collections) {
        const table = plans.find((p) => p.file.slug === e.slug)!.collection.table;
        e.inserted = counts.find((c) => c.table_name === table && c.op === "insert")?.n ?? 0;
        e.updated = counts.filter((c) => c.table_name === table && c.op !== "insert").reduce((a, c) => a + c.n, 0);
        e.unchanged = e.rows - e.inserted - e.updated;
      }
      report.links = linkStats;
      for (const p of plans) verify(db, p, ids, report.collections.find((e) => e.slug === p.file.slug)!);
      const fk = db.query("PRAGMA foreign_key_check").all() as { table: string; rowid: number; parent: string }[];
      if (fk.length) throw new Error(`foreign key violations: ${fk.slice(0, 5).map((f) => `${f.table}#${f.rowid} -> ${f.parent}`).join(", ")}`);
      db.exec("UPDATE _context SET source = NULL, op = NULL WHERE id = 1");
      if (o.dryRun) throw new DryRun();
    })();
  } catch (e) {
    if (!(e instanceof DryRun)) throw e;
  }
  if (!o.dryRun) {
    for (const c of copies) {
      mkdirSync(dirname(c.to), { recursive: true });
      if (!existsSync(c.to) || statSync(c.to).size !== statSync(c.from).size) copyFileSync(c.from, c.to);
    }
  }
  for (const e of report.collections) {
    log(
      `${e.slug} -> ${e.collection}${e.created ? " (new table)" : ""}: ${e.rows} rows, ${e.inserted} inserted, ${e.updated} updated, ${e.unchanged} unchanged` +
        (e.files || e.missingFiles ? `, ${e.files} files${e.missingFiles ? ` (${e.missingFiles} not downloaded)` : ""}` : ""),
    );
    if (e.ignored.length) log(`  ignored properties: ${e.ignored.join(", ")}`);
    if (e.truncatedRelations) log(`  ${e.truncatedRelations} relation values had several rows; only the first was kept`);
    for (const m of e.mismatches) log(`  ${m.column}: ${m.count} rows differ from Notion (${m.examples.join("; ")})`);
  }
  for (const l of report.links ?? []) if (l.added || l.removed) log(`${l.table}: ${l.added} links added, ${l.removed} removed`);
  return report;
}

const pairKey = (r: Record<string, string>, cols = Object.keys(r).filter((c) => c !== "id").sort()) => cols.map((c) => `${c}=${r[c]}`).join("|");

/**
 * Fills the many-to-many link tables from every side present in the export. A link is kept when any side
 * lists it; links of imported rows that no side lists any more are removed.
 */
function importLinks(db: Database, plans: Plan[], ids: Map<string, string>): { table: string; added: number; removed: number }[] {
  const byTable = new Map<string, { desired: Map<string, Record<string, string>>; owners: { column: string; rows: Set<string> }[] }>();
  for (const p of plans) {
    for (const l of p.links) {
      const t = byTable.get(l.table_name) ?? { desired: new Map<string, Record<string, string>>(), owners: [] as { column: string; rows: Set<string> }[] };
      byTable.set(l.table_name, t);
      const rows = new Set<string>();
      for (const row of p.file.rows) {
        const from = ids.get(row.notion_id)!;
        rows.add(from);
        const v = row.properties[l.notion_name];
        for (const target of Array.isArray(v) ? v : []) {
          const to = typeof target === "string" ? ids.get(target) : undefined;
          if (!to) continue;
          const pair: Record<string, string> = { [l.from_column]: from, [l.to_column]: to };
          t.desired.set(pairKey(pair), pair);
        }
      }
      t.owners.push({ column: l.from_column, rows });
    }
  }
  const out: { table: string; added: number; removed: number }[] = [];
  for (const [table, t] of byTable) {
    const pairCols = tableColumns(db, table).filter((c) => c !== "id" && c !== "created_at").sort();
    const existing = db.query(`SELECT id, ${pairCols.map(ident).join(", ")} FROM ${ident(table)}`).all() as Record<string, string>[];
    const have = new Set(existing.map((r) => pairKey(r, pairCols)));
    let added = 0;
    const insert = db.query(`INSERT INTO ${ident(table)} (${pairCols.map(ident).join(", ")}) VALUES (${pairCols.map(() => "?").join(", ")})`);
    for (const [key, pair] of t.desired) {
      if (have.has(key)) continue;
      insert.run(...pairCols.map((c) => pair[c]!));
      added++;
    }
    let removed = 0;
    const del = db.query(`DELETE FROM ${ident(table)} WHERE id = ?`);
    for (const r of existing) {
      if (t.desired.has(pairKey(r, pairCols))) continue;
      if (t.owners.some((o) => o.rows.has(r[o.column]!))) {
        del.run(r.id!);
        removed++;
      }
    }
    out.push({ table, added, removed });
  }
  return out;
}

interface ConvertCtx {
  ids: Map<string, string>;
  notionId: string;
  slug: string;
  o: ImportOptions;
  copies: FileCopy[];
  entry: { files: number; missingFiles: number; truncatedRelations: number };
  optionsSeen: Map<string, Set<string>>;
  percentFormatted: boolean;
  end?: boolean;
}

function convert(col: ColumnMeta, v: unknown, ctx: ConvertCtx): string | number | null {
  if (v === undefined) v = null;
  switch (col.type) {
    case "text":
    case "longtext":
      if (v === null || v === "") return v === "" ? "" : null;
      if (Array.isArray(v)) return v.join(", ");
      return typeof v === "object" ? (dateStart(v) ?? JSON.stringify(v)) : String(v);
    case "url":
      return typeof v === "string" && v ? v : null;
    case "number":
    case "percent": {
      const n = typeof v === "number" && Number.isFinite(v) ? v : typeof v === "string" && v.trim() && Number.isFinite(Number(v)) ? Number(v) : null;
      // Notion stores percent-formatted numbers as fractions already; a plain number mapped to a percent column is in %.
      return n !== null && col.type === "percent" && !ctx.percentFormatted ? n / 100 : n;
    }
    case "money":
      return typeof v === "number" && Number.isFinite(v) ? Math.round(v * 100) / 100 : null;
    case "date": {
      const s = ctx.end ? dateEnd(v) : dateStart(v);
      return s ? s.slice(0, 10) : null;
    }
    case "datetime": {
      const s = ctx.end ? dateEnd(v) : dateStart(v);
      return s && !Number.isNaN(Date.parse(s)) ? new Date(s).toISOString() : null;
    }
    case "bool":
      return v ? 1 : 0;
    case "select": {
      if (typeof v !== "string" || !v) return null;
      seen(ctx, col.name, v);
      return v;
    }
    case "multiselect": {
      const list = Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : [];
      for (const x of list) seen(ctx, col.name, x);
      return JSON.stringify(list);
    }
    case "ref": {
      if (Array.isArray(v) && v.length > 1) ctx.entry.truncatedRelations++;
      const first = Array.isArray(v) ? v[0] : typeof v === "string" ? v : undefined;
      return typeof first === "string" ? (ctx.ids.get(first) ?? null) : null;
    }
    case "file": {
      const list = Array.isArray(v) ? v : [];
      const out = list
        .filter((f): f is { name: string; url?: string; path?: string | null } => !!f && typeof f === "object" && typeof (f as { name?: unknown }).name === "string")
        .map((f) => {
          if (f.path && isSafeRelative(f.path)) {
            const root = ctx.o.filesRoot!;
            const from = join(root, f.path);
            const rel = f.path.replace(/^files\//, "");
            if (existsSync(from)) {
              ctx.copies.push({ from, to: join(ctx.o.filesDir, rel) });
              ctx.entry.files++;
              return { name: f.name, path: rel };
            }
          }
          ctx.entry.missingFiles++;
          return { name: f.name, ...(f.url ? { url: f.url } : {}) };
        });
      return JSON.stringify(out);
    }
  }
  return null;
}

function seen(ctx: ConvertCtx, column: string, value: string) {
  const s = ctx.optionsSeen.get(column) ?? new Set<string>();
  s.add(value);
  ctx.optionsSeen.set(column, s);
}

/** Select options = existing ones + the Notion property's options + every value found, so validation accepts real data. */
function mergeOptions(db: Database, p: Plan, seenValues: Map<string, Set<string>>) {
  for (const [prop, col] of p.mapping) {
    if (col.type !== "select" && col.type !== "multiselect") continue;
    const opts: SelectOption[] = [...col.options];
    const add = (name: string, color?: string) => {
      const o = opts.find((x) => x.name === name);
      if (!o) opts.push({ name, ...(color ? { color } : {}) });
      else if (color && !o.color) o.color = color;
    };
    const prop0 = p.file.properties.find((x) => x.name === prop);
    for (const o of (prop0?.config?.options ?? []) as SelectOption[]) if (o?.name) add(o.name, o.color);
    for (const v of seenValues.get(col.name) ?? []) add(v);
    db.query("UPDATE _columns SET options = ? WHERE collection_id = ? AND name = ?").run(JSON.stringify(opts), p.collection.id, col.name);
  }
}

/** Compares the views' computed columns with the values Notion computed (when the export carries them). */
function verify(db: Database, p: Plan, ids: Map<string, string>, entry: ImportReport["collections"][number]) {
  const stored = new Set(tableColumns(db, p.collection.table));
  const computed = p.collection.columns.filter((c) => c.computed && c.notionName && !stored.has(c.name));
  for (const col of computed) {
    const prop = p.file.properties.find((x) => x.name === col.notionName);
    if (!prop) continue;
    let count = 0;
    const examples: string[] = [];
    for (const row of p.file.rows) {
      if (!(col.notionName! in row.properties)) continue;
      const expected = row.properties[col.notionName!];
      if (expected === null || expected === undefined || (typeof expected === "object" && !("start" in (expected as object)))) continue;
      const got = (db.query(`SELECT ${ident(col.name)} AS v FROM ${ident(p.collection.view)} WHERE id = ?`).get(ids.get(row.notion_id)!) as { v: unknown } | null)?.v;
      const ok =
        typeof expected === "number"
          ? typeof got === "number" && Math.abs(got - expected) < 0.011
          : typeof expected === "string"
            ? String(got ?? "") === expected || (expected === "" && got === null) || String(got) === expected.trim()
            : typeof expected === "boolean"
              ? !!got === expected
              : String(got ?? "").slice(0, 10) === (dateStart(expected) ?? "").slice(0, 10);
      if (!ok) {
        count++;
        if (examples.length < 3) examples.push(`${JSON.stringify(expected)} vs ${JSON.stringify(got)}`);
      }
    }
    if (count) entry.mismatches.push({ column: col.name, count, examples });
  }
}

/** `dir` is either the export root (with databases/, files/, archive/ which is ignored) or its databases/ folder. */
export function importDir(db: Database, dir: string, o: Omit<ImportOptions, "filesRoot"> & { filesRoot?: string }): ImportReport {
  const root = existsSync(join(dir, "databases")) ? dir : join(dir, "..");
  const dbDir = existsSync(join(dir, "databases")) ? join(dir, "databases") : dir;
  return importExport(db, readExportDir(dbDir), { ...o, filesRoot: o.filesRoot ?? root });
}
