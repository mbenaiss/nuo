import { Database } from "bun:sqlite";
import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Dashboards, QueryWorker } from "../src/data/dashboards";
import { changeVersion, migrate, OWNER_ONLY_MARKER, openDataDb, regenerateTriggers, SCHEMA_DIR, schemaSummary } from "../src/data/db";
import { gitSync, importDocsTree, initDocsRepo } from "../src/data/docs";
import { importDir, importExport } from "../src/data/importer";
import { ReminderNotifier, Reminders } from "../src/data/reminders";
import { DataStore } from "../src/data/store";
import { effectiveInstructions } from "../src/bots/instructions";
import { botConfig, FakePusher, startTestApp, TEST_SCHEMA_DIRS, type TestApp } from "./helpers";

const FIXTURE = join(import.meta.dir, "fixtures", "data-import", "databases");
const tmps: string[] = [];
const tmp = () => {
  const d = mkdtempSync(join(tmpdir(), "nuo-data-"));
  tmps.push(d);
  return d;
};
let dbs: Database[] = [];
let t: TestApp | undefined;

afterEach(async () => {
  for (const db of dbs) db.close();
  dbs = [];
  await t?.close();
  t = undefined;
  for (const d of tmps.splice(0)) rmSync(d, { recursive: true, force: true });
});

function freshDb(): Database {
  const db = openDataDb(join(tmp(), "data.db"), TEST_SCHEMA_DIRS);
  dbs.push(db);
  return db;
}

function imported(): { db: Database; filesDir: string } {
  const db = freshDb();
  const filesDir = join(tmp(), "files");
  importDir(db, FIXTURE, { filesDir });
  return { db, filesDir };
}

const history = (db: Database) => db.query("SELECT table_name, row_id, op, source FROM _history ORDER BY id").all() as { table_name: string; row_id: string; op: string; source: string }[];

describe("data.db schema and history", () => {
  test("the schema summary lists each table's columns and only what a view adds, without the internal tables", () => {
    const db = freshDb();
    const path = db.filename;
    const summary = schemaSummary(path).split("\n");
    expect(summary).toContain("factures : " + (db.query("PRAGMA table_info(factures)").all() as { name: string }[]).map((c) => c.name).join(", "));
    const view = summary.find((l) => l.startsWith("v_factures = factures + "))!;
    expect(view).toContain("ca_ht");
    expect(view).not.toContain("numero");
    expect(summary.some((l) => /^_(history|context|migrations)\b/.test(l))).toBe(false);
    expect(schemaSummary(join(tmp(), "absent.db"))).toBe("");
  });

  test("views reproduce the Notion formulas", () => {
    const { db } = imported();
    const f = db.query("SELECT titre, client, ca_ht, tva, ttc, annee, mois, texte FROM v_factures ORDER BY numero").all() as any[];
    expect(f[0]).toMatchObject({ titre: "Juillet 2026", client: "Client A", ca_ht: 9000, tva: 1800, ttc: 10800, annee: 2026, mois: 7 });
    expect(f[0].texte).toContain("relative au mois de juillet 2026.");
    expect(f[2]).toMatchObject({ annee: 2025, ca_ht: 12000 });
    db.exec("INSERT INTO virements (commentaire, date, montant, exercice) VALUES ('Virement', '2024-03-01', 6000, 2024)");
    expect(db.query("SELECT impots, montant_net, mensualise, mensualise_net FROM v_virements WHERE exercice = 2024").get()).toEqual({ impots: 1068, montant_net: 4932, mensualise: 500, mensualise_net: 411 });
  });

  test("every change is recorded with its source and can be reverted", () => {
    const db = freshDb();
    const store = new DataStore(db);
    // Created earlier than the patch: within one millisecond both stamps would be equal.
    db.exec("INSERT INTO clients (id, nom, tjm, created_at, updated_at) VALUES ('c1', 'Acme', 500, '2026-11-02T09:00:00.000Z', '2026-11-02T09:00:00.000Z')");
    const row = store.patch("clients", "c1", { tjm: 550.123 });
    expect(row.values.tjm).toBe(550.12);
    db.exec("UPDATE clients SET nom = 'Acme SAS' WHERE id = 'c1'");
    expect(history(db).map((h) => [h.op, h.source])).toEqual([
      ["insert", "agent"],
      ["update", "app"],
      ["update", "agent"],
    ]);
    // updated_at is bumped even when the agent forgot it, without an extra history entry
    expect((db.query("SELECT updated_at FROM clients").get() as any).updated_at).not.toBe((db.query("SELECT created_at FROM clients").get() as any).created_at);

    const changes = store.history({ collection: "clients", rowId: "c1" });
    expect(changes[0]).toMatchObject({ op: "update", source: "agent", changes: { nom: ["Acme", "Acme SAS"] } });
    const revert = store.revert(changes[1]!.id);
    expect(revert).toMatchObject({ op: "revert", source: "app", changes: { tjm: [550.12, 500] } });
    expect(store.row("clients", "c1").values).toMatchObject({ nom: "Acme SAS", tjm: 500 });

    store.setArchived("clients", "c1", true);
    expect(store.history({ rowId: "c1" })[0]!.op).toBe("archive");
    store.revert(store.history({ rowId: "c1" })[0]!.id);
    expect(store.row("clients", "c1").archivedAt).toBeUndefined();

    db.exec("DELETE FROM clients WHERE id = 'c1'");
    const del = store.history({ rowId: "c1" })[0]!;
    expect(del.op).toBe("delete");
    store.revert(del.id);
    expect(store.row("clients", "c1").values.nom).toBe("Acme SAS");

    const insert = store.history({ rowId: "c1" }).at(-1)!;
    expect(insert.op).toBe("insert");
    store.revert(insert.id);
    expect(store.row("clients", "c1").archivedAt).toBeDefined();
    expect((db.query("SELECT source FROM _context").get() as any).source).toBeNull();
  });

  test("triggers follow a column added by hand", () => {
    const db = freshDb();
    db.exec("ALTER TABLE clients ADD COLUMN siret TEXT");
    regenerateTriggers(db);
    db.exec("INSERT INTO clients (id, nom, siret) VALUES ('c1', 'Acme', '123')");
    expect(JSON.parse((db.query("SELECT new_json FROM _history").get() as any).new_json).siret).toBe("123");
  });

  test("collection metadata follows columns added by another connection", () => {
    const db = freshDb();
    const store = new DataStore(db);
    const has = () => store.collection("clients").columns.some((c) => c.name === "siret");
    expect(has()).toBe(false);
    const agent = new Database((db.query("PRAGMA database_list").get() as any).file);
    agent.exec("ALTER TABLE clients ADD COLUMN siret TEXT; INSERT INTO _columns (collection_id, name, label, type, position) VALUES ('clients', 'siret', 'SIRET', 'text', 20)");
    agent.close();
    expect(has()).toBe(true);
  });

  test.skipIf(TEST_SCHEMA_DIRS.length === 1)("a new installation gets the shared tables only: no owner collection is shipped", () => {
    const db = openDataDb(join(tmp(), "data.db"));
    dbs.push(db);
    const shipped = (db.query("SELECT name FROM _migrations ORDER BY name").all() as { name: string }[]).map((r) => r.name);
    expect(shipped[0]).toBe("001_core.sql");
    expect(db.query("SELECT 1 FROM sqlite_master WHERE name IN ('clients', 'factures')").get()).toBeNull();
    expect((db.query("SELECT id FROM _collections").all() as { id: string }[]).map((r) => r.id)).not.toContain("factures");
  });

  test("owner-only migrations: applied once for the owner, never for another profile, optional afterwards", () => {
    const dir = tmp();
    const owner = join(dir, "owner-schema");
    mkdirSync(owner);
    writeFileSync(
      join(owner, "002_studio.sql"),
      `${OWNER_ONLY_MARKER}\nCREATE TABLE devis (id TEXT PRIMARY KEY, client TEXT NOT NULL, montant REAL);\n` +
        "INSERT INTO _collections (id, label, table_name, view_name, title_column, position) VALUES ('devis', 'Devis', 'devis', 'devis', 'client', 10);\n",
    );
    const ownerDb = join(dir, "owner.db");
    const first = openDataDb(ownerDb, [SCHEMA_DIR, owner]);
    first.exec("INSERT INTO devis (id, client, montant) VALUES ('DEV-2026-0412', 'Atelier Garnier', 4800)");
    first.close();

    // The public checkout does not ship the file: the owner's database still opens and keeps its rows.
    const without = openDataDb(ownerDb);
    expect(without.query("SELECT client, montant FROM devis").get()).toEqual({ client: "Atelier Garnier", montant: 4800 });
    without.close();
    // The private overlay brings it back: recorded by name, it is not run a second time.
    const back = new Database(ownerDb, { strict: true });
    dbs.push(back);
    expect(migrate(back, [SCHEMA_DIR, owner])).toEqual([]);
    expect(back.query("SELECT count(*) AS n FROM devis").get()).toEqual({ n: 1 });

    const other = openDataDb(join(dir, "alice.db"), [SCHEMA_DIR, owner], false);
    dbs.push(other);
    expect(other.query("SELECT 1 FROM sqlite_master WHERE name = 'devis'").get()).toBeNull();
    expect(other.query("SELECT 1 FROM _migrations WHERE name = '002_studio.sql'").get()).toBeNull();
  });

  test("a migration found in two schema folders is refused", () => {
    const dir = tmp();
    writeFileSync(join(dir, "001_core.sql"), "CREATE TABLE doublon (id TEXT);");
    expect(() => migrate(new Database(":memory:"), [SCHEMA_DIR, dir])).toThrow("001_core.sql found twice");
  });

  test("the history of one collection is read newest first through an index", () => {
    const db = freshDb();
    const plan = (db.query("EXPLAIN QUERY PLAN SELECT * FROM _history WHERE table_name = ? ORDER BY id DESC LIMIT 50").all("clients") as { detail: string }[]).map((p) => p.detail);
    expect(plan.some((d) => d.includes("_history_table"))).toBe(true);
    expect(plan.some((d) => d.includes("TEMP B-TREE"))).toBe(false);
  });
});

