import type { Database } from "bun:sqlite";
import { createHash } from "node:crypto";
import { HttpError } from "../bots/service";
import type { Interval } from "./availability";
import { bad, bool, int, iso, obj, str } from "./validate";

type Row = Record<string, string | number | null>;

export interface Calendar {
  id: string;
  key: string;
  title: string;
  account: string | null;
  type: string | null;
  color: string | null;
  deviceColor: string | null;
  colorOverride: string | null;
  allowsModifications: boolean;
  enabled: boolean;
  privacy: "full" | "busy";
  countsForAvailability: boolean;
  needsResync: boolean;
  sources: { deviceId: string; deviceName: string | null; calendarIdentifier: string; syncedAt: string | null; primary: boolean }[];
}

export interface AgendaItem {
  kind: "event" | "reminder" | "booking";
  id: string;
  title: string | null;
  start: string;
  end: string;
  allDay: boolean;
  [k: string]: unknown;
}

export interface BridgeDevice {
  id: string;
  name?: string;
}

const DAY = 86_400_000;
const CAL_TYPES = new Set(["local", "caldav", "exchange", "subscription", "birthday"]);
const AVAILABILITY = new Set(["busy", "free", "tentative", "unavailable"]);
const STATUSES = new Set(["confirmed", "tentative", "cancelled"]);
const ATTENDEE_STATUS = new Set(["accepted", "declined", "tentative", "pending", "unknown"]);
const COLOR = /^#[0-9A-Fa-f]{6}$/;
const MAX_EVENTS_PER_REQUEST = 5000;
const TRAVEL_MODES = new Set(["driving", "transit", "walking", "cycling"]);
const MAX_ALARMS = 20;

const CONFERENCE =
  /https?:\/\/(?:meet\.google\.com\/[a-z0-9-]+|(?:[\w-]+\.)?zoom\.us\/(?:j|my|w|s)\/[^\s<>"')]+|teams\.microsoft\.com\/l\/meetup-join\/[^\s<>"')]+|teams\.live\.com\/meet\/[^\s<>"')]+|[\w-]+\.webex\.com\/[^\s<>"')]+|whereby\.com\/[^\s<>"')]+|meet\.jit\.si\/[^\s<>"')]+)/i;

export function detectConferenceUrl(...texts: (string | null | undefined)[]): string | undefined {
  for (const t of texts) {
    const m = t ? CONFERENCE.exec(t) : null;
    if (m) return m[0];
  }
  return undefined;
}

export const calendarKey = (account: string | undefined | null, title: string) => `${(account ?? "").trim().toLowerCase()} / ${title.trim().toLowerCase()}`;
export const calendarIdFor = (key: string) => "k_" + createHash("sha256").update(key).digest("hex").slice(0, 12);

/** Copy of a calendar whose events are served: the one with the most recent complete sync. */
const PRIMARY_SOURCE = "(SELECT s.id FROM calendar_sources s WHERE s.calendar_id = c.id ORDER BY s.synced_at DESC NULLS LAST, s.id LIMIT 1)";

/** An event row with its calendar's settings and the travel time an app computed for it. */
const EVENT_SELECT = `SELECT e.*, c.privacy, c.color_override, c.device_color, c.allows_modifications, t.travel_time_sec AS app_travel_sec, t.mode AS travel_mode
  FROM calendar_events e JOIN calendars c ON c.id = e.calendar_id
  LEFT JOIN calendar_event_travel t ON t.calendar_id = e.calendar_id AND t.external_id = e.external_id`;

interface StoredEvent {
  externalId: string;
  seriesId: string | null;
  title: string | null;
  location: string | null;
  lat: number | null;
  lon: number | null;
  notes: string | null;
  url: string | null;
  conferenceUrl: string | null;
  start: string;
  end: string;
  allDay: number;
  availability: string;
  status: string | null;
  attendees: string | null;
  attendeesCount: number;
  organizer: string | null;
  travelTimeSec: number | null;
  hasAlarms: number;
  alarms: string | null;
}

export type EventAlarm = { offsetSec: number } | { at: string };

