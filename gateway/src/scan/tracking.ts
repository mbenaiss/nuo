import { carrierOf, type CarrierId } from "./codes";
import type { Fetch } from "./products";

export type ParcelStatus =
  | "pending"
  | "info_received"
  | "in_transit"
  | "out_for_delivery"
  | "available_for_pickup"
  | "delivered"
  | "exception"
  | "returned"
  | "expired"
  | "unknown";

/** Labels stored in the `statut` select column of the `colis` collection (010_colis.sql). */
export const STATUS_LABELS: Record<ParcelStatus, string> = {
  pending: "En attente",
  info_received: "Annoncé",
  in_transit: "En transit",
  out_for_delivery: "En livraison",
  available_for_pickup: "À retirer",
  delivered: "Livré",
  exception: "Incident",
  returned: "Retourné",
  expired: "Expiré",
  unknown: "Inconnu",
};

export const FINAL_STATUSES: ReadonlySet<ParcelStatus> = new Set(["delivered", "returned", "expired"]);

export interface TrackingEvent {
  at?: string;
  label: string;
  location?: string;
}

export interface TrackingResult {
  status: ParcelStatus;
  carrierName?: string;
  /** Newest first. */
  events: TrackingEvent[];
  estimatedDelivery?: string;
  url?: string;
  source: "laposte" | "ship24" | "17track";
}

export interface Tracker {
  /** Undefined when this tracker does not handle the number. */
  track(number: string, carrier?: CarrierId): Promise<TrackingResult | undefined>;
}

export class TrackingError extends Error {}

const TIMEOUT_MS = 10_000;

/** A carrier's malformed date drops that one date instead of failing the whole tracking. */
function isoOrNothing(value: string | undefined): { at: string } | {} {
  if (!value) return {};
  const t = Date.parse(value);
  return Number.isNaN(t) ? {} : { at: new Date(t).toISOString() };
}

/** `YYYY-MM-DD` that is a real day, or nothing (the column only takes real dates). */
export function calendarDay(value: string | undefined): string | undefined {
  const day = value?.slice(0, 10);
  if (!day || !/^\d{4}-\d{2}-\d{2}$/.test(day)) return undefined;
  const t = Date.parse(`${day}T00:00:00Z`);
  return !Number.isNaN(t) && new Date(t).toISOString().startsWith(day) ? day : undefined;
}

/** Event codes of the La Poste Suivi v2 API (developer.laposte.fr), newest event first. */
export function laPosteStatus(code: string | undefined, isFinal: boolean): ParcelStatus {
  const c = (code ?? "").toUpperCase();
  if (c === "DI2" || c === "RE1") return "returned";
  if (c === "DI0" || c === "DI1") return "delivered";
  if (c === "AG1") return "available_for_pickup";
  if (c === "MD2") return "out_for_delivery";
  if (c === "ND1" || c === "PB1" || c === "DR2" || c === "DO3" || c === "DI3") return "exception";
  if (c === "DR1") return "info_received";
  if (/^(PC|ET|EP|DO|PB)/.test(c)) return "in_transit";
  return isFinal ? "delivered" : "unknown";
}

type LaPosteShipment = { isFinal?: boolean; product?: string; url?: string; deliveryDate?: string; event?: { code?: string; label?: string; date?: string }[] };
type LaPosteBody = { returnCode?: number; returnMessage?: string; shipment?: LaPosteShipment; detail?: string; response?: LaPosteBody };

/** What laposte.fr's own tracking page asks: the Suivi v2 answer, without a key, for the occasional parcel. */
const LAPOSTE_PUBLIC = "https://www.laposte.fr/ssu/sun/back/suivi-unifie";
const BROWSER_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36";

/**
 * Colissimo, Chronopost (last status only), registered and tracked letters. With a developer.laposte.fr key it
 * calls the Suivi v2 API, without one the public endpoint behind laposte.fr's tracking page (same answer).
 */
