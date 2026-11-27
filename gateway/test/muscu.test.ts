import { Database } from "bun:sqlite";
import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Muscu, muscuFromEnv, parseSession, recap, type MuscuOptions } from "../src/muscu/service";
import { startTestApp, type TestApp } from "./helpers";

/** The chrono's catalog as the fitness repo ships it (webapp/chrono/exercises.js), cut to the gym's upper-body machines. */
const CATALOG = `"use strict";
const EXDB = [
  { k: "pec-fly",      n: "Pec Fly",                re: /pec fly|pec deck|butterfly/i, img: 1, mx: 1 },
  { k: "lat-pulldown", n: "Lat Pulldown",           re: /pull.?down|tirage (vertical|poitrine|nuque|haut)/i, img: 1, mx: 1 },
  { k: "chest-press",  n: "Chest Press machine",    re: /chest press|développé couché|bench press/i, img: 1, mx: 1, m: 1 },
  { k: "seated-row",   n: "Seated Row machine",     re: /rowing|\\brow\\b|tirage/i, img: 1, mx: 1, m: 1 },
  { k: "db-row",       n: "Rowing haltère",         re: /rowing|\\brow\\b/i, img: 1 },
];
const FREE_WEIGHT = /halt[eè]res?|dumbbell|kettlebell|\\bbarre\\b|poids du corps|bodyweight/i;
const findEx = (name) => {
  const n = String(name || "");
  const machine = !FREE_WEIGHT.test(n);
  for (const e of EXDB) if ((machine || !e.m) && e.re.test(n)) return e;
  return null;
};
const exThumb = (e) => (!e ? "" : e.mx ? "img/mx/" + e.k + ".jpg" : e.img ? "img/" + e.k + "-0.jpg" : "");
`;

/** « Haut du corps » as the coach's save_wod stores it (fitness repo, src/db/queries.ts normalizeWodConfig). */
const UPPER_BODY = {
  blocks: [
    {
      exercises: [
        { name: "Chest Press", reps: 10, alts: ["Pec Fly"] },
        { name: "Seated Row", reps: 10, alts: ["Rowing haltère"] },
      ],
    },
    {
      exercises: [
        { name: "Lat Pulldown", reps: 10, alts: ["Tirage vertical poulie haute"] },
        { name: "Lateral Raise", reps: 15, alts: [] },
      ],
    },
  ],
  sets: 3,
  rest: 75,
  restBlock: 120,
  rir: 2,
  days: [2],
};

const LEGS = {
  blocks: [{ exercises: [{ name: "Leg Press", reps: 10, alts: ["Hack Squat"] }] }],
  sets: 3,
  rest: 75,
  restBlock: 120,
  days: [4],
};

/** A fitness repo checkout: its database with the coach's tables and the chrono folder. */
function fitnessDir(): { dir: string; options: MuscuOptions; db: Database } {
  const dir = mkdtempSync(join(tmpdir(), "fitness-"));
  mkdirSync(join(dir, "data"));
  mkdirSync(join(dir, "webapp/chrono/img/mx"), { recursive: true });
  writeFileSync(join(dir, "webapp/chrono/exercises.js"), CATALOG);
  writeFileSync(join(dir, "webapp/chrono/img/mx/chest-press.jpg"), Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10]));
  const db = new Database(join(dir, "data/fitness.db"));
  db.exec(`
    CREATE TABLE workouts (id INTEGER PRIMARY KEY AUTOINCREMENT, day TEXT NOT NULL, title TEXT NOT NULL, detail TEXT, created_at TEXT NOT NULL DEFAULT (datetime('now','localtime')));
    CREATE TABLE wods (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, kind TEXT NOT NULL, config_json TEXT NOT NULL, note TEXT, created_at TEXT NOT NULL DEFAULT (datetime('now','localtime')));
  `);
  db.query("INSERT INTO wods (id, name, kind, config_json, note, created_at) VALUES (101, 'Haut du corps', 'sets', ?, 'Blocs dans l''ordre que tu veux.', '2026-09-07 18:30:00')").run(JSON.stringify(UPPER_BODY));
  db.query("INSERT INTO wods (id, name, kind, config_json, note, created_at) VALUES (102, 'Jambes + tronc', 'sets', ?, NULL, '2026-09-07 18:35:00')").run(JSON.stringify(LEGS));
  return { dir, options: muscuFromEnv({ NUO_FITNESS_DIR: dir })!, db };
}

