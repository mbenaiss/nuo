import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { Subprocess } from "bun";
import { HttpError } from "../bots/service";
import type { BlockType, Dashboard, DashboardBlock, DashboardSummary } from "./types";

const RUNNER = new URL("./dashboard-query.ts", import.meta.url).pathname;
const TYPES = new Set<BlockType>(["number", "line", "bar", "donut", "table", "list"]);
const SLUG = /^[a-z0-9][a-z0-9_-]*$/;
export const QUERY_TIMEOUT_MS = 2000;
const WORKER_IDLE_MS = 60_000;
/** Queries may use `now`: a kept dashboard is computed again after this even if nothing changed. */
const CACHE_MS = 5 * 60_000;

interface BlockDef {
  type: BlockType;
  title: string;
  sql: string;
  format?: string;
  collection?: string;
}

interface DashboardDef {
  title: string;
  emoji?: string;
  description?: string;
  blocks: BlockDef[];
}

export type QueryResult = { columns: string[]; rows: unknown[][]; truncated: boolean } | { error: string };
type Worker = Subprocess<"pipe", "pipe", "ignore">;

/**
 * A long-lived child process running dashboard queries read-only, one at a time in call order (spawning bun cost
 * far more than the queries). A query running longer than `timeoutMs` is killed with the process, which starts
 * again for the next one; an idle process exits after `idleMs`.
 */
export class QueryWorker {
  private proc?: Worker;
  private current?: { proc: Worker; done: (r: QueryResult) => void };
  private tail: Promise<unknown> = Promise.resolve();
  private idle?: ReturnType<typeof setTimeout>;

  constructor(
    private dbPath: string,
    private idleMs = WORKER_IDLE_MS,
  ) {}

  query(sql: string, timeoutMs = QUERY_TIMEOUT_MS): Promise<QueryResult> {
    const next = this.tail.then(() => this.send(sql, timeoutMs));
    this.tail = next;
    return next;
  }

  close() {
    clearTimeout(this.idle);
    if (this.proc) this.kill(this.proc);
  }

  private start(): Worker {
    const proc = Bun.spawn([process.execPath, RUNNER, this.dbPath], { stdin: "pipe", stdout: "pipe", stderr: "ignore" });
    proc.unref();
    this.proc = proc;
    void this.read(proc);
    return proc;
  }

  private kill(proc: Worker) {
    if (this.proc === proc) this.proc = undefined;
    proc.kill(9);
  }

  private async read(proc: Worker) {
    const decoder = new TextDecoder();
    let pending = "";
    try {
      for await (const chunk of proc.stdout) {
        pending += decoder.decode(chunk, { stream: true });
        for (let i = pending.indexOf("\n"); i >= 0; i = pending.indexOf("\n")) {
          const line = pending.slice(0, i);
          pending = pending.slice(i + 1);
          let r: QueryResult;
          try {
            r = JSON.parse(line) as QueryResult;
          } catch {
            r = { error: "query failed" };
          }
          if (this.current?.proc === proc) this.current.done(r);
        }
      }
    } catch {}
    if (this.proc === proc) this.proc = undefined;
    if (this.current?.proc === proc) this.current.done({ error: "query failed" });
  }

  private send(sql: string, timeoutMs: number): Promise<QueryResult> {
    clearTimeout(this.idle);
    const proc = this.proc ?? this.start();
    return new Promise((resolve) => {
      const done = (r: QueryResult) => {
        if (this.current?.done !== done) return;
        clearTimeout(timer);
        this.current = undefined;
        this.idle = setTimeout(() => this.proc && !this.current && this.kill(this.proc), this.idleMs);
        this.idle.unref?.();
        resolve(r);
      };
      const timer = setTimeout(() => {
        this.kill(proc);
        done({ error: `query took longer than ${timeoutMs / 1000} s` });
      }, timeoutMs);
      this.current = { proc, done };
      try {
        proc.stdin.write(JSON.stringify(sql) + "\n");
        proc.stdin.flush();
      } catch {
        this.kill(proc);
        done({ error: "query failed" });
      }
    });
  }
}

function parseDef(raw: unknown, slug: string): DashboardDef {
  const d = raw as Partial<DashboardDef>;
  if (!d || typeof d !== "object" || typeof d.title !== "string" || !Array.isArray(d.blocks)) throw new Error(`${slug}.json: title and blocks are required`);
  for (const b of d.blocks) {
    if (!b || !TYPES.has(b.type) || typeof b.sql !== "string" || typeof b.title !== "string") throw new Error(`${slug}.json: each block needs type, title and sql`);
  }
  return d as DashboardDef;
}

export class Dashboards {
  private worker: QueryWorker;
  private cache = new Map<string, { key: string; at: number; value: Promise<Dashboard> }>();

