/** A parsed 5-field cron expression (minute hour day-of-month month day-of-week). */
export interface Cron {
  minutes: Set<number>;
  hours: Set<number>;
  days: Set<number>;
  months: Set<number>;
  weekdays: Set<number>; // 0 = Sunday
  anyDay: boolean;
  anyWeekday: boolean;
  anyHour: boolean;
}

const MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
const WEEKDAYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];

const MACROS: Record<string, string> = {
  "@yearly": "0 0 1 1 *",
  "@annually": "0 0 1 1 *",
  "@monthly": "0 0 1 * *",
  "@weekly": "0 0 * * 0",
  "@daily": "0 0 * * *",
  "@midnight": "0 0 * * *",
  "@hourly": "0 * * * *",
};

interface FieldSpec {
  name: string;
  min: number;
  max: number;
  names?: string[];
  namesFrom?: number;
}

const FIELDS: FieldSpec[] = [
  { name: "minute", min: 0, max: 59 },
  { name: "hour", min: 0, max: 23 },
  { name: "day of month", min: 1, max: 31 },
  { name: "month", min: 1, max: 12, names: MONTHS, namesFrom: 1 },
  { name: "day of week", min: 0, max: 7, names: WEEKDAYS, namesFrom: 0 },
];

export class CronError extends Error {}

function value(raw: string, f: FieldSpec): number {
  const lower = raw.toLowerCase();
  const named = f.names?.indexOf(lower) ?? -1;
  if (named >= 0) return named + f.namesFrom!;
  if (!/^\d+$/.test(raw)) throw new CronError(`${f.name}: "${raw}" is not a number`);
  const n = Number(raw);
  if (n < f.min || n > f.max) throw new CronError(`${f.name}: ${n} is out of range ${f.min}-${f.max}`);
  return n;
}

function field(text: string, f: FieldSpec): { set: Set<number>; any: boolean } {
  const set = new Set<number>();
  let any = false;
  for (const part of text.split(",")) {
    if (!part) throw new CronError(`${f.name}: empty list item`);
    const [range, stepText, extra] = part.split("/");
    if (extra !== undefined) throw new CronError(`${f.name}: invalid step in "${part}"`);
    let step = 1;
    if (stepText !== undefined) {
      if (!/^\d+$/.test(stepText) || Number(stepText) < 1) throw new CronError(`${f.name}: invalid step "${stepText}"`);
      step = Number(stepText);
    }
    let lo: number;
    let hi: number;
    if (range === "*") {
      lo = f.min;
      hi = f.max;
      if (step === 1) any = true;
    } else if (range!.includes("-")) {
      const [a, b, more] = range!.split("-");
      if (more !== undefined || !a || !b) throw new CronError(`${f.name}: invalid range "${range}"`);
      lo = value(a, f);
      hi = value(b, f);
      if (lo > hi) throw new CronError(`${f.name}: range "${range}" is reversed`);
    } else {
      lo = value(range!, f);
      hi = stepText !== undefined ? f.max : lo;
    }
    for (let v = lo; v <= hi; v += step) set.add(v);
  }
  return { set, any };
}

export function parseCron(expr: string): Cron {
  const text = MACROS[expr.trim().toLowerCase()] ?? expr.trim();
  const parts = text.split(/\s+/);
  if (parts.length !== 5) throw new CronError(`expected 5 fields (minute hour day month weekday), got ${parts.length}`);
  const [mi, h, d, mo, w] = parts.map((p, i) => field(p, FIELDS[i]!));
  const weekdays = new Set([...w!.set].map((x) => x % 7));
  return {
    minutes: mi!.set,
    hours: h!.set,
    days: d!.set,
    months: mo!.set,
    weekdays,
    anyDay: d!.any,
    anyWeekday: w!.any,
    anyHour: h!.any,
  };
}

// ---------- time zones ----------

const formatters = new Map<string, Intl.DateTimeFormat>();

function formatter(tz: string): Intl.DateTimeFormat {
  let f = formatters.get(tz);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", {
      timeZone: tz,
      hourCycle: "h23",
      year: "numeric",
      month: "numeric",
      day: "numeric",
      hour: "numeric",
      minute: "numeric",
      second: "numeric",
    });
    formatters.set(tz, f);
  }
  return f;
}

export function isValidTimeZone(tz: string): boolean {
  if (typeof tz !== "string" || !tz) return false;
  try {
    formatter(tz);
    return true;
  } catch {
    return false;
  }
}

export interface WallTime {
  year: number;
  month: number; // 1-12
  day: number;
  hour: number;
  minute: number;
  weekday: number; // 0 = Sunday
}

