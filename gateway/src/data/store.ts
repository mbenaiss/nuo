import type { Database } from "bun:sqlite";
import { HttpError } from "../bots/service";
import { asApp, changeVersion, ident, NOW_SQL, tableColumns } from "./db";
import type { ChangeOp, ColumnType, DataChange, DataCollection, DataColumn, DataGroups, DataRow, SelectOption } from "./types";

export interface ColumnMeta {
  collectionId: string;
  name: string;
  label: string;
  type: ColumnType;
  options: SelectOption[];
  refCollection?: string;
  computed: boolean;
  hidden: boolean;
  position: number;
  notionName?: string;
}

export interface CollectionMeta {
  id: string;
  label: string;
  emoji?: string;
  table: string;
  view: string;
  titleColumn: string;
  defaultSort?: string;
  notionSlug?: string;
  position: number;
  columns: ColumnMeta[];
}

/** Columns every collection table has; filterable/sortable but never written through `values`. */
const SYSTEM_COLUMNS: Record<string, ColumnType> = { id: "text", created_at: "datetime", updated_at: "datetime", archived_at: "datetime" };
const RESERVED = new Set(["id", "notion_id", "created_at", "updated_at", "archived_at"]);
const OPS = new Set(["eq", "ne", "lt", "lte", "gt", "gte", "contains", "in", "empty", "notempty"]);
const TEXTUAL = new Set<ColumnType>(["text", "longtext", "select", "url", "multiselect"]);
const NUMERIC = new Set<ColumnType>(["number", "money", "percent"]);
const MAX_LIMIT = 200;
const GROUPABLE = new Set<ColumnType>(["text", "select", "bool", "ref", "date", "datetime", "number"]);

type Row = Record<string, unknown>;

export function loadCollections(db: Database): CollectionMeta[] {
  const cols = db.query("SELECT * FROM _columns ORDER BY collection_id, position, name").all() as Row[];
  const byCollection = new Map<string, ColumnMeta[]>();
  for (const c of cols) {
    const meta: ColumnMeta = {
      collectionId: String(c.collection_id),
      name: String(c.name),
      label: String(c.label),
      type: c.type as ColumnType,
      options: parseOptions(c.options),
      refCollection: (c.ref_collection as string) || undefined,
      computed: !!c.computed,
      hidden: !!c.hidden,
      position: Number(c.position),
      notionName: (c.notion_name as string) || undefined,
    };
    const list = byCollection.get(meta.collectionId) ?? [];
    list.push(meta);
    byCollection.set(meta.collectionId, list);
  }
  return (db.query("SELECT * FROM _collections ORDER BY position, id").all() as Row[]).map((r) => ({
    id: String(r.id),
    label: String(r.label),
    emoji: (r.emoji as string) || undefined,
    table: String(r.table_name),
    view: String(r.view_name),
    titleColumn: String(r.title_column),
    defaultSort: (r.default_sort as string) || undefined,
    notionSlug: (r.notion_slug as string) || undefined,
    position: Number(r.position),
    columns: byCollection.get(String(r.id)) ?? [],
  }));
}

function parseOptions(raw: unknown): SelectOption[] {
  if (typeof raw !== "string" || !raw) return [];
  try {
    const v = JSON.parse(raw);
    return Array.isArray(v) ? v.map((o) => (typeof o === "string" ? { name: o } : o)).filter((o) => o && typeof o.name === "string") : [];
  } catch {
    return [];
  }
}

function parseJsonArray(v: unknown): unknown[] {
  if (Array.isArray(v)) return v;
  if (typeof v !== "string" || !v) return [];
  try {
    const p = JSON.parse(v);
    return Array.isArray(p) ? p : [];
  } catch {
    return [];
  }
}

export function decodeValue(type: ColumnType | undefined, v: unknown): unknown {
  if (v === undefined) return null;
  switch (type) {
    case "bool":
      return v === null ? null : !!v;
    case "multiselect":
    case "file":
      return parseJsonArray(v);
    case "refs":
      return parseJsonArray(v).filter((x) => x !== null);
    default:
      return v;
  }
}