  /** `version` (changeVersion of data.db) enables keeping computed dashboards until the data or the file changes. */
  constructor(
    private dir: string,
    dbPath: string,
    private timeoutMs = QUERY_TIMEOUT_MS,
    private version?: () => string,
  ) {
    this.worker = new QueryWorker(dbPath);
  }

  private read(slug: string): { def: DashboardDef; text: string } {
    if (!SLUG.test(slug)) throw new HttpError(404, "dashboard not found");
    const file = join(this.dir, `${slug}.json`);
    if (!existsSync(file)) throw new HttpError(404, "dashboard not found");
    const text = readFileSync(file, "utf8");
    try {
      return { def: parseDef(JSON.parse(text), slug), text };
    } catch (e) {
      throw new HttpError(422, `invalid dashboard: ${(e as Error).message}`);
    }
  }

  list(): DashboardSummary[] {
    if (!existsSync(this.dir)) return [];
    const out: DashboardSummary[] = [];
    for (const f of readdirSync(this.dir).filter((f) => f.endsWith(".json")).sort()) {
      const slug = f.slice(0, -5);
      if (!SLUG.test(slug)) continue;
      try {
        const d = parseDef(JSON.parse(readFileSync(join(this.dir, f), "utf8")), slug);
        out.push({ slug, title: d.title, ...(d.emoji ? { emoji: d.emoji } : {}), ...(d.description ? { description: d.description } : {}) });
      } catch (e) {
        console.warn(`[dashboards] skipping ${f}: ${(e as Error).message}`);
      }
    }
    return out;
  }

  async get(slug: string): Promise<Dashboard> {
    const { def, text } = this.read(slug);
    if (!this.version) return this.compute(slug, def);
    const key = `${this.version()}\n${text}`;
    const hit = this.cache.get(slug);
    if (hit && hit.key === key && Date.now() - hit.at < CACHE_MS) return hit.value;
    const entry = { key, at: Date.now(), value: this.compute(slug, def) };
    this.cache.set(slug, entry);
    const forget = () => this.cache.get(slug) === entry && this.cache.delete(slug);
    // A failing block may be transient (busy database, killed worker): only clean results are kept.
    entry.value.then((d) => d.blocks.some((b) => b.error) && forget(), forget);
    return entry.value;
  }

  close() {
    this.worker.close();
  }

  private async compute(slug: string, d: DashboardDef): Promise<Dashboard> {
    const results = await Promise.all(d.blocks.map((b) => this.worker.query(b.sql, this.timeoutMs)));
    const blocks = d.blocks.map((b, i) => this.block(b, results[i]!));
    return { slug, title: d.title, ...(d.emoji ? { emoji: d.emoji } : {}), ...(d.description ? { description: d.description } : {}), blocks };
  }

  private block(b: BlockDef, r: QueryResult): DashboardBlock {
    const base: DashboardBlock = { type: b.type, title: b.title, ...(b.format ? { format: b.format } : {}), ...(b.collection ? { collection: b.collection } : {}) };
    if ("error" in r) return { ...base, error: r.error };
    return { ...base, ...shape(b, r.columns, r.rows), ...(r.truncated ? { truncated: true } : {}) };
  }
}

function shape(b: BlockDef, columns: string[], rows: unknown[][]): Partial<DashboardBlock> {
  const at = (name: string, fallback: number) => {
    const i = columns.indexOf(name);
    return i >= 0 ? i : fallback < columns.length ? fallback : -1;
  };
  const num = (v: unknown) => (v === null || v === undefined || v === "" ? null : Number(v));
  switch (b.type) {
    case "number": {
      const i = at("value", 0);
      return { value: rows[0] && i >= 0 ? ((rows[0][i] as number | string | null) ?? null) : null };
    }
    case "line":
    case "bar":
    case "donut": {
      const xi = at("x", 0);
      const yi = at("y", 1);
      const si = columns.indexOf("s");
      const series = new Map<string, { x: string | number; y: number | null }[]>();
      for (const row of rows) {
        const name = si >= 0 ? String(row[si] ?? "") : b.title;
        const list = series.get(name) ?? [];
        list.push({ x: (row[xi] as string | number) ?? "", y: yi >= 0 ? num(row[yi]) : null });
        series.set(name, list);
      }
      return { series: [...series].map(([name, points]) => ({ name, points })) };
    }
    case "table":
      return { columns, rows };
    case "list": {
      const ti = at("title", 0);
      const sub = columns.indexOf("subtitle");
      const val = columns.indexOf("value");
      const id = columns.indexOf("id");
      return {
        items: rows.map((r) => ({
          title: String(r[ti] ?? ""),
          ...(sub >= 0 && r[sub] !== null ? { subtitle: String(r[sub]) } : {}),
          ...(val >= 0 ? { value: r[val] } : {}),
          ...(id >= 0 && r[id] !== null ? { id: String(r[id]) } : {}),
        })),
      };
    }
  }
}
