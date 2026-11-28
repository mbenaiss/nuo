import type { Database } from "bun:sqlite";
import { createHash, randomBytes } from "node:crypto";
import { HttpError } from "../bots/service";
import { DEFAULT_UI_LANGUAGE, t as i18n, type UiLanguage } from "../i18n/language";
import { isValidTimeZone } from "../scheduler/cron";
import { BOOKING_TZ, computeSlots, parseHm, WEEKDAYS, type Interval, type WorkingHours } from "./availability";
import { formatTarget, GoogleError, parseTarget, type GoogleCalendar, type GoogleTarget } from "./google";
import type { CalendarStore } from "./store";
import { bad, bool, email, int, iso, obj, str } from "./validate";

type Row = Record<string, string | number | null>;

export type LocationKind = "google_meet" | "phone" | "address" | "custom";
export type QuestionType = "text" | "longtext" | "phone" | "select";

export interface Question {
  id: string;
  label: string;
  type: QuestionType;
  required: boolean;
  options?: string[];
}

export interface BookingType {
  id: string;
  slug: string;
  kind: "opening" | "proposal";
  title: string;
  description: string | null;
  durationMin: number;
  location: { kind: LocationKind; value?: string };
  workingHours: WorkingHours;
  bufferBeforeMin: number;
  bufferAfterMin: number;
  minNoticeMin: number;
  maxDaysAhead: number;
  maxPerDay: number | null;
  slotStepMin: number | null;
  googleCalendar: string | null;
  questions: Question[];
  candidateSlots: { start: string; end: string }[];
  active: boolean;
  archived: boolean;
  url?: string;
  createdAt: string;
  updatedAt: string;
}

export type BookingStatus = "pending" | "confirmed" | "cancelled" | "rescheduled" | "failed";

export interface Booking {
  id: string;
  typeId: string;
  typeTitle: string;
  start: string;
  end: string;
  status: BookingStatus;
  invitee: { name: string; email: string; timezone: string | null; notes: string | null; answers: Record<string, string> };
  googleEventId: string | null;
  googleTarget: string | null;
  meetUrl: string | null;
  rescheduledFrom: string | null;
  cancelReason: string | null;
  createdAt: string;
  ip: string | null;
}

export interface PublicBooking {
  start: string;
  end: string;
  title: string;
  durationMin: number;
  location: { kind: LocationKind; value?: string };
  meetUrl?: string;
  status: BookingStatus;
  inviteeName: string;
}

export interface BookingDeps {
  db: Database;
  calendars: CalendarStore;
  google?: GoogleCalendar;
  defaultTarget?: GoogleTarget;
  baseUrl?: string;
  notify?: (title: string, body: string, bookingId: string) => void;
  clock?: () => number;
  ownerLanguage?: () => UiLanguage;
}

const MIN = 60_000;
const DAY = 86_400_000;
/** A pending booking whose Google call never finished (crash) stops holding its slot after this. */
const PENDING_TTL_MS = 5 * MIN;
const LOCATIONS = new Set<LocationKind>(["google_meet", "phone", "address", "custom"]);
const QUESTION_TYPES = new Set<QuestionType>(["text", "longtext", "phone", "select"]);
const RESERVED_QUESTIONS = new Set(["name", "email", "notes", "start", "website", "timezone"]);
const SLUG = /^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$/;
const TOKEN = /^[A-Za-z0-9_-]{43}$/;
export const RESERVED_SLUGS = new Set(["api", "m", "assets", "favicon.ico", "robots.txt"]);

const hashToken = (t: string) => createHash("sha256").update(t).digest("hex");
const parse = <T>(s: unknown, fallback: T): T => {
  try {
    return typeof s === "string" ? (JSON.parse(s) as T) : fallback;
  } catch {
    return fallback;
  }
};

const parisLabel = (iso: string, lang: UiLanguage) =>
  new Intl.DateTimeFormat(i18n("locale", {}, lang), { timeZone: BOOKING_TZ, weekday: "long", day: "numeric", month: "long", hour: "2-digit", minute: "2-digit" }).format(new Date(iso));