describe("importer", () => {
  test("imports the export, remaps relations, copies files and is idempotent", () => {
    const db = freshDb();
    const filesDir = join(tmp(), "files");
    const logs: string[] = [];
    const dry = importDir(db, FIXTURE, { filesDir, dryRun: true, log: (l) => logs.push(l) });
    expect(dry.collections.find((c) => c.slug === "factures")).toMatchObject({ inserted: 3, updated: 0 });
    expect((db.query("SELECT count(*) AS n FROM factures").get() as any).n).toBe(0);
    expect(existsSync(filesDir)).toBe(false);
    expect(db.query("SELECT 1 FROM sqlite_master WHERE name = 'carnet_route'").get()).toBeNull();

    const first = importDir(db, FIXTURE, { filesDir });
    const factures = first.collections.find((c) => c.slug === "factures")!;
    expect(factures).toMatchObject({ rows: 3, inserted: 3, files: 1, missingFiles: 1, mismatches: [] });
    expect(first.collections.find((c) => c.slug === "clients")!.ignored).toEqual(["Factures"]);
    const f = db.query("SELECT f.client_id, c.notion_id AS client_notion, f.societe, f.paye, f.pdf FROM factures f JOIN clients c ON c.id = f.client_id WHERE f.notion_id = 'f0000003'").get() as any;
    expect(f).toMatchObject({ client_notion: "c0000002", paye: 1, societe: '["beta"]' });
    expect(JSON.parse(f.pdf)).toEqual([{ name: "Facture_0003.pdf", path: "factures/f0000003/Facture_0003.pdf" }]);
    expect(readFileSync(join(filesDir, "factures/f0000003/Facture_0003.pdf"), "utf8")).toContain("fake invoice");
    const societe = new DataStore(db).collection("factures").columns.find((c) => c.name === "societe")!;
    expect(societe.options.map((o) => o.name)).toEqual(["alpha", "beta", "gamma"]);
    expect(history(db).every((h) => h.source === "import")).toBe(true);

    const second = importDir(db, FIXTURE, { filesDir });
    for (const c of second.collections) expect([c.inserted, c.updated, c.unchanged]).toEqual([0, 0, c.rows]);
    expect((db.query("SELECT count(*) AS n FROM factures").get() as any).n).toBe(3);
  });

  test("an export without a schema gets a generated table, view and metadata", () => {
    const { db } = imported();
    const store = new DataStore(db);
    const c = store.collection("carnet_route");
    expect(c).toMatchObject({ label: "Carnet de route", emoji: "✈️", titleColumn: "depense", view: "v_carnet_route" });
    expect(c.columns.map((x) => [x.name, x.type, x.computed])).toEqual([
      ["depense", "text", false],
      ["montant_eur", "money", false],
      ["categorie", "select", false],
      ["jour", "date", false],
      ["rembourse", "bool", false],
      ["taux_tva", "percent", false],
      ["avec_tva", "number", true],
      ["parent_id", "ref", false],
    ]);
    const rows = store.rows("carnet_route", { sort: ["depense:asc"] }).rows;
    expect(rows[0]!.values).toMatchObject({ depense: "Taxi aéroport", rembourse: true, categorie: "Taxi", avec_tva: 36, taux_tva: 0.1 });
    expect(rows[0]!.refs).toEqual({ parent_id: "Vol aller" });
    db.exec("UPDATE carnet_route SET montant_eur = 31 WHERE depense = 'Taxi aéroport'");
    expect(history(db).at(-1)).toMatchObject({ table_name: "carnet_route", op: "update", source: "agent" });
  });
});

