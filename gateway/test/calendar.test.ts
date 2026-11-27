import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { computeSlots, type SlotRules } from "../src/calendar/availability";
import { GoogleCalendar, GoogleError, spawnRunner, type CommandRunner } from "../src/calendar/google";
import { calendarOptionsFromEnv, icsUidDomainFromEnv } from "../src/calendar/service";
import { pairDevice, startTestApp, type TestApp } from "./helpers";

const iso = (s: string) => new Date(s).toISOString();
const at = (s: string) => Date.parse(s);
const MON_FRI = { mon: [["09:00", "12:00"], ["14:00", "17:00"]], tue: [["09:00", "12:00"]], wed: [["09:00", "12:00"]], thu: [["09:00", "12:00"]], fri: [["09:00", "12:00"]] } as SlotRules["workingHours"];
const rules = (over: Partial<SlotRules> = {}): SlotRules => ({
  durationMin: 30,
  bufferBeforeMin: 0,
  bufferAfterMin: 0,
  minNoticeMin: 0,
  maxDaysAhead: 60,
  workingHours: MON_FRI,
  ...over,
});
const starts = (slots: { start: number }[]) => slots.map((s) => new Date(s.start).toISOString());

describe("availability", () => {
  const now = at("2026-10-18T12:00:00Z"); // Sunday

  test("working hours become slots in Paris time", () => {
    const s = computeSlots(rules(), { from: at("2026-10-19T00:00:00Z"), to: at("2026-10-20T00:00:00Z"), now, busy: [] });
    expect(starts(s)).toHaveLength(12);
    expect(starts(s)[0]).toBe(iso("2026-10-19T07:00:00Z"));
    expect(starts(s)[5]).toBe(iso("2026-10-19T09:30:00Z"));
    expect(starts(s)[6]).toBe(iso("2026-10-19T12:00:00Z"));
  });

  test("DST: 09:00 Paris is 07:00Z before the October change and 08:00Z after", () => {
    const s = computeSlots(rules({ workingHours: { fri: [["09:00", "09:30"]], mon: [["09:00", "09:30"]] } }), { from: at("2026-10-23T00:00:00Z"), to: at("2026-10-27T00:00:00Z"), now, busy: [] });
    expect(starts(s)).toEqual([iso("2026-10-23T07:00:00Z"), iso("2026-10-26T08:00:00Z")]);
  });

  test("DST: times skipped in March move forward and are not duplicated", () => {
    const s = computeSlots(rules({ workingHours: { sun: [["02:00", "04:00"]] } }), { from: at("2026-03-29T00:00:00Z"), to: at("2026-03-30T00:00:00Z"), now: at("2026-03-01T00:00:00Z"), busy: [] });
    expect(starts(s)).toEqual([iso("2026-03-29T01:00:00Z"), iso("2026-03-29T01:30:00Z")]);
  });

  test("buffers keep a margin around busy time", () => {
    const busy = [{ start: at("2026-10-19T08:00:00Z"), end: at("2026-10-19T09:00:00Z") }]; // 10:00-11:00 Paris
    const s = starts(computeSlots(rules({ bufferBeforeMin: 15, bufferAfterMin: 15 }), { from: at("2026-10-19T07:00:00Z"), to: at("2026-10-19T10:00:00Z"), now, busy }));
    expect(s).toEqual([iso("2026-10-19T07:00:00Z"), iso("2026-10-19T09:30:00Z")]);
  });

  test("minimum notice and max days ahead", () => {
    const n = at("2026-10-19T07:10:00Z"); // 09:10 Paris
    const s = starts(computeSlots(rules({ minNoticeMin: 60, maxDaysAhead: 1 }), { from: at("2026-10-19T00:00:00Z"), to: at("2026-10-25T00:00:00Z"), now: n, busy: [] }));
    expect(s[0]).toBe(iso("2026-10-19T08:30:00Z"));
    expect(s.every((x) => Date.parse(x) < n + 86_400_000)).toBe(true);
    expect(s.some((x) => x.startsWith("2026-10-20T07:00"))).toBe(true);
    expect(s.some((x) => x.startsWith("2026-10-20T07:30"))).toBe(false);
  });

  test("overlapping busy intervals are merged", () => {
    const busy = [
      { start: at("2026-10-20T07:00:00Z"), end: at("2026-10-20T08:00:00Z") },
      { start: at("2026-10-20T07:30:00Z"), end: at("2026-10-20T09:00:00Z") },
      { start: at("2026-10-20T08:45:00Z"), end: at("2026-10-20T09:15:00Z") },
    ];
    const s = starts(computeSlots(rules(), { from: at("2026-10-20T00:00:00Z"), to: at("2026-10-21T00:00:00Z"), now, busy }));
    expect(s).toEqual([iso("2026-10-20T09:30:00Z")]);
  });

  test("max per day closes a day that is full", () => {
    const q = { from: at("2026-10-20T00:00:00Z"), to: at("2026-10-22T00:00:00Z"), now, busy: [], booked: [at("2026-10-20T07:00:00Z")] };
    const s = starts(computeSlots(rules({ maxPerDay: 1 }), q));
    expect(s.some((x) => x.startsWith("2026-10-20"))).toBe(false);
    expect(s.some((x) => x.startsWith("2026-10-21"))).toBe(true);
  });

  test("proposals only offer their free candidates", () => {
    const candidateSlots = [
      { start: at("2026-10-20T07:00:00Z"), end: at("2026-10-20T07:30:00Z") },
      { start: at("2026-10-21T07:00:00Z"), end: at("2026-10-21T07:30:00Z") },
    ];
    const busy = [{ start: at("2026-10-21T07:00:00Z"), end: at("2026-10-21T08:00:00Z") }];
    const s = starts(computeSlots(rules({ candidateSlots, workingHours: {} }), { from: at("2026-10-19T00:00:00Z"), to: at("2026-10-30T00:00:00Z"), now, busy }));
    expect(s).toEqual([iso("2026-10-20T07:00:00Z")]);
  });
});