const encodeCursor = (offset: number) => Buffer.from(JSON.stringify({ o: offset })).toString("base64url");
function decodeCursor(c: string | null): number {
  if (!c) return 0;
  try {
    const o = JSON.parse(Buffer.from(c, "base64url").toString()).o;
    if (Number.isInteger(o) && o >= 0) return o;
  } catch {}
  throw new HttpError(400, "invalid cursor");
}

const escapeLike = (s: string) => `%${s.replace(/[\\%_]/g, (c) => `\\${c}`)}%`;

export interface RowQuery {
  q?: string;
  sort?: string[];
  filter?: string[];
  limit?: number;
  cursor?: string | null;
  archived?: boolean;
}

/** Tables outside `_collections` whose history is still listed under their own name. */
const OWN_TABLES = new Set(["reminders", "places", "areas", "projects", "project_headings"]);

export class DataStore {
  private meta?: { version: string; collections: CollectionMeta[] };

  constructor(readonly db: Database) {}

  /** Read several times per request; reloaded only after a commit (agents add collections and columns with sqlite3). */
  collections(): CollectionMeta[] {
    const version = changeVersion(this.db);
    if (this.meta?.version !== version) this.meta = { version, collections: loadCollections(this.db) };
    return this.meta.collections;
  }

  collection(id: string): CollectionMeta {
    const c = this.collections().find((c) => c.id === id);
    if (!c) throw new HttpError(404, "collection not found");
    return c;
  }

  listCollections(): DataCollection[] {
    return this.collections().map((c) => {
      const { n } = this.db.query(`SELECT count(*) AS n FROM ${ident(c.table)} WHERE archived_at IS NULL`).get() as { n: number };
      return {
        id: c.id,
        label: c.label,
        ...(c.emoji ? { emoji: c.emoji } : {}),
        count: n,
        columns: c.columns.map(publicColumn),
        titleColumn: c.titleColumn,
        ...(c.defaultSort ? { defaultSort: c.defaultSort } : {}),
      };
    });
  }

  private columnType(c: CollectionMeta, name: string): ColumnType {
    const col = c.columns.find((x) => x.name === name);
    if (col) return col.type;
    const sys = SYSTEM_COLUMNS[name];
    if (sys) return sys;
    throw new HttpError(400, `unknown column "${name}"`);
  }

  rows(collectionId: string, q: RowQuery): { rows: DataRow[]; nextCursor?: string; total: number } {
    const c = this.collection(collectionId);
    const [whereSql, params] = this.whereSql(c, q);
    const order: string[] = [];
    const sorts = q.sort?.length ? q.sort : c.defaultSort ? [c.defaultSort] : [];
    for (const s of sorts) {
      const [name, dir = "asc"] = s.split(":");
      if (dir !== "asc" && dir !== "desc") throw new HttpError(400, `invalid sort direction "${dir}"`);
      this.columnType(c, name!);
      order.push(`${ident(name!)} ${dir.toUpperCase()} NULLS LAST`);
    }
    order.push("id ASC");
    const limit = Math.min(Math.max(1, Math.floor(q.limit ?? 50) || 50), MAX_LIMIT);
    const offset = decodeCursor(q.cursor ?? null);
    const { total } = this.db.query(`SELECT count(*) AS total FROM ${ident(c.view)} ${whereSql}`).get(...params) as { total: number };
    const raw = this.db.query(`SELECT * FROM ${ident(c.view)} ${whereSql} ORDER BY ${order.join(", ")} LIMIT ? OFFSET ?`).all(...params, limit, offset) as Row[];
    const rows = this.toRows(c, raw);
    return { rows, total, ...(offset + raw.length < total ? { nextCursor: encodeCursor(offset + raw.length) } : {}) };
  }