export function wallTime(t: number, tz: string): WallTime {
  const p: Record<string, number> = {};
  for (const part of formatter(tz).formatToParts(new Date(t))) if (part.type !== "literal") p[part.type] = Number(part.value);
  const weekday = new Date(Date.UTC(p.year!, p.month! - 1, p.day!)).getUTCDay();
  return { year: p.year!, month: p.month!, day: p.day!, hour: p.hour! % 24, minute: p.minute!, weekday };
}

/** Milliseconds to add to UTC to get the wall clock of `tz` at instant `t`. */
export function tzOffset(t: number, tz: string): number {
  const w = wallTime(t, tz);
  const asUtc = Date.UTC(w.year, w.month - 1, w.day, w.hour, w.minute);
  return asUtc - Math.floor(t / 60_000) * 60_000;
}

/**
 * The instants at which the wall clock of `tz` shows this date and time: none in a DST gap, two in a
 * DST overlap, one otherwise.
 */
export function zonedInstants(year: number, month: number, day: number, hour: number, minute: number, tz: string): number[] {
  const guess = Date.UTC(year, month - 1, day, hour, minute);
  const out = new Set<number>();
  for (const probe of [guess - 6 * 3_600_000, guess + 6 * 3_600_000]) {
    const t = guess - tzOffset(probe, tz);
    const w = wallTime(t, tz);
    if (w.year === year && w.month === month && w.day === day && w.hour === hour && w.minute === minute) out.add(t);
  }
  return [...out].sort((a, b) => a - b);
}

/** Converts a wall-clock time to an instant; a time skipped by DST moves forward by the gap. */
export function zonedToUtc(year: number, month: number, day: number, hour: number, minute: number, tz: string): number {
  const found = zonedInstants(year, month, day, hour, minute, tz);
  if (found.length) return found[0]!;
  const guess = Date.UTC(year, month - 1, day, hour, minute);
  return guess - tzOffset(guess - 6 * 3_600_000, tz);
}

const MAX_YEARS = 5;

/**
 * The first instant strictly after `after` matching `cron` in `tz`, or undefined if none within 5 years.
 * DST like Vixie cron: a fixed-hour job whose time is skipped runs once right after the gap, and runs
 * once (the first time) when the time repeats; a job on every hour follows the real clock instead.
 */
export function nextRun(cron: Cron, tz: string, after: number): number | undefined {
  const start = wallTime(after, tz);
  const offset = tzOffset(after, tz);
  const MARGIN = 3 * 3_600_000;
  const dayMatches = (y: number, m: number, d: number) => {
    const weekday = new Date(Date.UTC(y, m - 1, d)).getUTCDay();
    const dom = cron.days.has(d);
    const dow = cron.weekdays.has(weekday);
    if (cron.anyDay && cron.anyWeekday) return true;
    if (cron.anyDay) return dow;
    if (cron.anyWeekday) return dom;
    return dom || dow;
  };
  const hours = [...cron.hours].sort((a, b) => a - b);
  const minutes = [...cron.minutes].sort((a, b) => a - b);
  // Start one day early: a wall date can still have instants after `after` around DST changes.
  let cursor = Date.UTC(start.year, start.month - 1, start.day) - 86_400_000;
  const end = cursor + MAX_YEARS * 366 * 86_400_000;
  for (; cursor <= end; cursor += 86_400_000) {
    const day = new Date(cursor);
    const y = day.getUTCFullYear();
    const m = day.getUTCMonth() + 1;
    const d = day.getUTCDate();
    if (!cron.months.has(m) || !dayMatches(y, m, d)) continue;
    let best: number | undefined;
    for (const h of hours) {
      if (Date.UTC(y, m - 1, d, h, 59) - offset + MARGIN <= after) continue;
      for (const mi of minutes) {
        if (Date.UTC(y, m - 1, d, h, mi) - offset + MARGIN <= after) continue;
        const found = zonedInstants(y, m, d, h, mi, tz);
        let candidates: number[];
        if (found.length === 0) candidates = cron.anyHour ? [] : [zonedToUtc(y, m, d, h, mi, tz)];
        else candidates = cron.anyHour ? found : [found[0]!];
        for (const c of candidates) if (c > after && (best === undefined || c < best)) best = c;
      }
      // Instants of later hours are later (DST shifts are at most a few hours apart).
      if (best !== undefined && h >= wallTime(best, tz).hour + 3) break;
    }
    if (best !== undefined) return best;
  }
  return undefined;
}