/** Tuesday 8 Sep 2026: A twice (chest press swapped for the Pec Fly on the 2nd set, 30 → 32,5 kg), then B once. */
const tuesday = {
  runId: "run-2026-09-08-1845",
  sessionId: 101,
  day: "2026-09-08",
  seconds: 1934,
  sets: [
    { block: 0, exercises: [{ name: "Chest Press", base: "Chest Press", reps: 10, kg: 30 }, { name: "Seated Row", base: "Seated Row", reps: 10, kg: 45 }] },
    { block: 0, exercises: [{ name: "Pec Fly", base: "Chest Press", reps: 12, kg: 32.5 }, { name: "Seated Row", base: "Seated Row", reps: 10, kg: 45 }] },
    { block: 1, exercises: [{ name: "Lat Pulldown", base: "Lat Pulldown", reps: 10, kg: 47.5 }, { name: "Lateral Raise", base: "Lateral Raise", reps: 15, kg: null }] },
  ],
};

const cleanups: (() => unknown)[] = [];
afterEach(async () => {
  for (const c of cleanups.splice(0)) await c();
});

function service() {
  const f = fitnessDir();
  const m = new Muscu(f.options);
  cleanups.push(() => m.close(), () => f.db.close(), () => rmSync(f.dir, { recursive: true, force: true }));
  return { ...f, m };
}

describe("muscu service", () => {
  test("NUO_FITNESS_DIR names the database and the chrono folder; without it the screen is off", () => {
    expect(muscuFromEnv({ NUO_FITNESS_DIR: "/srv/fitness" })).toEqual({ db: "/srv/fitness/data/fitness.db", chronoDir: "/srv/fitness/webapp/chrono" });
    expect(muscuFromEnv({ NUO_FITNESS_DIR: "/srv/fitness", NUO_FITNESS_DB: "/var/lib/fitness.db" })?.db).toBe("/var/lib/fitness.db");
    expect(muscuFromEnv({})).toBeUndefined();
  });

  test("lists the saved sessions live, newest first, with the machine photos of every exercise and replacement", () => {
    const { m, db } = service();
    const list = m.list();
    expect(list.sessions.map((s) => s.name)).toEqual(["Jambes + tronc", "Haut du corps"]);
    const upper = list.sessions[1]!;
    expect(upper).toMatchObject({ id: 101, sets: 3, rest: 75, restBlock: 120, rir: 2, days: [2], note: "Blocs dans l'ordre que tu veux." });
    expect(upper.blocks[0]!.exercises[0]).toEqual({ name: "Chest Press", reps: 10, alts: ["Pec Fly"] });
    expect(list.photos["Chest Press"]).toBe("/api/muscu/photos/mx/chest-press.jpg");
    expect(list.photos["Pec Fly"]).toBe("/api/muscu/photos/mx/pec-fly.jpg");
    // « haltère » asks for the free-weight row, not the machine.
    expect(list.photos["Rowing haltère"]).toBe("/api/muscu/photos/db-row-0.jpg");
    expect(list.photos["Lateral Raise"]).toBeUndefined();
    // A session the coach rewrites shows at once: nothing is copied.
    db.query("UPDATE wods SET name = 'Haut du corps (léger)' WHERE id = 101").run();
    expect(m.list().sessions[1]!.name).toBe("Haut du corps (léger)");
  });

  test("a finished session becomes the coach's workout and its loads prefill the next one", () => {
    const { m, db } = service();
    const out = m.finish(tuesday);
    expect(out.title).toBe("Muscu — Haut du corps");
    expect(out.detail).toBe(
      [
        "Séance « Haut du corps » (écran Muscu) : 32:14, 3/6 séries.",
        "Ordre réel : A → B · 2 reps en réserve visées",
        "A · Chest Press 1×10 · 30 kg ; ⇄ Pec Fly (à la place de Chest Press) 1×12 · 32,5 kg ; Seated Row 2×10 · 45 kg",
        "B · Lat Pulldown 1×10 · 47,5 kg ; Lateral Raise 1×15",
      ].join("\n"),
    );
    expect(db.query("SELECT day, title, detail FROM workouts").all()).toEqual([{ day: "2026-09-08", title: out.title, detail: out.detail }]);
    const loads = m.list().loads;
    expect(loads["Pec Fly"]).toEqual({ kg: 32.5, reps: 12, day: "2026-09-08" });
    expect(loads["Lat Pulldown"]).toEqual({ kg: 47.5, reps: 10, day: "2026-09-08" });
    expect(loads["Lateral Raise"]).toBeUndefined();
  });

  test("the same run sent again rewrites its workout instead of adding a second one", () => {
    const { m, db } = service();
    const first = m.finish(tuesday);
    const again = m.finish({ ...tuesday, seconds: 2100, sets: [...tuesday.sets, { block: 1, exercises: tuesday.sets[2]!.exercises }] });
    expect(again.workoutId).toBe(first.workoutId);
    const rows = db.query("SELECT detail FROM workouts").all() as { detail: string }[];
    expect(rows).toHaveLength(1);
    expect(rows[0]!.detail).toContain("35:00, 4/6 séries");
  });

  test("blocks never started are listed as not done", () => {
    const upper = parseSession({ id: 101, name: "Haut du corps", config_json: JSON.stringify(UPPER_BODY), note: null })!;
    const text = recap(upper, { ...tuesday, sets: [tuesday.sets[0]!] });
    expect(text.split("\n").at(-1)).toBe("Non fait : B");
  });

  test("refuses unknown sessions, blocks and malformed sends", () => {
    const { m } = service();
    expect(() => m.finish({ ...tuesday, sessionId: 99 })).toThrow("séance introuvable");
    expect(() => m.finish({ ...tuesday, sets: [{ block: 5, exercises: tuesday.sets[0]!.exercises }] })).toThrow("bloc inconnu");
    expect(() => m.finish({ ...tuesday, day: "24/11/2026" })).toThrow("YYYY-MM-DD");
    expect(() => m.finish({ ...tuesday, runId: "x" })).toThrow("runId");
  });

  test("serves only the chrono's photos", () => {
    const { m, dir } = service();
    expect(m.photo("mx/chest-press.jpg")).toBe(join(dir, "webapp/chrono/img/mx/chest-press.jpg"));
    expect(m.photo("mx/pec-fly.jpg")).toBeNull();
    expect(m.photo("../exercises.js")).toBeNull();
    expect(m.photo("mx/../../exercises.js")).toBeNull();
  });
});

