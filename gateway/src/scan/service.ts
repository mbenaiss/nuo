import type { Database } from "bun:sqlite";
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
  const parcels = new Parcels(db, o.tracker, pusher, devices, o.parcels);
  return {
    scanner: new Scanner(products, parcels),
    parcels,
    products,
    tools: new ScanTools(products, parcels),
    start: () => parcels.start(),
    stop: () => parcels.stop(),
  };
}

const fmtDate = (iso: string) => new Intl.DateTimeFormat("fr-FR", { timeZone: "Europe/Paris", dateStyle: "medium", timeStyle: "short" }).format(new Date(iso));
const fmtDay = (day: string) => new Intl.DateTimeFormat("fr-FR", { timeZone: "UTC", weekday: "long", day: "numeric", month: "long" }).format(new Date(`${day}T00:00:00Z`));

function describeParcel(p: Parcel): string {
  return [
    `- ${p.label ? `${p.label} · ` : ""}${p.number}${p.carrierName ? ` (${p.carrierName})` : ""} : ${p.statusLabel}`,
    p.lastEvent ? `  dernier événement : ${p.lastEvent.label}${p.lastEvent.at ? `, ${fmtDate(p.lastEvent.at)}` : ""}` : "",
    p.estimatedDelivery && !FINAL_STATUSES.has(p.status) ? `  livraison prévue : ${fmtDay(p.estimatedDelivery)}` : "",
    p.error ? `  dernière vérification en échec : ${p.error}` : "",
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
        if (typeof a.number !== "string" || !a.number.trim()) throw new ToolInputError("number requis");
        const p = await this.parcels.add(splitNumber(a.number, typeof a.label === "string" ? a.label : undefined));
        const notes = [
          !this.parcels.trackingConfigured
            ? "Aucune clé de suivi n'est configurée sur la passerelle (NUO_LAPOSTE_OKAPI_KEY, NUO_SHIP24_API_KEY, NUO_SEVENTEENTRACK_API_KEY) : le colis est enregistré avec le lien du transporteur, sans statut automatique."
            : "",
          p.error ? `Le transporteur n'a pas répondu : ${p.error}` : "",
          "La passerelle revérifie le colis toutes les 2 heures et notifie chaque changement de statut.",
        ].filter(Boolean);
        return `${parcelCard(p)}\n${notes.join("\n")}`;
      }
      case "parcel_list": {
        const all = this.parcels.list({ includeDone: a.all === true });
        if (!all.length) return a.all === true ? "Aucun colis suivi." : "Aucun colis en cours. (all=true pour voir les colis livrés.)";
        return `${all.length} colis :\n${all.map(describeParcel).join("\n")}`;
      }
      case "product_lookup": {
        const code = typeof a.barcode === "string" ? a.barcode.replace(/\D/g, "") : "";
        if (code.length < 8) throw new ToolInputError("barcode requis (8 à 14 chiffres)");
        const product = a.kind === "food" ? await this.products.food(code) : a.kind === "cosmetic" ? await this.products.cosmeticAnywhere(code) : await this.products.any(code);
        if (!product) return `Code ${code} absent d'Open Food Facts et d'Open Beauty Facts. Demande à l'utilisateur ce qu'est le produit ou une photo de l'étiquette.`;
        if (product.kind === "food") {
          return `::product ${JSON.stringify({ barcode: code })}\nAliment : ${product.name}${product.brand ? ` (${product.brand})` : ""}.`;
        }
        return `${cosmeticCard(product)}\n${cosmeticSummary(product)}`;
      }
      default:
        throw new ToolInputError(`outil inconnu ${name}`);
    }
  }
}

export function cosmeticSummary(p: CosmeticProduct): string {
  const a = p.analysis;
  if (a.score === undefined) return `Cosmétique : ${p.name}. Ingrédients non renseignés dans Open Beauty Facts : pas de note possible.`;
  const flagged = a.ingredients.filter((i) => i.risk !== "none");
  const lines = flagged.map((i) => `- ${i.name} : risque ${i.risk === "high" ? "élevé" : i.risk === "moderate" ? "modéré" : "faible"} (${i.reason})`);
  return [`Cosmétique : ${p.name}${p.brand ? ` (${p.brand})` : ""}, note ${a.score}/100.`, ...(lines.length ? ["Ingrédients à risque :", ...lines] : ["Aucun ingrédient à risque repéré."])].join("\n");
}