function workingHours(v: unknown): WorkingHours {
  const o = obj(v ?? {}, "workingHours");
  const out: WorkingHours = {};
  for (const [k, ranges] of Object.entries(o)) {
    if (!(WEEKDAYS as readonly string[]).includes(k)) throw bad(`workingHours: unknown day "${k}" (mon…sun)`);
    if (!Array.isArray(ranges) || ranges.length > 6) throw bad(`workingHours.${k} must be an array of at most 6 ["HH:MM","HH:MM"] ranges`);
    out[k as keyof WorkingHours] = ranges.map((r) => {
      if (!Array.isArray(r) || r.length !== 2 || typeof r[0] !== "string" || typeof r[1] !== "string") throw bad(`workingHours.${k}: ranges are ["HH:MM","HH:MM"]`);
      const a = parseHm(r[0]);
      const b = parseHm(r[1]);
      if (a === undefined || b === undefined || b <= a) throw bad(`workingHours.${k}: invalid range ${r[0]}–${r[1]}`);
      return [r[0], r[1]] as [string, string];
    });
  }
  return out;
}

function questions(v: unknown): Question[] {
  if (v === undefined || v === null) return [];
  if (!Array.isArray(v) || v.length > 10) throw bad("questions must be an array (max 10)");
  const ids = new Set<string>();
  return v.map((raw, i) => {
    const q = obj(raw, `questions[${i}]`);
    const id = str(q.id, `questions[${i}].id`, 31, true);
    if (!/^[a-z][a-z0-9_]*$/.test(id) || RESERVED_QUESTIONS.has(id) || ids.has(id)) throw bad(`questions[${i}].id must be unique snake_case (not name/email/notes)`);
    ids.add(id);
    const type = (q.type ?? "text") as QuestionType;
    if (!QUESTION_TYPES.has(type)) throw bad(`questions[${i}].type must be text, longtext, phone or select`);
    const out: Question = { id, label: str(q.label, `questions[${i}].label`, 200, true), type, required: bool(q.required, "required", false) };
    if (type === "select") {
      if (!Array.isArray(q.options) || !q.options.length || q.options.length > 20) throw bad(`questions[${i}].options must list 1 to 20 choices`);
      out.options = q.options.map((o, j) => str(o, `questions[${i}].options[${j}]`, 100, true));
    }
    return out;
  });
}

export class BookingService {
  private db: Database;
  private clock: () => number;
  private warnedNoGoogle = false;

  constructor(private d: BookingDeps) {
    this.db = d.db;
    this.clock = d.clock ?? Date.now;
  }

  private nowIso = () => new Date(this.clock()).toISOString();

  // ---- booking types -------------------------------------------------------------------------

  private toType(r: Row): BookingType {
    const location: BookingType["location"] = { kind: r.location_kind as LocationKind, ...(r.location_value ? { value: String(r.location_value) } : {}) };
    return {
      id: String(r.id),
      slug: String(r.slug),
      kind: r.kind === "proposal" ? "proposal" : "opening",
      title: String(r.title),
      description: (r.description as string) ?? null,
      durationMin: Number(r.duration_min),
      location,
      workingHours: parse(r.working_hours, {}),
      bufferBeforeMin: Number(r.buffer_before_min),
      bufferAfterMin: Number(r.buffer_after_min),
      minNoticeMin: Number(r.min_notice_min),
      maxDaysAhead: Number(r.max_days_ahead),
      maxPerDay: r.max_per_day === null ? null : Number(r.max_per_day),
      slotStepMin: r.slot_step_min === null ? null : Number(r.slot_step_min),
      googleCalendar: (r.google_calendar as string) ?? null,
      questions: parse(r.questions, []),
      candidateSlots: parse(r.candidate_slots, []),
      active: r.active === 1,
      archived: r.archived_at !== null,
      ...(this.d.baseUrl ? { url: `${this.d.baseUrl}/${r.slug}` } : {}),
      createdAt: String(r.created_at),
      updatedAt: String(r.updated_at),
    };
  }

  types(archived = false): BookingType[] {
    const rows = this.db.query(`SELECT * FROM booking_types ${archived ? "" : "WHERE archived_at IS NULL"} ORDER BY created_at`).all() as Row[];
    return rows.map((r) => this.toType(r));
  }

  type(id: string): BookingType {
    const r = this.db.query("SELECT * FROM booking_types WHERE id = ?").get(id) as Row | null;
    if (!r) throw new HttpError(404, "booking type not found");
    return this.toType(r);
  }

  /** Only active, non-archived types are public. */
  publicType(slug: string): BookingType | undefined {
    const r = this.db.query("SELECT * FROM booking_types WHERE slug = ? AND active = 1 AND archived_at IS NULL").get(slug) as Row | null;
    return r ? this.toType(r) : undefined;
  }