  /**
   * Rows matching `q`, grouped by `by` (`column`, or `column:year|month` for a date), with the count and the sum of
   * every money column per group (summing ids, years or day counts tells nothing). Dates come newest first, refs by title, other keys in ascending order, empty last.
   */
  groups(collectionId: string, q: RowQuery & { by: string }): DataGroups {
    const c = this.collection(collectionId);
    const [name, unit] = q.by.split(":");
    const type = this.columnType(c, name!);
    if (!GROUPABLE.has(type)) throw new HttpError(400, `cannot group by "${name}"`);
    const isDate = type === "date" || type === "datetime";
    if (unit !== undefined && (!isDate || !["year", "month", "day"].includes(unit))) throw new HttpError(400, `invalid grouping "${q.by}"`);
    const width = { year: 4, month: 7, day: 10 }[unit ?? (isDate ? "year" : "")] ?? 0;
    const key = width ? `substr(${ident(name!)}, 1, ${width})` : ident(name!);
    const summed = c.columns.filter((x) => x.type === "money");
    const sums = summed.map((x, i) => `, SUM(${ident(x.name)}) AS s${i}`).join("");
    const [whereSql, params] = this.whereSql(c, q);
    const raw = this.db
      .query(`SELECT ${key} AS k, count(*) AS n${sums} FROM ${ident(c.view)} ${whereSql} GROUP BY k ORDER BY k IS NULL OR k = '', k ${isDate ? "DESC" : "ASC"}`)
      .all(...params) as Row[];
    const titles = new Map<string, string>();
    const col = c.columns.find((x) => x.name === name);
    const target = type === "ref" && col?.refCollection ? this.collections().find((x) => x.id === col.refCollection) : undefined;
    const ids = raw.map((r) => r.k).filter((k): k is string => typeof k === "string");
    if (target && ids.length) {
      const found = this.db
        .query(`SELECT id, ${ident(target.titleColumn)} AS title FROM ${ident(target.view)} WHERE id IN (${ids.map(() => "?").join(", ")})`)
        .all(...ids) as { id: string; title: unknown }[];
      for (const f of found) titles.set(f.id, String(f.title ?? ""));
    }
    const sumsOf = (r: Row) => Object.fromEntries(summed.map((x, i) => [x.name, Number(r[`s${i}`] ?? 0)]));
    const groups = raw.map((r) => {
      const k = r.k === "" || r.k === undefined ? null : type === "bool" && r.k !== null ? !!r.k : (r.k as string | number | null);
      const label = typeof k === "string" ? titles.get(k) : undefined;
      return { key: k, ...(label !== undefined ? { label } : {}), count: Number(r.n), sums: sumsOf(r) };
    });
    // Ref keys are random ids: their titles give the order.
    if (target) groups.sort((a, b) => (a.key === null ? 1 : b.key === null ? -1 : (a.label ?? "").localeCompare(b.label ?? "", "fr")));
    const total = {
      count: groups.reduce((a, g) => a + g.count, 0),
      sums: Object.fromEntries(summed.map((x) => [x.name, groups.reduce((a, g) => a + g.sums[x.name]!, 0)])),
    };
    return { by: q.by, groups, total };
  }

  private whereSql(c: CollectionMeta, q: RowQuery): [string, (string | number | null)[]] {
    const where: string[] = [];
    const params: (string | number | null)[] = [];
    if (!q.archived) where.push("archived_at IS NULL");
    if (q.q?.trim()) {
      const textCols = [c.titleColumn, ...c.columns.filter((x) => TEXTUAL.has(x.type) && x.name !== c.titleColumn).map((x) => x.name)];
      where.push(`(${textCols.map((n) => `${ident(n)} LIKE ? ESCAPE '\\'`).join(" OR ")})`);
      for (const _ of textCols) params.push(escapeLike(q.q.trim()));
    }
    for (const f of q.filter ?? []) {
      const [sql, p] = this.filterSql(c, f);
      where.push(sql);
      params.push(...p);
    }
    return [where.length ? `WHERE ${where.join(" AND ")}` : "", params];
  }