export class LaPosteTracker implements Tracker {
  constructor(
    private key?: string,
    private fetcher: Fetch = fetch,
  ) {}

  async track(number: string, carrier?: CarrierId): Promise<TrackingResult | undefined> {
    if (carrier !== "laposte") return undefined;
    let res: Response;
    try {
      const id = encodeURIComponent(number);
      res = await this.fetcher(this.key ? `https://api.laposte.fr/suivi/v2/idships/${id}?lang=fr_FR` : `${LAPOSTE_PUBLIC}/${id}?lang=fr`, {
        headers: this.key ? { "X-Okapi-Key": this.key, accept: "application/json" } : { "user-agent": BROWSER_UA, accept: "application/json" },
        signal: AbortSignal.timeout(TIMEOUT_MS),
      });
    } catch (e) {
      throw new TrackingError(`La Poste injoignable : ${(e as Error)?.message ?? e}`);
    }
    const raw = (await res.json().catch(() => undefined)) as LaPosteBody | LaPosteBody[] | undefined;
    // The public endpoint wraps its errors ({detail, response}) and may answer a list of shipments.
    const first = Array.isArray(raw) ? raw[0] : raw;
    const body = first?.response ?? first;
    // 104: "pas encore disponible", the number is known to nobody yet (label printed, parcel not dropped off).
    if (res.status === 404) return { status: "pending", events: [], source: "laposte", carrierName: "La Poste" };
    if (res.status === 401 || res.status === 403) throw new TrackingError("clé La Poste (NUO_LAPOSTE_OKAPI_KEY) refusée");
    if (!res.ok || !body?.shipment) throw new TrackingError(body?.returnMessage ?? first?.detail ?? `La Poste a répondu ${res.status}`);
    const s = body.shipment;
    const events = (s.event ?? []).filter((e) => e.label).map((e) => ({ label: e.label!, ...isoOrNothing(e.date) }));
    const product = s.product ? s.product.charAt(0).toUpperCase() + s.product.slice(1) : "La Poste";
    return {
      status: laPosteStatus(s.event?.[0]?.code, !!s.isFinal),
      carrierName: product,
      events,
      ...(s.deliveryDate ? { estimatedDelivery: s.deliveryDate.slice(0, 10) } : {}),
      ...(s.url ? { url: s.url } : {}),
      source: "laposte",
    };
  }
}

const SHIP24_TIMEOUT_MS = 60_000;

const SHIP24_STATUS: Record<string, ParcelStatus> = {
  pending: "pending",
  info_received: "info_received",
  in_transit: "in_transit",
  out_for_delivery: "out_for_delivery",
  failed_attempt: "exception",
  available_for_pickup: "available_for_pickup",
  delivered: "delivered",
  exception: "exception",
};

/** Milestones of docs.ship24.com/status; a return is an `exception` milestone with its own status code. */
export function ship24Status(milestone: string | undefined, statusCode: string | undefined | null): ParcelStatus {
  if (statusCode === "exception_return") return "returned";
  return SHIP24_STATUS[milestone ?? ""] ?? "unknown";
}

interface Ship24Event {
  status?: string | null;
  occurrenceDatetime?: string;
  order?: number | null;
  location?: string | null;
  courierCode?: string | null;
}

/**
 * Any carrier (api.ship24.com). The first call for a number creates its tracker, which spends one shipment of
 * the monthly quota and may take up to a minute while Ship24 asks the carrier; later calls are free and instant.
 */
export class Ship24Tracker implements Tracker {
  private couriers?: Promise<Map<string, string>>;

  constructor(
    private key: string,
    private fetcher: Fetch = fetch,
    private base = "https://api.ship24.com/public/v1",
  ) {}