  private typeColumns(b: Record<string, unknown>, base?: BookingType): Record<string, string | number | null> {
    const has = (k: string) => b[k] !== undefined;
    const kind = has("kind") ? b.kind : (base?.kind ?? "opening");
    if (kind !== "opening" && kind !== "proposal") throw bad('kind must be "opening" or "proposal"');
    const slug = has("slug") ? str(b.slug, "slug", 40, true).toLowerCase() : base?.slug;
    if (!slug || !SLUG.test(slug) || RESERVED_SLUGS.has(slug)) throw bad("slug must be 1-40 characters a-z, 0-9 and -");
    const title = has("title") ? str(b.title, "title", 200, true) : base?.title;
    if (!title) throw bad("title is required");
    const duration = has("durationMin") ? int(b.durationMin, "durationMin", 5, 720) : (base?.durationMin ?? int(undefined, "durationMin", 5, 720));
    const loc = has("location") ? obj(b.location, "location") : (base?.location ?? { kind: "google_meet" });
    const locKind = loc.kind as LocationKind;
    if (!LOCATIONS.has(locKind)) throw bad("location.kind must be google_meet, phone, address or custom");
    const locValue = locKind === "google_meet" ? undefined : str(loc.value, "location.value", 500, true);
    const target = has("googleCalendar") ? (b.googleCalendar === null ? undefined : parseTarget(str(b.googleCalendar, "googleCalendar", 400))) : parseTarget(base?.googleCalendar);
    const wh = has("workingHours") ? workingHours(b.workingHours) : (base?.workingHours ?? {});
    let candidates: { start: string; end: string }[] = base?.candidateSlots ?? [];
    if (has("candidateSlots")) {
      if (!Array.isArray(b.candidateSlots) || b.candidateSlots.length > 50) throw bad("candidateSlots must be an array (max 50)");
      candidates = b.candidateSlots.map((c, i) => {
        const start = iso(obj(c, `candidateSlots[${i}]`).start, `candidateSlots[${i}].start`);
        return { start, end: new Date(Date.parse(start) + duration * MIN).toISOString() };
      });
    } else if (has("durationMin")) {
      candidates = candidates.map((c) => ({ start: c.start, end: new Date(Date.parse(c.start) + duration * MIN).toISOString() }));
    }
    if (kind === "proposal" && !candidates.length) throw bad("a proposal needs candidateSlots");
    const maxPerDay = has("maxPerDay") ? (b.maxPerDay === null ? null : int(b.maxPerDay, "maxPerDay", 1, 100)) : (base?.maxPerDay ?? null);
    const step = has("slotStepMin") ? (b.slotStepMin === null ? null : int(b.slotStepMin, "slotStepMin", 5, 720)) : (base?.slotStepMin ?? null);
    return {
      slug,
      kind,
      title,
      description: has("description") ? (str(b.description, "description", 4000) ?? null) : (base?.description ?? null),
      duration_min: duration,
      location_kind: locKind,
      location_value: locValue ?? null,
      working_hours: JSON.stringify(wh),
      buffer_before_min: has("bufferBeforeMin") ? int(b.bufferBeforeMin, "bufferBeforeMin", 0, 720) : (base?.bufferBeforeMin ?? 0),
      buffer_after_min: has("bufferAfterMin") ? int(b.bufferAfterMin, "bufferAfterMin", 0, 720) : (base?.bufferAfterMin ?? 0),
      min_notice_min: has("minNoticeMin") ? int(b.minNoticeMin, "minNoticeMin", 0, 60 * 24 * 60) : (base?.minNoticeMin ?? 240),
      max_days_ahead: has("maxDaysAhead") ? int(b.maxDaysAhead, "maxDaysAhead", 1, 365) : (base?.maxDaysAhead ?? 60),
      max_per_day: maxPerDay,
      slot_step_min: step,
      google_calendar: target ? formatTarget(target) : null,
      questions: JSON.stringify(has("questions") ? questions(b.questions) : (base?.questions ?? [])),
      candidate_slots: JSON.stringify(candidates),
      active: (has("active") ? bool(b.active, "active") : (base?.active ?? true)) ? 1 : 0,
    };
  }

