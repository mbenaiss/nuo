import { Database } from "bun:sqlite";
import { head } from "../text";
import { existsSync } from "node:fs";
import { join, resolve, sep } from "node:path";
import { loadCatalog, type ExerciseCatalog } from "./catalog";

/**
 * The owner's gym sessions, read live from the fitness coach's database (`wods`, written by its `save_wod` tool) so
 * the app's Muscu screen never shows a stale copy. A finished session goes to the same `workouts` table the coach's
 * `log_workout` writes, which its day and week summaries read.
 */
export interface MuscuOptions {
  /** The fitness repo's `data/fitness.db`. */
  db: string;
  /** The fitness repo's `webapp/chrono` folder: exercise catalog and machine photos. */
  chronoDir: string;
}

export function muscuFromEnv(env: Record<string, string | undefined> = process.env): MuscuOptions | undefined {
  const dir = env.NUO_FITNESS_DIR?.trim();
  if (!dir) return undefined;
  return { db: env.NUO_FITNESS_DB?.trim() || join(dir, "data/fitness.db"), chronoDir: join(dir, "webapp/chrono") };
}

export class MuscuInputError extends Error {}

export interface MuscuExercise {
  name: string;
  reps: number;
  /** Replacements when the machine is taken, the suggested one first. */
  alts: string[];
}

export interface MuscuBlock {
  exercises: MuscuExercise[];
  note?: string;
}

export interface MuscuSession {
  id: number;
  name: string;
  note: string;
  blocks: MuscuBlock[];
  sets: number;
  /** Rest between two sets of a block (s). */
  rest: number;
  /** Rest when moving to another block (s). */
  restBlock: number;
  rir?: number;
  /** ISO weekdays (1 = Monday) the session is planned on. */
  days: number[];
}

export interface LastLoad {
  kg: number | null;
  reps: number;
  day: string;
}

export interface MuscuList {
  sessions: MuscuSession[];
  /** Photo path (`/api/muscu/photos/…`) of every exercise and replacement named in the sessions. */
  photos: Record<string, string>;
  /** Last load lifted on every exercise and replacement named in the sessions, when there is one. */
  loads: Record<string, LastLoad>;
}

/** One set as done: its block and each exercise of the superset with what was really lifted. */
export interface DoneSet {
  block: number;
  exercises: { name: string; base: string; reps: number; kg: number | null }[];
}

export interface FinishedSession {
  /** Chosen by the app for the run: a second send of the same run rewrites its workout instead of adding one. */
  runId: string;
  sessionId: number;
  /** Local day of the session, YYYY-MM-DD. */
  day: string;
  seconds: number;
  sets: DoneSet[];
}

export const PHOTO_PREFIX = "/api/muscu/photos/";
const PHOTO_PATH = /^(mx\/)?[a-z0-9-]+\.jpg$/;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const RUN_ID = /^[A-Za-z0-9-]{8,64}$/;

const int = (v: unknown, fallback: number, min: number, max: number) =>
  typeof v === "number" && Number.isFinite(v) ? Math.min(max, Math.max(min, Math.round(v))) : fallback;
const text = (v: unknown, max: number) => (typeof v === "string" ? head(v.trim(), max) : "");

/** A stored session config, in the structured shape the coach's `save_wod` writes. */
export function parseSession(row: { id: number; name: string; config_json: string; note: string | null }): MuscuSession | null {
  let c: Record<string, unknown>;
  try {
    c = JSON.parse(row.config_json);
  } catch {
    return null;
  }
  if (!c || !Array.isArray(c.blocks)) return null;
  const blocks = (c.blocks as unknown[])
    .map((b): MuscuBlock => {
      const o = (b ?? {}) as Record<string, unknown>;
      const exercises = (Array.isArray(o.exercises) ? o.exercises : [])
        .map((e): MuscuExercise => {
          const x = (e ?? {}) as Record<string, unknown>;
          return {
            name: text(x.name, 60),
            reps: int(x.reps, 10, 1, 100),
            alts: (Array.isArray(x.alts) ? x.alts : []).map((a) => text(a, 60)).filter(Boolean).slice(0, 5),
          };
        })
        .filter((e) => e.name);
      const note = text(o.note, 200);
      return note ? { exercises, note } : { exercises };
    })
    .filter((b) => b.exercises.length);
  if (!blocks.length) return null;
  const days = Array.isArray(c.days) ? [...new Set(c.days.filter((d): d is number => Number.isInteger(d) && d >= 1 && d <= 7))].sort() : [];
  const session: MuscuSession = {
    id: row.id,
    name: row.name,
    note: row.note ?? "",
    blocks,
    sets: int(c.sets, 3, 1, 10),
    rest: int(c.rest, 75, 10, 600),
    restBlock: int(c.restBlock, 120, 10, 600),
    days,
  };
  if (typeof c.rir === "number" && c.rir >= 0) session.rir = Math.round(c.rir);
  return session;
}