// ---- gateway ---------------------------------------------------------------------------------

const NOW = at("2026-10-19T06:00:00Z"); // Monday 08:00 Paris

interface GogCall {
  args: string[];
}

function fakeGog(o: { delayMs?: number; failCreate?: boolean; busy?: { start: string; end: string }[] } = {}) {
  const calls: GogCall[] = [];
  let n = 0;
  const run: CommandRunner = async (args) => {
    calls.push({ args });
    if (o.delayMs) await Bun.sleep(o.delayMs);
    const sub = args[1];
    if (sub === "create") {
      if (o.failCreate) return { code: 1, stdout: "", stderr: "boom" };
      return { code: 0, stdout: JSON.stringify({ event: { id: `g${++n}`, htmlLink: "https://calendar.google.com/x", hangoutLink: "https://meet.google.com/abc-defg-hij" } }), stderr: "" };
    }
    if (sub === "freebusy") return { code: 0, stdout: JSON.stringify({ calendars: { primary: { busy: o.busy ?? [] } } }), stderr: "" };
    if (sub === "update" && args.includes("--help")) return { code: 0, stdout: "--send-updates=STRING", stderr: "" };
    return { code: 0, stdout: JSON.stringify({ event: { id: args[3] }, deleted: true }), stderr: "" };
  };
  return { calls, run };
}

let t: TestApp | undefined;
afterEach(async () => {
  await t?.close();
  t = undefined;
});

const RDV = "rdv.test";

