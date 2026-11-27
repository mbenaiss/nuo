import type { Database } from "bun:sqlite";
import { HttpError } from "../bots/service";
import type { Pusher } from "../push/apns";
import { CronError, nextRun, parseCron, wallTime, zonedToUtc } from "../scheduler/cron";
import type { Device } from "../store/store";
import { asApp } from "./db";
import { sqlite } from "./store";
import type { Reminder } from "./types";

export const REMINDER_TZ = "Europe/Paris";
export const REMINDER_CATEGORY = "nuo.reminder";
const SHORTCUTS = new Set(["daily", "weekly", "monthly", "yearly"]);
const SCOPES = new Set(["today", "upcoming", "overdue", "done", "all", "inbox", "anytime", "someday"]);
const LIST_LIMIT = 500;

type Row = Record<string, string | number | null>;

export interface Place {
  id: string;
  name: string;
  address?: string;
  lat: number;
  lon: number;
  radiusM: number;
  createdAt: string;
  updatedAt: string;
}

function toPlace(r: Row): Place {
  return {
    id: String(r.id),
    name: String(r.name),
    ...(r.address ? { address: String(r.address) } : {}),
    lat: Number(r.lat),
    lon: Number(r.lon),
    radiusM: Number(r.radius_m),
    createdAt: String(r.created_at),
    updatedAt: String(r.updated_at),
  };
}

const TRIGGERS = new Set(["arrive", "leave"]);

function toReminder(r: Row): Reminder {
  const opt = (k: string) => (r[k] === null || r[k] === undefined ? undefined : String(r[k]));
  return {
    id: String(r.id),
    title: String(r.title),
    ...(opt("notes") !== undefined ? { notes: opt("notes") } : {}),
    ...(opt("due_at") ? { dueAt: opt("due_at") } : {}),
    ...(opt("repeat") ? { repeat: opt("repeat") } : {}),
    list: String(r.list),
    priority: Number(r.priority),
    ...(opt("done_at") ? { doneAt: opt("done_at") } : {}),
    ...(opt("snoozed_until") ? { snoozedUntil: opt("snoozed_until") } : {}),
    ...(opt("place_trigger") ? { placeTrigger: opt("place_trigger") as "arrive" | "leave" } : {}),
    ...(opt("project_id") ? { projectId: opt("project_id") } : {}),
    ...(opt("area_id") ? { areaId: opt("area_id") } : {}),
    ...(opt("heading_id") ? { headingId: opt("heading_id") } : {}),
    someday: Number(r.someday) === 1,
    position: Number(r.position ?? 0),
    ...(opt("checklist") ? { checklist: JSON.parse(String(r.checklist)) as { title: string; done: boolean }[] } : {}),
    createdAt: String(r.created_at),
    updatedAt: String(r.updated_at),
  };
}

/** A 5-field cron for `repeat`; the shortcuts keep the wall-clock time (and day) of `dueAt` in Europe/Paris. */
export function repeatCron(repeat: string, dueAt: string | undefined | null, now: number): string {
  if (!SHORTCUTS.has(repeat)) return repeat;
  const w = wallTime(dueAt ? Date.parse(dueAt) : now, REMINDER_TZ);
  switch (repeat) {
    case "daily":
      return `${w.minute} ${w.hour} * * *`;
    case "weekly":
      return `${w.minute} ${w.hour} * * ${w.weekday}`;
    case "monthly":
      return `${w.minute} ${w.hour} ${w.day} * *`;
    default:
      return `${w.minute} ${w.hour} ${w.day} ${w.month} *`;
  }
}

export function validateRepeat(repeat: unknown): string | null {
  if (repeat === null || repeat === undefined || repeat === "") return null;
  if (typeof repeat !== "string") throw new HttpError(400, "repeat must be a cron expression or daily|weekly|monthly|yearly");
  const r = repeat.trim();
  if (SHORTCUTS.has(r)) return r;
  try {
    parseCron(r);
  } catch (e) {
    throw new HttpError(400, `invalid repeat: ${e instanceof CronError ? e.message : String(e)}`);
  }
  return r;
}

function isoOrNull(v: unknown, field: string): string | null {
  if (v === null || v === undefined || v === "") return null;
  if (typeof v !== "string" || Number.isNaN(Date.parse(v))) throw new HttpError(400, `${field} must be an ISO date-time`);
  return new Date(v).toISOString();
}

