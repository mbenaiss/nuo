import { readFileSync } from "node:fs";
import { HttpError } from "../bots/service";
import { isValidTimeZone, zonedToUtc } from "../scheduler/cron";
import { BOOKING_TZ } from "./availability";
import type { Booking, BookingService, BookingType } from "./booking";
import { icsCalendar } from "./ics";
import { LEGAL_PAGES, legalMain } from "./legal";
import type { Turnstile } from "./turnstile";

const ASSETS: Record<string, { type: string; path: string }> = {
  "/assets/booking.css": { type: "text/css; charset=utf-8", path: new URL("./public/booking.css", import.meta.url).pathname },
  "/assets/booking.js": { type: "text/javascript; charset=utf-8", path: new URL("./public/booking.js", import.meta.url).pathname },
};

const MAX_BODY = 16 * 1024;
const MAX_RANGE_DAYS = 62;
const DAY = 86_400_000;
const TURNSTILE_ORIGIN = "https://challenges.cloudflare.com";

const CSP = [
  "default-src 'none'",
  `script-src 'self' ${TURNSTILE_ORIGIN}`,
  "style-src 'self'",
  "img-src 'self' data:",
  "connect-src 'self'",
  `frame-src ${TURNSTILE_ORIGIN}`,
  "form-action 'self'",
  "base-uri 'none'",
  "frame-ancestors 'none'",
].join("; ");

const HEADERS: Record<string, string> = {
  "content-security-policy": CSP,
  "x-content-type-options": "nosniff",
  "x-frame-options": "DENY",
  "referrer-policy": "no-referrer",
  "strict-transport-security": "max-age=31536000",
  "permissions-policy": "camera=(), microphone=(), geolocation=(), payment=()",
  "cross-origin-opener-policy": "same-origin",
  "x-robots-tag": "noindex, nofollow",
};

export function bookingHostsFromEnv(env: Record<string, string | undefined> = process.env): Set<string> {
  return new Set(
    (env.NUO_BOOKING_HOSTS ?? "")
      .split(",")
      .map((h) => h.trim().toLowerCase())
      .filter(Boolean),
  );
}

/** Host of the request without the port; `[::1]:8790` → `[::1]`. */
export function requestHost(req: Request): string {
  return (req.headers.get("host") ?? "").trim().toLowerCase().replace(/:\d+$/, "");
}

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
/** JSON inside <script type="application/json">: `<` escaped so the data can never close the tag. */
const scriptJson = (v: unknown) => JSON.stringify(v).replace(/</g, "\\u003c").replace(/\u2028/g, "\\u2028").replace(/\u2029/g, "\\u2029");

const json = (data: unknown, status = 200) => Response.json(data, { status, headers: { "cache-control": "no-store" } });

function frenchError(e: HttpError): string {
  const m = e.message;
  if (/^name\b/.test(m)) return "Indiquez votre nom.";
  if (/^email\b/.test(m)) return "Indiquez une adresse e-mail valide.";
  if (/^notes\b/.test(m)) return "Votre message est trop long (2000 caractères au plus).";
  if (/^(start|from|to)\b/.test(m)) return "Créneau invalide.";
  if (/^answers: /.test(m)) return m.slice("answers: ".length);
  if (/^(answers|unknown answer)/.test(m)) return "Réponses invalides.";
  if (/^reason\b/.test(m)) return "Motif trop long (500 caractères au plus).";
  return m;
}

export interface PublicSiteOptions {
  bookings: BookingService;
  turnstile: Turnstile;
  ownerName?: string;
  /** Address printed on /privacy and /terms (NUO_LEGAL_CONTACT). */
  contactEmail?: string;
  /** NUO_BOOKING_UID_DOMAIN, `nuo` by default. */
  icsUidDomain?: string;
}

/** Everything the booking hostname serves (docs/calendar.md#public-booking-host); anything else is 404. */
export class PublicSite {
  private assets = new Map<string, string>();