/** EventKit alarms: offsets in seconds from the start (negative = before) or absolute instants. */
function parseAlarms(v: unknown): EventAlarm[] | null {
  if (v === undefined || v === null) return null;
  if (!Array.isArray(v) || v.length > MAX_ALARMS) throw bad(`alarms must be an array (max ${MAX_ALARMS})`);
  return v.map((raw, i) => {
    const a = obj(raw, `alarms[${i}]`);
    if (a.offsetSec !== undefined && a.offsetSec !== null) return { offsetSec: int(a.offsetSec, `alarms[${i}].offsetSec`, -30 * 86_400, 30 * 86_400) };
    return { at: iso(a.at, `alarms[${i}].at`) };
  });
}

function person(v: unknown, field: string): { name?: string; email?: string } | undefined {
  if (v === undefined || v === null) return undefined;
  const o = obj(v, field);
  const name = str(o.name, `${field}.name`, 200);
  const email = str(o.email, `${field}.email`, 254);
  return { ...(name ? { name } : {}), ...(email ? { email } : {}) };
}

/** Validates a bridged event and drops every detail field of busy-only calendars before anything is stored. */
export function normalizeEvent(raw: unknown, privacy: "full" | "busy"): StoredEvent {
  const e = obj(raw, "event");
  const externalId = str(e.externalId, "externalId", 512, true);
  const start = iso(e.start, "start");
  const end = iso(e.end, "end");
  if (end < start) throw bad("end must not be before start");
  const availability = e.availability === undefined || e.availability === "notSupported" ? "busy" : String(e.availability);
  if (!AVAILABILITY.has(availability)) throw bad("availability must be busy, free, tentative or unavailable");
  const status = e.status === undefined || e.status === null ? null : String(e.status);
  if (status !== null && !STATUSES.has(status)) throw bad("status must be confirmed, tentative or cancelled");
  const allDay = bool(e.allDay, "allDay", false) ? 1 : 0;
  const alarms = parseAlarms(e.alarms);
  // Alarm times say nothing about the event, so busy-only calendars keep them for the apps' notifications.
  const base = { externalId, start, end, allDay, availability, status, alarms: alarms ? JSON.stringify(alarms) : null, hasAlarms: e.hasAlarms === true || !!alarms?.length ? 1 : 0 };
  if (privacy === "busy") {
    return { ...base, seriesId: null, title: null, location: null, lat: null, lon: null, notes: null, url: null, conferenceUrl: null, attendees: null, attendeesCount: 0, organizer: null, travelTimeSec: null };
  }
  const title = str(e.title, "title", 1000) ?? null;
  const location = str(e.location, "location", 1000) ?? null;
  const notes = str(e.notes, "notes", 20_000) ?? null;
  const url = str(e.url, "url", 2000) ?? null;
  let lat: number | null = null;
  let lon: number | null = null;
  if (e.coordinates !== undefined && e.coordinates !== null) {
    const c = obj(e.coordinates, "coordinates");
    if (typeof c.lat !== "number" || typeof c.lon !== "number" || Math.abs(c.lat) > 90 || Math.abs(c.lon) > 180) throw bad("coordinates must be {lat, lon}");
    lat = c.lat;
    lon = c.lon;
  }
  let attendees: string | null = null;
  let count = 0;
  if (e.attendees !== undefined && e.attendees !== null) {
    if (!Array.isArray(e.attendees) || e.attendees.length > 500) throw bad("attendees must be an array (max 500)");
    const list = e.attendees.map((a, i) => {
      const p = person(a, `attendees[${i}]`)!;
      const st = (a as Record<string, unknown>).status;
      const s = typeof st === "string" && ATTENDEE_STATUS.has(st) ? st : "unknown";
      return { ...p, status: s, ...((a as Record<string, unknown>).organizer === true ? { organizer: true } : {}) };
    });
    attendees = JSON.stringify(list);
    count = list.length;
  }
  if (typeof e.attendeesCount === "number" && Number.isInteger(e.attendeesCount) && e.attendeesCount >= 0) count = e.attendeesCount;
  const organizer = person(e.organizer, "organizer");
  const travel = e.travelTimeSec;
  if (travel !== undefined && travel !== null && (typeof travel !== "number" || !Number.isInteger(travel) || travel < 0 || travel > 86_400)) throw bad("travelTimeSec must be an integer of seconds");
  return {
    ...base,
    seriesId: str(e.seriesId, "seriesId", 512) ?? null,
    title,
    location,
    lat,
    lon,
    notes,
    url,
    conferenceUrl: detectConferenceUrl(url, location, notes) ?? null,
    attendees,
    attendeesCount: count,
    organizer: organizer ? JSON.stringify(organizer) : null,
    travelTimeSec: (travel as number | undefined) ?? null,
  };
}