/** Start of the next Paris day after `now`, as an instant. */
function endOfParisDay(now: number): number {
  const w = wallTime(now, REMINDER_TZ);
  const d = new Date(Date.UTC(w.year, w.month - 1, w.day + 1));
  return zonedToUtc(d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate(), 0, 0, REMINDER_TZ);
}

const IN_SOMEDAY_PROJECT = "coalesce((SELECT p.someday FROM projects p WHERE p.id = reminders.project_id), 0) = 1";

export const listLabel = (id: string) => (id === "inbox" ? "Boîte de réception" : id.charAt(0).toUpperCase() + id.slice(1));

export class Reminders {
  constructor(
    readonly db: Database,
    private clock: () => number = Date.now,
  ) {}

  private get(id: string): Row {
    const r = this.db.query("SELECT * FROM reminders WHERE id = ? AND archived_at IS NULL").get(id) as Row | null;
    if (!r) throw new HttpError(404, "reminder not found");
    return r;
  }

  one(id: string): Reminder {
    return this.withPlaces([this.get(id)])[0]!;
  }

  /** Embeds the place of location reminders (archived places included: their reminders keep working), the project and the area. */
  private withPlaces(rows: Row[]): Reminder[] {
    const lookup = (table: string, key: string, ids: string[]) => {
      const out = new Map<string, Row>();
      const unique = [...new Set(ids)];
      if (unique.length) {
        for (const r of this.db.query(`SELECT * FROM ${table} WHERE ${key} IN (${unique.map(() => "?").join(", ")})`).all(...unique) as Row[]) out.set(String(r[key]), r);
      }
      return out;
    };
    const str = (v: unknown): v is string => typeof v === "string";
    const places = lookup("places", "id", rows.map((r) => r.place_id).filter(str));
    const projects = lookup("projects", "id", rows.map((r) => r.project_id).filter(str));
    const areaIds = [...rows.map((r) => r.area_id), ...[...projects.values()].map((p) => p.area_id)].filter(str);
    const areas = lookup("areas", "id", areaIds);
    const ref = (r: Row | undefined) => (r ? { id: String(r.id), title: String(r.title), ...(r.emoji ? { emoji: String(r.emoji) } : {}) } : undefined);
    return rows.map((r) => {
      const rem = toReminder(r);
      const p = str(r.place_id) ? places.get(r.place_id) : undefined;
      const project = str(r.project_id) ? projects.get(r.project_id) : undefined;
      const areaId = str(r.area_id) ? r.area_id : str(project?.area_id) ? (project!.area_id as string) : undefined;
      const area = areaId ? areas.get(areaId) : undefined;
      return {
        ...rem,
        ...(p ? { place: { id: String(p.id), name: String(p.name), lat: Number(p.lat), lon: Number(p.lon), radiusM: Number(p.radius_m) } } : {}),
        ...(project ? { project: ref(project) } : {}),
        ...(area ? { areaId: String(area.id), area: ref(area) } : {}),
      };
    });
  }