  private writeType(sql: string, params: (string | number | null)[]) {
    try {
      this.db.query(sql).run(...params);
    } catch (e) {
      if (/UNIQUE constraint failed: booking_types.slug/.test(String((e as Error)?.message))) throw new HttpError(409, "this slug is already used");
      throw e;
    }
  }

  createType(b: Record<string, unknown>): BookingType {
    const cols = this.typeColumns(b);
    const id = randomBytes(16).toString("hex");
    const names = Object.keys(cols);
    this.writeType(`INSERT INTO booking_types (id, ${names.join(", ")}) VALUES (?, ${names.map(() => "?").join(", ")})`, [id, ...Object.values(cols)]);
    return this.type(id);
  }

  patchType(id: string, b: Record<string, unknown>): BookingType {
    const current = this.type(id);
    if (current.archived) throw new HttpError(404, "booking type not found");
    const cols = this.typeColumns(b, current);
    this.writeType(`UPDATE booking_types SET ${Object.keys(cols).map((k) => `${k} = ?`).join(", ")}, updated_at = ? WHERE id = ?`, [...Object.values(cols), this.nowIso(), id]);
    return this.type(id);
  }

  archiveType(id: string): void {
    this.type(id);
    this.db.query("UPDATE booking_types SET archived_at = coalesce(archived_at, ?), active = 0, updated_at = ? WHERE id = ?").run(this.nowIso(), this.nowIso(), id);
  }

  // ---- availability --------------------------------------------------------------------------

  private activeBookings(from: number, to: number, excludeId?: string): { typeId: string; start: number; end: number }[] {
    const pendingSince = new Date(this.clock() - PENDING_TTL_MS).toISOString();
    const rows = this.db
      .query(
        `SELECT type_id, start_at, end_at FROM bookings
         WHERE (status = 'confirmed' OR (status = 'pending' AND created_at > ?)) AND start_at < ? AND end_at > ? AND id IS NOT ?`,
      )
      .all(pendingSince, new Date(to).toISOString(), new Date(from).toISOString(), excludeId ?? null) as Row[];
    return rows.map((r) => ({ typeId: String(r.type_id), start: Date.parse(String(r.start_at)), end: Date.parse(String(r.end_at)) }));
  }

  slots(t: BookingType, from: number, to: number, excludeBookingId?: string): Interval[] {
    const margin = DAY + (t.bufferBeforeMin + t.bufferAfterMin + t.durationMin) * MIN;
    const bookings = this.activeBookings(from - margin, to + margin, excludeBookingId);
    return computeSlots(
      {
        durationMin: t.durationMin,
        slotStepMin: t.slotStepMin,
        bufferBeforeMin: t.bufferBeforeMin,
        bufferAfterMin: t.bufferAfterMin,
        minNoticeMin: t.minNoticeMin,
        maxDaysAhead: t.maxDaysAhead,
        maxPerDay: t.maxPerDay,
        workingHours: t.workingHours,
        ...(t.kind === "proposal" ? { candidateSlots: t.candidateSlots.map((c) => ({ start: Date.parse(c.start), end: Date.parse(c.end) })) } : {}),
      },
      {
        from,
        to,
        now: this.clock(),
        busy: [...this.d.calendars.busy(from - margin, to + margin), ...bookings],
        booked: bookings.filter((b) => b.typeId === t.id).map((b) => b.start),
      },
    );
  }

  // ---- bookings ------------------------------------------------------------------------------

  private toBooking(r: Row): Booking {
    return {
      id: String(r.id),
      typeId: String(r.type_id),
      typeTitle: String(r.type_title ?? ""),
      start: String(r.start_at),
      end: String(r.end_at),
      status: r.status as BookingStatus,
      invitee: {
        name: String(r.invitee_name),
        email: String(r.invitee_email),
        timezone: (r.invitee_timezone as string) ?? null,
        notes: (r.invitee_notes as string) ?? null,
        answers: parse(r.answers, {}),
      },
      googleEventId: (r.google_event_id as string) ?? null,
      googleTarget: (r.google_target as string) ?? null,
      meetUrl: (r.meet_url as string) ?? null,
      rescheduledFrom: (r.rescheduled_from as string) ?? null,
      cancelReason: (r.cancel_reason as string) ?? null,
      createdAt: String(r.created_at),
      ip: (r.ip as string) ?? null,
    };
  }

  private row(where: string, ...params: string[]): Row | null {
    return this.db.query(`SELECT b.*, t.title AS type_title FROM bookings b JOIN booking_types t ON t.id = b.type_id WHERE ${where}`).get(...params) as Row | null;
  }

