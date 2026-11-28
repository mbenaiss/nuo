import { DEFAULT_UI_LANGUAGE, t, type UiLanguage } from "../i18n/language";
import type { MessageKey } from "../i18n/messages";
import { head } from "../text";
import type { Database } from "bun:sqlite";
import { asApp, NOW_SQL } from "../data/db";
import type { Pusher } from "../push/apns";
import type { Device } from "../store/store";
import { carrierOf, cleanTrackingNumber, guessParcel, type CarrierId } from "./codes";
import { calendarDay, carrierUrl, FINAL_STATUSES, STATUS_LABELS, type ParcelStatus, type Tracker, type TrackingEvent } from "./tracking";

export interface Parcel {
  id: string;
  number: string;
  label?: string;
  carrier?: CarrierId;
  carrierName?: string;
  status: ParcelStatus;
  statusLabel: string;
  lastEvent?: TrackingEvent;
  /** Newest first. */
  events: TrackingEvent[];
  estimatedDelivery?: string;
  deliveredAt?: string;
  url: string;
  checkedAt?: string;
  error?: string;
  createdAt: string;
  archivedAt?: string;
}

export interface ParcelOptions {
  /** How often the refresher wakes up. */
  intervalMs?: number;
  /** A parcel is asked again once its last check is this old. */
  refreshMs?: number;
  /** Parcels added longer ago stop being refreshed (the carriers keep about 60 days of history). */
  maxAgeDays?: number;
  /** A manual refresh or a re-add within this delay answers from the last check without asking the carrier. */
  minRecheckMs?: number;
  /** Parcels on their way per profile: each new number spends a unit of the shared 17TRACK quota. */
  maxActive?: number;
  clock?: () => number;
  autoStart?: boolean;
  /** The profile's language: the status labels and notifications are written in it, whoever asks. */
  language?: () => UiLanguage;
}

export class ParcelError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

interface Row {
  id: string;
  numero: string;
  libelle: string | null;
  transporteur: string | null;
  transporteur_id: string | null;
  statut: string;
  dernier_evenement: string | null;
  dernier_evenement_at: string | null;
  livraison_prevue: string | null;
  livre_at: string | null;
  lien: string | null;
  evenements: string;
  erreur: string | null;
  verifie_at: string | null;
  created_at: string;
  archived_at: string | null;
}

const STATUS_BY_LABEL = new Map(Object.entries(STATUS_LABELS).map(([k, v]) => [v, k as ParcelStatus]));
const MAX_EVENTS = 50;
/** Statuses a carrier falls back to when it momentarily loses a number: they never replace a known one. */
const VAGUE: ReadonlySet<ParcelStatus> = new Set(["unknown", "pending"]);

/** What the app and the cards show; the stored `statut` stays the French label of STATUS_LABELS. */
export function parcelStatusLabel(status: ParcelStatus, lang: UiLanguage): string {
  return t(`parcel.status.${status}` as MessageKey, {}, lang);
}

function toParcel(r: Row, lang: UiLanguage, checkedAt?: string): Parcel {
  const status = STATUS_BY_LABEL.get(r.statut) ?? "unknown";
  let events: TrackingEvent[] = [];
  try {
    events = JSON.parse(r.evenements) as TrackingEvent[];
  } catch {}
  const carrier = carrierOf(r.transporteur_id)?.id;
  return {
    id: r.id,
    number: r.numero,
    ...(r.libelle ? { label: r.libelle } : {}),
    ...(carrier ? { carrier } : {}),
    ...(r.transporteur ? { carrierName: r.transporteur } : {}),
    status,
    statusLabel: parcelStatusLabel(status, lang),
    ...(r.dernier_evenement ? { lastEvent: { label: r.dernier_evenement, ...(r.dernier_evenement_at ? { at: r.dernier_evenement_at } : {}) } } : {}),
    events,
    ...(r.livraison_prevue ? { estimatedDelivery: r.livraison_prevue } : {}),
    ...(r.livre_at ? { deliveredAt: r.livre_at } : {}),
    url: r.lien ?? carrierUrl(r.numero, carrier),
    ...((checkedAt ?? r.verifie_at) ? { checkedAt: checkedAt ?? r.verifie_at! } : {}),
    ...(r.erreur ? { error: r.erreur } : {}),
    createdAt: r.created_at,
    ...(r.archived_at ? { archivedAt: r.archived_at } : {}),
  };
}

/** The `::parcel` card the app draws (docs/protocol.md): the essentials, the five latest events. */
export function parcelCard(p: Parcel): string {
  const card = {
    id: p.id,
    number: p.number,
    ...(p.label ? { label: p.label } : {}),
    ...(p.carrierName ? { carrier: p.carrierName } : {}),
    status: p.status,
    statusLabel: p.statusLabel,
    ...(p.lastEvent ? { lastEvent: p.lastEvent.label, ...(p.lastEvent.at ? { lastEventAt: p.lastEvent.at } : {}) } : {}),
    ...(p.estimatedDelivery ? { eta: p.estimatedDelivery } : {}),
    url: p.url,
    events: p.events.slice(0, 5),
  };
  return `::parcel ${JSON.stringify(card)}`;
}