  /**
   * projectId / areaId / headingId of a request. A reminder sits in a project (optionally under one of its
   * headings) or directly in an area, never both: setting one clears the other; a heading implies its project.
   */
  private organisation(b: Record<string, unknown>, current?: Row): Record<string, string | number | null> {
    const set: Record<string, string | number | null> = {};
    const id = (k: string, table: string, what: string): string | null | undefined => {
      if (!(k in b)) return undefined;
      const v = b[k];
      if (v === null || v === "") return null;
      if (typeof v !== "string" || !this.db.query(`SELECT 1 FROM ${table} WHERE id = ? AND archived_at IS NULL`).get(v)) {
        throw new HttpError(400, `${k} must be an existing ${what}`);
      }
      return v;
    };
    const project = id("projectId", "projects", "project");
    const area = id("areaId", "areas", "area");
    const heading = id("headingId", "project_headings", "heading");
    if (project && area) throw new HttpError(400, "a reminder is in a project or in an area, not both");
    if (project !== undefined) Object.assign(set, { project_id: project, ...(project ? { area_id: null } : {}) });
    if (area !== undefined) Object.assign(set, { area_id: area, ...(area ? { project_id: null, heading_id: null } : {}) });
    if (heading) {
      const owner = String((this.db.query("SELECT project_id FROM project_headings WHERE id = ?").get(heading) as Row).project_id);
      if (project && project !== owner) throw new HttpError(400, "headingId belongs to another project");
      Object.assign(set, { heading_id: heading, project_id: owner, area_id: null });
    } else if (heading === null || ("project_id" in set && set.project_id !== (current?.project_id ?? null))) {
      set.heading_id = null;
    }
    if ("someday" in b) {
      if (typeof b.someday !== "boolean") throw new HttpError(400, "someday must be a boolean");
      set.someday = b.someday ? 1 : 0;
    }
    if ("position" in b) {
      if (typeof b.position !== "number" || !Number.isFinite(b.position)) throw new HttpError(400, "position must be a number");
      set.position = b.position;
    }
    if ("checklist" in b) {
      const c = b.checklist;
      if (c === null || (Array.isArray(c) && c.length === 0)) set.checklist = null;
      else if (!Array.isArray(c) || !c.every((i) => i && typeof i === "object" && typeof i.title === "string" && i.title.trim() && (i.done === undefined || typeof i.done === "boolean"))) {
        throw new HttpError(400, "checklist must be an array of {title, done}");
      } else set.checklist = JSON.stringify(c.map((i: { title: string; done?: boolean }) => ({ title: i.title.trim(), done: i.done === true })));
    }
    return set;
  }

  /** placeId/placeTrigger of a request: the place must exist (and be active); the trigger defaults to arrive. */
  private placeFields(b: Record<string, unknown>, current?: Row): { place_id: string | null; place_trigger: string | null } | undefined {
    if (!("placeId" in b) && !("placeTrigger" in b)) return undefined;
    const placeId = "placeId" in b ? b.placeId : current?.place_id;
    if (placeId === null || placeId === undefined || placeId === "") {
      if (b.placeTrigger !== undefined && b.placeTrigger !== null) throw new HttpError(400, "placeTrigger needs a placeId");
      return { place_id: null, place_trigger: null };
    }
    if (typeof placeId !== "string" || !this.db.query("SELECT 1 FROM places WHERE id = ? AND archived_at IS NULL").get(placeId)) {
      if (!(current && placeId === current.place_id)) throw new HttpError(400, "placeId must be an existing place");
    }
    const trigger = b.placeTrigger ?? current?.place_trigger ?? "arrive";
    if (typeof trigger !== "string" || !TRIGGERS.has(trigger)) throw new HttpError(400, "placeTrigger must be arrive or leave");
    return { place_id: placeId as string, place_trigger: trigger };
  }

  list(scope = "all", list?: string, filter: { project?: string; area?: string } = {}): Reminder[] {
    const q = this.scopeQuery(scope, list, filter);
    return this.withPlaces(this.db.query(`SELECT * FROM reminders WHERE ${q.where} ORDER BY ${q.order} LIMIT ${LIST_LIMIT}`).all(...q.params) as Row[]);
  }

  private scopeQuery(scope: string, list?: string, filter: { project?: string; area?: string } = {}): { where: string; params: string[]; order: string } {
    if (!SCOPES.has(scope)) throw new HttpError(400, "scope must be today, upcoming, overdue, done, all, inbox, anytime or someday");
    const now = this.clock();
    const nowIso = new Date(now).toISOString();
    const eod = new Date(endOfParisDay(now)).toISOString();
    const due = "coalesce(snoozed_until, due_at)";
    const where = ["archived_at IS NULL"];
    const params: string[] = [];
    switch (scope) {
      case "today":
        where.push("done_at IS NULL", `${due} IS NOT NULL`, `julianday(${due}) < julianday(?)`);
        params.push(eod);
        break;
      case "upcoming":
        where.push("done_at IS NULL", `${due} IS NOT NULL`, `julianday(${due}) >= julianday(?)`);
        params.push(eod);
        break;
      case "overdue":
        where.push("done_at IS NULL", `${due} IS NOT NULL`, `julianday(${due}) < julianday(?)`);
        params.push(nowIso);
        break;
      case "done":
        where.push("done_at IS NOT NULL");
        break;
      case "all":
        where.push("done_at IS NULL");
        break;
      case "inbox":
        where.push("done_at IS NULL", "project_id IS NULL", "area_id IS NULL", "someday = 0", `${due} IS NULL`, "place_id IS NULL");
        break;
      case "anytime":
        where.push("done_at IS NULL", "someday = 0", `NOT ${IN_SOMEDAY_PROJECT}`);
        break;
      case "someday":
        where.push("done_at IS NULL", `(someday = 1 OR ${IN_SOMEDAY_PROJECT})`);
        break;
    }
    if (filter.project) {
      where.push("project_id = ?");
      params.push(filter.project);
    }
    if (filter.area) {
      where.push("(area_id = ? OR project_id IN (SELECT id FROM projects WHERE area_id = ?))");
      params.push(filter.area, filter.area);
    }
    if (list) {
      where.push("list = ?");
      params.push(list);
    }
    const order =
      scope === "done"
        ? "done_at DESC"
        : filter.project
          ? "position, created_at"
          : `julianday(${due}) ASC NULLS LAST, priority DESC, position, created_at`;
    return { where: where.join(" AND "), params, order };
  }