const letter = (i: number) => String.fromCharCode(65 + i);
const fmtKg = (kg: number) => String(Math.round(kg * 100) / 100).replace(".", ",");
const fmtClock = (sec: number) => {
  const s = Math.max(0, Math.round(sec));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const ss = String(s % 60).padStart(2, "0");
  return h ? `${h}:${String(m).padStart(2, "0")}:${ss}` : `${m}:${ss}`;
};
const repsText = (reps: number[]) => (reps.every((r) => r === reps[0]) ? `${reps.length}×${reps[0]}` : reps.join(", "));
const kgText = (kgs: (number | null)[]) => {
  const k = kgs.filter((x): x is number => x != null);
  if (!k.length) return "";
  const first = k[0]!;
  const last = k[k.length - 1]!;
  return `${first === last ? fmtKg(last) : `${fmtKg(first)} → ${fmtKg(last)}`} kg`;
};

/** The recap the coach reads in its summaries, as the chrono's « Partager au coach » text. */
export function recap(session: MuscuSession, done: FinishedSession): string {
  const order: number[] = [];
  for (const s of done.sets) if (!order.includes(s.block)) order.push(s.block);
  const lines = [
    `Séance « ${session.name} » (écran Muscu) : ${fmtClock(done.seconds)}, ${done.sets.length}/${session.sets * session.blocks.length} séries.`,
    `Ordre réel : ${order.map(letter).join(" → ") || "—"}${session.rir != null ? ` · ${session.rir} reps en réserve visées` : ""}`,
  ];
  for (const bi of order) {
    const rows: { ei: number; name: string; base: string; reps: number[]; kgs: (number | null)[] }[] = [];
    for (const set of done.sets.filter((s) => s.block === bi)) {
      set.exercises.forEach((x, ei) => {
        let row = rows.find((r) => r.ei === ei && r.name === x.name);
        if (!row) rows.push((row = { ei, name: x.name, base: x.base, reps: [], kgs: [] }));
        row.reps.push(x.reps);
        row.kgs.push(x.kg);
      });
    }
    rows.sort((a, b) => a.ei - b.ei);
    const parts = rows.map((r) => {
      const kg = kgText(r.kgs);
      return `${r.name !== r.base ? `⇄ ${r.name} (à la place de ${r.base})` : r.name} ${repsText(r.reps)}${kg ? ` · ${kg}` : ""}`;
    });
    lines.push(`${letter(bi)} · ${parts.join(" ; ")}`);
  }
  const missed = session.blocks.map((_, i) => i).filter((i) => !order.includes(i));
  if (missed.length) lines.push(`Non fait : ${missed.map(letter).join(", ")}`);
  return lines.join("\n");
}

const fold = (s: string) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().trim();

export class Muscu {
  private db?: Database;
  private catalog?: ExerciseCatalog;
  private readonly photosDir: string;

  constructor(private o: MuscuOptions) {
    this.photosDir = resolve(o.chronoDir, "img");
  }

  /** Opened on first use: the fitness database is the coach's, and may appear after the gateway starts. */
  private open(): Database {
    if (this.db) return this.db;
    if (!existsSync(this.o.db)) throw new Error(`fitness database not found: ${this.o.db}`);
    const db = new Database(this.o.db);
    // The coach's MCP server writes to the same file.
    db.exec("PRAGMA busy_timeout = 3000;");
    db.exec(`
      CREATE TABLE IF NOT EXISTS muscu_loads (
        key  TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        kg   REAL,
        reps INTEGER NOT NULL,
        day  TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS muscu_runs (
        run_id     TEXT PRIMARY KEY,
        workout_id INTEGER NOT NULL
      );
    `);
    return (this.db = db);
  }

  private photoOf(name: string): string | null {
    this.catalog ??= loadCatalog(this.o.chronoDir);
    return this.catalog.photo(name);
  }