  private filterSql(c: CollectionMeta, f: string): [string, (string | number | null)[]] {
    const i = f.indexOf(":");
    const j = i < 0 ? -1 : f.indexOf(":", i + 1);
    if (i < 0) throw new HttpError(400, `invalid filter "${f}" (expected column:op:value)`);
    const name = f.slice(0, i);
    const op = j < 0 ? f.slice(i + 1) : f.slice(i + 1, j);
    const raw = j < 0 ? "" : f.slice(j + 1);
    if (!OPS.has(op)) throw new HttpError(400, `invalid filter operator "${op}"`);
    const type = this.columnType(c, name);
    const col = ident(name);
    const coerce = (v: string): string | number => {
      if (NUMERIC.has(type)) {
        const n = Number(v);
        if (v.trim() === "" || !Number.isFinite(n)) throw new HttpError(400, `filter on "${name}" expects a number`);
        return n;
      }
      if (type === "bool") {
        if (v === "true" || v === "1") return 1;
        if (v === "false" || v === "0") return 0;
        throw new HttpError(400, `filter on "${name}" expects true or false`);
      }
      return v;
    };
    switch (op) {
      case "empty":
        return [`(${col} IS NULL OR ${col} = '' OR ${col} = '[]')`, []];
      case "notempty":
        return [`(${col} IS NOT NULL AND ${col} <> '' AND ${col} <> '[]')`, []];
      case "eq":
        return [`${col} = ?`, [coerce(raw)]];
      case "ne":
        return [`${col} IS NOT ?`, [coerce(raw)]];
      case "lt":
        return [`${col} < ?`, [coerce(raw)]];
      case "lte":
        return [`${col} <= ?`, [coerce(raw)]];
      case "gt":
        return [`${col} > ?`, [coerce(raw)]];
      case "gte":
        return [`${col} >= ?`, [coerce(raw)]];
      case "contains":
        if (type === "multiselect") return [`EXISTS (SELECT 1 FROM json_each(${col}) WHERE value = ?)`, [raw]];
        return [`${col} LIKE ? ESCAPE '\\'`, [escapeLike(raw)]];
      case "in": {
        const values = raw.split(",").map(coerce);
        if (!values.length) throw new HttpError(400, `filter "${f}" has no values`);
        return [`${col} IN (${values.map(() => "?").join(", ")})`, values];
      }
    }
    throw new HttpError(400, `invalid filter "${f}"`);
  }

  private toRows(c: CollectionMeta, raw: Row[]): DataRow[] {
    const refs = new Map<string, Map<string, string>>();
    const idsOf = (col: ColumnMeta, v: unknown): string[] =>
      col.type === "refs" ? (decodeValue("refs", v) as unknown[]).filter((x): x is string => typeof x === "string") : typeof v === "string" ? [v] : [];
    for (const col of c.columns.filter((x) => (x.type === "ref" || x.type === "refs") && x.refCollection)) {
      const ids = [...new Set(raw.flatMap((r) => idsOf(col, r[col.name])))];
      if (!ids.length) continue;
      const target = this.collections().find((x) => x.id === col.refCollection);
      if (!target) continue;
      const found = this.db
        .query(`SELECT id, ${ident(target.titleColumn)} AS title FROM ${ident(target.view)} WHERE id IN (${ids.map(() => "?").join(", ")})`)
        .all(...ids) as { id: string; title: unknown }[];
      refs.set(col.name, new Map(found.map((f) => [f.id, String(f.title ?? "")])));
    }
    return raw.map((r) => {
      const values: Record<string, unknown> = {};
      for (const col of c.columns) values[col.name] = decodeValue(col.type, r[col.name]);
      const rowRefs: Record<string, string> = {};
      for (const [name, m] of refs) {
        const col = c.columns.find((x) => x.name === name)!;
        const titles = idsOf(col, r[name]).map((id) => m.get(id)).filter((x): x is string => x !== undefined);
        if (titles.length) rowRefs[name] = titles.join(", ");
      }
      return {
        id: String(r.id),
        values,
        title: String(r[c.titleColumn] ?? ""),
        ...(Object.keys(rowRefs).length ? { refs: rowRefs } : {}),
        updatedAt: String(r.updated_at),
        ...(r.archived_at ? { archivedAt: String(r.archived_at) } : {}),
      };
    });
  }

  row(collectionId: string, rowId: string): DataRow {
    const c = this.collection(collectionId);
    const r = this.db.query(`SELECT * FROM ${ident(c.view)} WHERE id = ?`).get(rowId) as Row | null;
    if (!r) throw new HttpError(404, "row not found");
    return this.toRows(c, [r])[0]!;
  }

  rowWithHistory(collectionId: string, rowId: string): { row: DataRow; history: DataChange[] } {
    return { row: this.row(collectionId, rowId), history: this.history({ collection: collectionId, rowId, limit: 50 }) };
  }

