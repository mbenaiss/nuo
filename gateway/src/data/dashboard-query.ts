// Long-lived child of the gateway that runs dashboard queries on a read-only connection, in its own process so the
// parent can kill a slow one (bun:sqlite has no interrupt). Usage: bun dashboard-query.ts <data.db>; one JSON SQL
// string per stdin line, one JSON result per stdout line, in order.
import { Database } from "bun:sqlite";

const MAX_ROWS = 500;
const path = process.argv[2];
let db: Database | undefined;

function connection(): Database {
  if (db) return db;
  if (!path) throw new Error("missing database path");
  const opened = new Database(path, { readonly: true });
  opened.exec("PRAGMA query_only = 1; PRAGMA busy_timeout = 1000;");
  return (db = opened);
}

function run(raw: unknown) {
  const sql = String(raw).trim().replace(/;\s*$/, "");
  if (!/^(select|with)\b/i.test(sql)) throw new Error("only SELECT queries are allowed");
  // Wrapping as a subquery also rejects anything that is not a single SELECT.
  const stmt = connection().query(`SELECT * FROM (\n${sql}\n) LIMIT ${MAX_ROWS + 1}`);
  const rows = stmt.values() as unknown[][];
  return { columns: stmt.columnNames, rows: rows.slice(0, MAX_ROWS), truncated: rows.length > MAX_ROWS };
}

for await (const line of console) {
  if (!line.trim()) continue;
  let out: unknown;
  try {
    out = run(JSON.parse(line));
  } catch (e) {
    out = { error: (e as Error)?.message ?? String(e) };
  }
  // Awaited so the answer reaches the parent before the next query can block this thread.
  await Bun.write(Bun.stdout, JSON.stringify(out) + "\n");
}
