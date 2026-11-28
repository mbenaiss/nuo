import type { Database } from "bun:sqlite";
import type { UiLanguage } from "../i18n/language";
import type { Pusher } from "../push/apns";
import type { Device } from "../store/store";
import { cosmeticCard, type CosmeticProduct } from "./cards";
import { guessParcel } from "./codes";
import { parcelCard, Parcels, type Parcel, type ParcelOptions } from "./parcels";
import { ProductLookup, type Fetch, type ProductSources } from "./products";
import { Scanner } from "./scan";
import { FINAL_STATUSES, type Tracker } from "./tracking";

export interface ScanOptions {
  tracker: Tracker & { configured?: boolean };
  fetcher?: Fetch;
  parcels?: ParcelOptions;
  products?: ProductSources;
  /** The profile's language, for the parcels' labels and notifications. */
  language?: () => UiLanguage;
}

export interface ScanServices {
  scanner: Scanner;
  parcels: Parcels;
  products: ProductLookup;
  tools: ScanTools;
  start(): void;
  stop(): void;
}

export function createScanServices(db: Database, pusher: Pusher, devices: () => Device[], o: ScanOptions): ScanServices {
  const products = new ProductLookup(o.fetcher, o.products);
  const parcels = new Parcels(db, o.tracker, pusher, devices, { ...o.parcels, ...(o.language ? { language: o.language } : {}) });
  return {
    scanner: new Scanner(products, parcels),
    parcels,
    products,
    tools: new ScanTools(products, parcels),
    start: () => parcels.start(),
    stop: () => parcels.stop(),
  };
}

const fmtDate = (iso: string) => new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/Paris", dateStyle: "medium", timeStyle: "short" }).format(new Date(iso));
const fmtDay = (day: string) => new Intl.DateTimeFormat("en-GB", { timeZone: "UTC", weekday: "long", day: "numeric", month: "long" }).format(new Date(`${day}T00:00:00Z`));

function describeParcel(p: Parcel): string {
  return [
    `- ${p.label ? `${p.label} · ` : ""}${p.number}${p.carrierName ? ` (${p.carrierName})` : ""}: ${p.statusLabel}`,
    p.lastEvent ? `  last event: ${p.lastEvent.label}${p.lastEvent.at ? `, ${fmtDate(p.lastEvent.at)}` : ""}` : "",
    p.estimatedDelivery && !FINAL_STATUSES.has(p.status) ? `  expected delivery: ${fmtDay(p.estimatedDelivery)}` : "",
    p.error ? `  last check failed: ${p.error}` : "",
  ]
    .filter(Boolean)
    .join("\n");
}

/**
 * `/colis 6A 123 456 789 01 Chaussures` gives the first word as the number and the rest as the label: the
 * following words with digits and no lowercase letter are glued back onto the number, until it reads as a
 * carrier's own format.
 */
export function splitNumber(number: string, label: string | undefined): { number: string; label?: string } {
  const words = (label ?? "").split(/\s+/).filter(Boolean);
  let n = number.trim();
  while (words.length && /\d/.test(words[0]!) && !/[a-z]/.test(words[0]!) && !guessParcel(n)?.distinctive) n += ` ${words.shift()}`;
  const rest = words.join(" ");
  return { number: n, ...(rest ? { label: rest } : {}) };
}

export class ToolInputError extends Error {}

/** The `nuo` MCP tools of src/scan/tools.ts; each answer is text the agent relays, cards included. */
export class ScanTools {
  constructor(
    private products: ProductLookup,
    private parcels: Parcels,
  ) {}

  async call(name: string, a: Record<string, unknown>): Promise<string> {
    switch (name) {
      case "parcel_track": {
        if (typeof a.number !== "string" || !a.number.trim()) throw new ToolInputError("number is required");
        const p = await this.parcels.add(splitNumber(a.number, typeof a.label === "string" ? a.label : undefined));
        const notes = [
          !this.parcels.trackingConfigured
            ? "No tracking key is set on the gateway (NUO_LAPOSTE_OKAPI_KEY, NUO_SHIP24_API_KEY, NUO_SEVENTEENTRACK_API_KEY): the parcel is saved with the carrier's link, without an automatic status."
            : "",
          p.error ? `The carrier did not answer: ${p.error}` : "",
          "The gateway checks the parcel again every 2 hours and notifies each change of status.",
        ].filter(Boolean);
        return `${parcelCard(p)}\n${notes.join("\n")}`;
      }
      case "parcel_list": {
        const all = this.parcels.list({ includeDone: a.all === true });
        if (!all.length) return a.all === true ? "No tracked parcel." : "No parcel on its way. (all=true to see the delivered parcels.)";
        return `${all.length} parcel(s):\n${all.map(describeParcel).join("\n")}`;
      }
      case "product_lookup": {
        const code = typeof a.barcode === "string" ? a.barcode.replace(/\D/g, "") : "";
        if (code.length < 8) throw new ToolInputError("barcode is required (8 to 14 digits)");
        const product = a.kind === "food" ? await this.products.food(code) : a.kind === "cosmetic" ? await this.products.cosmeticAnywhere(code) : await this.products.any(code);
        if (!product) return `Code ${code} is in neither Open Food Facts nor Open Beauty Facts. Ask the user what the product is, or for a photo of the label.`;
        if (product.kind === "food") {
          return `::product ${JSON.stringify({ barcode: code })}\nFood: ${product.name}${product.brand ? ` (${product.brand})` : ""}.`;
        }
        return `${cosmeticCard(product)}\n${cosmeticSummary(product)}`;
      }
      default:
        throw new ToolInputError(`unknown tool ${name}`);
    }
  }
}

export function cosmeticSummary(p: CosmeticProduct): string {
  const a = p.analysis;
  if (a.score === undefined) return `Cosmetic: ${p.name}. No ingredients in Open Beauty Facts: no score possible.`;
  const flagged = a.ingredients.filter((i) => i.risk !== "none");
  const lines = flagged.map((i) => `- ${i.name}: ${i.risk} risk (${i.reason})`);
  return [`Cosmetic: ${p.name}${p.brand ? ` (${p.brand})` : ""}, score ${a.score}/100.`, ...(lines.length ? ["Risky ingredients:", ...lines] : ["No risky ingredient found."])].join("\n");
}