  constructor(private o: PublicSiteOptions) {}

  private asset(path: string): Response | undefined {
    const a = ASSETS[path];
    if (!a) return undefined;
    let body = this.assets.get(path);
    if (body === undefined) {
      body = readFileSync(a.path, "utf8");
      this.assets.set(path, body);
    }
    return new Response(body, { headers: { "content-type": a.type, "cache-control": "public, max-age=3600" } });
  }

  async handle(req: Request, path: string, url: URL, ip: string): Promise<Response> {
    let res: Response;
    try {
      res = (await this.route(req, path, url, ip)) ?? this.notFound();
    } catch (e) {
      if (e instanceof HttpError) res = e.status === 404 ? this.notFound(path.startsWith("/api/") || req.method === "POST") : json({ error: frenchError(e) }, e.status);
      else {
        console.error(`[booking] ${req.method} ${path}:`, e);
        res = json({ error: "Une erreur est survenue." }, 500);
      }
    }
    for (const [k, v] of Object.entries(HEADERS)) res.headers.set(k, v);
    if (!res.headers.has("cache-control")) res.headers.set("cache-control", "no-store");
    if (req.method === "HEAD") return new Response(null, { status: res.status, headers: res.headers });
    return res;
  }

  private notFound(asJson = false): Response {
    if (asJson) return json({ error: "not found" }, 404);
    return this.html(404, "Page introuvable", `<main class="shell"><section class="panel"><p class="brand">Nuo</p><h1>Page introuvable</h1><p class="muted">Ce lien de rendez-vous n'existe pas ou n'est plus actif.</p></section></main>`);
  }

  private html(status: number, title: string, body: string, data?: unknown, turnstile = false): Response {
    const page = `<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<meta name="theme-color" content="#FF6A2B">
<title>${esc(title)}</title>
<link rel="icon" href="data:,">
<link rel="stylesheet" href="/assets/booking.css">
${data !== undefined ? '<script src="/assets/booking.js" defer></script>' : ""}
${turnstile ? `<script src="${TURNSTILE_ORIGIN}/turnstile/v0/api.js?render=explicit" async defer></script>` : ""}
</head>
<body>
${body}
${data !== undefined ? `<script type="application/json" id="booking-data">${scriptJson(data)}</script>` : ""}
</body>
</html>`;
    return new Response(page, { status, headers: { "content-type": "text/html; charset=utf-8" } });
  }

  private intro(t: BookingType): string {
    const loc =
      t.location.kind === "google_meet" ? "Google Meet" : t.location.kind === "phone" ? "Téléphone" : t.location.kind === "address" ? (t.location.value ?? "Sur place") : (t.location.value ?? "");
    return `<header class="intro">
<p class="brand">${esc(this.o.ownerName ?? "Nuo")}</p>
<h1>${esc(t.title)}</h1>
<ul class="facts"><li>${t.durationMin} min</li>${loc ? `<li>${esc(loc)}</li>` : ""}<li>Heure de Paris</li></ul>
${t.description ? `<p class="desc">${esc(t.description)}</p>` : ""}
</header>`;
  }

  private pageData(t: BookingType, extra: Record<string, unknown>) {
    return {
      title: t.title,
      durationMin: t.durationMin,
      location: t.location,
      questions: t.questions,
      siteKey: this.o.turnstile.enabled ? this.o.turnstile.siteKey : null,
      ...extra,
    };
  }

  private bookingPage(t: BookingType): Response {
    const body = `<main class="shell">${this.intro(t)}<section id="app" class="panel" aria-live="polite"><noscript>Activez JavaScript pour choisir un créneau.</noscript><p class="muted">Chargement…</p></section></main>`;
    return this.html(200, `${t.title} · Prendre rendez-vous`, body, this.pageData(t, { mode: "book", slug: t.slug }), this.o.turnstile.enabled);
  }