  create(b: Record<string, unknown>): Reminder {
    if (typeof b.title !== "string" || !b.title.trim()) throw new HttpError(400, "title is required");
    const id = crypto.randomUUID();
    const dueAt = isoOrNull(b.dueAt, "dueAt");
    const repeat = validateRepeat(b.repeat);
    const priority = b.priority === undefined ? 0 : b.priority;
    if (!Number.isInteger(priority) || (priority as number) < 0 || (priority as number) > 3) throw new HttpError(400, "priority must be 0..3");
    if (b.list !== undefined && (typeof b.list !== "string" || !b.list.trim())) throw new HttpError(400, "list must be a non-empty string");
    if (b.notes !== undefined && b.notes !== null && typeof b.notes !== "string") throw new HttpError(400, "notes must be a string");
    const place = this.placeFields(b) ?? { place_id: null, place_trigger: null };
    const org = this.organisation(b);
    if (!("position" in org)) {
      const scope = org.project_id ? ["project_id = ?", org.project_id] : org.area_id ? ["area_id = ?", org.area_id] : ["project_id IS NULL AND area_id IS NULL"];
      org.position = (this.db.query(`SELECT coalesce(max(position), 0) + 1 AS p FROM reminders WHERE ${scope[0]}`).get(...scope.slice(1)) as { p: number }).p;
    }
    const extra = Object.keys(org);
    sqlite(() =>
      asApp(this.db, () =>
        this.db
          .query(
            `INSERT INTO reminders (id, title, notes, due_at, repeat, list, priority, place_id, place_trigger${extra.map((k) => `, "${k}"`).join("")})
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?${extra.map(() => ", ?").join("")})`,
          )
          .run(id, b.title as string, (b.notes as string) ?? null, dueAt, repeat, typeof b.list === "string" ? b.list.trim() : "inbox", priority as number, place.place_id, place.place_trigger, ...extra.map((k) => org[k]!)),
      ),
    );
    return this.one(id);
  }

  patch(id: string, b: Record<string, unknown>): Reminder {
    const cur = this.get(id);
    const set: Record<string, string | number | null> = {};
    const place = this.placeFields(b, cur);
    if (place) Object.assign(set, place);
    Object.assign(set, this.organisation(b, cur));
    if ("title" in b) {
      if (typeof b.title !== "string" || !b.title.trim()) throw new HttpError(400, "title must be a non-empty string");
      set.title = b.title;
    }
    if ("notes" in b) {
      if (b.notes !== null && typeof b.notes !== "string") throw new HttpError(400, "notes must be a string");
      set.notes = (b.notes as string | null) || null;
    }
    if ("dueAt" in b) {
      Object.assign(set, { due_at: isoOrNull(b.dueAt, "dueAt"), notified_at: null, snoozed_until: null });
    }
    if ("repeat" in b) set.repeat = validateRepeat(b.repeat);
    if ("list" in b) {
      if (typeof b.list !== "string" || !b.list.trim()) throw new HttpError(400, "list must be a non-empty string");
      set.list = b.list.trim();
    }
    if ("priority" in b) {
      if (!Number.isInteger(b.priority) || (b.priority as number) < 0 || (b.priority as number) > 3) throw new HttpError(400, "priority must be 0..3");
      set.priority = b.priority as number;
    }
    if ("snoozedUntil" in b) Object.assign(set, { snoozed_until: isoOrNull(b.snoozedUntil, "snoozedUntil"), notified_at: null });
    this.update(id, set);
    return this.one(id);
  }

