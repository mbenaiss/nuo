import { HttpError } from "../bots/service";
import type { Device } from "../store/store";
import { formatTarget, parseTarget } from "./google";
import type { CalendarServices } from "./service";
import { zonedToUtc } from "../scheduler/cron";
import { bad, bool, isEmail, iso, str } from "./validate";

type Ctx = { req: Request; params: string[]; url: URL; device: Device };
export type CalendarRoute = [string, RegExp, (ctx: Ctx) => unknown];

const MAX_RANGE_MS = 400 * 86_400_000;

async function body(req: Request): Promise<Record<string, unknown>> {
  try {
    const b = await req.json();
    if (b && typeof b === "object" && !Array.isArray(b)) return b as Record<string, unknown>;
  } catch {}
  throw new HttpError(400, "invalid JSON body");
}

/** `YYYY-MM-DD` is Paris midnight; anything else must be an ISO instant. */
function instant(v: string | null, field: string): string {
  if (v && /^\d{4}-\d{2}-\d{2}$/.test(v)) {
    const [y, m, d] = v.split("-").map(Number) as [number, number, number];
    return new Date(zonedToUtc(y, m, d, 0, 0, "Europe/Paris")).toISOString();
  }
  return iso(v, field);
}

/** Validated input of POST /api/calendar/events and the calendar-create CLI. */
export function googleEventInput(b: Record<string, unknown>) {
  const allDay = bool(b.allDay, "allDay", false);
  const date = (v: unknown, f: string) => {
    if (typeof v !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(v)) throw bad(`${f} must be YYYY-MM-DD for an all-day event`);
    return v;
  };
  const start = allDay ? date(b.start, "start") : iso(b.start, "start");
  const end = allDay ? date(b.end, "end") : iso(b.end, "end");
  if (end <= start) throw bad("end must be after start");
  let attendees: string[] | undefined;
  if (b.attendees !== undefined && b.attendees !== null) {
    if (!Array.isArray(b.attendees) || b.attendees.length > 50 || b.attendees.some((a) => typeof a !== "string" || !isEmail(a))) throw bad("attendees must be an array of email addresses");
    attendees = b.attendees as string[];
  }
  return {
    title: str(b.title, "title", 500, true),
    start,
    end,
    allDay,
    location: str(b.location, "location", 1000),
    description: str(b.notes, "notes", 8000),
    attendees,
    meet: bool(b.meet, "meet", false),
  };
}