describe("muscu routes", () => {
  let t: TestApp;
  afterEach(async () => t && (await t.close()));

  test("the paired app lists the sessions, loads a photo and logs a session", async () => {
    const f = fitnessDir();
    cleanups.push(() => f.db.close(), () => rmSync(f.dir, { recursive: true, force: true }));
    t = await startTestApp({ muscu: f.options });
    const list = await t.api("GET", "/api/muscu");
    expect(list.status).toBe(200);
    expect(list.data.sessions.map((s: { id: number }) => s.id)).toEqual([102, 101]);

    const photo = await fetch(t.base + "/api/muscu/photos/mx/chest-press.jpg", { headers: { authorization: `Bearer ${t.token}` } });
    expect(photo.status).toBe(200);
    expect(photo.headers.get("content-type")).toBe("image/jpeg");
    expect(new Uint8Array(await photo.arrayBuffer())[0]).toBe(0xff);
    expect((await t.api("GET", "/api/muscu/photos/mx/pec-fly.jpg")).status).toBe(404);

    const done = await t.api("POST", "/api/muscu/sessions", tuesday);
    expect(done.status).toBe(200);
    expect(done.data.title).toBe("Muscu — Haut du corps");
    expect((await t.api("POST", "/api/muscu/sessions", { ...tuesday, sessionId: 99 })).status).toBe(400);
  });

  test("needs a paired device", async () => {
    const f = fitnessDir();
    cleanups.push(() => f.db.close(), () => rmSync(f.dir, { recursive: true, force: true }));
    t = await startTestApp({ muscu: f.options });
    const res = await fetch(t.base + "/api/muscu");
    expect(res.status).toBe(401);
  });

  test("without the fitness coach the routes do not exist", async () => {
    t = await startTestApp();
    expect((await t.api("GET", "/api/muscu")).status).toBe(404);
  });
});
