import type { Database } from "bun:sqlite";
import { BookingService } from "./booking";
import { GoogleCalendar, parseTarget, spawnRunner, type CommandRunner, type GoogleTarget } from "./google";
import { bookingHostsFromEnv, PublicSite } from "./public";
import { CalendarStore } from "./store";
import { createTurnstile, type Turnstile } from "./turnstile";

export interface CalendarOptions {
  /** Hostnames that serve the public booking pages only (NUO_BOOKING_HOSTS). */
  bookingHosts?: Set<string>;
  baseUrl?: string;
  ownerName?: string;
  /** Address printed on /privacy and /terms (NUO_LEGAL_CONTACT). */
  contactEmail?: string;
  turnstileSiteKey?: string;
  turnstileSecret?: string;
  /** Turnstile siteverify call (tests). */
  fetch?: typeof fetch;
  /** Default Google target `account[/calendarId]` (NUO_GOOGLE_CALENDAR). */
  googleCalendar?: string;
  googleAccounts?: string[];
  gogBin?: string;
  /** Replaces the gog process (tests); null disables Google entirely. */
  gogRunner?: CommandRunner | null;
  clock?: () => number;
}

export interface CalendarServices {
  store: CalendarStore;
  bookings: BookingService;
  google?: GoogleCalendar;
  defaultTarget?: GoogleTarget;
  googleAccounts: string[];
  turnstile: Turnstile;
  bookingHosts: Set<string>;
  site: PublicSite;
}

const list = (s: string | undefined) => (s ?? "").split(",").map((x) => x.trim()).filter(Boolean);

export function calendarOptionsFromEnv(env: Record<string, string | undefined> = process.env): CalendarOptions {
  return {
    bookingHosts: bookingHostsFromEnv(env),
    baseUrl: env.NUO_BOOKING_BASE_URL || undefined,
    ownerName: env.NUO_BOOKING_OWNER || undefined,
    contactEmail: env.NUO_LEGAL_CONTACT || undefined,
    turnstileSiteKey: env.NUO_TURNSTILE_SITEKEY || undefined,
    turnstileSecret: env.NUO_TURNSTILE_SECRET || undefined,
    googleCalendar: env.NUO_GOOGLE_CALENDAR || undefined,
    googleAccounts: list(env.NUO_GOOGLE_ACCOUNTS),
    gogBin: env.NUO_GOG_BIN || undefined,
  };
}

/** Builds a GoogleCalendar for the CLI and the gateway; undefined when gog is explicitly disabled. */
export function googleFrom(o: Pick<CalendarOptions, "gogBin" | "gogRunner">): GoogleCalendar | undefined {
  if (o.gogRunner === null) return undefined;
  return new GoogleCalendar(o.gogRunner ?? spawnRunner(o.gogBin ?? "gog"));
}

export function createCalendarServices(db: Database, notify: (title: string, body: string, bookingId: string) => void, o: CalendarOptions = {}): CalendarServices {
  const bookingHosts = o.bookingHosts ?? new Set<string>();
  const baseUrl = (o.baseUrl ?? (bookingHosts.size ? `https://${[...bookingHosts][0]}` : undefined))?.replace(/\/+$/, "");
  const defaultTarget = parseTarget(o.googleCalendar);
  const googleAccounts = o.googleAccounts?.length ? o.googleAccounts : defaultTarget ? [defaultTarget.account] : [];
  const google = googleFrom(o);
  const store = new CalendarStore(db, o.clock);
  const bookings = new BookingService({ db, calendars: store, google, defaultTarget, baseUrl, notify, clock: o.clock });
  const turnstile = createTurnstile({ siteKey: o.turnstileSiteKey, secret: o.turnstileSecret, fetch: o.fetch });
  if (bookingHosts.size) {
    if (!turnstile.enabled) console.warn("[booking] NUO_TURNSTILE_SITEKEY/NUO_TURNSTILE_SECRET are not set: the public booking form has NO bot protection (dev only)");
    if (!defaultTarget) console.warn("[booking] NUO_GOOGLE_CALENDAR is not set: booking types without googleCalendar create no Google event");
  }
  const site = new PublicSite({ bookings, turnstile, ownerName: o.ownerName, contactEmail: o.contactEmail });
  return { store, bookings, google, defaultTarget, googleAccounts, turnstile, bookingHosts, site };
}