  booking(id: string): Booking {
    const r = this.row("b.id = ?", id);
    if (!r) throw new HttpError(404, "booking not found");
    return this.toBooking(r);
  }

  /** The booking a manage link points to (the latest one after reschedules). */
  byToken(token: string): Booking | undefined {
    if (!TOKEN.test(token)) return undefined;
    const r = this.row("b.manage_token_hash = ?", hashToken(token));
    return r ? this.toBooking(r) : undefined;
  }

  bookings(q: { from?: string; to?: string; status?: string; typeId?: string }): Booking[] {
    const where: string[] = [];
    const params: string[] = [];
    const statuses = (q.status ?? "confirmed").split(",").filter(Boolean);
    if (!statuses.includes("all")) {
      where.push(`b.status IN (${statuses.map(() => "?").join(", ")})`);
      params.push(...statuses);
    }
    const from = q.from ? iso(q.from, "from") : q.to ? undefined : this.nowIso();
    if (from) where.push("b.end_at > ?"), params.push(from);
    if (q.to) where.push("b.start_at < ?"), params.push(iso(q.to, "to"));
    if (q.typeId) where.push("b.type_id = ?"), params.push(q.typeId);
    const rows = this.db
      .query(`SELECT b.*, t.title AS type_title FROM bookings b JOIN booking_types t ON t.id = b.type_id ${where.length ? "WHERE " + where.join(" AND ") : ""} ORDER BY b.start_at LIMIT 500`)
      .all(...params) as Row[];
    return rows.map((r) => this.toBooking(r));
  }

  publicView(b: Booking): PublicBooking {
    const t = this.type(b.typeId);
    return {
      start: b.start,
      end: b.end,
      title: t.title,
      durationMin: t.durationMin,
      location: t.location,
      ...(b.meetUrl ? { meetUrl: b.meetUrl } : {}),
      status: b.status,
      inviteeName: b.invitee.name,
    };
  }

  private ownerLanguage(): UiLanguage {
    return this.d.ownerLanguage?.() ?? DEFAULT_UI_LANGUAGE;
  }

  manageUrl(token: string): string {
    return `${this.d.baseUrl ?? ""}/m/${token}`;
  }

  private target(t: BookingType): GoogleTarget | undefined {
    return parseTarget(t.googleCalendar) ?? this.d.defaultTarget;
  }

  private validateInvitee(t: BookingType, b: Record<string, unknown>) {
    const answersIn = b.answers === undefined || b.answers === null ? {} : obj(b.answers, "answers");
    const answers: Record<string, string> = {};
    for (const q of t.questions) {
      const max = q.type === "longtext" ? 2000 : q.type === "phone" ? 40 : 300;
      const raw = answersIn[q.id];
      if (raw !== undefined && raw !== null && typeof raw !== "string") throw bad(`answers: ${i18n("booking.answerInvalid", { label: q.label })}`);
      const v = typeof raw === "string" ? raw.trim() : "";
      if (!v) {
        if (q.required) throw bad(`answers: ${i18n("booking.answerRequired", { label: q.label })}`);
        continue;
      }
      if (v.length > max) throw bad(`answers: ${i18n("booking.answerTooLong", { label: q.label })}`);
      if (q.type === "phone" && !/^[+0-9 ().-]{4,40}$/.test(v)) throw bad(`answers: ${i18n("booking.answerPhone", { label: q.label })}`);
      if (q.type === "select" && !q.options?.includes(v)) throw bad(`answers: ${i18n("booking.answerChoice", { label: q.label })}`);
      answers[q.id] = v;
    }
    for (const k of Object.keys(answersIn)) if (!t.questions.some((q) => q.id === k)) throw bad(`unknown answer "${k}"`);
    const tz = str(b.timezone, "timezone", 64);
    return {
      name: str(b.name, "name", 120, true),
      email: email(b.email, "email"),
      notes: str(b.notes, "notes", 2000) ?? null,
      timezone: tz && isValidTimeZone(tz) ? tz : null,
      answers,
    };
  }

  private description(t: BookingType, inv: { name: string; email: string; notes: string | null; answers: Record<string, string> }, token: string): string {
    const lines = [i18n("booking.bookedBy", { name: inv.name, email: inv.email })];
    if (inv.notes) lines.push("", inv.notes);
    for (const q of t.questions) if (inv.answers[q.id]) lines.push(i18n("booking.answerLine", { label: q.label, value: inv.answers[q.id]! }));
    lines.push("", i18n("booking.manageLine", { url: this.manageUrl(token) }));
    return lines.join("\n");
  }