  /** Validates app input against the column types; returns SQL-ready values. */
  encode(c: CollectionMeta, values: unknown): Record<string, string | number | null> {
    if (!values || typeof values !== "object" || Array.isArray(values)) throw new HttpError(400, "values must be an object");
    const out: Record<string, string | number | null> = {};
    for (const [name, v] of Object.entries(values as Record<string, unknown>)) {
      if (RESERVED.has(name)) throw new HttpError(400, `"${name}" cannot be written`);
      const col = c.columns.find((x) => x.name === name);
      if (!col) throw new HttpError(400, `unknown column "${name}"`);
      if (col.computed) throw new HttpError(400, `"${name}" is computed`);
      out[name] = this.encodeValue(col, v);
    }
    return out;
  }

  private encodeValue(col: ColumnMeta, v: unknown): string | number | null {
    const bad = (what: string): never => {
      throw new HttpError(400, `"${col.name}" expects ${what}`);
    };
    if (col.type === "bool") {
      if (v === null || v === undefined) return 0;
      return typeof v === "boolean" ? (v ? 1 : 0) : bad("a boolean");
    }
    if (col.type === "multiselect" || col.type === "file") {
      if (v === null || v === undefined) return "[]";
      if (!Array.isArray(v)) return bad("an array");
      if (col.type === "multiselect") {
        for (const x of v) {
          if (typeof x !== "string") bad("an array of strings");
          if (col.options.length && !col.options.some((o) => o.name === x)) bad(`values among ${col.options.map((o) => o.name).join(", ")}`);
        }
        return JSON.stringify(v);
      }
      const files = v.map((f) => {
        if (!f || typeof f !== "object" || typeof f.name !== "string") return bad("an array of {name, path|url}");
        if (f.path !== undefined && (typeof f.path !== "string" || !isSafeRelative(f.path))) return bad("relative file paths");
        if (f.url !== undefined && typeof f.url !== "string") return bad("string urls");
        return { name: f.name, ...(f.path ? { path: f.path } : {}), ...(f.url ? { url: f.url } : {}) };
      });
      return JSON.stringify(files);
    }
    if (v === null || v === undefined) return null;
    switch (col.type) {
      case "text":
      case "longtext":
        return typeof v === "string" ? v : bad("a string");
      case "url":
        if (typeof v !== "string") return bad("a URL");
        if (v === "") return null;
        return URL.canParse(v) ? v : bad("a URL");
      case "number":
      case "percent":
        return typeof v === "number" && Number.isFinite(v) ? v : bad("a number");
      case "money":
        return typeof v === "number" && Number.isFinite(v) ? Math.round(v * 100) / 100 : bad("an amount");
      case "date":
        return typeof v === "string" && isDate(v) ? v : bad("a date YYYY-MM-DD");
      case "datetime": {
        if (typeof v !== "string" || Number.isNaN(Date.parse(v))) return bad("an ISO date-time");
        return new Date(v).toISOString();
      }
      case "select":
        if (typeof v !== "string") return bad("a string");
        if (col.options.length && !col.options.some((o) => o.name === v)) return bad(`one of ${col.options.map((o) => o.name).join(", ")}`);
        return v;
      case "ref": {
        if (typeof v !== "string") return bad("a row id");
        const target = this.collections().find((x) => x.id === col.refCollection);
        if (!target) return bad("a known collection");
        if (!this.db.query(`SELECT 1 FROM ${ident(target.table)} WHERE id = ?`).get(v)) return bad(`an existing ${target.label} row`);
        return v;
      }
    }
    return bad("a supported value");
  }

  insert(collectionId: string, values: unknown): DataRow {
    const c = this.collection(collectionId);
    const enc = this.encode(c, values);
    const id = crypto.randomUUID();
    const names = Object.keys(enc);
    sqlite(() =>
      asApp(this.db, () => {
        this.db
          .query(`INSERT INTO ${ident(c.table)} (id${names.map((n) => `, ${ident(n)}`).join("")}) VALUES (?${names.map(() => ", ?").join("")})`)
          .run(id, ...names.map((n) => enc[n]!));
      }),
    );
    return this.row(collectionId, id);
  }