describe("data REST", () => {
  async function app() {
    t = await startTestApp({ data: { autoStart: false } });
    const db = t.app.data.db;
    importDir(db, FIXTURE, { filesDir: join(t.dataDir, "files") });
    return t;
  }

  test("collections, filters, sort and cursor pagination", async () => {
    await app();
    const cols = (await t!.api("GET", "/api/data/collections")).data as any[];
    const factures = cols.find((c) => c.id === "factures");
    expect(factures).toMatchObject({ label: "Factures", count: 3, titleColumn: "titre", defaultSort: "numero:desc" });
    expect(factures.columns.find((c: any) => c.name === "ca_ht")).toMatchObject({ type: "money", computed: true });
    expect(factures.columns.find((c: any) => c.name === "client_id")).toMatchObject({ type: "ref", ref: "clients" });

    const page1 = (await t!.api("GET", "/api/data/collections/factures/rows?limit=2")).data;
    expect(page1.total).toBe(3);
    expect(page1.rows.map((r: any) => r.values.numero)).toEqual([3, 2]);
    expect(page1.rows[0]).toMatchObject({ title: "Novembre 2025", refs: { client_id: "Client B" } });
    expect(page1.rows[0].values).toMatchObject({ paye: true, societe: ["beta"], ca_ht: 12000 });
    const page2 = (await t!.api("GET", `/api/data/collections/factures/rows?limit=2&cursor=${page1.nextCursor}`)).data;
    expect(page2.rows.map((r: any) => r.values.numero)).toEqual([1]);
    expect(page2.nextCursor).toBeUndefined();

    const q = (s: string) => t!.api("GET", `/api/data/collections/factures/rows?${s}`);
    expect((await q("filter=annee:eq:2026&sort=ca_ht:asc")).data.rows.map((r: any) => r.values.ca_ht)).toEqual([5000, 9000]);
    expect((await q("filter=paye:eq:false")).data.total).toBe(1);
    expect((await q("filter=paye:eq:0")).data.total).toBe(1);
    expect((await q("filter=paye:eq:1")).data.total).toBe(2);
    expect((await q("filter=paye:eq:oui")).status).toBe(400);
    expect((await q(`filter=${encodeURIComponent("client:in:Client B,Client C")}`)).data.total).toBe(1);
    expect((await q("filter=societe:contains:alpha")).data.total).toBe(2);
    expect((await q("filter=numero:in:1,3")).data.total).toBe(2);
    expect((await q("filter=date_encaissement:empty")).data.total).toBe(1);
    expect((await q("q=juillet")).data.total).toBe(1);
    expect((await q("filter=nope:eq:1")).status).toBe(400);
    expect((await q("filter=ca_ht:eq:abc")).status).toBe(400);
    expect((await q("filter=titre:drop:1")).status).toBe(400);
    expect((await q('sort=titre";DROP TABLE factures;--:asc')).status).toBe(400);
    expect((await q("cursor=garbage")).status).toBe(400);
  });

  test("writes are validated, archived, recorded as app changes and revertible", async () => {
    await app();
    const clientA = (await t!.api("GET", "/api/data/search?q=Client A")).data[0];
    expect(clientA).toMatchObject({ collection: "clients", row: { title: "Client A" } });

    const bad = async (values: unknown) => (await t!.api("POST", "/api/data/collections/factures/rows", { values })).status;
    expect(await bad({ jours: "dix" })).toBe(400);
    expect(await bad({ date_emission: "2026-02-30" })).toBe(400);
    expect(await bad({ client_id: "missing" })).toBe(400);
    expect(await bad({ societe: ["inconnue"] })).toBe(400);
    expect(await bad({ ca_ht: 10 })).toBe(400);
    expect(await bad({ id: "x" })).toBe(400);
    expect(await bad({ paye: "yes" })).toBe(400);

    const created = await t!.api("POST", "/api/data/collections/factures/rows", {
      values: { titre: "Septembre 2026", numero: 4, jours: 2, client_id: clientA.row.id, societe: ["alpha"], date_emission: "2026-09-30", paye: false },
    });
    expect(created.status).toBe(200);
    expect(created.data.values).toMatchObject({ ca_ht: 1000, ttc: 1200, annee: 2026, mois: 9, client_id: clientA.row.id });
    const id = created.data.id;
    const patched = await t!.api("PATCH", `/api/data/collections/factures/rows/${id}`, { values: { jours: 3, paye: true } });
    expect(patched.data.values).toMatchObject({ jours: 3, paye: true, ca_ht: 1500 });

    const detail = (await t!.api("GET", `/api/data/collections/factures/rows/${id}`)).data;
    expect(detail.history.map((h: any) => [h.op, h.source])).toEqual([
      ["update", "app"],
      ["insert", "app"],
    ]);
    expect(detail.history[0].changes).toEqual({ jours: [2, 3], paye: [false, true] });

    expect((await t!.api("POST", `/api/data/collections/factures/rows/${id}/archive`)).data.archivedAt).toBeDefined();
    expect((await t!.api("GET", "/api/data/collections/factures/rows")).data.total).toBe(3);
    expect((await t!.api("GET", "/api/data/collections/factures/rows?archived=1")).data.total).toBe(4);
    expect((await t!.api("POST", `/api/data/collections/factures/rows/${id}/unarchive`)).data.archivedAt).toBeUndefined();

    const changes = (await t!.api("GET", `/api/data/history?collection=factures&rowId=${id}`)).data;
    const update = changes.find((c: any) => c.op === "update");
    const revert = await t!.api("POST", `/api/data/history/${update.id}/revert`);
    expect(revert.data).toMatchObject({ op: "revert", source: "app", changes: { jours: [3, 2], paye: [true, false] } });
    expect((await t!.api("GET", `/api/data/collections/factures/rows/${id}`)).data.row.values.jours).toBe(2);
    expect((await t!.api("POST", "/api/data/history/999999/revert")).status).toBe(404);
    expect((await t!.api("GET", "/api/data/collections/nope/rows")).status).toBe(404);
  });

  test("row files are served from data/files only", async () => {
    await app();
    const ok = await fetch(`${t!.base}/api/data/files?path=factures/f0000003/Facture_0003.pdf`, { headers: { authorization: `Bearer ${t!.token}` } });
    expect(ok.status).toBe(200);
    expect(await ok.text()).toContain("fake invoice");
    for (const p of ["../data.db", "/etc/passwd", "factures/../../data.db"]) {
      expect((await t!.api("GET", `/api/data/files?path=${encodeURIComponent(p)}`)).status).toBe(400);
    }
  });

  test("groups rows by year, month, ref or bool with money sums, honouring filters", async () => {
    await app();
    const groups = async (query: string) => (await t!.api("GET", `/api/data/collections/factures/groups?${query}`)).data;
    const sums = (ca_ht: number, tjm: number) => ({ tjm, ca_ht, tva: ca_ht * 0.2, ttc: ca_ht * 1.2 });

    expect(await groups("by=date_emission")).toEqual({
      by: "date_emission",
      groups: [
        { key: "2026", count: 2, sums: sums(14000, 1000) },
        { key: "2025", count: 1, sums: sums(12000, 600) },
      ],
      total: { count: 3, sums: sums(26000, 1600) },
    });
    expect((await groups("by=date_emission:month")).groups.map((g: any) => [g.key, g.sums.ca_ht])).toEqual([
      ["2026-08", 5000],
      ["2026-07", 9000],
      ["2025-11", 12000],
    ]);
    expect((await groups("by=client_id")).groups.map((g: any) => [g.label, g.count, g.sums.ttc])).toEqual([
      ["Client A", 2, 16800],
      ["Client B", 1, 14400],
    ]);
    const unpaid2026 = await groups(`by=paye&filter=${encodeURIComponent("date_emission:gte:2026")}`);
    expect(unpaid2026.groups.map((g: any) => [g.key, g.count, g.sums.ca_ht])).toEqual([
      [false, 1, 5000],
      [true, 1, 9000],
    ]);
    expect(unpaid2026.total).toEqual({ count: 2, sums: sums(14000, 1000) });

    for (const bad of ["by=societe", "by=paye:year", "by=date_emission:week", "by=nope", ""]) {
      expect((await t!.api("GET", `/api/data/collections/factures/groups?${bad}`)).status).toBe(400);
    }
    expect((await t!.api("GET", "/api/data/collections/nope/groups?by=titre")).status).toBe(404);
  });

  test("attach files to a row's file column, never overwriting", async () => {
    await app();
    const row = (await t!.api("GET", "/api/data/collections/factures/rows?limit=1")).data.rows[0];
    expect(row.values.numero).toBe(3);
    const attach = (column: string, name: string, body: Uint8Array) =>
      fetch(`${t!.base}/api/data/collections/factures/rows/${row.id}/files/${column}?name=${encodeURIComponent(name)}`, {
        method: "POST",
        headers: { authorization: `Bearer ${t!.token}`, "content-type": "application/pdf" },
        body,
      });
    const pdf = new Uint8Array([0x25, 0x50, 0x44, 0x46, 0x2d, 1, 2, 255]);

    const first = await attach("pdf", "Avoir_0003.pdf", pdf);
    expect(first.status).toBe(201);
    const second = await attach("pdf", "../../Avoir_0003.pdf", pdf);
    const files = (await second.json()).values.pdf;
    expect(files).toEqual([
      { name: "Facture_0003.pdf", path: "factures/f0000003/Facture_0003.pdf" },
      { name: "Avoir_0003.pdf", path: `factures/${row.id}/Avoir_0003.pdf` },
      { name: "Avoir_0003-2.pdf", path: `factures/${row.id}/Avoir_0003-2.pdf` },
    ]);
    const served = await fetch(`${t!.base}/api/data/files?path=${encodeURIComponent(files[2].path)}`, { headers: { authorization: `Bearer ${t!.token}` } });
    expect(Buffer.from(await served.arrayBuffer()).equals(Buffer.from(pdf))).toBe(true);
    const history = (await t!.api("GET", `/api/data/history?collection=factures&rowId=${row.id}`)).data;
    expect(history[0]).toMatchObject({ op: "update", source: "app" });

    expect((await attach("titre", "Avoir_0003.pdf", pdf)).status).toBe(400);
    expect((await attach("pdf", "..", pdf)).status).toBe(400);
    const missing = await fetch(`${t!.base}/api/data/collections/factures/rows/nope/files/pdf?name=a.pdf`, {
      method: "POST",
      headers: { authorization: `Bearer ${t!.token}` },
      body: pdf,
    });
    expect(missing.status).toBe(404);
    expect(existsSync(join(t!.dataDir, "files", "factures", "nope"))).toBe(false);
  });
});