  private googleLocation(t: BookingType): string | undefined {
    if (t.location.kind === "google_meet") return undefined;
    return t.location.kind === "phone" ? i18n("booking.phone", { number: t.location.value ?? "" }) : t.location.value;
  }

  private isOffered(t: BookingType, start: number, excludeId?: string): Interval | undefined {
    return this.slots(t, start, start + 1, excludeId).find((s) => s.start === start);
  }

  private async googleBusy(target: GoogleTarget, t: BookingType, slot: Interval): Promise<boolean> {
    if (!this.d.google) return false;
    const from = slot.start - t.bufferBeforeMin * MIN;
    const to = slot.end + t.bufferAfterMin * MIN;
    try {
      return (await this.d.google.freeBusy(target, from, to)).some((b) => b.start < to && b.end > from);
    } catch (e) {
      console.warn(`[booking] Google free/busy check skipped: ${(e as Error)?.message ?? e}`);
      return false;
    }
  }

  private setStatus(id: string, status: BookingStatus, extra: Record<string, string | null> = {}) {
    const cols = Object.keys(extra);
    this.db.query(`UPDATE bookings SET status = ?, ${cols.map((c) => `${c} = ?, `).join("")}updated_at = ? WHERE id = ?`).run(status, ...Object.values(extra), this.nowIso(), id);
  }