/**
 * Parcels live in the `colis` collection of the profile's data.db, so the app lists them like any other
 * collection and agents read `v_colis`. The gateway refreshes the ones still on their way and pushes each
 * change of status.
 */
export class Parcels {
  private timer?: ReturnType<typeof setInterval>;
  private running = false;
  private readonly clock: () => number;
  /**
   * Last check of each parcel. Writing it on the row at every check would record a history entry (with the whole
   * event list twice) every two hours per parcel: the row only changes when the carrier says something new.
   */
  private checks = new Map<string, string>();
  private inflight = new Map<string, Promise<Parcel | undefined>>();

  constructor(
    private db: Database,
    private tracker: Tracker & { configured?: boolean },
    private pusher: Pusher,
    private devices: () => Device[],
    private o: ParcelOptions = {},
  ) {
    this.clock = o.clock ?? Date.now;
  }

  get trackingConfigured(): boolean {
    return this.tracker.configured !== false;
  }

  start() {
    if (this.timer || this.o.autoStart === false) return;
    this.timer = setInterval(() => void this.tick(), this.o.intervalMs ?? 15 * 60_000);
    void this.tick();
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
  }

  private row(id: string): Row | undefined {
    return (this.db.query("SELECT * FROM colis WHERE id = ?").get(id) as Row | null) ?? undefined;
  }

  private parcel(r: Row): Parcel {
    return toParcel(r, this.lang(), this.checks.get(r.id));
  }

  private lang(): UiLanguage {
    return this.o.language?.() ?? DEFAULT_UI_LANGUAGE;
  }

  private lastCheck(r: Pick<Row, "id" | "verifie_at">): string | undefined {
    return this.checks.get(r.id) ?? r.verifie_at ?? undefined;
  }

  get(id: string): Parcel | undefined {
    const r = this.row(id);
    return r ? this.parcel(r) : undefined;
  }

  byNumber(number: string): Parcel | undefined {
    const r = this.db.query("SELECT * FROM colis WHERE numero = ? AND archived_at IS NULL").get(number) as Row | null;
    return r ? this.parcel(r) : undefined;
  }

  /** Active parcels, those still on their way first, then the latest added. */
  list(o: { includeDone?: boolean } = {}): Parcel[] {
    const done = [...FINAL_STATUSES].map((s) => STATUS_LABELS[s]);
    const rows = this.db
      .query(
        `SELECT * FROM colis WHERE archived_at IS NULL ${o.includeDone ? "" : `AND statut NOT IN (${done.map(() => "?").join(", ")})`}
         ORDER BY CASE WHEN statut IN (${done.map(() => "?").join(", ")}) THEN 1 ELSE 0 END, created_at DESC`,
      )
      .all(...(o.includeDone ? [] : done), ...done) as Row[];
    return rows.map((r) => this.parcel(r));
  }

  /** Adds the number (or renames the parcel already tracked with it), then asks the carrier right away. */
  async add(input: { number: string; label?: string; carrier?: string }): Promise<Parcel> {
    const number = cleanTrackingNumber(input.number ?? "");
    if (!number) throw new ParcelError(400, t("parcel.invalidNumber"));
    const label = head(input.label?.trim() ?? "", 120) || null;
    const carrier = carrierOf(input.carrier)?.id ?? guessParcel(number)?.carrier;
    const existing = this.byNumber(number);
    let id: string;
    if (existing) {
      id = existing.id;
      if (label) asApp(this.db, () => this.db.query(`UPDATE colis SET libelle = ?, updated_at = ${NOW_SQL} WHERE id = ?`).run(label, id));
    } else {
      const max = this.o.maxActive ?? 50;
      if (this.list().length >= max) throw new ParcelError(429, t("parcel.tooMany", { max }));
      const row = asApp(this.db, () =>
        this.db
          .query(`INSERT INTO colis (numero, libelle, transporteur, transporteur_id, statut, lien) VALUES (?, ?, ?, ?, ?, ?) RETURNING id`)
          .get(number, label, carrier ? carrierOf(carrier)!.name : null, carrier ?? null, STATUS_LABELS.unknown, carrierUrl(number, carrier)),
      ) as { id: string };
      id = row.id;
    }
    return (await this.refresh(id, { notify: false, manual: true })) ?? this.get(id)!;
  }

  archive(id: string): Parcel {
    const r = this.row(id);
    if (!r || r.archived_at) throw new ParcelError(404, t("parcel.notFound"));
    asApp(this.db, () => this.db.query(`UPDATE colis SET archived_at = ${NOW_SQL}, updated_at = ${NOW_SQL} WHERE id = ?`).run(id));
    return this.get(id)!;
  }