function parseJson(s: string | number | null): unknown {
  if (typeof s !== "string") return undefined;
  try {
    return JSON.parse(s);
  } catch {
    return undefined;
  }
}

export class CalendarStore {
  constructor(
    readonly db: Database,
    private clock: () => number = Date.now,
  ) {}

  private nowIso = () => new Date(this.clock()).toISOString();

  putSources(device: BridgeDevice, body: Record<string, unknown>): Calendar[] {
    const list = body.calendars;
    if (!Array.isArray(list) || list.length > 500) throw bad("calendars must be an array (max 500)");
    const items = list.map((raw, i) => {
      const c = obj(raw, `calendars[${i}]`);
      const color = str(c.color, "color", 9);
      const type = str(c.type, "type", 20);
      return {
        identifier: str(c.id, `calendars[${i}].id`, 256, true),
        title: str(c.title, `calendars[${i}].title`, 300, true),
        color: color && COLOR.test(color) ? color.toUpperCase() : null,
        account: str(c.account, "account", 300) ?? null,
        type: type && CAL_TYPES.has(type) ? type : null,
        allowsModifications: c.allowsModifications === false ? 0 : 1,
      };
    });
    const now = this.nowIso();
    this.db.transaction(() => {
      const keep = new Set<string>();
      for (const it of items) {
        const key = calendarKey(it.account, it.title);
        const calId = calendarIdFor(key);
        this.db
          .query(
            `INSERT INTO calendars (id, key, title, account, type, device_color, allows_modifications) VALUES (?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(id) DO UPDATE SET title = excluded.title, account = excluded.account, type = excluded.type,
               device_color = excluded.device_color, allows_modifications = excluded.allows_modifications, updated_at = ?`,
          )
          .run(calId, key, it.title, it.account, it.type, it.color, it.allowsModifications, now);
        const sourceId = `${device.id}:${it.identifier}`;
        keep.add(sourceId);
        this.db
          .query(
            `INSERT INTO calendar_sources (id, calendar_id, device_id, device_name, calendar_identifier, title, color, account, type, allows_modifications)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(id) DO UPDATE SET calendar_id = excluded.calendar_id, device_name = excluded.device_name, title = excluded.title,
               color = excluded.color, account = excluded.account, type = excluded.type, allows_modifications = excluded.allows_modifications`,
          )
          .run(sourceId, calId, device.id, device.name ?? null, it.identifier, it.title, it.color, it.account, it.type, it.allowsModifications);
        // A renamed calendar gets a new key: its old events belong to the old one.
        this.db.query("UPDATE calendar_events SET calendar_id = ? WHERE source_id = ? AND calendar_id <> ?").run(calId, sourceId, calId);
      }
      const existing = this.db.query("SELECT id FROM calendar_sources WHERE device_id = ?").all(device.id) as { id: string }[];
      for (const s of existing) if (!keep.has(s.id)) this.db.query("DELETE FROM calendar_sources WHERE id = ?").run(s.id);
    })();
    return this.calendars();
  }

  calendars(): Calendar[] {
    // Rows without a source are kept so their settings (privacy!) survive a calendar disappearing for a while.
    const cals = this.db.query("SELECT * FROM calendars WHERE id IN (SELECT calendar_id FROM calendar_sources) ORDER BY account, title").all() as Row[];
    const sources = this.db.query("SELECT * FROM calendar_sources ORDER BY synced_at DESC NULLS LAST, id").all() as Row[];
    return cals.map((c) => this.toCalendar(c, sources));
  }

  calendar(id: string): Calendar {
    const c = this.db.query("SELECT * FROM calendars WHERE id = ?").get(id) as Row | null;
    if (!c) throw new HttpError(404, "calendar not found");
    return this.toCalendar(c, this.db.query("SELECT * FROM calendar_sources WHERE calendar_id = ? ORDER BY synced_at DESC NULLS LAST, id").all(id) as Row[]);
  }