  patch(collectionId: string, rowId: string, values: unknown): DataRow {
    const c = this.collection(collectionId);
    this.row(collectionId, rowId);
    const enc = this.encode(c, values);
    const names = Object.keys(enc);
    if (names.length) {
      sqlite(() =>
        asApp(this.db, () => {
          this.db
            .query(`UPDATE ${ident(c.table)} SET ${names.map((n) => `${ident(n)} = ?`).join(", ")}, updated_at = ${NOW_SQL} WHERE id = ?`)
            .run(...names.map((n) => enc[n]!), rowId);
        }),
      );
    }
    return this.row(collectionId, rowId);
  }

  setArchived(collectionId: string, rowId: string, archived: boolean): DataRow {
    const c = this.collection(collectionId);
    this.row(collectionId, rowId);
    asApp(this.db, () => {
      this.db
        .query(
          archived
            ? `UPDATE ${ident(c.table)} SET archived_at = ${NOW_SQL}, updated_at = ${NOW_SQL} WHERE id = ? AND archived_at IS NULL`
            : `UPDATE ${ident(c.table)} SET archived_at = NULL, updated_at = ${NOW_SQL} WHERE id = ? AND archived_at IS NOT NULL`,
        )
        .run(rowId);
    });
    return this.row(collectionId, rowId);
  }

  private tableToCollection(): Map<string, CollectionMeta> {
    return new Map(this.collections().map((c) => [c.table, c]));
  }

  history(o: { collection?: string; rowId?: string; limit?: number }): DataChange[] {
    const where: string[] = [];
    const params: (string | number)[] = [];
    if (o.collection) {
      const table = OWN_TABLES.has(o.collection) ? o.collection : this.collection(o.collection).table;
      where.push("table_name = ?");
      params.push(table);
    }
    if (o.rowId) {
      where.push("row_id = ?");
      params.push(o.rowId);
    }
    const limit = Math.min(Math.max(1, Math.floor(o.limit ?? 50) || 50), 500);
    const rows = this.db
      .query(`SELECT * FROM _history ${where.length ? `WHERE ${where.join(" AND ")}` : ""} ORDER BY id DESC LIMIT ?`)
      .all(...params, limit) as HistoryRow[];
    const byTable = this.tableToCollection();
    return rows.map((r) => toChange(r, byTable.get(r.table_name)));
  }

  /** Undoes one recorded change; recorded itself as a `revert` by the app. */
  revert(changeId: string): DataChange {
    const id = Number(changeId);
    const h = Number.isInteger(id) ? (this.db.query("SELECT * FROM _history WHERE id = ?").get(id) as HistoryRow | null) : null;
    if (!h) throw new HttpError(404, "change not found");
    const table = ident(h.table_name);
    const cols = new Set(tableColumns(this.db, h.table_name));
    const before = this.lastHistoryId();
    sqlite(() =>
      asApp(
        this.db,
        () => {
          const exists = !!this.db.query(`SELECT 1 FROM ${table} WHERE id = ?`).get(h.row_id);
          if (h.op === "insert") {
            if (!exists) throw new HttpError(409, "the row no longer exists");
            if (!cols.has("archived_at")) {
              this.db.query(`DELETE FROM ${table} WHERE id = ?`).run(h.row_id);
              return;
            }
            this.db.query(`UPDATE ${table} SET archived_at = ${NOW_SQL}, updated_at = ${NOW_SQL} WHERE id = ? AND archived_at IS NULL`).run(h.row_id);
            return;
          }
          const old = JSON.parse(h.old_json ?? "{}") as Row;
          if (h.op === "delete") {
            if (exists) throw new HttpError(409, "the row already exists");
            const names = Object.keys(old).filter((n) => cols.has(n));
            this.db
              .query(`INSERT INTO ${table} (${names.map(ident).join(", ")}) VALUES (${names.map(() => "?").join(", ")})`)
              .run(...names.map((n) => old[n] as string | number | null));
            return;
          }
          if (!exists) throw new HttpError(409, "the row no longer exists");
          const now = JSON.parse(h.new_json ?? "{}") as Row;
          const names = Object.keys(old).filter((n) => cols.has(n) && n !== "updated_at" && n !== "id" && !sameValue(old[n], now[n]));
          if (!names.length) return;
          this.db
            .query(`UPDATE ${table} SET ${names.map((n) => `${ident(n)} = ?`).join(", ")}, updated_at = ${NOW_SQL} WHERE id = ?`)
            .run(...names.map((n) => old[n] as string | number | null), h.row_id);
        },
        "revert",
      ),
    );
    const latest = this.db.query("SELECT * FROM _history WHERE id > ? AND table_name = ? AND row_id = ? ORDER BY id DESC LIMIT 1").get(before, h.table_name, h.row_id) as
      | HistoryRow
      | null;
    if (!latest) throw new HttpError(409, "nothing to revert");
    return toChange(latest, this.tableToCollection().get(latest.table_name));
  }