  private managePage(token: string, b: Booking): Response {
    const t = this.o.bookings.type(b.typeId);
    const body = `<main class="shell">${this.intro(t)}<section id="app" class="panel" aria-live="polite"><noscript>Activez JavaScript pour gérer ce rendez-vous.</noscript></section></main>`;
    return this.html(200, `${t.title} · Votre rendez-vous`, body, this.pageData(t, { mode: "manage", token, booking: this.o.bookings.publicView(b) }), this.o.turnstile.enabled);
  }

  private range(url: URL): { from: number; to: number } {
    const tzParam = url.searchParams.get("tz") ?? BOOKING_TZ;
    const tz = isValidTimeZone(tzParam) ? tzParam : BOOKING_TZ;
    const point = (v: string | null, end: boolean): number => {
      if (!v) throw new HttpError(400, "from and to are required");
      const d = /^(\d{4})-(\d{2})-(\d{2})$/.exec(v);
      if (d) {
        const next = new Date(Date.UTC(Number(d[1]), Number(d[2]) - 1, Number(d[3]) + (end ? 1 : 0)));
        return zonedToUtc(next.getUTCFullYear(), next.getUTCMonth() + 1, next.getUTCDate(), 0, 0, tz);
      }
      const t = Date.parse(v);
      if (Number.isNaN(t)) throw new HttpError(400, "from must be YYYY-MM-DD or an ISO date-time");
      return t;
    };
    const from = point(url.searchParams.get("from"), false);
    const to = point(url.searchParams.get("to"), true);
    if (to <= from || to - from > MAX_RANGE_DAYS * DAY + DAY) throw new HttpError(400, `from/to must span at most ${MAX_RANGE_DAYS} days`);
    return { from, to };
  }

  private slotsResponse(t: BookingType, url: URL, exclude?: string): Response {
    const { from, to } = this.range(url);
    const slots = this.o.bookings.slots(t, from, to, exclude).map((s) => ({ start: new Date(s.start).toISOString(), end: new Date(s.end).toISOString() }));
    return json({ timezone: BOOKING_TZ, durationMin: t.durationMin, slots });
  }

  private async readBody(req: Request): Promise<Record<string, unknown>> {
    const len = req.headers.get("content-length");
    if (len === null) throw new HttpError(411, "content-length required");
    if (Number(len) > MAX_BODY) throw new HttpError(413, "request body too large");
    if (!(req.headers.get("content-type") ?? "").toLowerCase().startsWith("application/json")) throw new HttpError(415, "expected application/json");
    const text = await req.text();
    if (text.length > MAX_BODY) throw new HttpError(413, "request body too large");
    try {
      const b = JSON.parse(text);
      if (b && typeof b === "object" && !Array.isArray(b)) return b;
    } catch {}
    throw new HttpError(400, "invalid JSON body");
  }

  private links(token: string) {
    const manageUrl = this.o.bookings.manageUrl(token);
    return { manageUrl, icsUrl: `${manageUrl}/event.ics` };
  }

  private ics(b: Booking): Response {
    let root = b;
    for (let i = 0; i < 50 && root.rescheduledFrom; i++) root = this.o.bookings.booking(root.rescheduledFrom);
    const t = this.o.bookings.type(b.typeId);
    const v = this.o.bookings.publicView(b);
    const where = t.location.kind === "google_meet" ? b.meetUrl ?? undefined : t.location.kind === "phone" ? `Téléphone : ${t.location.value}` : t.location.value;
    const body = icsCalendar({
      uid: `${root.id}@${this.o.icsUidDomain ?? "nuo"}`,
      start: b.start,
      end: b.end,
      title: `${t.title}${this.o.ownerName ? ` · ${this.o.ownerName}` : ""}`,
      description: v.meetUrl ? `Google Meet : ${v.meetUrl}` : undefined,
      location: where,
      url: b.meetUrl ?? undefined,
      cancelled: b.status === "cancelled",
      sequence: Math.floor(Date.parse(b.createdAt) / 1000) - Math.floor(Date.parse(root.createdAt) / 1000),
    });
    return new Response(body, { headers: { "content-type": "text/calendar; charset=utf-8", "content-disposition": 'attachment; filename="rendez-vous.ics"' } });
  }