  private toCalendar(c: Row, allSources: Row[]): Calendar {
    const sources = allSources.filter((s) => s.calendar_id === c.id);
    return {
      id: String(c.id),
      key: String(c.key),
      title: String(c.title),
      account: (c.account as string) ?? null,
      type: (c.type as string) ?? null,
      color: ((c.color_override ?? c.device_color) as string) ?? null,
      deviceColor: (c.device_color as string) ?? null,
      colorOverride: (c.color_override as string) ?? null,
      allowsModifications: c.allows_modifications === 1,
      enabled: c.enabled === 1,
      privacy: c.privacy === "busy" ? "busy" : "full",
      countsForAvailability: c.counts_for_availability === 1,
      needsResync: c.needs_resync === 1,
      sources: sources.map((s, i) => ({
        deviceId: String(s.device_id),
        deviceName: (s.device_name as string) ?? null,
        calendarIdentifier: String(s.calendar_identifier),
        syncedAt: (s.synced_at as string) ?? null,
        primary: i === 0,
      })),
    };
  }

  patchCalendar(id: string, body: Record<string, unknown>): Calendar {
    const current = this.calendar(id);
    const sets: string[] = [];
    const vals: (string | number | null)[] = [];
    if (body.enabled !== undefined) sets.push("enabled = ?"), vals.push(bool(body.enabled, "enabled") ? 1 : 0);
    if (body.countsForAvailability !== undefined) sets.push("counts_for_availability = ?"), vals.push(bool(body.countsForAvailability, "countsForAvailability") ? 1 : 0);
    if (body.colorOverride !== undefined) {
      if (body.colorOverride !== null && (typeof body.colorOverride !== "string" || !COLOR.test(body.colorOverride))) throw bad("colorOverride must be #RRGGBB or null");
      sets.push("color_override = ?"), vals.push(body.colorOverride === null ? null : (body.colorOverride as string).toUpperCase());
    }
    let privacy: "full" | "busy" | undefined;
    if (body.privacy !== undefined) {
      if (body.privacy !== "full" && body.privacy !== "busy") throw bad('privacy must be "full" or "busy"');
      privacy = body.privacy;
      sets.push("privacy = ?"), vals.push(privacy);
      if (privacy === "full" && current.privacy === "busy") sets.push("needs_resync = 1");
      if (privacy === "busy") sets.push("needs_resync = 0");
    }
    if (!sets.length) return current;
    this.db.transaction(() => {
      this.db.query(`UPDATE calendars SET ${sets.join(", ")}, updated_at = ? WHERE id = ?`).run(...vals, this.nowIso(), id);
      if (privacy === "busy") this.scrub(id);
      if (body.enabled === false) {
        this.db.query("DELETE FROM calendar_events WHERE calendar_id = ?").run(id);
        this.db.query("DELETE FROM calendar_event_travel WHERE calendar_id = ?").run(id);
      }
    })();
    return this.calendar(id);
  }

  private scrub(calendarId: string) {
    this.db
      .query(
        `UPDATE calendar_events SET series_id = NULL, title = NULL, location = NULL, lat = NULL, lon = NULL, notes = NULL, url = NULL,
           conference_url = NULL, attendees_json = NULL, attendees_count = 0, organizer_json = NULL, travel_time_sec = NULL
         WHERE calendar_id = ?`,
      )
      .run(calendarId);
    this.db.query("DELETE FROM calendar_event_travel WHERE calendar_id = ?").run(calendarId);
  }

  private sourceOf(device: BridgeDevice, identifier: unknown): { sourceId: string; calendarId: string; enabled: boolean; privacy: "full" | "busy" } {
    const ident = str(identifier, "calendarId", 256, true);
    const r = this.db
      .query("SELECT s.id, s.calendar_id, c.enabled, c.privacy FROM calendar_sources s JOIN calendars c ON c.id = s.calendar_id WHERE s.device_id = ? AND s.calendar_identifier = ?")
      .get(device.id, ident) as Row | null;
    if (!r) throw bad(`calendar ${ident} is unknown: PUT /api/calendar/sources first`);
    return { sourceId: String(r.id), calendarId: String(r.calendar_id), enabled: r.enabled === 1, privacy: r.privacy === "busy" ? "busy" : "full" };
  }