describe("reminders", () => {
  function setup(at: string) {
    const db = freshDb();
    let now = Date.parse(at);
    const reminders = new Reminders(db, () => now);
    const pusher = new FakePusher();
    const device = { id: "d1", name: "iPhone", apnsToken: "ab".repeat(32), apnsEnv: "development" } as any;
    const notifier = new ReminderNotifier(reminders, pusher, () => [device], 30_000);
    return { db, reminders, pusher, notifier, set: (iso: string) => (now = Date.parse(iso)) };
  }

  test("a due reminder is pushed once, snoozing pushes it again", async () => {
    const r = setup("2026-10-18T08:00:00Z");
    const rem = r.reminders.create({ title: "Payer l'URSSAF", notes: "Avant le 20", dueAt: "2026-10-18T09:00:00Z", priority: 2 });
    expect(await r.notifier.tick()).toEqual([]);
    r.set("2026-10-18T09:00:10Z");
    expect((await r.notifier.tick()).map((x) => x.id)).toEqual([rem.id]);
    expect(r.pusher.sent[0]!.payload).toMatchObject({ title: "Payer l'URSSAF", body: "Avant le 20", reminderId: rem.id, category: "nuo.reminder", destination: { kind: "reminder", id: rem.id } });
    expect(await r.notifier.tick()).toEqual([]);
    expect(r.reminders.list("overdue").map((x) => x.id)).toEqual([rem.id]);

    r.reminders.snooze(rem.id, { minutes: 60 });
    r.set("2026-10-18T09:30:00Z");
    expect(await r.notifier.tick()).toEqual([]);
    expect(r.reminders.list("overdue")).toEqual([]);
    r.set("2026-10-18T10:01:00Z");
    expect((await r.notifier.tick()).length).toBe(1);
    expect(r.pusher.sent).toHaveLength(2);

    r.reminders.snooze(rem.id, { minutes: 30 });
    r.reminders.patch(rem.id, { dueAt: "2026-10-18T09:30:00Z" });
    expect(r.reminders.one(rem.id).snoozedUntil).toBeUndefined();
    expect((await r.notifier.tick()).length).toBe(1);

    r.reminders.done(rem.id);
    expect(r.reminders.list("done").map((x) => x.id)).toEqual([rem.id]);
    expect(r.reminders.list("all")).toEqual([]);
  });

  test("a repeating reminder moves to its next occurrence in Paris time", () => {
    const r = setup("2026-10-18T07:30:00Z");
    // 09:00 Paris = 07:00Z in summer time (until 25 October), 08:00Z after.
    const daily = r.reminders.create({ title: "Vitamines", dueAt: "2026-10-18T07:00:00Z", repeat: "daily" });
    expect(r.reminders.done(daily.id)).toMatchObject({ dueAt: "2026-10-19T07:00:00.000Z" });
    expect(r.reminders.done(daily.id).dueAt).toBe("2026-10-20T07:00:00.000Z");
    const cron = r.reminders.create({ title: "Revue", dueAt: "2026-10-23T07:00:00Z", repeat: "0 9 * * 5" });
    expect(r.reminders.done(cron.id).dueAt).toBe("2026-10-30T08:00:00.000Z");
    expect(r.reminders.one(cron.id).doneAt).toBeUndefined();
    expect(() => r.reminders.create({ title: "x", repeat: "every day" })).toThrow();
  });

  test("scopes split today and upcoming on the Paris day; agents can insert directly", () => {
    const r = setup("2026-10-18T20:00:00Z"); // 22:00 in Paris
    r.db.exec("INSERT INTO reminders (title, due_at) VALUES ('ce soir', '2026-10-18T21:30:00Z'), ('demain', '2026-10-18T22:30:00Z')");
    expect(r.reminders.list("today").map((x) => x.title)).toEqual(["ce soir"]);
    expect(r.reminders.list("upcoming").map((x) => x.title)).toEqual(["demain"]);
    expect(r.reminders.list("all").every((x) => x.list === "inbox")).toBe(true);
  });

  test("REST endpoints", async () => {
    t = await startTestApp({ data: { autoStart: false } });
    const c = await t.api("POST", "/api/reminders", { title: "Appeler le comptable", dueAt: "2030-01-02T09:00:00+01:00", list: "Lumen Studio" });
    expect(c.data).toMatchObject({ title: "Appeler le comptable", dueAt: "2030-01-02T08:00:00.000Z", list: "Lumen Studio", priority: 0 });
    expect((await t.api("PATCH", `/api/reminders/${c.data.id}`, { priority: 5 })).status).toBe(400);
    expect((await t.api("PATCH", `/api/reminders/${c.data.id}`, { priority: 3 })).data.priority).toBe(3);
    expect((await t.api("GET", "/api/reminders?scope=upcoming&list=Lumen%20Studio")).data).toHaveLength(1);
    await t.api("POST", "/api/reminders", { title: "Sans liste" });
    expect((await t.api("GET", "/api/reminders/lists")).data).toEqual([
      { id: "inbox", label: "Boîte de réception", count: 1 },
      { id: "Lumen Studio", label: "Lumen Studio", count: 1 },
    ]);
    expect((await t.api("POST", `/api/reminders/${c.data.id}/snooze`, { until: "2030-01-03T08:00:00Z" })).data.snoozedUntil).toBe("2030-01-03T08:00:00.000Z");
    expect((await t.api("POST", `/api/reminders/${c.data.id}/done`)).data.doneAt).toBeDefined();
    expect((await t.api("POST", `/api/reminders/${c.data.id}/undone`)).data.doneAt).toBeUndefined();
    expect((await t.api("DELETE", `/api/reminders/${c.data.id}`)).status).toBe(204);
    expect((await t.api("GET", "/api/reminders")).data.map((r: any) => r.title)).toEqual(["Sans liste"]);
    expect((await t.api("GET", "/api/reminders?scope=later")).status).toBe(400);
    expect((await t.api("GET", `/api/data/history?collection=reminders&rowId=${c.data.id}`)).data[0]).toMatchObject({ op: "archive", source: "app" });
  });
});