  private lastHistoryId(): number {
    return (this.db.query("SELECT coalesce(max(id), 0) AS id FROM _history").get() as { id: number }).id;
  }

  search(q: string, max = 30): { collection: string; row: DataRow }[] {
    const term = q.trim();
    if (!term) return [];
    const out: { collection: string; row: DataRow }[] = [];
    for (const c of this.collections()) {
      if (out.length >= max) break;
      const raw = this.db
        .query(`SELECT * FROM ${ident(c.view)} WHERE archived_at IS NULL AND ${ident(c.titleColumn)} LIKE ? ESCAPE '\\' ORDER BY updated_at DESC LIMIT ?`)
        .all(escapeLike(term), max - out.length) as Row[];
      for (const row of this.toRows(c, raw)) out.push({ collection: c.id, row });
    }
    return out;
  }
}

interface HistoryRow {
  id: number;
  at: string;
  table_name: string;
  row_id: string;
  op: ChangeOp;
  old_json: string | null;
  new_json: string | null;
  source: string;
}

const IGNORED_IN_CHANGES = new Set(["updated_at", "created_at", "id"]);

function toChange(h: HistoryRow, c: CollectionMeta | undefined): DataChange {
  const old = h.old_json ? (JSON.parse(h.old_json) as Row) : {};
  const now = h.new_json ? (JSON.parse(h.new_json) as Row) : {};
  const type = (n: string) => c?.columns.find((x) => x.name === n)?.type;
  const changes: Record<string, [unknown, unknown]> = {};
  for (const k of new Set([...Object.keys(old), ...Object.keys(now)])) {
    if (IGNORED_IN_CHANGES.has(k)) continue;
    const a = old[k] ?? null;
    const b = now[k] ?? null;
    if (sameValue(a, b)) continue;
    changes[k] = [decodeValue(type(k), a), decodeValue(type(k), b)];
  }
  return {
    id: String(h.id),
    at: h.at,
    collection: c?.id ?? h.table_name,
    rowId: h.row_id,
    op: h.op,
    changes,
    source: h.source === "app" || h.source === "import" ? h.source : "agent",
  };
}

const sameValue = (a: unknown, b: unknown) => (a ?? null) === (b ?? null);

export function isDate(v: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(v)) return false;
  const d = new Date(`${v}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === v;
}

export function isSafeRelative(p: string): boolean {
  return !!p && !p.startsWith("/") && !p.includes("\0") && !p.split(/[\\/]/).some((s) => s === ".." || s === "");
}

function publicColumn(c: ColumnMeta): DataColumn {
  return {
    name: c.name,
    label: c.label,
    type: c.type,
    ...(c.type === "select" || c.type === "multiselect" ? { options: c.options } : {}),
    ...(c.refCollection ? { ref: c.refCollection } : {}),
    computed: c.computed,
    hidden: c.hidden,
    order: c.position,
  };
}

/** Maps SQLite constraint failures (CHECK, NOT NULL, FOREIGN KEY) to 400. */
export function sqlite<T>(fn: () => T): T {
  try {
    return fn();
  } catch (e) {
    if (e instanceof HttpError) throw e;
    const code = (e as { code?: string })?.code ?? "";
    if (code.startsWith("SQLITE_CONSTRAINT")) throw new HttpError(400, (e as Error).message);
    throw e;
  }
}