  private upsert(sourceId: string, calendarId: string, e: StoredEvent, syncId: string | null) {
    this.db
      .query(
        `INSERT INTO calendar_events (source_id, calendar_id, external_id, series_id, title, location, lat, lon, notes, url, conference_url,
           start_at, end_at, all_day, availability, status, attendees_json, attendees_count, organizer_json, travel_time_sec, has_alarms, alarms_json, sync_id, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(source_id, external_id) DO UPDATE SET calendar_id = excluded.calendar_id, series_id = excluded.series_id, title = excluded.title,
           location = excluded.location, lat = excluded.lat, lon = excluded.lon, notes = excluded.notes, url = excluded.url,
           conference_url = excluded.conference_url, start_at = excluded.start_at, end_at = excluded.end_at, all_day = excluded.all_day,
           availability = excluded.availability, status = excluded.status, attendees_json = excluded.attendees_json,
           attendees_count = excluded.attendees_count, organizer_json = excluded.organizer_json, travel_time_sec = excluded.travel_time_sec,
           has_alarms = excluded.has_alarms, alarms_json = excluded.alarms_json, sync_id = coalesce(excluded.sync_id, calendar_events.sync_id), updated_at = excluded.updated_at`,
      )
      .run(
        sourceId,
        calendarId,
        e.externalId,
        e.seriesId,
        e.title,
        e.location,
        e.lat,
        e.lon,
        e.notes,
        e.url,
        e.conferenceUrl,
        e.start,
        e.end,
        e.allDay,
        e.availability,
        e.status,
        e.attendees,
        e.attendeesCount,
        e.organizer,
        e.travelTimeSec,
        e.hasAlarms,
        e.alarms,
        syncId,
        this.nowIso(),
      );
  }

  /** Batched, idempotent mirror update (docs/calendar.md#post-apicalendarsync-batched-idempotent). */
  sync(device: BridgeDevice, body: Record<string, unknown>): { upserted: number; deleted: number; removedStale: number } {
    const syncId = str(body.syncId, "syncId", 128) ?? null;
    const list = body.calendars;
    if (!Array.isArray(list) || list.length > 500) throw bad("calendars must be an array (max 500)");
    const now = this.clock();
    const batches = list.map((raw, i) => {
      const c = obj(raw, `calendars[${i}]`);
      const src = this.sourceOf(device, c.calendarId);
      const events = c.events === undefined ? [] : c.events;
      const deleted = c.deleted === undefined ? [] : c.deleted;
      if (!Array.isArray(events) || !Array.isArray(deleted)) throw bad("events and deleted must be arrays");
      if (deleted.some((d) => typeof d !== "string")) throw bad("deleted must be an array of externalId strings");
      const complete = c.complete === true;
      if (complete && !syncId) throw bad("syncId is required with complete");
      let window: { from: string; to: string } | undefined;
      if (complete) {
        const w = obj(c.window, "window");
        const from = Math.max(Date.parse(iso(w.from, "window.from")), now - 30 * 86_400_000 - DAY);
        const to = Math.min(Date.parse(iso(w.to, "window.to")), now + 181 * DAY);
        window = { from: new Date(from).toISOString(), to: new Date(to).toISOString() };
      }
      return { src, events: src.enabled ? events.map((e) => normalizeEvent(e, src.privacy)) : [], deleted: deleted as string[], complete, window };
    });
    if (batches.reduce((n, b) => n + b.events.length + b.deleted.length, 0) > MAX_EVENTS_PER_REQUEST) throw bad(`at most ${MAX_EVENTS_PER_REQUEST} events per request`);
    const out = { upserted: 0, deleted: 0, removedStale: 0 };
    this.db.transaction(() => {
      for (const b of batches) {
        for (const e of b.events) this.upsert(b.src.sourceId, b.src.calendarId, e, syncId);
        out.upserted += b.events.length;
        for (const id of b.deleted) out.deleted += this.db.query("DELETE FROM calendar_events WHERE source_id = ? AND external_id = ?").run(b.src.sourceId, id).changes;
        if (b.complete && b.window) {
          out.removedStale += this.db
            .query("DELETE FROM calendar_events WHERE source_id = ? AND start_at < ? AND end_at > ? AND sync_id IS NOT ?")
            .run(b.src.sourceId, b.window.to, b.window.from, syncId).changes;
          this.db.query("DELETE FROM calendar_events WHERE source_id = ? AND end_at < ?").run(b.src.sourceId, new Date(now - 30 * DAY).toISOString());
          this.db
            .query("DELETE FROM calendar_event_travel WHERE calendar_id = ? AND NOT EXISTS (SELECT 1 FROM calendar_events e WHERE e.calendar_id = calendar_event_travel.calendar_id AND e.external_id = calendar_event_travel.external_id)")
            .run(b.src.calendarId);
          this.db.query("UPDATE calendar_sources SET synced_at = ? WHERE id = ?").run(new Date(now).toISOString(), b.src.sourceId);
          if (b.src.enabled) this.db.query("UPDATE calendars SET needs_resync = 0 WHERE id = ?").run(b.src.calendarId);
        }
      }
    })();
    return out;
  }