describe("dashboards", () => {
  test("blocks are computed from read-only queries", async () => {
    const { db } = imported();
    const dir = tmp();
    const path = (db.query("PRAGMA database_list").get() as any).file;
    writeFileSync(
      join(dir, "test.json"),
      JSON.stringify({
        title: "Test",
        emoji: "🧪",
        blocks: [
          { type: "number", title: "CA 2026", sql: "SELECT sum(ca_ht) AS value FROM v_factures WHERE annee = 2026", format: "money" },
          { type: "bar", title: "Par client", sql: "SELECT annee AS x, sum(ca_ht) AS y, client AS s FROM v_factures GROUP BY annee, client ORDER BY annee" },
          { type: "table", title: "Factures", sql: "SELECT id, titre FROM v_factures ORDER BY numero;", collection: "factures" },
          { type: "list", title: "Clients", sql: "SELECT nom AS title, tjm AS value, id FROM clients ORDER BY nom" },
          { type: "table", title: "Écriture", sql: "INSERT INTO clients (nom) VALUES ('pirate')" },
          { type: "table", title: "Écriture cachée", sql: "WITH x AS (SELECT 1) INSERT INTO clients (nom) SELECT 'pirate' FROM x" },
          { type: "table", title: "Deux requêtes", sql: "SELECT 1; DELETE FROM clients" },
          { type: "number", title: "Erreur", sql: "SELECT nope FROM nowhere" },
        ],
      }),
    );
    writeFileSync(join(dir, "broken.json"), "{");
    const d = new Dashboards(dir, path);
    expect(d.list()).toEqual([{ slug: "test", title: "Test", emoji: "🧪" }]);
    const out = await d.get("test");
    expect(out.blocks[0]).toMatchObject({ value: 14000, format: "money" });
    expect(out.blocks[1]!.series).toEqual([
      { name: "Client B", points: [{ x: 2025, y: 12000 }] },
      { name: "Client A", points: [{ x: 2026, y: 14000 }] },
    ]);
    expect(out.blocks[2]).toMatchObject({ columns: ["id", "titre"], collection: "factures" });
    expect(out.blocks[2]!.rows).toHaveLength(3);
    expect(out.blocks[3]!.items![0]).toMatchObject({ title: "Client A", value: 500 });
    for (const b of out.blocks.slice(4)) expect(b.error).toBeDefined();
    expect((db.query("SELECT count(*) AS n FROM clients").get() as any).n).toBe(2);
    await expect(d.get("../etc")).rejects.toThrow();
    d.close();
  });

  test("a slow query is stopped after the time limit and the worker restarts for the next ones", async () => {
    const db = freshDb();
    const path = (db.query("PRAGMA database_list").get() as any).file;
    const slow = "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) SELECT count(*) FROM n";
    const w = new QueryWorker(path);
    const r = await Promise.all(["SELECT 1 AS a", slow, "SELECT 2 AS b"].map((sql) => w.query(sql, 300)));
    w.close();
    expect(r).toEqual([
      { columns: ["a"], rows: [[1]], truncated: false },
      { error: "query took longer than 0.3 s" },
      { columns: ["b"], rows: [[2]], truncated: false },
    ]);
  });

  test("a computed dashboard is kept until data.db or its file changes", async () => {
    const db = freshDb();
    const path = (db.query("PRAGMA database_list").get() as any).file;
    const dir = tmp();
    const def = (sql: string) => writeFileSync(join(dir, "n.json"), JSON.stringify({ title: "N", blocks: [{ type: "number", title: "Clients", sql }] }));
    def("SELECT count(*) AS value FROM clients");
    const d = new Dashboards(dir, path, 2000, () => changeVersion(db));
    const value = async () => (await d.get("n")).blocks[0]!.value;
    const first = await d.get("n");
    expect(first.blocks[0]!.value).toBe(0);
    expect(await d.get("n")).toBe(first);
    db.exec("INSERT INTO clients (nom) VALUES ('Acme')");
    expect(await value()).toBe(1);
    const agent = new Database(path);
    agent.exec("INSERT INTO clients (nom) VALUES ('Globex')");
    agent.close();
    expect(await value()).toBe(2);
    def("SELECT count(*) * 10 AS value FROM clients");
    expect(await value()).toBe(20);
    d.close();
  });

  test("starter dashboards are copied on the first run and served", async () => {
    t = await startTestApp({ data: { autoStart: false } });
    await t.api("POST", "/api/reminders", { title: "Relancer le devis Lumen Studio", dueAt: "2020-03-02T09:00:00Z", list: "Lumen Studio" });
    await t.api("POST", "/api/reminders", { title: "Renouveler le passeport", dueAt: "2030-05-12T08:00:00Z" });
    const list = (await t.api("GET", "/api/dashboards")).data;
    expect(list.map((d: any) => d.slug)).toContain("rappels");
    const reminders = (await t.api("GET", "/api/dashboards/rappels")).data;
    expect(reminders.blocks.every((b: any) => !b.error)).toBe(true);
    expect(reminders.blocks.slice(0, 2).map((b: any) => b.value)).toEqual([2, 1]);
    expect(reminders.blocks[3].rows.map((r: any[]) => r[1])).toEqual(["Relancer le devis Lumen Studio", "Renouveler le passeport"]);
    expect((await t.api("GET", "/api/dashboards/nope")).status).toBe(404);
  });
});

