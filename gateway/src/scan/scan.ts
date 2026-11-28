import { carrierOf, cleanTrackingNumber, guessParcel, inspectCode, isRetailSymbology, SCAN_KINDS, type CarrierId, type ScanKind } from "./codes";
import type { Parcel, Parcels } from "./parcels";
import { LookupError, type CosmeticProduct, type FoodSummary, type ProductLookup } from "./products";
import { carrierUrl } from "./tracking";
import { t } from "../i18n/language";

export interface ParcelDetection {
  number: string;
  carrier?: CarrierId;
  carrierName?: string;
  url: string;
  /** Already followed: the app shows it instead of offering to add it. */
  tracked?: Parcel;
}

/** Answer of `GET /api/scan/:code` (docs/protocol.md). */
export interface ScanResult {
  code: string;
  /** "unknown": the app asks which of `candidates` it is, the likeliest first. */
  kind: ScanKind | "unknown";
  candidates: ScanKind[];
  food?: FoodSummary;
  cosmetic?: CosmeticProduct;
  parcel?: ParcelDetection;
  /** The product bases could not be reached: the code may still be a product. */
  error?: string;
}

export interface ScanOptions {
  /** Chosen by the user after an "unknown" answer. */
  kind?: ScanKind;
  /** DataScanner symbology (ean13, code128, qr…): a retail one is never a parcel label. */
  symbology?: string;
}

export class Scanner {
  constructor(
    private products: ProductLookup,
    private parcels: Parcels,
  ) {}

  private detection(number: string, carrier?: CarrierId): ParcelDetection {
    const tracked = this.parcels.byNumber(number);
    return {
      number,
      ...(carrier ? { carrier, carrierName: carrierOf(carrier)!.name } : {}),
      url: tracked?.url ?? carrierUrl(number, carrier),
      ...(tracked ? { tracked } : {}),
    };
  }

  private parcelResult(code: string, number: string, carrier?: CarrierId): ScanResult {
    return { code, kind: "parcel", candidates: ["parcel"], parcel: this.detection(number, carrier) };
  }

  async scan(raw: string, o: ScanOptions = {}): Promise<ScanResult> {
    const info = inspectCode(raw);
    const { code } = info;
    if (!code) return { code, kind: "unknown", candidates: [...SCAN_KINDS], error: t("scan.emptyCode") };

    if (o.kind === "parcel") {
      const number = cleanTrackingNumber(code);
      if (!number) return { code, kind: "unknown", candidates: ["food", "cosmetic"], error: t("scan.notTracking") };
      return this.parcelResult(code, number, guessParcel(number)?.carrier);
    }
    if (o.kind === "food" || o.kind === "cosmetic") {
      try {
        const product = o.kind === "food" ? await this.products.food(code) : await this.products.cosmeticAnywhere(code);
        return { code, kind: o.kind, candidates: [o.kind], ...(product ? { [o.kind]: product } : {}) };
      } catch (e) {
        return { code, kind: o.kind, candidates: [o.kind], error: (e as Error).message };
      }
    }

    const retail = isRetailSymbology(o.symbology);
    if (info.parcel?.distinctive && !retail) return this.parcelResult(code, info.parcel.number, info.parcel.carrier);
    if (info.gtin) {
      let error: string | undefined;
      try {
        const product = await this.products.any(code);
        if (product?.kind === "food") return { code, kind: "food", candidates: ["food"], food: product };
        if (product?.kind === "cosmetic") return { code, kind: "cosmetic", candidates: ["cosmetic"], cosmetic: product };
      } catch (e) {
        if (!(e instanceof LookupError)) throw e;
        error = e.message;
      }
      return { code, kind: "unknown", candidates: ["food", "cosmetic", "parcel"], ...(error ? { error } : {}) };
    }
    if (info.parcel && !retail) return this.parcelResult(code, info.parcel.number, info.parcel.carrier);
    return { code, kind: "unknown", candidates: ["parcel", "food", "cosmetic"] };
  }
}