  private async call(method: string, path: string, body?: unknown): Promise<any> {
    let res: Response;
    try {
      res = await this.fetcher(`${this.base}/${path}`, {
        method,
        headers: { authorization: `Bearer ${this.key}`, "content-type": "application/json; charset=utf-8" },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        signal: AbortSignal.timeout(SHIP24_TIMEOUT_MS),
      });
    } catch (e) {
      throw new TrackingError(`Ship24 injoignable : ${(e as Error)?.message ?? e}`);
    }
    const data = (await res.json().catch(() => undefined)) as { data?: any; errors?: { code?: string; message?: string }[] } | undefined;
    if (res.status === 401) throw new TrackingError("clé Ship24 (NUO_SHIP24_API_KEY) refusée");
    const error = data?.errors?.[0];
    if (error?.code === "quota_limit_reached") throw new TrackingError("quota Ship24 du mois atteint");
    if (!res.ok || !data?.data) throw new TrackingError(`Ship24 : ${error?.message ?? `réponse ${res.status}`}`);
    return data.data;
  }

  /** Courier names by code, read once: the list costs no quota. */
  private courierNames(): Promise<Map<string, string>> {
    this.couriers ??= this.call("GET", "couriers")
      .then((d) => new Map(((d?.couriers ?? []) as { courierCode?: string; courierName?: string }[]).filter((c) => c.courierCode && c.courierName).map((c) => [c.courierCode!, c.courierName!])))
      .catch(() => {
        this.couriers = undefined;
        return new Map<string, string>();
      });
    return this.couriers;
  }

  async track(number: string): Promise<TrackingResult> {
    const data = await this.call("POST", "trackers/track", { trackingNumber: number });
    const tracking = (data?.trackings ?? [])[0];
    if (!tracking) return { status: "pending", events: [], source: "ship24" };
    const raw = ((tracking.events ?? []) as Ship24Event[]).filter((e) => e.status);
    const events = raw
      .map((e) => ({ e, t: Date.parse(e.occurrenceDatetime ?? "") || 0 }))
      .sort((a, b) => b.t - a.t || (b.e.order ?? 0) - (a.e.order ?? 0))
      .map(({ e }) => ({ label: e.status!, ...isoOrNothing(e.occurrenceDatetime), ...(e.location ? { location: e.location } : {}) }));
    const shipment = tracking.shipment ?? {};
    const code = raw.find((e) => e.courierCode)?.courierCode ?? [tracking.tracker?.courierCode].flat()[0];
    const carrierName = code ? (await this.courierNames()).get(code) : undefined;
    const eta = shipment.delivery?.estimatedDeliveryDate ?? shipment.delivery?.courierEstimatedDeliveryDate?.to ?? shipment.delivery?.courierEstimatedDeliveryDate?.from;
    return {
      status: ship24Status(shipment.statusMilestone, shipment.statusCode),
      ...(carrierName ? { carrierName } : {}),
      events,
      ...(typeof eta === "string" ? { estimatedDelivery: eta.slice(0, 10) } : {}),
      source: "ship24",
    };
  }
}

const SEVENTEEN_STATUS: Record<string, ParcelStatus> = {
  NotFound: "pending",
  InfoReceived: "info_received",
  InTransit: "in_transit",
  Expired: "expired",
  AvailableForPickup: "available_for_pickup",
  OutForDelivery: "out_for_delivery",
  DeliveryFailure: "exception",
  Delivered: "delivered",
  Exception: "exception",
};

export function seventeenStatus(status: string | undefined, subStatus: string | undefined): ParcelStatus {
  if (subStatus === "Exception_Returned" || subStatus === "Exception_Returning") return "returned";
  return SEVENTEEN_STATUS[status ?? ""] ?? "unknown";
}

const ALREADY_REGISTERED = -18019901;

interface SeventeenEvent {
  time_iso?: string;
  description?: string;
  location?: string | null;
}

/**
 * Any carrier, detected by 17TRACK (api.17track.net, key `17token`). Registering a number spends one unit of
 * the account's quota, re-reading it is free: the number is registered once, then only read.
 */
export class SeventeenTrackTracker implements Tracker {
  constructor(
    private key: string,
    private fetcher: Fetch = fetch,
    private base = "https://api.17track.net/track/v2.4",
  ) {}

