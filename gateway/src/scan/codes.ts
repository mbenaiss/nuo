/** What a scanned or typed code is: a retail product (GTIN) or a parcel tracking number, and from which carrier. */

export type ScanKind = "food" | "cosmetic" | "parcel";
export const SCAN_KINDS: readonly ScanKind[] = ["food", "cosmetic", "parcel"];

export type CarrierId = "laposte" | "ups" | "dhl" | "fedex" | "gls" | "dpd" | "mondial_relay" | "amazon" | "cainiao" | "post";

export interface Carrier {
  id: CarrierId;
  name: string;
  /** Public tracking page of the number, opened from the app. */
  url(number: string): string;
}

const enc = encodeURIComponent;

export const CARRIERS: Record<CarrierId, Carrier> = {
  laposte: { id: "laposte", name: "La Poste / Colissimo", url: (n) => `https://www.laposte.fr/outils/suivre-vos-envois?code=${enc(n)}` },
  ups: { id: "ups", name: "UPS", url: (n) => `https://www.ups.com/track?loc=fr_FR&tracknum=${enc(n)}` },
  dhl: { id: "dhl", name: "DHL", url: (n) => `https://www.dhl.com/fr-fr/home/suivi.html?tracking-id=${enc(n)}` },
  fedex: { id: "fedex", name: "FedEx", url: (n) => `https://www.fedex.com/fedextrack/?trknbr=${enc(n)}` },
  gls: { id: "gls", name: "GLS", url: (n) => `https://gls-group.com/FR/fr/suivi-colis/?match=${enc(n)}` },
  dpd: { id: "dpd", name: "DPD", url: (n) => `https://trace.dpd.fr/fr/trace/${enc(n)}` },
  mondial_relay: { id: "mondial_relay", name: "Mondial Relay", url: (n) => `https://www.mondialrelay.fr/suivi-de-colis/?NumeroExpedition=${enc(n)}` },
  amazon: { id: "amazon", name: "Amazon Logistics", url: (n) => `https://track.amazon.com/tracking/${enc(n)}` },
  cainiao: { id: "cainiao", name: "Cainiao (AliExpress)", url: (n) => `https://global.cainiao.com/detail.htm?mailNoList=${enc(n)}` },
  post: { id: "post", name: "Poste internationale", url: (n) => `https://t.17track.net/fr#nums=${enc(n)}` },
};

export function carrierOf(id: string | null | undefined): Carrier | undefined {
  return id && id in CARRIERS ? CARRIERS[id as CarrierId] : undefined;
}

/**
 * Formats with letters are distinctive; pure digit ones (GLS, DPD, DHL Express, FedEx, Mondial Relay) collide
 * with each other and with GTINs, so they only make a parcel a candidate.
 */
const DISTINCT: [RegExp, CarrierId][] = [
  [/1Z[0-9A-Z]{16}/, "ups"],
  [/TBA\d{12}/, "amazon"],
  [/(?:JJD|JVGL)\d{10,20}/, "dhl"],
  [/\d[A-Z]\d{11}/, "laposte"],
  [/[A-Z]{2}\d{9}FR/, "laposte"],
  [/LP\d{14,16}/, "cainiao"],
  [/[A-Z]{2}\d{9}[A-Z]{2}/, "post"],
];

const NUMERIC: [RegExp, CarrierId][] = [
  [/^\d{8}$/, "mondial_relay"],
  [/^\d{10}$/, "dhl"],
  [/^\d{11}$/, "gls"],
  [/^\d{12}$/, "fedex"],
  [/^\d{14}$/, "dpd"],
  [/^\d{15}$/, "fedex"],
];

export interface ParcelGuess {
  number: string;
  carrier?: CarrierId;
  /** The format names one carrier only (letters in it). */
  distinctive: boolean;
}

export interface CodeInfo {
  /** Trimmed and uppercased, spaces removed. */
  code: string;
  /** A GTIN with a valid check digit (EAN-8, UPC-A, EAN-13, GTIN-14). */
  gtin: boolean;
  parcel?: ParcelGuess;
}

/** Barcode symbologies that only ever carry a retail GTIN (DataScanner names, lowercased). */
const RETAIL_SYMBOLOGIES = new Set(["ean8", "ean13", "upce", "upca", "ean-8", "ean-13", "upc-e", "upc-a"]);

export function isRetailSymbology(symbology: string | undefined): boolean {
  return !!symbology && RETAIL_SYMBOLOGIES.has(symbology.toLowerCase().replace(/^vnbarcodesymbology/, ""));
}

export function normalizeCode(raw: string): string {
  return raw.trim().toUpperCase().replace(/[\s-]+/g, "");
}

export function validGtin(code: string): boolean {
  if (!/^\d+$/.test(code) || ![8, 12, 13, 14].includes(code.length)) return false;
  const digits = [...code].map(Number);
  const check = digits.pop()!;
  const sum = digits.reverse().reduce((s, d, i) => s + d * (i % 2 === 0 ? 3 : 1), 0);
  return (10 - (sum % 10)) % 10 === check;
}

/**
 * A label barcode often carries more than the tracking number (routing prefix, weight, service code): a
 * distinctive number found inside wins over the raw payload.
 */
export function guessParcel(raw: string): ParcelGuess | undefined {
  const code = normalizeCode(raw);
  if (!/^[0-9A-Z%]{8,60}$/.test(code)) return undefined;
  for (const [re, carrier] of DISTINCT) {
    const m = code.match(new RegExp(`^${re.source}$`)) ?? code.match(re);
    if (m) return { number: m[0], carrier, distinctive: true };
  }
  for (const [re, carrier] of NUMERIC) if (re.test(code)) return { number: code, carrier, distinctive: false };
  if (/^\d{16,22}$/.test(code) || /^(?=.*\d)(?=.*[A-Z])[0-9A-Z]{10,30}$/.test(code)) return { number: code, distinctive: false };
  return undefined;
}

export function inspectCode(raw: string): CodeInfo {
  const code = normalizeCode(raw);
  return { code, gtin: validGtin(code), parcel: guessParcel(code) };
}

/** Tracking numbers stored and sent to providers: 6 to 40 letters and digits, at least one digit. */
export function cleanTrackingNumber(raw: string): string | undefined {
  const code = normalizeCode(raw);
  const guess = guessParcel(code);
  const number = guess?.distinctive ? guess.number : code;
  return /^(?=.*\d)[0-9A-Z]{6,40}$/.test(number) ? number : undefined;
}
