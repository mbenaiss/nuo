import { wallTime, zonedToUtc } from "../scheduler/cron";

export const BOOKING_TZ = "Europe/Paris";
export const WEEKDAYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"] as const;
export type Weekday = (typeof WEEKDAYS)[number];
export type WorkingHours = Partial<Record<Weekday, [string, string][]>>;

export interface Interval {
  start: number;
  end: number;
}

export interface SlotRules {
  durationMin: number;
  slotStepMin?: number | null;
  bufferBeforeMin: number;
  bufferAfterMin: number;
  minNoticeMin: number;
  maxDaysAhead: number;
  maxPerDay?: number | null;
  workingHours: WorkingHours;
  /** Proposals: the only candidates, instead of working hours. */
  candidateSlots?: Interval[];
}

export interface SlotQuery {
  from: number;
  to: number;
  now: number;
  /** Everything that blocks a slot: busy events and other bookings. */
  busy: Interval[];
  /** Starts of this type's active bookings, for `maxPerDay`. */
  booked?: number[];
}

const MIN = 60_000;
const DAY = 86_400_000;

export function parseHm(s: string): number | undefined {
  const m = /^([01]\d|2[0-4]):([0-5]\d)$/.exec(s);
  if (!m) return undefined;
  const v = Number(m[1]) * 60 + Number(m[2]);
  return v <= 24 * 60 ? v : undefined;
}

export function dayKey(t: number, tz = BOOKING_TZ): string {
  const w = wallTime(t, tz);
  return `${w.year}-${String(w.month).padStart(2, "0")}-${String(w.day).padStart(2, "0")}`;
}

export function mergeIntervals(list: Interval[]): Interval[] {
  const sorted = list.filter((i) => i.end > i.start).sort((a, b) => a.start - b.start);
  const out: Interval[] = [];
  for (const i of sorted) {
    const last = out[out.length - 1];
    if (last && i.start <= last.end) last.end = Math.max(last.end, i.end);
    else out.push({ ...i });
  }
  return out;
}

function overlapsAny(merged: Interval[], start: number, end: number): boolean {
  let lo = 0;
  let hi = merged.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (merged[mid]!.end <= start) lo = mid + 1;
    else hi = mid;
  }
  const c = merged[lo];
  return !!c && c.start < end;
}

/** Candidate slots of one Paris wall-clock day from the working hours, deduplicated across DST. */
function daySlots(y: number, m: number, d: number, rules: SlotRules, tz: string): Interval[] {
  const weekday = WEEKDAYS[new Date(Date.UTC(y, m - 1, d)).getUTCDay()]!;
  const duration = rules.durationMin * MIN;
  const step = (rules.slotStepMin || rules.durationMin) * MIN;
  const seen = new Set<number>();
  const out: Interval[] = [];
  for (const [a, b] of rules.workingHours[weekday] ?? []) {
    const rs = parseHm(a);
    const re = parseHm(b);
    if (rs === undefined || re === undefined || re <= rs) continue;
    const rangeStart = zonedToUtc(y, m, d, Math.floor(rs / 60), rs % 60, tz);
    const next = new Date(Date.UTC(y, m - 1, d + 1));
    const rangeEnd =
      re === 24 * 60 ? zonedToUtc(next.getUTCFullYear(), next.getUTCMonth() + 1, next.getUTCDate(), 0, 0, tz) : zonedToUtc(y, m, d, Math.floor(re / 60), re % 60, tz);
    for (let wall = rs; wall + rules.durationMin <= re; wall += step / MIN) {
      const start = zonedToUtc(y, m, d, Math.floor(wall / 60), wall % 60, tz);
      if (start < rangeStart || start + duration > rangeEnd || seen.has(start)) continue;
      seen.add(start);
      out.push({ start, end: start + duration });
    }
  }
  return out.sort((x, z) => x.start - z.start);
}

/** Free slots whose start is in [from, to), see docs/calendar.md#availability. */
export function computeSlots(rules: SlotRules, q: SlotQuery, tz = BOOKING_TZ): Interval[] {
  const earliest = Math.max(q.from, q.now + rules.minNoticeMin * MIN);
  const latest = Math.min(q.to, q.now + rules.maxDaysAhead * DAY);
  if (latest <= earliest) return [];
  const busy = mergeIntervals(q.busy);
  const before = rules.bufferBeforeMin * MIN;
  const after = rules.bufferAfterMin * MIN;
  const perDay = new Map<string, number>();
  if (rules.maxPerDay) for (const b of q.booked ?? []) perDay.set(dayKey(b, tz), (perDay.get(dayKey(b, tz)) ?? 0) + 1);

  let candidates: Interval[];
  if (rules.candidateSlots) {
    candidates = [...rules.candidateSlots].sort((a, b) => a.start - b.start);
  } else {
    candidates = [];
    const first = wallTime(earliest, tz);
    const last = wallTime(latest, tz);
    for (let cursor = Date.UTC(first.year, first.month - 1, first.day); cursor <= Date.UTC(last.year, last.month - 1, last.day); cursor += DAY) {
      const day = new Date(cursor);
      candidates.push(...daySlots(day.getUTCFullYear(), day.getUTCMonth() + 1, day.getUTCDate(), rules, tz));
    }
  }
  return candidates.filter((s) => {
    if (s.start < earliest || s.start >= latest) return false;
    if (rules.maxPerDay && (perDay.get(dayKey(s.start, tz)) ?? 0) >= rules.maxPerDay) return false;
    return !overlapsAny(busy, s.start - before, s.end + after);
  });
}