  list(): MuscuList {
    const db = this.open();
    const rows = db.query("SELECT id, name, config_json, note FROM wods ORDER BY created_at DESC, id DESC").all() as {
      id: number;
      name: string;
      config_json: string;
      note: string | null;
    }[];
    const sessions = rows.map(parseSession).filter((s): s is MuscuSession => !!s);
    const names = new Set(sessions.flatMap((s) => s.blocks.flatMap((b) => b.exercises.flatMap((e) => [e.name, ...e.alts]))));
    const photos: Record<string, string> = {};
    const loads: Record<string, LastLoad> = {};
    const load = db.query("SELECT kg, reps, day FROM muscu_loads WHERE key = ?");
    for (const name of names) {
      const photo = this.photoOf(name);
      if (photo) photos[name] = PHOTO_PREFIX + photo;
      const last = load.get(fold(name)) as LastLoad | null;
      if (last) loads[name] = last;
    }
    return { sessions, photos, loads };
  }

  /** A machine photo of the chrono's `img/` folder, or null for any other path. */
  photo(path: string): string | null {
    if (!PHOTO_PATH.test(path)) return null;
    const file = resolve(this.photosDir, path);
    if (!file.startsWith(this.photosDir + sep) || !existsSync(file)) return null;
    return file;
  }

  /** Logs a finished session as a workout and remembers its loads; the same run sent again rewrites its workout. */
  finish(input: unknown): { workoutId: number; title: string; detail: string } {
    const done = this.parseFinished(input);
    const db = this.open();
    const row = db.query("SELECT id, name, config_json, note FROM wods WHERE id = ?").get(done.sessionId) as Parameters<typeof parseSession>[0] | null;
    const session = row && parseSession(row);
    if (!session) throw new MuscuInputError("séance introuvable");
    for (const s of done.sets) if (s.block >= session.blocks.length) throw new MuscuInputError("bloc inconnu");
    const title = `Muscu — ${session.name}`;
    const detail = recap(session, done);
    return db.transaction(() => {
      const known = db.query("SELECT w.id FROM muscu_runs r JOIN workouts w ON w.id = r.workout_id WHERE r.run_id = ?").get(done.runId) as { id: number } | null;
      let workoutId: number;
      if (known) {
        db.query("UPDATE workouts SET day = ?, title = ?, detail = ? WHERE id = ?").run(done.day, title, detail, known.id);
        workoutId = known.id;
      } else {
        workoutId = (db.query("INSERT INTO workouts (day, title, detail) VALUES (?, ?, ?) RETURNING id").get(done.day, title, detail) as { id: number }).id;
        db.query("INSERT OR REPLACE INTO muscu_runs (run_id, workout_id) VALUES (?, ?)").run(done.runId, workoutId);
      }
      const remember = db.query(
        "INSERT INTO muscu_loads (key, name, kg, reps, day) VALUES (?, ?, ?, ?, ?) ON CONFLICT(key) DO UPDATE SET name = excluded.name, kg = excluded.kg, reps = excluded.reps, day = excluded.day",
      );
      for (const set of done.sets) for (const x of set.exercises) if (x.kg != null) remember.run(fold(x.name), x.name, x.kg, x.reps, done.day);
      return { workoutId, title, detail };
    })();
  }

  private parseFinished(input: unknown): FinishedSession {
    const b = (input && typeof input === "object" ? input : {}) as Record<string, unknown>;
    const runId = typeof b.runId === "string" ? b.runId : "";
    if (!RUN_ID.test(runId)) throw new MuscuInputError("runId is required");
    if (typeof b.sessionId !== "number" || !Number.isInteger(b.sessionId)) throw new MuscuInputError("sessionId is required");
    const day = typeof b.day === "string" ? b.day : "";
    if (!DAY.test(day)) throw new MuscuInputError("day must be YYYY-MM-DD");
    if (!Array.isArray(b.sets) || b.sets.length > 100) throw new MuscuInputError("sets is required");
    const sets = b.sets.map((raw): DoneSet => {
      const s = (raw ?? {}) as Record<string, unknown>;
      const exercises = (Array.isArray(s.exercises) ? s.exercises : []).slice(0, 4).map((e) => {
        const x = (e ?? {}) as Record<string, unknown>;
        const name = text(x.name, 60);
        if (!name) throw new MuscuInputError("exercise name is required");
        const kg = typeof x.kg === "number" && Number.isFinite(x.kg) ? Math.min(500, Math.max(0, Math.round(x.kg * 100) / 100)) : null;
        return { name, base: text(x.base, 60) || name, reps: int(x.reps, 1, 1, 100), kg };
      });
      if (!exercises.length) throw new MuscuInputError("a set needs its exercises");
      return { block: int(s.block, 0, 0, 7), exercises };
    });
    return { runId, sessionId: b.sessionId, day, seconds: int(b.seconds, 0, 0, 6 * 3600), sets };
  }

  close() {
    this.db?.close();
    this.db = undefined;
  }
}