describe("docs", () => {
  test("read, write with commits, stale baseSha, trash, search and traversal", async () => {
    t = await startTestApp({ data: { autoStart: false } });
    const docs = join(t.profileHome, "docs");
    expect(gitSync(docs, ["log", "--format=%s"]).out.trim()).toBe("docs: Initial commit");

    const created = await t.api("POST", "/api/docs/file", { path: "santé/plan.md", content: "# Plan\n\nMarcher 30 min.\n" });
    expect(created.status).toBe(201);
    expect((await t.api("POST", "/api/docs/file", { path: "santé/plan.md", content: "" })).status).toBe(409);
    const read = (await t.api("GET", `/api/docs/file?path=${encodeURIComponent("santé/plan.md")}`)).data;
    expect(read).toMatchObject({ path: "santé/plan.md", content: "# Plan\n\nMarcher 30 min.\n", sha: created.data.sha });
    expect(read.sha).toBe(gitSync(docs, ["hash-object", "santé/plan.md"]).out.trim());

    const upd = await t.api("PUT", "/api/docs/file", { path: "santé/plan.md", content: "# Plan\n\nMarcher 45 min.\n", baseSha: read.sha });
    expect(upd.status).toBe(200);
    expect((await t.api("PUT", "/api/docs/file", { path: "santé/plan.md", content: "conflit", baseSha: read.sha })).status).toBe(409);
    const log = gitSync(docs, ["log", "--format=%an <%ae>|%s"]).out.trim().split("\n");
    expect(log.slice(0, 2)).toEqual(["Nuo <nuo@dev>|docs(app): Update santé/plan.md", "Nuo <nuo@dev>|docs(app): Create santé/plan.md"]);

    const tree = (await t.api("GET", "/api/docs/tree")).data;
    expect(tree.map((n: any) => [n.path, n.kind])).toEqual([
      ["santé", "dir"],
      ["santé/plan.md", "file"],
    ]);
    expect((await t.api("GET", "/api/docs/search?q=marcher")).data).toEqual([{ path: "santé/plan.md", line: 3, snippet: "Marcher 45 min." }]);

    mkdirSync(join(docs, "santé", "img"));
    const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 1, 2]);
    writeFileSync(join(docs, "santé", "img", "courbe.png"), png);
    const raw = await fetch(`${t.base}/api/docs/raw?path=${encodeURIComponent("santé/img/courbe.png")}`, { headers: { authorization: `Bearer ${t.token}` } });
    expect(raw.status).toBe(200);
    expect(raw.headers.get("content-type")).toBe("image/png");
    expect(raw.headers.get("cache-control")).toContain("private");
    expect(Buffer.from(await raw.arrayBuffer()).equals(png)).toBe(true);
    const again = await fetch(`${t.base}/api/docs/raw?path=${encodeURIComponent("santé/img/courbe.png")}`, {
      headers: { authorization: `Bearer ${t.token}`, "if-none-match": raw.headers.get("etag")! },
    });
    expect(again.status).toBe(304);
    rmSync(join(docs, "santé", "img"), { recursive: true });

    mkdirSync(join(t.home, "outside"));
    writeFileSync(join(t.home, "outside", "secret.md"), "secret");
    symlinkSync(join(t.home, "outside"), join(docs, "lien"));
    for (const p of ["../outside/secret.md", "/etc/passwd", "lien/secret.md", ".git/config", ".trash/x.md"]) {
      expect((await t.api("GET", `/api/docs/file?path=${encodeURIComponent(p)}`)).status).toBe(400);
      expect((await t.api("PUT", "/api/docs/file", { path: p, content: "x" })).status).toBe(400);
      expect((await t.api("GET", `/api/docs/raw?path=${encodeURIComponent(p)}`)).status).toBe(400);
    }

    expect((await t.api("DELETE", `/api/docs/file?path=${encodeURIComponent("santé/plan.md")}`)).status).toBe(204);
    expect(existsSync(join(docs, ".trash", "santé", "plan.md"))).toBe(true);
    expect((await t.api("GET", `/api/docs/file?path=${encodeURIComponent("santé/plan.md")}`)).status).toBe(404);
    expect(gitSync(docs, ["log", "-1", "--format=%s"]).out.trim()).toBe("docs(app): Delete santé/plan.md");
    expect(gitSync(docs, ["status", "--porcelain"]).out.trim()).toBe("?? lien");
  });

  test("upload binary files next to a document, never overwriting", async () => {
    t = await startTestApp({ data: { autoStart: false } });
    const docs = join(t.profileHome, "docs");
    const upload = (path: string, body: Uint8Array) =>
      fetch(`${t.base}/api/docs/upload?path=${encodeURIComponent(path)}`, { method: "POST", headers: { authorization: `Bearer ${t.token}`, "content-type": "application/pdf" }, body });
    const pdf = new Uint8Array([0x25, 0x50, 0x44, 0x46, 0x2d, 0, 1, 2, 255]);

    const first = await upload("santé/_fichiers/rapport.pdf", pdf);
    expect(first.status).toBe(201);
    expect(await first.json()).toEqual({ path: "santé/_fichiers/rapport.pdf", size: pdf.byteLength });
    expect(Buffer.from(readFileSync(join(docs, "santé", "_fichiers", "rapport.pdf"))).equals(Buffer.from(pdf))).toBe(true);
    expect(gitSync(docs, ["log", "-1", "--format=%s"]).out.trim()).toBe("docs(app): Add santé/_fichiers/rapport.pdf");

    const second = await upload("santé/_fichiers/rapport.pdf", new Uint8Array([1]));
    expect((await second.json()).path).toBe("santé/_fichiers/rapport-2.pdf");
    expect(Buffer.from(readFileSync(join(docs, "santé", "_fichiers", "rapport.pdf"))).equals(Buffer.from(pdf))).toBe(true);

    const raw = await fetch(`${t.base}/api/docs/raw?path=${encodeURIComponent("santé/_fichiers/rapport-2.pdf")}`, { headers: { authorization: `Bearer ${t.token}` } });
    expect(raw.status).toBe(200);

    expect((await upload("../dehors.pdf", pdf)).status).toBe(400);
    expect((await upload(".git/objects/x", pdf)).status).toBe(400);
    expect((await upload("notes.md", pdf)).status).toBe(400);
  });

  test("move files and folders, create and delete folders", async () => {
    t = await startTestApp({ data: { autoStart: false } });
    const docs = join(t.profileHome, "docs");
    const subject = () => gitSync(docs, ["log", "-1", "--format=%s"]).out.trim();
    const paths = async () => (await t.api("GET", "/api/docs/tree")).data.map((n: any) => `${n.kind === "dir" ? "d" : "f"}:${n.path}`);
    await t.api("POST", "/api/docs/file", { path: "a.md", content: "A" });
    await t.api("POST", "/api/docs/file", { path: "projets/b.md", content: "B" });

    const folder = await t.api("POST", "/api/docs/folder", { path: "archives/2026" });
    expect(folder).toMatchObject({ status: 201, data: { path: "archives/2026" } });
    expect(subject()).toBe("docs(app): Create folder archives/2026");
    expect((await t.api("POST", "/api/docs/folder", { path: "archives/2026" })).status).toBe(409);
    expect((await t.api("POST", "/api/docs/folder", { path: "a.md/x" })).status).toBe(400);
    expect(await paths()).toEqual(["f:a.md", "d:archives", "d:archives/2026", "d:projets", "f:projets/b.md"]);

    expect((await t.api("POST", "/api/docs/move", { from: "a.md", to: "archives/2026/a.md" })).data).toEqual({ path: "archives/2026/a.md", kind: "file" });
    expect(subject()).toBe("docs(app): Move a.md → archives/2026/a.md");
    expect(readFileSync(join(docs, "archives/2026/a.md"), "utf8")).toBe("A");

    expect((await t.api("POST", "/api/docs/move", { from: "projets/b.md", to: "neuf/sous/b.md" })).status).toBe(200);
    expect(existsSync(join(docs, "projets", ".keep"))).toBe(true);
    expect((await t.api("POST", "/api/docs/move", { from: "projets", to: "archives/projets" })).data).toEqual({ path: "archives/projets", kind: "dir" });
    expect(await paths()).toEqual(["d:archives", "d:archives/2026", "f:archives/2026/a.md", "d:archives/projets", "d:neuf", "d:neuf/sous", "f:neuf/sous/b.md"]);
    expect(gitSync(docs, ["status", "--porcelain"]).out.trim()).toBe("");

    expect((await t.api("POST", "/api/docs/move", { from: "archives", to: "archives/2026/x" })).status).toBe(400);
    expect((await t.api("POST", "/api/docs/move", { from: "neuf/sous/b.md", to: "archives/2026/a.md" })).status).toBe(409);
    expect((await t.api("POST", "/api/docs/move", { from: "nope.md", to: "x.md" })).status).toBe(404);
    expect((await t.api("POST", "/api/docs/move", { from: "neuf/sous/b.md", to: "archives/2026/a.md/b.md" })).status).toBe(400);
    for (const [from, to] of [["../x", "y"], ["neuf", ".git/neuf"], ["neuf", ".trash/neuf"], ["neuf", "/etc/neuf"]]) {
      expect((await t.api("POST", "/api/docs/move", { from, to })).status).toBe(400);
    }

    expect((await t.api("DELETE", `/api/docs/folder?path=archives`)).status).toBe(204);
    expect(subject()).toBe("docs(app): Delete folder archives");
    expect(existsSync(join(docs, ".trash", "archives", "2026", "a.md"))).toBe(true);
    expect((await t.api("DELETE", `/api/docs/folder?path=archives`)).status).toBe(404);
    expect((await t.api("DELETE", `/api/docs/folder?path=neuf/sous/b.md`)).status).toBe(404);
    expect(await paths()).toEqual(["d:neuf", "d:neuf/sous", "f:neuf/sous/b.md"]);
    expect(gitSync(docs, ["status", "--porcelain"]).out.trim()).toBe("");
  });

  test("pins follow moves and deletions, outside the docs repo", async () => {
    t = await startTestApp({ data: { autoStart: false } });
    const docs = join(t.profileHome, "docs");
    for (const p of ["a.md", "projets/b.md", "projets/c.md", "notes/d.md"]) await t.api("POST", "/api/docs/file", { path: p, content: p });
    expect((await t.api("GET", "/api/docs/pins")).data).toEqual({ paths: [] });
    const set = await t.api("PUT", "/api/docs/pins", { paths: ["projets/b.md", "a.md", "./a.md", "projets", "notes/d.md"] });
    expect(set.data).toEqual({ paths: ["projets/b.md", "a.md", "projets", "notes/d.md"] });
    expect((await t.api("PUT", "/api/docs/pins", { paths: ["../x.md"] })).status).toBe(400);
    expect((await t.api("PUT", "/api/docs/pins", { paths: "a.md" })).status).toBe(400);

    await t.api("POST", "/api/docs/move", { from: "projets", to: "archives/projets" });
    await t.api("POST", "/api/docs/move", { from: "a.md", to: "archives/a.md" });
    await t.api("DELETE", `/api/docs/folder?path=notes`);
    expect((await t.api("GET", "/api/docs/pins")).data).toEqual({ paths: ["archives/projets/b.md", "archives/a.md", "archives/projets"] });
    await t.api("DELETE", `/api/docs/file?path=${encodeURIComponent("archives/projets/b.md")}`);
    rmSync(join(docs, "archives", "a.md"));
    expect((await t.api("GET", "/api/docs/pins")).data).toEqual({ paths: ["archives/projets"] });
    expect(gitSync(docs, ["ls-files"]).out).not.toContain("pins");
  });
});