/** Device routes of docs/calendar.md (app scope). */
export function calendarRoutes(c: CalendarServices): CalendarRoute[] {
  const bridge = (device: Device) => ({ id: device.id, name: device.name });
  return [
    ["PUT", /^\/api\/calendar\/sources$/, async ({ req, device }) => ({ calendars: c.store.putSources(bridge(device), await body(req)) })],
    ["POST", /^\/api\/calendar\/sync$/, async ({ req, device }) => c.store.sync(bridge(device), await body(req))],
    ["POST", /^\/api\/calendar\/sync\/events$/, async ({ req, device }) => c.store.syncOne(bridge(device), await body(req))],
    ["GET", /^\/api\/calendar\/calendars$/, () => c.store.calendars()],
    ["PATCH", /^\/api\/calendar\/calendars\/([^/]+)$/, async ({ req, params }) => c.store.patchCalendar(params[0]!, await body(req))],
    ["PUT", /^\/api\/calendar\/events\/([^/]+)\/travel$/, async ({ req, params }) => ({ event: c.store.setTravel(params[0]!, await body(req)) })],
    [
      "GET",
      /^\/api\/calendar\/events$/,
      ({ url }) => {
        const s = url.searchParams;
        const from = instant(s.get("from"), "from");
        const to = instant(s.get("to"), "to");
        if (to <= from || Date.parse(to) - Date.parse(from) > MAX_RANGE_MS) throw bad("from/to must span at most 400 days");
        const calendars = (s.get("calendars") ?? "").split(",").map((x) => x.trim()).filter(Boolean);
        return {
          from,
          to,
          items: c.store.events({ from, to, calendars: calendars.length ? calendars : undefined, reminders: s.get("reminders") !== "0", bookings: s.get("bookings") === "1" }),
        };
      },
    ],
    [
      "POST",
      /^\/api\/calendar\/events$/,
      async ({ req }) => {
        const b = await body(req);
        if (!c.google) throw new HttpError(503, "Google Calendar is not available on this gateway");
        const target = b.target === undefined || b.target === null ? c.defaultTarget : parseTarget(str(b.target, "target", 400));
        if (!target) throw bad("target is required (no NUO_GOOGLE_CALENDAR default)");
        const ev = await c.google.createEvent(target, googleEventInput(b)).catch((e) => {
          throw new HttpError(502, (e as Error)?.message ?? String(e));
        });
        return Response.json({ googleEventId: ev.id, target: formatTarget(target), ...(ev.htmlLink ? { htmlLink: ev.htmlLink } : {}), ...(ev.meetUrl ? { meetUrl: ev.meetUrl } : {}) }, { status: 201 });
      },
    ],
    [
      "GET",
      /^\/api\/calendar\/google\/calendars$/,
      async () => {
        if (!c.google) return [];
        const out = [];
        for (const account of c.googleAccounts) {
          try {
            out.push(...(await c.google.calendars(account)));
          } catch (e) {
            console.warn(`[calendar] cannot list Google calendars of ${account}: ${(e as Error)?.message ?? e}`);
          }
        }
        return out;
      },
    ],

    ["GET", /^\/api\/booking\/types$/, ({ url }) => c.bookings.types(url.searchParams.get("archived") === "1")],
    ["POST", /^\/api\/booking\/types$/, async ({ req }) => Response.json(c.bookings.createType(await body(req)), { status: 201 })],
    ["GET", /^\/api\/booking\/types\/([^/]+)$/, ({ params }) => c.bookings.type(params[0]!)],
    ["PATCH", /^\/api\/booking\/types\/([^/]+)$/, async ({ req, params }) => c.bookings.patchType(params[0]!, await body(req))],
    [
      "DELETE",
      /^\/api\/booking\/types\/([^/]+)$/,
      ({ params }) => {
        c.bookings.archiveType(params[0]!);
        return new Response(null, { status: 204 });
      },
    ],
    [
      "GET",
      /^\/api\/booking\/types\/([^/]+)\/slots$/,
      ({ params, url }) => {
        const t = c.bookings.type(params[0]!);
        const from = Date.parse(instant(url.searchParams.get("from"), "from"));
        const to = Date.parse(instant(url.searchParams.get("to"), "to"));
        if (to <= from || to - from > 93 * 86_400_000) throw bad("from/to must span at most 93 days");
        return { timezone: "Europe/Paris", durationMin: t.durationMin, slots: c.bookings.slots(t, from, to).map((s) => ({ start: new Date(s.start).toISOString(), end: new Date(s.end).toISOString() })) };
      },
    ],
    [
      "GET",
      /^\/api\/booking\/bookings$/,
      ({ url }) => {
        const s = url.searchParams;
        return c.bookings.bookings({ from: s.get("from") || undefined, to: s.get("to") || undefined, status: s.get("status") || undefined, typeId: s.get("typeId") || undefined });
      },
    ],
    ["GET", /^\/api\/booking\/bookings\/([^/]+)$/, ({ params }) => c.bookings.booking(params[0]!)],
    [
      "POST",
      /^\/api\/booking\/bookings\/([^/]+)\/cancel$/,
      async ({ req, params }) => {
        const b = req.headers.get("content-length") === "0" ? {} : await body(req).catch(() => ({}) as Record<string, unknown>);
        return c.bookings.cancel(params[0]!, { reason: b.reason, byInvitee: false });
      },
    ],
  ];
}