  /** One event created or edited in EventKit, mirrored right away. */
  syncOne(device: BridgeDevice, body: Record<string, unknown>): { event?: AgendaItem; deleted?: number } {
    const src = this.sourceOf(device, body.calendarId);
    if (body.deleted !== undefined) {
      if (!Array.isArray(body.deleted) || body.deleted.some((d) => typeof d !== "string") || body.deleted.length > 100) throw bad("deleted must be an array of externalId strings");
      let n = 0;
      for (const id of body.deleted as string[]) n += this.db.query("DELETE FROM calendar_events WHERE source_id = ? AND external_id = ?").run(src.sourceId, id).changes;
      return { deleted: n };
    }
    const e = normalizeEvent(body.event, src.privacy);
    if (!src.enabled) return {};
    this.upsert(src.sourceId, src.calendarId, e, null);
    const row = this.db.query("SELECT id FROM calendar_events WHERE source_id = ? AND external_id = ?").get(src.sourceId, e.externalId) as { id: string };
    return { event: this.event(row.id) };
  }

  private event(id: string): AgendaItem {
    const r = this.db.query(`${EVENT_SELECT} WHERE e.id = ?`).get(id) as Row | null;
    if (!r) throw new HttpError(404, "event not found");
    return this.toEvent(r);
  }

  /**
   * Travel time an app computed for an event (MapKit, from a place the user chose); `null` clears it. Kept per
   * calendar and externalId, so it survives syncs and applies to whichever device's copy is served.
   */
  setTravel(eventId: string, body: Record<string, unknown>): AgendaItem {
    const r = this.db.query("SELECT e.calendar_id, e.external_id, c.privacy FROM calendar_events e JOIN calendars c ON c.id = e.calendar_id WHERE e.id = ?").get(eventId) as Row | null;
    if (!r) throw new HttpError(404, "event not found");
    if (r.privacy === "busy") throw bad("busy-only calendars have no travel time");
    if (body.travelTimeSec === null) {
      this.db.query("DELETE FROM calendar_event_travel WHERE calendar_id = ? AND external_id = ?").run(r.calendar_id, r.external_id);
      return this.event(eventId);
    }
    const seconds = int(body.travelTimeSec, "travelTimeSec", 0, 86_400);
    const mode = str(body.mode, "mode", 20) ?? null;
    if (mode !== null && !TRAVEL_MODES.has(mode)) throw bad("mode must be driving, transit, walking or cycling");
    this.db
      .query(
        `INSERT INTO calendar_event_travel (calendar_id, external_id, travel_time_sec, mode, updated_at) VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(calendar_id, external_id) DO UPDATE SET travel_time_sec = excluded.travel_time_sec, mode = excluded.mode, updated_at = excluded.updated_at`,
      )
      .run(r.calendar_id, r.external_id, seconds, mode, this.nowIso());
    return this.event(eventId);
  }