  private async call(path: string, body: unknown): Promise<any> {
    let res: Response;
    try {
      res = await this.fetcher(`${this.base}/${path}`, {
        method: "POST",
        headers: { "17token": this.key, "content-type": "application/json" },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(TIMEOUT_MS),
      });
    } catch (e) {
      throw new TrackingError(`17TRACK injoignable : ${(e as Error)?.message ?? e}`);
    }
    if (res.status === 401) throw new TrackingError("clé 17TRACK (NUO_SEVENTEENTRACK_API_KEY) refusée");
    if (!res.ok) throw new TrackingError(`17TRACK a répondu ${res.status}`);
    const data = (await res.json().catch(() => undefined)) as { code?: number; data?: any } | undefined;
    if (data?.code !== 0) throw new TrackingError(`17TRACK a refusé la requête (code ${data?.code ?? "?"})`);
    return data.data;
  }

  async track(number: string): Promise<TrackingResult> {
    const reg = await this.call("register", [{ number, lang: "fr" }]);
    const refusal = (reg?.rejected ?? []).find((r: any) => r?.error?.code !== ALREADY_REGISTERED);
    if (refusal) throw new TrackingError(`17TRACK : ${refusal.error?.message ?? "numéro refusé"}`);
    const info = await this.call("gettrackinfo", [{ number }]);
    const accepted = (info?.accepted ?? [])[0];
    const t = accepted?.track_info;
    if (!t) return { status: "pending", events: [], source: "17track" };
    const providers: any[] = t.tracking?.providers ?? [];
    const events = providers
      .flatMap((p) => (p?.events ?? []) as SeventeenEvent[])
      .filter((e) => e.description)
      .map((e) => ({ label: e.description!, ...isoOrNothing(e.time_iso), ...(e.location ? { location: e.location } : {}) }))
      .sort((a, b) => (b.at ?? "").localeCompare(a.at ?? ""));
    const eta = t.time_metrics?.estimated_delivery_date;
    const carrierName = providers[0]?.provider?.name as string | undefined;
    return {
      status: seventeenStatus(t.latest_status?.status, t.latest_status?.sub_status),
      ...(carrierName ? { carrierName } : {}),
      events,
      ...(typeof (eta?.to ?? eta?.from) === "string" ? { estimatedDelivery: String(eta.to ?? eta.from).slice(0, 10) } : {}),
      source: "17track",
    };
  }
}

/**
 * La Poste first for its own numbers (free, no quota), then Ship24 (free monthly quota), then 17TRACK when
 * the others fail or Ship24 has spent its quota.
 */
export class TrackerChain implements Tracker {
  constructor(private trackers: Tracker[]) {}

  get configured() {
    return this.trackers.length > 0;
  }

  async track(number: string, carrier?: CarrierId): Promise<TrackingResult | undefined> {
    let lastError: unknown;
    for (const t of this.trackers) {
      try {
        const r = await t.track(number, carrier);
        if (r) return r;
      } catch (e) {
        lastError = e;
      }
    }
    if (lastError) throw lastError;
    return undefined;
  }
}

export function trackerFromEnv(env: Record<string, string | undefined> = process.env, fetcher: Fetch = fetch): TrackerChain {
  const chain: Tracker[] = [];
  chain.push(new LaPosteTracker(env.NUO_LAPOSTE_OKAPI_KEY || undefined, fetcher));
  if (env.NUO_SHIP24_API_KEY) chain.push(new Ship24Tracker(env.NUO_SHIP24_API_KEY, fetcher));
  if (env.NUO_SEVENTEENTRACK_API_KEY) chain.push(new SeventeenTrackTracker(env.NUO_SEVENTEENTRACK_API_KEY, fetcher));
  return new TrackerChain(chain);
}

export function carrierUrl(number: string, carrier: CarrierId | undefined): string {
  return carrierOf(carrier)?.url(number) ?? `https://t.17track.net/fr#nums=${encodeURIComponent(number)}`;
}