describe("docs import", () => {
  test("docs export trees are copied and committed once", () => {
    const src = tmp();
    const docs = join(tmp(), "docs");
    initDocsRepo(docs);
    mkdirSync(join(src, "Perso", "Santé"), { recursive: true });
    writeFileSync(join(src, "Perso", "Santé", "Sport.md"), "# Sport\n\n![](img/courbe.png)\n");
    mkdirSync(join(src, "Perso", "Santé", "img"));
    writeFileSync(join(src, "Perso", "Santé", "img", "courbe.png"), Buffer.from([0x89, 0x50]));
    expect(importDocsTree(src, docs, { dryRun: true })).toEqual({ added: 2, changed: 0, unchanged: 0, committed: false });
    expect(existsSync(join(docs, "Perso"))).toBe(false);
    expect(importDocsTree(src, docs)).toEqual({ added: 2, changed: 0, unchanged: 0, committed: true });
    expect(gitSync(docs, ["log", "-1", "--format=%an|%s"]).out.trim()).toBe("Nuo|docs(import): Import Notion pages");
    expect(importDocsTree(src, docs)).toEqual({ added: 0, changed: 0, unchanged: 2, committed: false });
  });
});

describe("places and location reminders", () => {
  test("places CRUD and location reminders over REST; the gateway never pushes them", async () => {
    t = await startTestApp({ data: { autoStart: false } });
    expect((await t.api("POST", "/api/places", { name: "Salle", lat: 95, lon: 2 })).status).toBe(400);
    const place = (await t.api("POST", "/api/places", { name: "Salle de sport", address: "1 rue X", lat: 48.85, lon: 2.35 })).data;
    expect(place).toMatchObject({ name: "Salle de sport", lat: 48.85, lon: 2.35, radiusM: 150 });
    expect((await t.api("PATCH", `/api/places/${place.id}`, { radiusM: 200 })).data.radiusM).toBe(200);

    expect((await t.api("POST", "/api/reminders", { title: "x", placeId: "nope" })).status).toBe(400);
    expect((await t.api("POST", "/api/reminders", { title: "x", placeId: place.id, placeTrigger: "near" })).status).toBe(400);
    expect((await t.api("POST", "/api/reminders", { title: "x", placeTrigger: "leave" })).status).toBe(400);
    const loc = (await t.api("POST", "/api/reminders", { title: "Prendre la serviette", placeId: place.id })).data;
    expect(loc).toMatchObject({ placeTrigger: "arrive", place: { id: place.id, name: "Salle de sport", lat: 48.85, lon: 2.35, radiusM: 200 } });
    expect(loc.dueAt).toBeUndefined();
    const both = (await t.api("POST", "/api/reminders", { title: "Les deux", placeId: place.id, placeTrigger: "leave", dueAt: "2020-01-01T08:00:00Z" })).data;

    expect((await t.app.data.notifier.tick()).map((r) => r.id)).toEqual([both.id]);

    expect((await t.api("DELETE", `/api/places/${place.id}`)).status).toBe(204);
    expect((await t.api("GET", "/api/places")).data).toEqual([]);
    const kept = (await t.api("GET", "/api/reminders")).data.find((r: any) => r.id === loc.id);
    expect(kept.place.name).toBe("Salle de sport");
    expect((await t.api("PATCH", `/api/reminders/${loc.id}`, { placeTrigger: "leave" })).data.placeTrigger).toBe("leave");
    const cleared = (await t.api("PATCH", `/api/reminders/${loc.id}`, { placeId: null })).data;
    expect(cleared.place).toBeUndefined();
    expect(cleared.placeTrigger).toBeUndefined();
    expect((await t.api("GET", "/api/data/history?collection=places")).data[0]).toMatchObject({ op: "archive", source: "app" });

    t.app.data.db.exec("INSERT INTO places (id, name, lat, lon) VALUES ('agent-place', 'Bureau', 48.9, 2.3)");
    const agentChange = (await t.api("GET", "/api/data/history?collection=places&rowId=agent-place")).data[0];
    expect(agentChange).toMatchObject({ op: "insert", source: "agent", collection: "places" });
    expect((await t.api("POST", `/api/data/history/${agentChange.id}/revert`)).data).toMatchObject({ op: "revert", source: "app" });
    expect((await t.api("GET", "/api/places")).data).toEqual([]);
  });
});