  private update(id: string, set: Record<string, string | number | null>) {
    const names = Object.keys(set);
    if (!names.length) return;
    sqlite(() =>
      asApp(this.db, () =>
        this.db
          .query(`UPDATE reminders SET ${names.map((n) => `"${n}" = ?`).join(", ")}, updated_at = ? WHERE id = ?`)
          .run(...names.map((n) => set[n]!), new Date(this.clock()).toISOString(), id),
      ),
    );
  }

  /** Open reminders per smart list, for the sidebar. */
  counts(): Record<"inbox" | "today" | "overdue" | "upcoming" | "anytime" | "someday", number> {
    const n = (scope: string) => {
      const q = this.scopeQuery(scope);
      return (this.db.query(`SELECT count(*) AS n FROM (SELECT 1 FROM reminders WHERE ${q.where} LIMIT ${LIST_LIMIT})`).get(...q.params) as { n: number }).n;
    };
    return { inbox: n("inbox"), today: n("today"), overdue: n("overdue"), upcoming: n("upcoming"), anytime: n("anytime"), someday: n("someday") };
  }

  /** A repeating reminder is not closed: it moves to its next occurrence after max(due, now). */
  /** Lists with their count of open reminders; `inbox` is always there. */
  lists(): { id: string; label: string; count: number }[] {
    const rows = this.db.query("SELECT list, count(*) AS n FROM reminders WHERE archived_at IS NULL AND done_at IS NULL GROUP BY list").all() as { list: string; n: number }[];
    const counts = new Map(rows.map((r) => [r.list, r.n]));
    if (!counts.has("inbox")) counts.set("inbox", 0);
    return [...counts]
      .map(([id, count]) => ({ id, label: listLabel(id), count }))
      .sort((a, b) => (a.id === "inbox" ? -1 : b.id === "inbox" ? 1 : a.label.localeCompare(b.label, "fr")));
  }

  done(id: string): Reminder {
    const cur = this.get(id);
    const now = this.clock();
    if (cur.repeat) {
      const due = cur.due_at ? Date.parse(String(cur.due_at)) : now;
      const cron = parseCron(repeatCron(String(cur.repeat), cur.due_at as string | null, now));
      const next = nextRun(cron, REMINDER_TZ, Math.max(due, now));
      if (next !== undefined) {
        this.update(id, { due_at: new Date(next).toISOString(), snoozed_until: null, notified_at: null, done_at: null });
        return this.one(id);
      }
    }
    this.update(id, { done_at: new Date(now).toISOString(), snoozed_until: null });
    return this.one(id);
  }

  undone(id: string): Reminder {
    this.get(id);
    this.update(id, { done_at: null, notified_at: null });
    return this.one(id);
  }

  snooze(id: string, b: Record<string, unknown>): Reminder {
    this.get(id);
    let until: string | null;
    if (b.minutes !== undefined) {
      if (typeof b.minutes !== "number" || !Number.isFinite(b.minutes) || b.minutes <= 0) throw new HttpError(400, "minutes must be a positive number");
      until = new Date(this.clock() + b.minutes * 60_000).toISOString();
    } else {
      until = isoOrNull(b.until, "until");
      if (!until) throw new HttpError(400, "minutes or until is required");
    }
    this.update(id, { snoozed_until: until, notified_at: null, done_at: null });
    return this.one(id);
  }

  archive(id: string): void {
    this.get(id);
    this.update(id, { archived_at: new Date(this.clock()).toISOString() });
  }

  /** Reminders whose due time (or snooze end) has passed and that were not pushed yet; marks them pushed. */
  takeDue(): Reminder[] {
    const nowIso = new Date(this.clock()).toISOString();
    return this.db.transaction(() => {
      const rows = this.db
        .query(
          `SELECT * FROM reminders WHERE archived_at IS NULL AND done_at IS NULL AND notified_at IS NULL
             AND NOT (place_id IS NOT NULL AND due_at IS NULL AND snoozed_until IS NULL)
             AND coalesce(snoozed_until, due_at) IS NOT NULL AND julianday(coalesce(snoozed_until, due_at)) <= julianday(?)
           ORDER BY julianday(coalesce(snoozed_until, due_at)) LIMIT 50`,
        )
        .all(nowIso) as Row[];
      const mark = this.db.query("UPDATE reminders SET notified_at = ? WHERE id = ?");
      for (const r of rows) mark.run(nowIso, String(r.id));
      return this.withPlaces(rows);
    })();
  }
}