  private async route(req: Request, path: string, url: URL, ip: string): Promise<Response | undefined> {
    const get = req.method === "GET" || req.method === "HEAD";
    const post = req.method === "POST";
    if (get) {
      const asset = this.asset(path);
      if (asset) return asset;
    }

    let m = /^\/api\/public\/booking\/([a-z0-9-]{1,40})\/slots$/.exec(path);
    if (m && get) {
      const t = this.o.bookings.publicType(m[1]!);
      return t ? this.slotsResponse(t, url) : undefined;
    }
    m = /^\/api\/public\/booking\/([a-z0-9-]{1,40})$/.exec(path);
    if (m && post) {
      const t = this.o.bookings.publicType(m[1]!);
      if (!t) return undefined;
      const b = await this.readBody(req);
      if (typeof b.website === "string" && b.website.trim() !== "") {
        // Bots get a believable answer and nothing is stored or sent.
        const start = typeof b.start === "string" && !Number.isNaN(Date.parse(b.start)) ? new Date(b.start).toISOString() : new Date().toISOString();
        const end = new Date(Date.parse(start) + t.durationMin * 60_000).toISOString();
        return json({ booking: { start, end, title: t.title, durationMin: t.durationMin, location: t.location, status: "confirmed", inviteeName: String(b.name ?? "") }, manageUrl: "/", icsUrl: "/" }, 201);
      }
      if (!(await this.o.turnstile.verify(b.turnstileToken, ip))) throw new HttpError(403, "La vérification anti-spam a échoué.");
      const { booking, token } = await this.o.bookings.book(t.slug, b, ip);
      return json({ booking: this.o.bookings.publicView(booking), ...this.links(token) }, 201);
    }

    m = /^\/m\/([A-Za-z0-9_-]{43})(\/slots|\/event\.ics)?$/.exec(path);
    if (m) {
      const token = m[1]!;
      const b = this.o.bookings.byToken(token);
      if (!b) return undefined;
      if (m[2] === "/slots" && get) {
        const t = this.o.bookings.type(b.typeId);
        return t.archived ? json({ timezone: BOOKING_TZ, durationMin: t.durationMin, slots: [] }) : this.slotsResponse(t, url, b.id);
      }
      if (m[2] === "/event.ics" && get) return this.ics(b);
      if (!m[2] && get) return this.managePage(token, b);
      if (!m[2] && post) {
        const body = await this.readBody(req);
        if (body.action === "cancel") {
          const out = await this.o.bookings.cancel(b.id, { reason: body.reason, byInvitee: true });
          return json({ booking: this.o.bookings.publicView(out), ...this.links(token) });
        }
        if (body.action === "reschedule") {
          if (!(await this.o.turnstile.verify(body.turnstileToken, ip))) throw new HttpError(403, "La vérification anti-spam a échoué.");
          const out = await this.o.bookings.reschedule(token, body.start);
          return json({ booking: this.o.bookings.publicView(out), ...this.links(token) });
        }
        throw new HttpError(400, 'action must be "cancel" or "reschedule"');
      }
      return undefined;
    }

    // Before the slug route: a booking type called "privacy" must not shadow the page Google checks.
    if (get) {
      const legal = legalMain(path, { ownerName: this.o.ownerName, contactEmail: this.o.contactEmail });
      if (legal) return this.html(200, `${LEGAL_PAGES[path]!.title} · Nuo`, legal);
    }

    m = /^\/([a-z0-9-]{1,40})$/.exec(path);
    if (m && get) {
      const t = this.o.bookings.publicType(m[1]!);
      return t ? this.bookingPage(t) : undefined;
    }
    return undefined;
  }
}