  private toEvent(r: Row): AgendaItem {
    const busyOnly = r.privacy === "busy";
    const base: AgendaItem = {
      kind: "event",
      id: String(r.id),
      calendarId: String(r.calendar_id),
      externalId: String(r.external_id),
      title: busyOnly ? null : ((r.title as string) ?? null),
      start: String(r.start_at),
      end: String(r.end_at),
      allDay: r.all_day === 1,
      availability: String(r.availability),
      color: ((r.color_override ?? r.device_color) as string) ?? null,
      busyOnly,
      hasAlarms: r.has_alarms === 1,
    };
    const alarms = parseJson(r.alarms_json);
    if (alarms) base.alarms = alarms;
    if (busyOnly) return base;
    const opt = (k: string, v: unknown) => (v === null || v === undefined ? {} : { [k]: v });
    const travelFromApp = r.travel_time_sec === null && r.app_travel_sec !== null && r.app_travel_sec !== undefined;
    return {
      ...base,
      ...opt("seriesId", r.series_id),
      ...opt("location", r.location),
      ...(r.lat !== null && r.lon !== null ? { coordinates: { lat: r.lat, lon: r.lon } } : {}),
      ...opt("notes", r.notes),
      ...opt("url", r.url),
      ...opt("conferenceUrl", r.conference_url),
      ...opt("status", r.status),
      ...opt("attendees", parseJson(r.attendees_json)),
      attendeesCount: Number(r.attendees_count),
      ...opt("organizer", parseJson(r.organizer_json)),
      ...opt("travelTimeSec", travelFromApp ? r.app_travel_sec : r.travel_time_sec),
      ...(travelFromApp ? opt("travelMode", r.travel_mode) : {}),
      editable: r.allows_modifications === 1,
    };
  }

  events(o: { from: string; to: string; calendars?: string[]; reminders?: boolean; bookings?: boolean }): AgendaItem[] {
    const params: (string | number)[] = [o.to, o.from];
    let filter = "";
    if (o.calendars?.length) {
      filter = ` AND c.id IN (${o.calendars.map(() => "?").join(", ")})`;
      params.push(...o.calendars);
    }
    const rows = this.db
      .query(
        `${EVENT_SELECT}
         WHERE c.enabled = 1 AND e.source_id = ${PRIMARY_SOURCE} AND e.start_at < ? AND e.end_at >= ?${filter}
         ORDER BY e.start_at, e.end_at`,
      )
      .all(...params) as Row[];
    const items = rows.map((r) => this.toEvent(r));
    if (o.reminders !== false) {
      const rem = this.db
        .query("SELECT id, title, due_at, done_at, list, priority FROM reminders WHERE archived_at IS NULL AND due_at IS NOT NULL AND julianday(due_at) >= julianday(?) AND julianday(due_at) < julianday(?) ORDER BY julianday(due_at)")
        .all(o.from, o.to) as Row[];
      for (const r of rem) {
        const at = new Date(String(r.due_at)).toISOString();
        items.push({ kind: "reminder", id: String(r.id), title: String(r.title), start: at, end: at, allDay: false, done: r.done_at !== null, list: String(r.list), priority: Number(r.priority) });
      }
    }
    if (o.bookings) {
      const bk = this.db
        .query(
          `SELECT b.id, b.start_at, b.end_at, b.status, b.type_id, b.invitee_name, t.title FROM bookings b JOIN booking_types t ON t.id = b.type_id
           WHERE b.status IN ('pending','confirmed') AND b.start_at < ? AND b.end_at > ? ORDER BY b.start_at`,
        )
        .all(o.to, o.from) as Row[];
      for (const r of bk) {
        items.push({ kind: "booking", id: String(r.id), title: `${r.title} · ${r.invitee_name}`, start: String(r.start_at), end: String(r.end_at), allDay: false, bookingTypeId: String(r.type_id), status: String(r.status) });
      }
    }
    return items.sort((a, b) => (a.start < b.start ? -1 : a.start > b.start ? 1 : 0));
  }

  /** Busy time from the calendars that count for availability; titles never leave this function. */
  busy(from: number, to: number): Interval[] {
    const rows = this.db
      .query(
        `SELECT e.start_at, e.end_at FROM calendar_events e
         JOIN calendars c ON c.id = e.calendar_id AND c.enabled = 1 AND c.counts_for_availability = 1
         WHERE e.source_id = ${PRIMARY_SOURCE} AND e.availability <> 'free' AND coalesce(e.status, 'confirmed') <> 'cancelled'
           AND e.start_at < ? AND e.end_at > ?`,
      )
      .all(new Date(to).toISOString(), new Date(from).toISOString()) as { start_at: string; end_at: string }[];
    return rows.map((r) => ({ start: Date.parse(r.start_at), end: Date.parse(r.end_at) }));
  }
}