async function pub(app: TestApp, method: string, path: string, body?: unknown, headers: Record<string, string> = {}) {
  const res = await fetch(app.base + path, {
    method,
    headers: { host: RDV, ...(body !== undefined ? { "content-type": "application/json" } : {}), ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let data: any = text;
  try {
    data = JSON.parse(text);
  } catch {}
  return { status: res.status, data, headers: res.headers };
}

const bookingType = {
  slug: "rdv-30",
  title: "Rendez-vous 30 min",
  durationMin: 30,
  location: { kind: "google_meet" },
  workingHours: { mon: [["09:00", "12:00"]], tue: [["09:00", "12:00"]] },
  minNoticeMin: 60,
  questions: [{ id: "phone", label: "Téléphone", type: "phone", required: false }],
};

async function bookingApp(extra: Parameters<typeof startTestApp>[0] = {}, gog = fakeGog()) {
  const app = await startTestApp({
    ...extra,
    calendar: { bookingHosts: new Set([RDV]), googleCalendar: "me@example.com", gogRunner: gog.run, clock: () => NOW, ...extra.calendar },
  });
  const r = await app.api("POST", "/api/booking/types", bookingType);
  expect(r.status).toBe(201);
  return { app, gog, type: r.data };
}

const invitee = (start: string, over: Record<string, unknown> = {}) => ({ start, name: "Jean Dupont", email: "jean@example.com", notes: "Projet", website: "", turnstileToken: "", ...over });

describe("calendar bridge", () => {
  const source = (title = "Travail", account = "me@example.com") => ({ calendars: [{ id: "EK-1", title, color: "#1badf8", account, type: "caldav", allowsModifications: true }] });
  const ev = (id: string, start: string, over: Record<string, unknown> = {}) => ({
    externalId: id,
    title: "Déjeuner secret",
    location: "Café",
    notes: "Lien https://meet.google.com/abc-defg-hij",
    start,
    end: new Date(Date.parse(start) + 3_600_000).toISOString(),
    availability: "busy",
    attendees: [{ name: "Sami", email: "sami@example.com", status: "accepted" }],
    ...over,
  });
  const window = { from: "2026-09-19T00:00:00Z", to: "2027-04-17T00:00:00Z" };

  test("sources, idempotent sync and stale removal", async () => {
    t = await startTestApp({ calendar: { gogRunner: null, clock: () => NOW } });
    const s = await t.api("PUT", "/api/calendar/sources", source());
    expect(s.status).toBe(200);
    const cal = s.data.calendars[0];
    expect(cal).toMatchObject({ title: "Travail", color: "#1BADF8", enabled: true, privacy: "full", countsForAvailability: true });
    const batch = { syncId: "s1", calendars: [{ calendarId: "EK-1", window, events: [ev("a", "2026-10-20T10:00:00Z"), ev("b", "2026-10-21T10:00:00Z")], complete: true }] };
    expect((await t.api("POST", "/api/calendar/sync", batch)).data).toEqual({ upserted: 2, deleted: 0, removedStale: 0 });
    await t.api("POST", "/api/calendar/sync", batch);
    let events = await t.api("GET", "/api/calendar/events?from=2026-10-19&to=2026-10-25");
    expect(events.data.items.filter((i: any) => i.kind === "event")).toHaveLength(2);
    expect(events.data.items[0]).toMatchObject({ title: "Déjeuner secret", conferenceUrl: "https://meet.google.com/abc-defg-hij", busyOnly: false, attendeesCount: 1 });

    const next = { syncId: "s2", calendars: [{ calendarId: "EK-1", window, events: [ev("a", "2026-10-20T10:00:00Z")], complete: true }] };
    expect((await t.api("POST", "/api/calendar/sync", next)).data.removedStale).toBe(1);
    events = await t.api("GET", "/api/calendar/events?from=2026-10-19&to=2026-10-25&reminders=0");
    expect(events.data.items.map((i: any) => i.externalId)).toEqual(["a"]);

    const one = await t.api("POST", "/api/calendar/sync/events", { calendarId: "EK-1", event: ev("c", "2026-10-22T10:00:00Z", { title: "Nouveau" }) });
    expect(one.data.event).toMatchObject({ title: "Nouveau", kind: "event" });
    expect((await t.api("POST", "/api/calendar/sync/events", { calendarId: "EK-1", deleted: ["c"] })).data).toEqual({ deleted: 1 });
    expect((await t.api("POST", "/api/calendar/sync", { calendars: [{ calendarId: "nope", events: [] }] })).status).toBe(400);
  });

  test("busy-only calendars never store details", async () => {
    t = await startTestApp({ calendar: { gogRunner: null, clock: () => NOW } });
    const cal = (await t.api("PUT", "/api/calendar/sources", source())).data.calendars[0];
    await t.api("POST", "/api/calendar/sync", { syncId: "s1", calendars: [{ calendarId: "EK-1", window, events: [ev("a", "2026-10-20T10:00:00Z")], complete: true }] });
    const p = await t.api("PATCH", `/api/calendar/calendars/${cal.id}`, { privacy: "busy" });
    expect(p.data.privacy).toBe("busy");
    const raw = () => t!.app.data.db.query("SELECT title, location, notes, attendees_json, conference_url FROM calendar_events").all();
    expect(raw()).toEqual([{ title: null, location: null, notes: null, attendees_json: null, conference_url: null }]);

    await t.api("POST", "/api/calendar/sync", { syncId: "s2", calendars: [{ calendarId: "EK-1", window, events: [ev("a", "2026-10-20T10:00:00Z"), ev("b", "2026-10-21T10:00:00Z")], complete: true }] });
    await t.api("POST", "/api/calendar/sync/events", { calendarId: "EK-1", event: ev("c", "2026-10-22T10:00:00Z") });
    expect(raw().every((r: any) => r.title === null && r.notes === null && r.location === null && r.attendees_json === null)).toBe(true);
    const items = (await t.api("GET", "/api/calendar/events?from=2026-10-19&to=2026-10-25&reminders=0")).data.items;
    expect(items).toHaveLength(3);
    for (const i of items) {
      expect(i.title).toBeNull();
      expect(i.busyOnly).toBe(true);
      expect(i.notes).toBeUndefined();
      expect(i.attendees).toBeUndefined();
    }
    const agenda = t.app.data.db.query("SELECT title, busy_only FROM v_agenda WHERE kind = 'event'").all() as any[];
    expect(agenda.every((r) => r.title === "Occupé" && r.busy_only === 1)).toBe(true);

    expect((await t.api("PATCH", `/api/calendar/calendars/${cal.id}`, { privacy: "full" })).data.needsResync).toBe(true);
  });

  test("two devices bridging the same calendar: one copy, the latest complete sync", async () => {
    let now = NOW;
    t = await startTestApp({ calendar: { gogRunner: null, clock: () => now } });
    const mac = await pairDevice({ base: t.base, api: (m, p, b, tok) => t!.api(m, p, b, tok), store: t.app.store, totpSecret: t.totpSecret, now: Date.now(), name: "Mac" });
    await t.api("PUT", "/api/calendar/sources", source());
    await t.api("PUT", "/api/calendar/sources", { calendars: [{ id: "MAC-ID", title: "Travail", account: "ME@example.com" }] }, mac.accessToken);
    const cals = (await t.api("GET", "/api/calendar/calendars")).data;
    expect(cals).toHaveLength(1);
    expect(cals[0].sources).toHaveLength(2);

    await t.api("POST", "/api/calendar/sync", { syncId: "p", calendars: [{ calendarId: "EK-1", window, events: [ev("x", "2026-10-20T10:00:00Z", { title: "Version iPhone" })], complete: true }] });
    now += 60_000;
    await t.api("POST", "/api/calendar/sync", { syncId: "m", calendars: [{ calendarId: "MAC-ID", window, events: [ev("x", "2026-10-20T10:00:00Z", { title: "Version Mac" })], complete: true }] }, mac.accessToken);
    const items = (await t.api("GET", "/api/calendar/events?from=2026-10-19&to=2026-10-25&reminders=0")).data.items;
    expect(items.map((i: any) => i.title)).toEqual(["Version Mac"]);
  });

  test("alarms are stored, busy-only calendars keep only their times", async () => {
    t = await startTestApp({ calendar: { gogRunner: null, clock: () => NOW } });
    const cals = (await t.api("PUT", "/api/calendar/sources", { calendars: [{ id: "EK-1", title: "Travail", account: "me@example.com" }, { id: "EK-2", title: "Client", account: "me@example.com" }] })).data.calendars;
    const client = cals.find((c: any) => c.title === "Client");
    await t.api("PATCH", `/api/calendar/calendars/${client.id}`, { privacy: "busy" });
    const alarms = [{ offsetSec: -900 }, { at: "2026-10-20T08:00:00+02:00" }];
    await t.api("POST", "/api/calendar/sync", {
      syncId: "s",
      calendars: [
        { calendarId: "EK-1", window, events: [ev("a", "2026-10-20T10:00:00Z", { alarms }), ev("legacy", "2026-10-21T10:00:00Z", { hasAlarms: true }), ev("none", "2026-10-22T10:00:00Z")], complete: true },
        { calendarId: "EK-2", window, events: [ev("b", "2026-10-20T12:00:00Z", { alarms: [{ offsetSec: -600 }] })], complete: true },
      ],
    });
    const items = (await t.api("GET", "/api/calendar/events?from=2026-10-19&to=2026-10-25&reminders=0")).data.items;
    const byId = Object.fromEntries(items.map((i: any) => [i.externalId, i]));
    expect(byId.a).toMatchObject({ hasAlarms: true, alarms: [{ offsetSec: -900 }, { at: "2026-10-20T06:00:00.000Z" }] });
    expect(byId.legacy.hasAlarms).toBe(true);
    expect(byId.legacy.alarms).toBeUndefined();
    expect(byId.none).toMatchObject({ hasAlarms: false });
    expect(byId.b).toMatchObject({ title: null, busyOnly: true, hasAlarms: true, alarms: [{ offsetSec: -600 }] });
    expect(byId.b.location).toBeUndefined();

    const one = await t.api("POST", "/api/calendar/sync/events", { calendarId: "EK-1", event: ev("a", "2026-10-20T10:00:00Z", { alarms: [] }) });
    expect(one.data.event).toMatchObject({ hasAlarms: false, alarms: [] });
    for (const bad of [[{ offsetSec: 1.5 }], [{ at: "demain" }], "x", Array.from({ length: 21 }, () => ({ offsetSec: 0 }))]) {
      expect((await t.api("POST", "/api/calendar/sync/events", { calendarId: "EK-1", event: ev("a", "2026-10-20T10:00:00Z", { alarms: bad }) })).status).toBe(400);
    }
  });

  test("travel times computed by the apps survive syncs and device changes", async () => {
    let now = NOW;
    t = await startTestApp({ calendar: { gogRunner: null, clock: () => now } });
    const cal = (await t.api("PUT", "/api/calendar/sources", source())).data.calendars[0];
    const sync = (syncId: string, events: unknown[], token?: string, calendarId = "EK-1") =>
      t!.api("POST", "/api/calendar/sync", { syncId, calendars: [{ calendarId, window, events, complete: true }] }, token);
    await sync("s1", [ev("a", "2026-10-20T10:00:00Z"), ev("b", "2026-10-21T10:00:00Z", { travelTimeSec: 600 })]);
    const list = async () => Object.fromEntries((await t!.api("GET", "/api/calendar/events?from=2026-10-19&to=2026-10-25&reminders=0")).data.items.map((i: any) => [i.externalId, i]));
    let items = await list();

    const put = await t.api("PUT", `/api/calendar/events/${items.a.id}/travel`, { travelTimeSec: 1500, mode: "driving" });
    expect(put.status).toBe(200);
    expect(put.data.event).toMatchObject({ externalId: "a", travelTimeSec: 1500, travelMode: "driving" });
    await t.api("PUT", `/api/calendar/events/${items.b.id}/travel`, { travelTimeSec: 900, mode: "transit" });

    await sync("s2", [ev("a", "2026-10-20T10:00:00Z", { title: "Renommé" }), ev("b", "2026-10-21T10:00:00Z", { travelTimeSec: 600 })]);
    items = await list();
    expect(items.a).toMatchObject({ title: "Renommé", travelTimeSec: 1500, travelMode: "driving" });
    expect(items.b.travelTimeSec).toBe(600);
    expect(items.b.travelMode).toBeUndefined();

    const mac = await pairDevice({ base: t.base, api: (m, p, b, tok) => t!.api(m, p, b, tok), store: t.app.store, totpSecret: t.totpSecret, now: Date.now(), name: "Mac" });
    await t.api("PUT", "/api/calendar/sources", { calendars: [{ id: "MAC-ID", title: "Travail", account: "me@example.com" }] }, mac.accessToken);
    now += 60_000;
    await sync("m", [ev("a", "2026-10-20T10:00:00Z")], mac.accessToken, "MAC-ID");
    items = await list();
    expect(items.a).toMatchObject({ travelTimeSec: 1500 });

    expect((await t.api("PUT", `/api/calendar/events/${items.a.id}/travel`, { travelTimeSec: -1 })).status).toBe(400);
    expect((await t.api("PUT", `/api/calendar/events/${items.a.id}/travel`, { travelTimeSec: 60, mode: "teleport" })).status).toBe(400);
    expect((await t.api("PUT", "/api/calendar/events/nope/travel", { travelTimeSec: 60 })).status).toBe(404);
    const cleared = await t.api("PUT", `/api/calendar/events/${items.a.id}/travel`, { travelTimeSec: null });
    expect(cleared.data.event.travelTimeSec).toBeUndefined();

    await t.api("PUT", `/api/calendar/events/${items.a.id}/travel`, { travelTimeSec: 300 });
    await t.api("PATCH", `/api/calendar/calendars/${cal.id}`, { privacy: "busy" });
    expect(t.app.data.db.query("SELECT count(*) AS n FROM calendar_event_travel").get()).toEqual({ n: 0 });
    expect((await t.api("PUT", `/api/calendar/events/${items.a.id}/travel`, { travelTimeSec: 60 })).status).toBe(400);
  });

  test("reminders with a due date are part of the agenda", async () => {
    t = await startTestApp({ calendar: { gogRunner: null, clock: () => NOW } });
    await t.api("POST", "/api/reminders", { title: "Payer l'URSSAF", dueAt: "2026-10-21T07:00:00Z" });
    const items = (await t.api("GET", "/api/calendar/events?from=2026-10-19&to=2026-10-25")).data.items;
    expect(items).toEqual([expect.objectContaining({ kind: "reminder", title: "Payer l'URSSAF", start: "2026-10-21T07:00:00.000Z", done: false })]);
  });

  test("busy events block booking slots, free ones and other calendars do not", async () => {
    const { app } = await bookingApp();
    t = app;
    const cals = (await t.api("PUT", "/api/calendar/sources", { calendars: [{ id: "EK-1", title: "Travail", account: "me@example.com" }, { id: "EK-2", title: "Anniversaires", account: "me@example.com" }] })).data.calendars;
    const other = cals.find((c: any) => c.title === "Anniversaires");
    await t.api("PATCH", `/api/calendar/calendars/${other.id}`, { countsForAvailability: false });
    await t.api("POST", "/api/calendar/sync", {
      syncId: "s",
      calendars: [
        { calendarId: "EK-1", window, events: [ev("busy", "2026-10-20T07:00:00Z"), ev("free", "2026-10-20T09:00:00Z", { availability: "free" })], complete: true },
        { calendarId: "EK-2", window, events: [ev("bday", "2026-10-20T08:00:00Z")], complete: true },
      ],
    });
    const slots = (await pub(t, "GET", "/api/public/booking/rdv-30/slots?from=2026-10-20&to=2026-10-20&tz=Europe/Paris")).data.slots.map((s: any) => s.start);
    expect(slots).not.toContain("2026-10-20T07:00:00.000Z");
    expect(slots).not.toContain("2026-10-20T07:30:00.000Z");
    expect(slots).toContain("2026-10-20T08:00:00.000Z");
    expect(slots).toContain("2026-10-20T09:00:00.000Z");
    const body = JSON.stringify((await pub(t, "GET", "/api/public/booking/rdv-30/slots?from=2026-10-20&to=2026-10-20")).data);
    expect(body).not.toContain("Déjeuner");
    expect(body).not.toContain("Travail");
  });
});

describe("public booking host", () => {
  test("only public routes are served on the booking host, and never on the app host", async () => {
    const { app } = await bookingApp();
    t = app;
    expect((await pub(t, "GET", "/api/bots", undefined, { authorization: `Bearer ${t.token}` })).status).toBe(404);
    expect((await pub(t, "GET", "/api/health")).status).toBe(404);
    expect((await pub(t, "POST", "/api/pair", {})).status).toBe(404);
    expect((await pub(t, "GET", "/api/booking/types", undefined, { authorization: `Bearer ${t.token}` })).status).toBe(404);
    expect((await pub(t, "GET", "/")).status).toBe(404);
    expect((await pub(t, "GET", "/nope")).status).toBe(404);

    const page = await pub(t, "GET", "/rdv-30");
    expect(page.status).toBe(200);
    expect(page.headers.get("content-type")).toContain("text/html");
    expect(page.headers.get("content-security-policy")).toContain("default-src 'none'");
    expect(page.headers.get("content-security-policy")).not.toContain("unsafe-inline");
    expect(page.data).toContain("Rendez-vous 30 min");
    expect((await pub(t, "GET", "/assets/booking.js")).status).toBe(200);

    const onApp = await fetch(`${t.base}/rdv-30`, { headers: { authorization: `Bearer ${t.token}` } });
    expect(onApp.status).toBe(404);
    expect(await onApp.text()).not.toContain("<html");
    expect((await t.api("GET", "/api/public/booking/rdv-30/slots?from=2026-10-20&to=2026-10-20")).status).toBe(404);
  });

  test("double booking the same slot: one wins, the other gets 409", async () => {
    const gog = fakeGog({ delayMs: 30 });
    const { app } = await bookingApp({}, gog);
    t = app;
    const start = "2026-10-20T08:00:00.000Z";
    const [a, b] = await Promise.all([pub(t, "POST", "/api/public/booking/rdv-30", invitee(start)), pub(t, "POST", "/api/public/booking/rdv-30", invitee(start, { email: "other@example.com" }))]);
    expect([a.status, b.status].sort()).toEqual([201, 409]);
    expect(gog.calls.filter((c) => c.args[1] === "create")).toHaveLength(1);
    const rows = t.app.data.db.query("SELECT status FROM bookings").all() as any[];
    expect(rows).toEqual([{ status: "confirmed" }]);
    const slots = (await pub(t, "GET", "/api/public/booking/rdv-30/slots?from=2026-10-20&to=2026-10-20")).data.slots.map((s: any) => s.start);
    expect(slots).not.toContain(start);
  });

  test("a booking creates the Google event, notifies the owner and can be cancelled or moved", async () => {
    const { app, gog } = await bookingApp();
    t = app;
    const r = await pub(t, "POST", "/api/public/booking/rdv-30", invitee("2026-10-20T08:00:00Z", { answers: { phone: "+33 6 12 34 56 78" } }));
    expect(r.status).toBe(201);
    expect(r.data.booking).toMatchObject({ start: "2026-10-20T08:00:00.000Z", status: "confirmed", meetUrl: "https://meet.google.com/abc-defg-hij" });
    const create = gog.calls.find((c) => c.args[1] === "create")!.args;
    expect(create).toContain("--account=me@example.com");
    expect(create).toContain("--attendees=jean@example.com");
    expect(create).toContain("--with-meet");
    expect(create).toContain("--send-updates=all");
    expect(create.find((a) => a.startsWith("--description="))).toContain("Téléphone : +33 6 12 34 56 78");
    const push = t.pusher.sent.find((p) => p.payload.title === "📅 Nouveau rendez-vous")!;
    expect(push.payload).toMatchObject({ category: "nuo.booking" });
    expect(push.payload.bookingId).toBeString();
    expect(push.payload.destination).toEqual({ kind: "booking", id: push.payload.bookingId! });

    const token = r.data.manageUrl.split("/m/")[1];
    expect((await pub(t, "GET", `/m/${token}`)).status).toBe(200);
    const ics = await pub(t, "GET", `/m/${token}/event.ics`);
    expect(ics.headers.get("content-type")).toContain("text/calendar");
    expect(ics.data).toContain("DTSTART:20261020T080000Z");
    expect(ics.data).toMatch(/^UID:[^@\r\n]+@nuo\r?$/m);

    const moved = await pub(t, "POST", `/m/${token}`, { action: "reschedule", start: "2026-10-20T09:00:00Z", turnstileToken: "" });
    expect(moved.status).toBe(200);
    expect(moved.data.booking.start).toBe("2026-10-20T09:00:00.000Z");
    const update = gog.calls.find((c) => c.args[1] === "update" && !c.args.includes("--help"))!.args;
    expect(update).toContain("--from=2026-10-20T09:00:00.000Z");
    expect(update).toContain("--send-updates=all");
    expect((await t.api("GET", "/api/booking/bookings?status=rescheduled,confirmed&from=2026-10-01T00:00:00Z")).data.map((b: any) => b.status).sort()).toEqual(["confirmed", "rescheduled"]);

    const cancelled = await pub(t, "POST", `/m/${token}`, { action: "cancel", reason: "Empêchement" });
    expect(cancelled.data.booking.status).toBe("cancelled");
    expect(gog.calls.some((c) => c.args[1] === "delete")).toBe(true);
    expect((await t.app.data.db.query("SELECT count(*) AS n FROM bookings").get()) as any).toEqual({ n: 2 });
    expect(() => t!.app.data.db.exec("DELETE FROM bookings")).toThrow();
  });

  test("an install renamed since its first invitations keeps their UID, so a guest's calendar updates them", async () => {
    const { app } = await bookingApp({ calendar: { icsUidDomain: "halo" } });
    t = app;
    const r = await pub(t, "POST", "/api/public/booking/rdv-30", invitee("2026-10-20T08:00:00Z"));
    expect(r.status).toBe(201);
    const token = r.data.manageUrl.split("/m/")[1];
    const first = (await pub(t, "GET", `/m/${token}/event.ics`)).data as string;
    expect(first).toMatch(/^UID:[^@\r\n]+@halo\r?$/m);
    expect((await pub(t, "POST", `/m/${token}`, { action: "reschedule", start: "2026-10-20T09:00:00Z", turnstileToken: "" })).status).toBe(200);
    const moved = (await pub(t, "GET", `/m/${token}/event.ics`)).data as string;
    const uid = (ics: string) => /^UID:(.+?)\r?$/m.exec(ics)?.[1];
    expect(uid(moved)).toBe(uid(first));

    expect(icsUidDomainFromEnv({})).toBeUndefined();
    expect(icsUidDomainFromEnv({ NUO_BOOKING_UID_DOMAIN: " halo " })).toBe("halo");
    expect(calendarOptionsFromEnv({ NUO_BOOKING_UID_DOMAIN: "rdv.lumen-studio.fr" }).icsUidDomain).toBe("rdv.lumen-studio.fr");
    for (const bad of ["halo\nX-INJECTED:1", "halo@lumen", "-halo", "x".repeat(64)]) expect(() => icsUidDomainFromEnv({ NUO_BOOKING_UID_DOMAIN: bad })).toThrow();
  });

  test("validation, honeypot and Google failure", async () => {
    const { app } = await bookingApp({}, fakeGog({ failCreate: true }));
    t = app;
    expect((await pub(t, "POST", "/api/public/booking/rdv-30", invitee("2026-10-20T08:00:00Z", { email: "nope" }))).status).toBe(400);
    expect((await pub(t, "POST", "/api/public/booking/rdv-30", invitee("2026-10-20T08:10:00Z"))).status).toBe(409);
    expect((await pub(t, "POST", "/api/public/booking/rdv-30", invitee("2026-10-20T08:00:00Z", { answers: { evil: "x" } }))).status).toBe(400);
    const trap = await pub(t, "POST", "/api/public/booking/rdv-30", invitee("2026-10-20T08:00:00Z", { website: "http://spam" }));
    expect(trap.status).toBe(201);
    expect(t.app.data.db.query("SELECT count(*) AS n FROM bookings").get()).toEqual({ n: 0 });
    const failed = await pub(t, "POST", "/api/public/booking/rdv-30", invitee("2026-10-20T08:00:00Z"));
    expect(failed.status).toBe(502);
    expect(t.app.data.db.query("SELECT status FROM bookings").all()).toEqual([{ status: "failed" }]);
    const slots = (await pub(t, "GET", "/api/public/booking/rdv-30/slots?from=2026-10-20&to=2026-10-20")).data.slots.map((s: any) => s.start);
    expect(slots).toContain("2026-10-20T08:00:00.000Z");
  });

  test("Google free/busy catches events the bridge has not synced yet", async () => {
    const { app } = await bookingApp({}, fakeGog({ busy: [{ start: "2026-10-20T08:00:00Z", end: "2026-10-20T09:00:00Z" }] }));
    t = app;
    expect((await pub(t, "POST", "/api/public/booking/rdv-30", invitee("2026-10-20T08:00:00Z"))).status).toBe(409);
  });

  test("Turnstile enabled: the token is verified with Cloudflare", async () => {
    const verified: string[] = [];
    const fakeFetch = (async (_url: string, init: RequestInit) => {
      const p = new URLSearchParams(String(init.body));
      verified.push(`${p.get("secret")}|${p.get("response")}`);
      return Response.json({ success: p.get("response") === "good" });
    }) as unknown as typeof fetch;
    const { app } = await bookingApp({ calendar: { turnstileSiteKey: "site", turnstileSecret: "sec", fetch: fakeFetch } });
    t = app;
    expect((await pub(t, "GET", "/rdv-30")).data).toContain("challenges.cloudflare.com/turnstile");
    expect((await pub(t, "POST", "/api/public/booking/rdv-30", invitee("2026-10-20T08:00:00Z", { turnstileToken: "bad" }))).status).toBe(403);
    expect((await pub(t, "POST", "/api/public/booking/rdv-30", invitee("2026-10-20T08:00:00Z"))).status).toBe(403);
    expect((await pub(t, "POST", "/api/public/booking/rdv-30", invitee("2026-10-20T08:00:00Z", { turnstileToken: "good" }))).status).toBe(201);
    expect(verified).toEqual(["sec|bad", "sec|good"]);
  });

  test("Turnstile disabled: the page has no widget and bookings go through", async () => {
    const { app } = await bookingApp();
    t = app;
    expect((await pub(t, "GET", "/rdv-30")).data).not.toContain("challenges.cloudflare.com/turnstile/v0/api.js");
    expect((await pub(t, "POST", "/api/public/booking/rdv-30", invitee("2026-10-20T08:00:00Z"))).status).toBe(201);
  });

  test("proposals close after their first booking", async () => {
    const { app } = await bookingApp();
    t = app;
    const p = await t.api("POST", "/api/booking/types", { slug: "sami", kind: "proposal", title: "Café avec Sami", durationMin: 60, location: { kind: "address", value: "Café Lomi" }, candidateSlots: [{ start: "2026-10-21T08:00:00Z" }, { start: "2026-10-22T08:00:00Z" }] });
    expect(p.status).toBe(201);
    const slots = (await pub(t, "GET", "/api/public/booking/sami/slots?from=2026-10-19&to=2026-10-30")).data.slots;
    expect(slots).toHaveLength(2);
    expect((await pub(t, "POST", "/api/public/booking/sami", invitee("2026-10-22T08:00:00Z"))).status).toBe(201);
    expect((await pub(t, "GET", "/sami")).status).toBe(404);
    expect((await t.api("GET", `/api/booking/types/${p.data.id}`)).data.active).toBe(false);
  });

  test("the legal pages Google needs are served with the contact address", async () => {
    const { app } = await bookingApp({ calendar: { ownerName: "Alex Morgan", contactEmail: "alex@example.com" } });
    t = app;
    const privacy = await pub(t, "GET", "/privacy");
    expect(privacy.status).toBe(200);
    expect(privacy.headers.get("content-type")).toContain("text/html");
    expect(privacy.data).toContain("Politique de confidentialité");
    expect(privacy.data).toContain("Alex Morgan");
    expect(privacy.data).toContain("mailto:alex@example.com");
    expect(privacy.data).toContain("api-services-user-data-policy");
    expect(privacy.data).toContain('href="/terms"');

    const terms = await pub(t, "GET", "/terms");
    expect(terms.status).toBe(200);
    expect(terms.data).toContain("Conditions d&#39;utilisation");
    expect(terms.data).toContain('href="/privacy"');
  });

  test("a booking type named privacy does not shadow the legal page", async () => {
    const { app } = await bookingApp({ calendar: { contactEmail: "alex@example.com" } });
    t = app;
    expect((await t.api("POST", "/api/booking/types", { ...bookingType, slug: "privacy", title: "Point confidentialité" })).status).toBe(201);
    const res = await pub(t, "GET", "/privacy");
    expect(res.data).toContain("Politique de confidentialité");
    expect(res.data).not.toContain("Point confidentialité");
  });

  test("without a contact address the legal pages carry no mailto", async () => {
    const { app } = await bookingApp();
    t = app;
    const privacy = await pub(t, "GET", "/privacy");
    expect(privacy.status).toBe(200);
    expect(privacy.data).not.toContain("mailto:");
  });
});

describe("gog wrapper", () => {
  let dir: string;
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  function fakeBinary(helpHasSendUpdates: boolean) {
    dir = mkdtempSync(join(tmpdir(), "nuo-gog-"));
    const log = join(dir, "args.log");
    const bin = join(dir, "gog");
    writeFileSync(
      bin,
      `#!/bin/sh
printf '%s\\n' "$@" >> "${log}"
printf '%s\\n' "---" >> "${log}"
case "$2" in
  create) echo '{"event":{"id":"evt1","htmlLink":"https://g/x","conferenceData":{"entryPoints":[{"entryPointType":"video","uri":"https://meet.google.com/aaa-bbbb-ccc"}]}}}' ;;
  update) case "$*" in *--help*) ${helpHasSendUpdates ? 'echo "      --send-updates=STRING"' : 'echo "      --summary=STRING"'} ;; *) echo '{"event":{"id":"evt1"}}' ;; esac ;;
  delete) echo '{"deleted":true}' ;;
  freebusy) echo '{"calendars":{"team@example.com":{"busy":[{"start":"2026-10-20T08:00:00Z","end":"2026-10-20T09:00:00Z"}]}}}' ;;
  calendars) echo '{"calendars":[{"id":"me@example.com","summary":"Moi","primary":true,"accessRole":"owner"},{"id":"abc@group.calendar.google.com","summary":"Rdv"}]}' ;;
  *) echo "unknown" >&2; exit 3 ;;
esac
`,
    );
    chmodSync(bin, 0o755);
    const calls = () =>
      readFileSync(log, "utf8")
        .split("---\n")
        .filter((c) => c.trim())
        .map((c) => c.trimEnd().split("\n"));
    return { google: new GoogleCalendar(spawnRunner(bin)), calls };
  }

  test("create, update, delete, free/busy and calendars", async () => {
    const { google, calls } = fakeBinary(false);
    const target = { account: "me@example.com", calendarId: "primary" };
    const ev = await google.createEvent(target, { title: "--danger; rm -rf /", start: "2026-10-20T08:00:00Z", end: "2026-10-20T09:00:00Z", attendees: ["a@b.co"], meet: true });
    expect(ev).toEqual({ id: "evt1", htmlLink: "https://g/x", meetUrl: "https://meet.google.com/aaa-bbbb-ccc" });
    const c = calls()[0]!;
    expect(c.slice(0, 3)).toEqual(["calendar", "create", "primary"]);
    expect(c).toContain("--summary=--danger; rm -rf /");
    expect(c).toContain("--account=me@example.com");
    expect(c).toContain("--json");

    await google.updateEvent(target, "evt1", { start: "2026-10-21T08:00:00Z" });
    await google.deleteEvent(target, "evt1");
    const edits = calls().filter((x) => x[1] === "update" || x[1] === "delete");
    expect(edits.filter((x) => !x.includes("--help")).every((x) => !x.includes("--send-updates=all"))).toBe(true);
    expect(calls().filter((x) => x.includes("--help"))).toHaveLength(1);

    const busy = await google.freeBusy({ account: "me@example.com", calendarId: "team@example.com" }, at("2026-10-20T00:00:00Z"), at("2026-10-21T00:00:00Z"));
    expect(busy).toEqual([{ start: at("2026-10-20T08:00:00Z"), end: at("2026-10-20T09:00:00Z") }]);

    const cals = await google.calendars("me@example.com");
    expect(cals.map((x) => x.target)).toEqual(["me@example.com/primary", "me@example.com/abc@group.calendar.google.com"]);
  });

  test("newer gog: edits notify attendees; failures raise GoogleError", async () => {
    const { google, calls } = fakeBinary(true);
    await google.deleteEvent({ account: "me@example.com", calendarId: "primary" }, "evt1");
    expect(calls().find((x) => x[1] === "delete")).toContain("--send-updates=all");
    const failing = new GoogleCalendar(spawnRunner(join(dir, "missing-gog")));
    await expect(failing.createEvent({ account: "me@example.com", calendarId: "primary" }, { title: "x", start: "2026-10-20T08:00:00Z", end: "2026-10-20T09:00:00Z" })).rejects.toBeInstanceOf(GoogleError);
  });
});