  /**
   * Asks the carrier; a failure is kept on the row (`erreur`) so the app and the agents can say why. Calls for
   * the same parcel share one request, and a `manual` one shortly after the last check answers from it.
   */
  refresh(id: string, o: { notify?: boolean; manual?: boolean } = {}): Promise<Parcel | undefined> {
    const running = this.inflight.get(id);
    if (running) return running;
    const p = this.check(id, o).finally(() => this.inflight.delete(id));
    this.inflight.set(id, p);
    return p;
  }

  private async check(id: string, o: { notify?: boolean; manual?: boolean }): Promise<Parcel | undefined> {
    const r = this.row(id);
    if (!r) return undefined;
    const before = this.parcel(r);
    if (!this.trackingConfigured) return before;
    const last = this.lastCheck(r);
    if (o.manual && last && this.clock() - Date.parse(last) < (this.o.minRecheckMs ?? 5 * 60_000)) return before;
    const checkedAt = new Date(this.clock()).toISOString();
    let error: string | null = null;
    try {
      const t = await this.tracker.track(r.numero, before.carrier);
      if (t) {
        const events = t.events.slice(0, MAX_EVENTS);
        const newest = events[0];
        const status = VAGUE.has(t.status) && !VAGUE.has(before.status) ? before.status : t.status;
        const next = {
          statut: STATUS_LABELS[status],
          transporteur: t.carrierName ?? r.transporteur,
          dernier_evenement: newest?.label ?? null,
          dernier_evenement_at: newest?.at ?? null,
          livraison_prevue: calendarDay(t.estimatedDelivery) ?? null,
          livre_at: status === "delivered" ? (r.livre_at ?? newest?.at ?? checkedAt) : null,
          lien: t.url ?? r.lien,
          evenements: JSON.stringify(events),
          source: t.source,
          erreur: null,
        };
        const changed = (Object.keys(next) as (keyof typeof next)[]).some((k) => next[k] !== r[k as keyof Row]);
        if (changed) {
          asApp(this.db, () =>
            this.db
              .query(
                `UPDATE colis SET statut = ?, transporteur = ?, dernier_evenement = ?, dernier_evenement_at = ?, livraison_prevue = ?, livre_at = ?,
                   lien = ?, evenements = ?, source = ?, erreur = NULL, verifie_at = ?, updated_at = ${NOW_SQL} WHERE id = ?`,
              )
              .run(next.statut, next.transporteur, next.dernier_evenement, next.dernier_evenement_at, next.livraison_prevue, next.livre_at, next.lien, next.evenements, next.source, checkedAt, id),
          );
        }
      }
    } catch (e) {
      error = ((e as Error)?.message ?? String(e)).slice(0, 300);
      if (error !== r.erreur) asApp(this.db, () => this.db.query(`UPDATE colis SET erreur = ?, verifie_at = ? WHERE id = ?`).run(error, checkedAt, id));
    }
    this.checks.set(id, checkedAt);
    const after = this.get(id)!;
    if (o.notify !== false && after.status !== before.status && !VAGUE.has(after.status)) await this.notify(after);
    return after;
  }

  private async notify(p: Parcel) {
    const lang = this.lang();
    const title = t("parcel.pushTitle", { parcel: p.label ?? p.number, status: p.statusLabel.toLowerCase() }, lang);
    const body = p.lastEvent?.label ?? `${p.carrierName ?? t("parcel.carrier", {}, lang)} · ${p.number}`;
    const url = `nuo://data/colis/${p.id}`;
    await Promise.all(
      this.devices().map((d) =>
        this.pusher.send(d, { title, body, category: "nuo.parcel", messageId: `parcel-${p.id}-${p.status}`, url, destination: { kind: "link", url } }).catch(() => {}),
      ),
    );
  }

  /** Refreshes, one at a time, the parcels still on their way whose last check is old enough. */
  async tick(): Promise<number> {
    if (this.running || !this.trackingConfigured) return 0;
    this.running = true;
    try {
      const now = this.clock();
      const staleBefore = new Date(now - (this.o.refreshMs ?? 2 * 3600_000)).toISOString();
      const createdAfter = new Date(now - (this.o.maxAgeDays ?? 60) * 86400_000).toISOString();
      const done = [...FINAL_STATUSES].map((s) => STATUS_LABELS[s]);
      const rows = this.db
        .query(`SELECT id, verifie_at FROM colis WHERE archived_at IS NULL AND statut NOT IN (${done.map(() => "?").join(", ")}) AND created_at > ?`)
        .all(...done, createdAfter) as Pick<Row, "id" | "verifie_at">[];
      const stale = rows
        .map((r) => ({ id: r.id, at: this.lastCheck(r) ?? "" }))
        .filter((r) => r.at < staleBefore)
        .sort((a, b) => a.at.localeCompare(b.at));
      for (const { id } of stale) await this.refresh(id);
      return stale.length;
    } finally {
      this.running = false;
    }
  }
}