describe("bot instructions", () => {
  const paths = { home: "/r", db: "/r/data/data.db", docs: "/r/docs", dashboards: "/r/dashboards" };
  test("only shell bots get the data rules", () => {
    const auto = effectiveInstructions(botConfig({ permissionPolicy: "auto" }) as any, undefined, "", paths);
    expect(auto).toContain("## Données et documents");
    expect(auto).toContain("/r/data/data.db");
    expect(auto).toContain("Ne fais jamais de `DELETE`");
    expect(auto).toContain("Ne crée, ne déplace et ne supprime jamais de lieu");
    const ro = effectiveInstructions(botConfig({ permissionPolicy: "readonly" }) as any, undefined, "", paths);
    expect(ro).toContain("gérées par Cobot");
    expect(ro).not.toContain("data.db");
  });
});


describe("areas and projects", () => {
  test("projects group reminders under headings, complete with them and show their progress", async () => {
    t = await startTestApp();
    const area = (await t.api("POST", "/api/areas", { title: "Pro", emoji: "💼" })).data;
    const project = (await t.api("POST", "/api/projects", { title: "Lancer Nuo", areaId: area.id, deadline: "2026-12-01" })).data;
    expect(project).toMatchObject({ areaId: area.id, status: "open", openCount: 0, progress: 0, someday: false });
    expect((await t.api("POST", "/api/projects", { title: "X", deadline: "2026-13-01" })).status).toBe(400);
    const heading = (await t.api("POST", `/api/projects/${project.id}/headings`, { title: "Beta" })).data;

    const a = (await t.api("POST", "/api/reminders", { title: "Widgets", projectId: project.id })).data;
    const b = (await t.api("POST", "/api/reminders", { title: "TestFlight", headingId: heading.id, checklist: [{ title: "Build" }, { title: "Notes", done: true }] })).data;
    expect(b).toMatchObject({ projectId: project.id, headingId: heading.id, area: { id: area.id, title: "Pro" }, project: { title: "Lancer Nuo" } });
    expect(b.checklist).toEqual([{ title: "Build", done: false }, { title: "Notes", done: true }]);
    expect(b.position).toBeGreaterThan(a.position);
    expect((await t.api("POST", "/api/reminders", { title: "Y", projectId: project.id, areaId: area.id })).status).toBe(400);

    await t.api("POST", `/api/reminders/${a.id}/done`);
    const detail = (await t.api("GET", `/api/projects/${project.id}`)).data;
    expect(detail.project).toMatchObject({ openCount: 1, doneCount: 1, progress: 0.5 });
    expect(detail.headings.map((h: any) => h.title)).toEqual(["Beta"]);
    expect(detail.reminders.map((r: any) => r.title)).toEqual(["TestFlight", "Widgets"]);

    const loose = (await t.api("POST", "/api/reminders", { title: "Inbox" })).data;
    await t.api("POST", "/api/reminders", { title: "Plus tard", someday: true });
    const overview = (await t.api("GET", "/api/reminders/overview")).data;
    expect(overview.counts).toMatchObject({ inbox: 1, someday: 1, anytime: 2 });
    expect(overview.areas[0]).toMatchObject({ title: "Pro", projects: [{ id: project.id }] });
    expect((await t.api("GET", `/api/reminders?area=${area.id}`)).data.map((r: any) => r.id)).toEqual([b.id]);

    const moved = (await t.api("PATCH", `/api/reminders/${loose.id}`, { areaId: area.id })).data;
    expect(moved).toMatchObject({ areaId: area.id });
    expect((await t.api("PATCH", `/api/reminders/${b.id}`, { projectId: null })).data.headingId).toBeUndefined();

    expect((await t.api("POST", `/api/projects/${project.id}/done`, {})).data).toMatchObject({ status: "done", openCount: 0 });
    expect((await t.api("GET", "/api/projects")).data).toEqual([]);
    expect((await t.api("POST", `/api/projects/${project.id}/reopen`)).data.status).toBe("open");
    expect((await t.api("DELETE", `/api/areas/${area.id}`)).status).toBe(204);
    expect((await t.api("GET", `/api/projects/${project.id}`)).data.project.areaId).toBeUndefined();
    expect((await t.api("GET", "/api/data/history?collection=projects")).data[0]).toMatchObject({ source: "app" });
  });

  test("free-text lists become areas when the projects schema arrives", () => {
    const dir = tmp();
    const schema = join(dir, "schema");
    mkdirSync(schema);
    for (const f of ["001_core.sql", "005_places.sql"]) writeFileSync(join(schema, f), readFileSync(join(import.meta.dir, "../src/data/schema", f)));
    const path = join(dir, "data.db");
    const before = openDataDb(path, schema);
    before.exec("INSERT INTO reminders (id, title, list) VALUES ('r1', 'Lait', 'courses'), ('r2', 'Mail', 'inbox')");
    before.close();
    writeFileSync(join(schema, "007_projects.sql"), readFileSync(join(import.meta.dir, "../src/data/schema/007_projects.sql")));
    const db = openDataDb(path, schema);
    dbs.push(db);
    expect(db.query("SELECT title FROM areas").all()).toEqual([{ title: "Courses" }]);
    expect(db.query("SELECT id, area_id IS NOT NULL AS filed FROM reminders ORDER BY id").all()).toEqual([
      { id: "r1", filed: 1 },
      { id: "r2", filed: 0 },
    ]);
  });
});