export class Places {
  constructor(
    readonly db: Database,
    private clock: () => number = Date.now,
  ) {}

  private get(id: string): Row {
    const r = this.db.query("SELECT * FROM places WHERE id = ? AND archived_at IS NULL").get(id) as Row | null;
    if (!r) throw new HttpError(404, "place not found");
    return r;
  }

  list(): Place[] {
    return (this.db.query("SELECT * FROM places WHERE archived_at IS NULL ORDER BY name COLLATE NOCASE").all() as Row[]).map(toPlace);
  }

  private fields(b: Record<string, unknown>, partial: boolean): Record<string, string | number | null> {
    const set: Record<string, string | number | null> = {};
    const num = (k: string, min: number, max: number) => {
      const v = b[k];
      if (typeof v !== "number" || !Number.isFinite(v) || v < min || v > max) throw new HttpError(400, `${k} must be a number between ${min} and ${max}`);
      return v;
    };
    if (!partial || "name" in b) {
      if (typeof b.name !== "string" || !b.name.trim()) throw new HttpError(400, "name is required");
      set.name = b.name.trim();
    }
    if ("address" in b) {
      if (b.address !== null && typeof b.address !== "string") throw new HttpError(400, "address must be a string");
      set.address = (b.address as string | null) || null;
    }
    if (!partial || "lat" in b) set.lat = num("lat", -90, 90);
    if (!partial || "lon" in b) set.lon = num("lon", -180, 180);
    if ("radiusM" in b) set.radius_m = num("radiusM", 1, 100_000);
    return set;
  }

  create(b: Record<string, unknown>): Place {
    const set = { id: crypto.randomUUID(), ...this.fields(b, false) };
    const names = Object.keys(set);
    sqlite(() =>
      asApp(this.db, () =>
        this.db.query(`INSERT INTO places (${names.map((n) => `"${n}"`).join(", ")}) VALUES (${names.map(() => "?").join(", ")})`).run(...names.map((n) => set[n as keyof typeof set]!)),
      ),
    );
    return toPlace(this.get(set.id));
  }

  patch(id: string, b: Record<string, unknown>): Place {
    this.get(id);
    const set = this.fields(b, true);
    const names = Object.keys(set);
    if (names.length) {
      sqlite(() =>
        asApp(this.db, () =>
          this.db
            .query(`UPDATE places SET ${names.map((n) => `"${n}" = ?`).join(", ")}, updated_at = ? WHERE id = ?`)
            .run(...names.map((n) => set[n]!), new Date(this.clock()).toISOString(), id),
        ),
      );
    }
    return toPlace(this.get(id));
  }

  archive(id: string): void {
    this.get(id);
    const now = new Date(this.clock()).toISOString();
    asApp(this.db, () => this.db.query("UPDATE places SET archived_at = ?, updated_at = ? WHERE id = ?").run(now, now, id));
  }
}

/** Pushes due reminders every 30 s, once each (category nuo.reminder, payload {reminderId}). */
export class ReminderNotifier {
  private timer?: ReturnType<typeof setInterval>;
  private running = false;

  constructor(
    private reminders: Reminders,
    private pusher: Pusher,
    private devices: () => Device[],
    private intervalMs = 30_000,
  ) {}

  start() {
    if (this.timer) return;
    this.timer = setInterval(() => void this.tick(), this.intervalMs);
    void this.tick();
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
  }

  async tick(): Promise<Reminder[]> {
    if (this.running) return [];
    this.running = true;
    try {
      const due = this.reminders.takeDue();
      const devices = this.devices();
      for (const r of due) {
        await Promise.all(
          devices.map((d) =>
            this.pusher.send(d, {
              title: r.title,
              body: r.notes?.split("\n")[0] || "Rappel",
              reminderId: r.id,
              category: REMINDER_CATEGORY,
              messageId: `reminder-${r.id}`,
              destination: { kind: "reminder", id: r.id },
            }),
          ),
        );
      }
      return due;
    } catch (e) {
      console.warn(`[reminders] ${(e as Error)?.message ?? e}`);
      return [];
    } finally {
      this.running = false;
    }
  }
}