  /** Public booking; the slot is reserved in a write transaction before Google is called. */
  async book(slug: string, b: Record<string, unknown>, ip: string): Promise<{ booking: Booking; token: string }> {
    const t = this.publicType(slug);
    if (!t) throw new HttpError(404, "not found");
    const start = Date.parse(iso(b.start, "start"));
    const inv = this.validateInvitee(t, b);
    const token = randomBytes(32).toString("base64url");
    const id = randomBytes(16).toString("hex");
    const target = this.target(t);
    const reserve = this.db.transaction(() => {
      const slot = this.isOffered(t, start);
      if (!slot) throw new HttpError(409, i18n("booking.slotTaken"));
      this.db
        .query(
          `INSERT INTO bookings (id, type_id, start_at, end_at, status, invitee_name, invitee_email, invitee_timezone, invitee_notes, answers, google_target, manage_token_hash, ip, created_at, updated_at)
           VALUES (?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .run(id, t.id, new Date(slot.start).toISOString(), new Date(slot.end).toISOString(), inv.name, inv.email, inv.timezone, inv.notes, JSON.stringify(inv.answers), target ? formatTarget(target) : null, hashToken(token), ip, this.nowIso(), this.nowIso());
      if (t.kind === "proposal") this.db.query("UPDATE booking_types SET active = 0, updated_at = ? WHERE id = ?").run(this.nowIso(), t.id);
      return slot;
    });
    const slot = reserve.immediate();
    if (target && this.d.google) {
      if (await this.googleBusy(target, t, slot)) {
        this.failBooking(id, t);
        throw new HttpError(409, i18n("booking.slotTaken"));
      }
      try {
        const ev = await this.d.google.createEvent(target, {
          title: `${t.title} · ${inv.name}`,
          start: new Date(slot.start).toISOString(),
          end: new Date(slot.end).toISOString(),
          description: this.description(t, inv, token),
          location: this.googleLocation(t),
          attendees: [inv.email],
          meet: t.location.kind === "google_meet",
          privateProps: { nuo_booking: id },
        });
        this.setStatus(id, "confirmed", { google_event_id: ev.id, meet_url: ev.meetUrl ?? null });
      } catch (e) {
        console.error(`[booking] Google event creation failed for booking ${id}: ${(e as Error)?.message ?? e}`);
        this.failBooking(id, t);
        throw new HttpError(502, i18n("booking.saveFailed"));
      }
    } else {
      if (!this.warnedNoGoogle) console.warn("[booking] no Google calendar configured (NUO_GOOGLE_CALENDAR or the type's googleCalendar): bookings are stored without a Google event");
      this.warnedNoGoogle = true;
      this.setStatus(id, "confirmed");
    }
    const booking = this.booking(id);
    const lang = this.ownerLanguage();
    this.d.notify?.(i18n("booking.notifyNew", {}, lang), `${inv.name} · ${parisLabel(booking.start, lang)} · ${t.title}`, id);
    return { booking, token };
  }

  private failBooking(id: string, t: BookingType) {
    this.db.transaction(() => {
      this.setStatus(id, "failed", { manage_token_hash: null });
      if (t.kind === "proposal") this.db.query("UPDATE booking_types SET active = 1 WHERE id = ? AND archived_at IS NULL").run(t.id);
    })();
  }

  async cancel(id: string, o: { reason?: unknown; byInvitee: boolean }): Promise<Booking> {
    const b = this.booking(id);
    if (b.status !== "confirmed" && b.status !== "pending") throw new HttpError(409, i18n("booking.notActive"));
    const reason = str(o.reason, "reason", 500) ?? null;
    const t = this.type(b.typeId);
    this.db.transaction(() => {
      this.setStatus(id, "cancelled", { cancel_reason: reason });
      if (t.kind === "proposal") this.db.query("UPDATE booking_types SET active = 1, updated_at = ? WHERE id = ? AND archived_at IS NULL").run(this.nowIso(), t.id);
    })();
    const target = parseTarget(b.googleTarget);
    if (b.googleEventId && target && this.d.google) {
      await this.d.google.deleteEvent(target, b.googleEventId).catch((e) => console.error(`[booking] Google event of cancelled booking ${id} not deleted: ${(e as Error)?.message ?? e}`));
    }
    if (o.byInvitee) {
      const lang = this.ownerLanguage();
      const text = `${b.invitee.name} · ${parisLabel(b.start, lang)} · ${t.title}`;
      this.d.notify?.(i18n("booking.notifyCancelled", {}, lang), reason ? i18n("booking.withReason", { text, reason }, lang) : text, id);
    }
    return this.booking(id);
  }

  async reschedule(token: string, startRaw: unknown): Promise<Booking> {
    const old = this.byToken(token);
    if (!old || old.status !== "confirmed") throw new HttpError(404, "not found");
    const t = this.type(old.typeId);
    if (t.archived) throw new HttpError(409, i18n("booking.typeGone"));
    const start = Date.parse(iso(startRaw, "start"));
    const id = randomBytes(16).toString("hex");
    const hash = hashToken(token);
    const slot = this.db
      .transaction(() => {
        const s = this.isOffered(t, start, old.id);
        if (!s) throw new HttpError(409, i18n("booking.slotTaken"));
        this.setStatus(old.id, "rescheduled", { manage_token_hash: null });
        this.db
          .query(
            `INSERT INTO bookings (id, type_id, start_at, end_at, status, invitee_name, invitee_email, invitee_timezone, invitee_notes, answers,
               google_target, google_event_id, meet_url, manage_token_hash, rescheduled_from, ip, created_at, updated_at)
             SELECT ?, type_id, ?, ?, 'pending', invitee_name, invitee_email, invitee_timezone, invitee_notes, answers,
               google_target, google_event_id, meet_url, ?, id, ip, ?, ? FROM bookings WHERE id = ?`,
          )
          .run(id, new Date(s.start).toISOString(), new Date(s.end).toISOString(), hash, this.nowIso(), this.nowIso(), old.id);
        return s;
      })
      .immediate();
    const target = parseTarget(old.googleTarget);
    if (old.googleEventId && target && this.d.google) {
      try {
        await this.d.google.updateEvent(target, old.googleEventId, { start: new Date(slot.start).toISOString(), end: new Date(slot.end).toISOString() });
      } catch (e) {
        console.error(`[booking] Google event of booking ${old.id} not moved: ${(e as Error)?.message ?? e}`);
        this.db.transaction(() => {
          this.setStatus(id, "failed", { manage_token_hash: null });
          this.setStatus(old.id, "confirmed", { manage_token_hash: hash });
        })();
        throw new HttpError(502, e instanceof GoogleError ? i18n("booking.moveFailed") : "internal error");
      }
    }
    this.setStatus(id, "confirmed");
    const moved = this.booking(id);
    const lang = this.ownerLanguage();
    const when = i18n("booking.movedFrom", { when: parisLabel(moved.start, lang), before: parisLabel(old.start, lang) }, lang);
    this.d.notify?.(i18n("booking.notifyMoved", {}, lang), `${moved.invitee.name} · ${when} · ${t.title}`, id);
    return moved;
  }
}
