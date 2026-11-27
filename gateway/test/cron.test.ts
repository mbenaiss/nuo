import { expect, test } from "bun:test";
import { CronError, isValidTimeZone, nextRun, parseCron, zonedInstants, zonedToUtc } from "../src/scheduler/cron";

const PARIS = "Europe/Paris";
const iso = (t: number | undefined) => (t === undefined ? undefined : new Date(t).toISOString());
const runs = (expr: string, from: string, n: number, tz = PARIS) => {
  const c = parseCron(expr);
  const out: string[] = [];
  let t = Date.parse(from);
  for (let i = 0; i < n; i++) {
    t = nextRun(c, tz, t)!;
    out.push(iso(t)!);
  }
  return out;
};

test("parses lists, ranges, steps, names and macros", () => {
  const c = parseCron("0,30 8-10 */10 jan,JUL-aug mon-fri");
  expect([...c.minutes]).toEqual([0, 30]);
  expect([...c.hours]).toEqual([8, 9, 10]);
  expect([...c.days]).toEqual([1, 11, 21, 31]);
  expect([...c.months]).toEqual([1, 7, 8]);
  expect([...c.weekdays]).toEqual([1, 2, 3, 4, 5]);
  expect([...parseCron("0 0 * * 7").weekdays]).toEqual([0]);
  expect([...parseCron("5/20 * * * *").minutes]).toEqual([5, 25, 45]);
  expect([...parseCron("0 9-17/4 * * *").hours]).toEqual([9, 13, 17]);
  expect(parseCron("@daily")).toEqual(parseCron("0 0 * * *"));
});

test("rejects malformed expressions", () => {
  for (const bad of ["* * * *", "* * * * * *", "60 * * * *", "* 24 * * *", "* * 0 * *", "* * * 13 *", "* * * * 8", "10-5 * * * *", "*/0 * * * *", "a * * * *", "1,,2 * * * *", "1/2/3 * * * *"]) {
    expect(() => parseCron(bad)).toThrow(CronError);
  }
});

test("validates time zones", () => {
  expect(isValidTimeZone("Europe/Paris")).toBe(true);
  expect(isValidTimeZone("UTC")).toBe(true);
  expect(isValidTimeZone("Mars/Olympus")).toBe(false);
  expect(isValidTimeZone("")).toBe(false);
});

test("next runs on weekdays in the task's time zone", () => {
  // Saturday 17 Oct 2026, 12:00 in Paris (UTC+2).
  expect(runs("0 7 * * 1-5", "2026-10-17T10:00:00Z", 3)).toEqual(["2026-10-19T05:00:00.000Z", "2026-10-20T05:00:00.000Z", "2026-10-21T05:00:00.000Z"]);
  expect(runs("0 7 * * sat,sun", "2026-10-17T10:00:00Z", 2)).toEqual(["2026-10-18T05:00:00.000Z", "2026-10-24T05:00:00.000Z"]);
  expect(runs("0 7 * * *", "2026-10-17T10:00:00Z", 1, "America/New_York")).toEqual(["2026-10-17T11:00:00.000Z"]);
});

test("steps and strictly-after semantics", () => {
  expect(runs("*/15 * * * *", "2026-10-17T10:00:00Z", 3)).toEqual(["2026-10-17T10:15:00.000Z", "2026-10-17T10:30:00.000Z", "2026-10-17T10:45:00.000Z"]);
  expect(runs("0 */6 * * *", "2026-10-17T10:00:00Z", 2)).toEqual(["2026-10-17T16:00:00.000Z", "2026-10-17T22:00:00.000Z"]);
});

test("day of month and day of week combine with OR like cron", () => {
  // The 1st of the month or any Monday.
  expect(runs("0 9 1 * mon", "2026-10-27T10:00:00Z", 3)).toEqual(["2026-11-01T08:00:00.000Z", "2026-11-02T08:00:00.000Z", "2026-11-09T08:00:00.000Z"]);
  expect(runs("0 0 29 2 *", "2026-10-17T10:00:00Z", 1)).toEqual(["2028-02-28T23:00:00.000Z"]);
  expect(nextRun(parseCron("0 0 31 2 *"), PARIS, Date.parse("2026-10-17T10:00:00Z"))).toBeUndefined();
});

test("DST gap: a fixed time skipped by the clock change runs right after it", () => {
  // 29 Mar 2026: 02:00 → 03:00 in Paris.
  expect(runs("30 2 * * *", "2026-03-28T10:00:00Z", 2)).toEqual(["2026-03-29T01:30:00.000Z", "2026-03-30T00:30:00.000Z"]);
  // Every-hour jobs follow the real clock: no duplicate at 03:xx.
  expect(runs("30 * * * *", "2026-03-29T00:00:00Z", 3)).toEqual(["2026-03-29T00:30:00.000Z", "2026-03-29T01:30:00.000Z", "2026-03-29T02:30:00.000Z"]);
});

test("DST overlap: a fixed time that repeats runs once", () => {
  // 25 Oct 2026: 03:00 → 02:00 in Paris.
  expect(runs("30 2 * * *", "2026-10-24T10:00:00Z", 2)).toEqual(["2026-10-25T00:30:00.000Z", "2026-10-26T01:30:00.000Z"]);
  expect(runs("30 * * * *", "2026-10-24T23:00:00Z", 3)).toEqual(["2026-10-24T23:30:00.000Z", "2026-10-25T00:30:00.000Z", "2026-10-25T01:30:00.000Z"]);
});

test("wall-clock conversion around DST", () => {
  expect(zonedInstants(2026, 3, 29, 2, 30, PARIS)).toEqual([]);
  expect(zonedInstants(2026, 10, 25, 2, 30, PARIS).map((t) => iso(t))).toEqual(["2026-10-25T00:30:00.000Z", "2026-10-25T01:30:00.000Z"]);
  expect(iso(zonedToUtc(2026, 3, 29, 2, 30, PARIS))).toBe("2026-03-29T01:30:00.000Z");
  expect(iso(zonedToUtc(2026, 10, 18, 7, 0, PARIS))).toBe("2026-10-18T05:00:00.000Z");
});
