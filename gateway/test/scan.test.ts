import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDataDb } from "../src/data/db";
import { cleanTrackingNumber, guessParcel, inspectCode, validGtin } from "../src/scan/codes";
import { analyzeCosmetic, assessIngredient, splitIngredients } from "../src/scan/cosmetics";
import { Parcels, type ParcelOptions } from "../src/scan/parcels";
import { splitNumber } from "../src/scan/service";
import { looksLikeInci, LookupError, ProductLookup, type Fetch } from "../src/scan/products";
import { Scanner } from "../src/scan/scan";
import { LaPosteTracker, laPosteStatus, SeventeenTrackTracker, Ship24Tracker, ship24Status, trackerFromEnv, TrackerChain, type Tracker, type TrackingResult } from "../src/scan/tracking";
import { botConfig, FakePusher, Socket, startTestApp, type TestApp } from "./helpers";

const NUTELLA = "3017620422003";
const CERAVE = "3337875597197";
const COLISSIMO = "6A12345678901";

const json = (data: unknown, status = 200) => new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });
const notFound = (code: string) => json({ code, status: 0, status_verbose: "product not found" }, 404);

/** Open Food Facts knows Nutella, Open Beauty Facts the CeraVe cleanser; every other code is unknown to both. */
function productBases(calls: string[] = []): Fetch {
  return async (input) => {
    const url = String(input);
    calls.push(url);
    if (url.includes("openfoodfacts") && url.includes(`/${NUTELLA}.json`)) {
      return json({ status: 1, product: { product_name_fr: "Nutella", brands: "Ferrero,Nutella", quantity: "400 g", nutriscore_grade: "e", nova_group: 4, image_front_url: "https://images.openfoodfacts.org/nutella.jpg" } });
    }
    if (url.includes("openbeautyfacts") && url.includes(`/${CERAVE}.json`)) {
      return json({
        status: 1,
        product: {
          product_name: "Hydrating Foaming Oil Cleanser",
          brands: "CeraVe",
          quantity: "236ml",
          ingredients_text: "Aqua, Glycerin, Sodium Lauroyl Sarcosinate, Parfum (Fragrance), Propylparaben, Limonene, Ceramide NP",
          labels_tags: ["en:not-tested-on-animals"],
          periods_after_opening_tags: ["en:12-months"],
        },
      });
    }
    const code = url.match(/product\/([^/.]+)\.json/)?.[1] ?? "";
    return notFound(code);
  };
}

describe("codes", () => {
  test("GTINs need a valid check digit", () => {
    expect(validGtin(NUTELLA)).toBe(true);
    expect(validGtin("3017620422004")).toBe(false);
    expect(validGtin("96385074")).toBe(true);
    expect(validGtin("012345678905")).toBe(true);
    expect(validGtin(COLISSIMO)).toBe(false);
  });

  test("distinctive tracking numbers name their carrier, even inside a label barcode", () => {
    expect(guessParcel("1Z999AA10123456784")).toEqual({ number: "1Z999AA10123456784", carrier: "ups", distinctive: true });
    expect(guessParcel("6a 1234 5678 901")).toEqual({ number: COLISSIMO, carrier: "laposte", distinctive: true });
    expect(guessParcel("LU680211095FR")).toEqual({ number: "LU680211095FR", carrier: "laposte", distinctive: true });
    expect(guessParcel("RR123456789CN")).toMatchObject({ carrier: "post", distinctive: true });
    expect(guessParcel("TBA123456789012")).toMatchObject({ carrier: "amazon" });
    expect(guessParcel("%0075010 6A12345678901 250")).toEqual({ number: COLISSIMO, carrier: "laposte", distinctive: true });
  });

  test("digit-only numbers are only candidates, and short codes are nothing", () => {
    expect(guessParcel("12345678901")).toEqual({ number: "12345678901", carrier: "gls", distinctive: false });
    expect(guessParcel("1234")).toBeUndefined();
    expect(inspectCode(` ${NUTELLA} `)).toEqual({ code: NUTELLA, gtin: true, parcel: undefined });
  });

  test("tracking numbers are cleaned before being stored", () => {
    expect(cleanTrackingNumber(" 6a-1234 5678 901 ")).toBe(COLISSIMO);
    expect(cleanTrackingNumber("%0075010 6A12345678901 250")).toBe(COLISSIMO);
    expect(cleanTrackingNumber("abc")).toBeUndefined();
    expect(cleanTrackingNumber("colis de maman")).toBeUndefined();
  });
});

describe("cosmetic analysis", () => {
  test("splits an INCI list without breaking parentheses", () => {
    expect(splitIngredients("Ingredients: Aqua, Parfum (Fragrance, Limonene), CI 77491 (Iron Oxides).")).toEqual(["Aqua", "Parfum (Fragrance, Limonene)", "CI 77491 (Iron Oxides)"]);
  });

  test("each ingredient takes its worst risk", () => {
    expect(assessIngredient("Propylparaben")).toMatchObject({ risk: "high" });
    expect(assessIngredient("Methylparaben")).toMatchObject({ risk: "moderate" });
    expect(assessIngredient("Linalool")).toMatchObject({ risk: "low" });
    expect(assessIngredient("Glycerin")).toEqual({ name: "Glycerin", risk: "none" });
    expect(assessIngredient("Aqua")).toEqual({ name: "Aqua", risk: "none" });
  });

  test("TEA and DEA count as INCI words only, not in tea tree or green tea", () => {
    expect(assessIngredient("TEA-Lauryl Sulfate")).toMatchObject({ risk: "moderate", reason: "Peut former des nitrosamines" });
    expect(assessIngredient("Cocamide DEA")).toMatchObject({ risk: "moderate" });
    expect(assessIngredient("Melaleuca Alternifolia (Tea Tree) Leaf Oil")).toMatchObject({ risk: "none" });
    expect(assessIngredient("Camellia Sinensis (Green Tea) Leaf Extract")).toMatchObject({ risk: "none" });
  });

  test("the worst ingredient caps the score, each other flagged one takes a few points", () => {
    expect(analyzeCosmetic(["Aqua", "Glycerin", "Butyrospermum Parkii Butter"])).toMatchObject({ score: 100, verdict: "excellent" });
    expect(analyzeCosmetic(["Aqua", "Parfum", "Limonene"])).toMatchObject({ score: 72, verdict: "good", counts: { high: 0, moderate: 0, low: 2 } });
    expect(analyzeCosmetic(["Aqua", "Sodium Lauryl Sulfate"])).toMatchObject({ score: 50, verdict: "good" });
    expect(analyzeCosmetic(["Aqua", "Propylparaben", "Parfum"])).toMatchObject({ score: 21, verdict: "bad" });
    expect(analyzeCosmetic([])).toEqual({ verdict: "unknown", ingredients: [], counts: { high: 0, moderate: 0, low: 0 } });
  });
});

describe("product lookup", () => {
  test("a food comes from Open Food Facts, a cosmetic from Open Beauty Facts", async () => {
    const lookup = new ProductLookup(productBases());
    expect(await lookup.any(NUTELLA)).toEqual({
      kind: "food",
      barcode: NUTELLA,
      name: "Nutella",
      brand: "Ferrero",
      imageUrl: "https://images.openfoodfacts.org/nutella.jpg",
      quantity: "400 g",
      nutriscore: "e",
      nova: 4,
    });
    const cerave = await lookup.any(CERAVE);
    expect(cerave).toMatchObject({ kind: "cosmetic", name: "Hydrating Foaming Oil Cleanser", brand: "CeraVe", periodAfterOpening: "12 mois", labels: ["not tested on animals"] });
    expect(cerave?.kind === "cosmetic" && cerave.analysis).toMatchObject({ score: 17, verdict: "bad", counts: { high: 1, moderate: 0, low: 2 } });
    expect(await lookup.any("3760000000017")).toBeUndefined();
  });

  test("a 200 with status 0 is a miss, an unreachable base an error", async () => {
    const lookup = new ProductLookup(async () => json({ code: "00000017", status: 0, status_verbose: "no code or invalid code" }));
    expect(await lookup.food("0000000000017")).toBeUndefined();
    const down = new ProductLookup(async () => {
      throw new TypeError("fetch failed");
    });
    expect(down.any(NUTELLA)).rejects.toBeInstanceOf(LookupError);
  });

  test("a cosmetic Open Beauty Facts lacks comes from INCI API, then a name from UPCitemdb, then a photographed list", async () => {
    const SWISS = "7618900911239";
    const UNKNOWN = "7610000000017";
    const calls: string[] = [];
    const memory = new Map<string, { name?: string; brand?: string; ingredients: string }>();
    const fetcher: Fetch = async (input, init) => {
      const url = String(input);
      calls.push(url);
      if (url.startsWith("https://inciapi.com/v1/products/")) {
        expect(new Headers(init?.headers).get("x-api-key")).toBe("inci_fixture_k3y");
        if (url.endsWith(SWISS)) return json({ product: { barcode: SWISS, name: "Crème mains Amande", brand: "Weleda", details: { inci: ["Aqua", "Prunus Amygdalus Dulcis Oil", "Parfum", "Limonene"] } } });
        return json({ error: "Not found" }, 404);
      }
      if (url.startsWith("https://api.upcitemdb.com/")) {
        if (url.endsWith(UNKNOWN)) return json({ code: "OK", total: 1, items: [{ title: "Gel douche Avoine 250 ml", brand: "Migros Plus" }] });
        return json({ code: "OK", total: 0, items: [] });
      }
      return notFound("x");
    };
    const lookup = new ProductLookup(fetcher, { inciApiKey: "inci_fixture_k3y", memory: { get: (c) => memory.get(c), set: (c, e) => void memory.set(c, e) } });

    const fromInci = await lookup.cosmeticAnywhere(SWISS);
    expect(fromInci).toMatchObject({ source: "inciapi", name: "Crème mains Amande", brand: "Weleda" });
    expect(fromInci!.analysis.ingredients.map((i) => i.name.toLowerCase())).toContain("limonene");

    const named = await lookup.cosmeticAnywhere(UNKNOWN);
    expect(named).toMatchObject({ source: "upcitemdb", name: "Gel douche Avoine 250 ml", brand: "Migros Plus" });
    expect(named!.analysis.ingredients).toEqual([]);

    const photo = lookup.rememberIngredients(UNKNOWN, { name: "Gel douche Avoine", ingredients: "AQUA, SODIUM LAURETH SULFATE, COCAMIDOPROPYL BETAINE, AVENA SATIVA KERNEL EXTRACT, PARFUM, METHYLISOTHIAZOLINONE" });
    expect(photo.source).toBe("photo");
    expect(photo.analysis.counts.high).toBeGreaterThan(0);
    calls.length = 0;
    expect(await lookup.cosmetic(UNKNOWN)).toMatchObject({ source: "photo", name: "Gel douche Avoine" });
    expect(calls).toEqual([]);
    expect(() => lookup.rememberIngredients(UNKNOWN, { ingredients: "  ,  " })).toThrow(LookupError);
  });

  test("a cosmetic filed in Open Food Facts as food is shown as a cosmetic, not as its wrong food name", async () => {
    const SVR = "3662361003402";
    const fetcher: Fetch = async (input) => {
      const url = String(input);
      if (url.includes("openbeautyfacts")) return json({ code: SVR, status: 0, status_verbose: "product found with a different product type: food" }, 404);
      if (url.includes("openfoodfacts")) {
        return json({
          status: 1,
          product: {
            product_name: "Spaghetti",
            brands: "SVR",
            categories_tags: ["en:plant-based-foods-and-beverages", "en:pastas", "en:spaghetti"],
            ingredients_text: "AQUA/WATER/EAU, GLYCERIN, GLUCONOLACTONE, DECYL GLUCOSIDE, DISODIUM COCOYL GLUTAMATE, COCO-BETAINE, SALICYLIC ACID, SODIUM HYDROXIDE, PARFUM (FRAGRANCE)",
          },
        });
      }
      return notFound(SVR);
    };
    const result = await new Scanner(new ProductLookup(fetcher), { byNumber: () => undefined } as never).scan(SVR);
    expect(result.kind).toBe("cosmetic");
    expect(result.food).toBeUndefined();
    expect(result.cosmetic).toMatchObject({ name: "Cosmétique SVR", brand: "SVR", source: "openfoodfacts" });
    expect(result.cosmetic!.analysis.ingredients.length).toBeGreaterThan(5);
    expect(looksLikeInci("Semoule de blé dur, eau, sel")).toBe(false);
    expect(looksLikeInci("Aqua, Glycerin, Parfum")).toBe(true);
  });

  test("without an INCI API key the base is never asked", async () => {
    const calls: string[] = [];
    await new ProductLookup(productBases(calls)).cosmetic("7618900911239");
    expect(calls.some((u) => u.includes("inciapi.com"))).toBe(false);
  });

  test("an outage page served as a 404 is an error, not an unknown cosmetic", async () => {
    const outage = new ProductLookup(async () => new Response("<!DOCTYPE html><title>Unscheduled downtime - Open Food Facts</title>", { status: 404, headers: { "content-type": "text/html" } }));
    expect(outage.cosmetic("7618900911239")).rejects.toBeInstanceOf(LookupError);
    const scanner = new Scanner(outage, { byNumber: () => undefined } as never);
    const result = await scanner.scan("7618900911239", { kind: "cosmetic" });
    expect(result.cosmetic).toBeUndefined();
    expect(result.error).toContain("indisponible");
  });

  test("one base down does not hide the other's answer", async () => {
    const lookup = new ProductLookup(async (input) => {
      if (String(input).includes("openbeautyfacts")) return new Response("busy", { status: 503 });
      return productBases()(input);
    });
    expect(await lookup.any(NUTELLA)).toMatchObject({ kind: "food", name: "Nutella" });
  });
});

describe("trackers", () => {
  test("La Poste event codes map to a status", () => {
    expect(laPosteStatus("DI1", true)).toBe("delivered");
    expect(laPosteStatus("DI2", true)).toBe("returned");
    expect(laPosteStatus("AG1", false)).toBe("available_for_pickup");
    expect(laPosteStatus("MD2", false)).toBe("out_for_delivery");
    expect(laPosteStatus("ET3", false)).toBe("in_transit");
    expect(laPosteStatus("ND1", false)).toBe("exception");
    expect(laPosteStatus("DR1", false)).toBe("info_received");
  });

  test("La Poste answers its own numbers only, with the key in X-Okapi-Key", async () => {
    const seen: Request[] = [];
    const tracker = new LaPosteTracker("okapi-test-key", async (input, init) => {
      seen.push(new Request(String(input), init));
      return json({
        lang: "fr_FR",
        returnCode: 200,
        shipment: {
          idShip: "LU680211095FR",
          product: "colissimo",
          isFinal: false,
          url: "https://www.laposte.fr/outils/suivre-vos-envois?code=LU680211095FR",
          event: [
            { code: "MD2", label: "Votre colis est en cours de livraison", date: "2026-10-24T08:12:00+02:00" },
            { code: "PC1", label: "Votre colis est pris en charge par La Poste", date: "2026-10-22T18:40:00+02:00" },
          ],
        },
      });
    });
    expect(await tracker.track("1Z999AA10123456784", "ups")).toBeUndefined();
    const r = await tracker.track("LU680211095FR", "laposte");
    expect(seen[0]!.headers.get("x-okapi-key")).toBe("okapi-test-key");
    expect(seen[0]!.url).toBe("https://api.laposte.fr/suivi/v2/idships/LU680211095FR?lang=fr_FR");
    expect(r).toEqual({
      status: "out_for_delivery",
      carrierName: "Colissimo",
      events: [
        { label: "Votre colis est en cours de livraison", at: "2026-10-24T06:12:00.000Z" },
        { label: "Votre colis est pris en charge par La Poste", at: "2026-10-22T16:40:00.000Z" },
      ],
      url: "https://www.laposte.fr/outils/suivre-vos-envois?code=LU680211095FR",
      source: "laposte",
    });
    const unknown = new LaPosteTracker("k", async () => json({ returnCode: 104, returnMessage: "Votre suivi n'est pas encore disponible." }, 404));
    expect(await unknown.track(COLISSIMO, "laposte")).toMatchObject({ status: "pending", events: [] });
  });

  test("Ship24 milestones map to a status, a return included", () => {
    expect(ship24Status("delivered", "delivery_delivered")).toBe("delivered");
    expect(ship24Status("exception", "exception_return")).toBe("returned");
    expect(ship24Status("failed_attempt", "delivery_attempted")).toBe("exception");
    expect(ship24Status("available_for_pickup", null)).toBe("available_for_pickup");
    expect(ship24Status("pending", null)).toBe("pending");
    expect(ship24Status(undefined, undefined)).toBe("unknown");
  });

  test("Ship24 creates or reuses the tracker in one call, with the key as a bearer, and names the courier", async () => {
    const seen: Request[] = [];
    const tracker = new Ship24Tracker("ship24-test-key", async (input, init) => {
      seen.push(new Request(String(input), init));
      if (String(input).endsWith("/couriers")) return json({ data: { couriers: [{ courierCode: "fr-colissimo", courierName: "Colissimo" }] } });
      return json({
        data: {
          trackings: [
            {
              tracker: { trackerId: "26148317-7502-d3ac-44a9-546d240ac0dd", trackingNumber: COLISSIMO, courierCode: ["fr-colissimo"], isTracked: true },
              shipment: { statusMilestone: "out_for_delivery", statusCode: "delivery_out_for_delivery", delivery: { estimatedDeliveryDate: "2026-10-24T18:00:00" } },
              events: [
                { status: "Votre colis est pris en charge par La Poste", occurrenceDatetime: "2026-10-22T18:40:00+02:00", location: "Lyon", courierCode: "fr-colissimo" },
                { status: "Votre colis est en cours de livraison", occurrenceDatetime: "2026-10-24T08:12:00+02:00", courierCode: "fr-colissimo" },
                { status: null, occurrenceDatetime: "2026-10-24T09:00:00+02:00" },
              ],
            },
          ],
        },
      });
    });
    const r = await tracker.track(COLISSIMO);
    const track = seen.find((q) => q.url.endsWith("/trackers/track"))!;
    expect(track.method).toBe("POST");
    expect(track.headers.get("authorization")).toBe("Bearer ship24-test-key");
    expect(await track.json()).toEqual({ trackingNumber: COLISSIMO });
    expect(r).toEqual({
      status: "out_for_delivery",
      carrierName: "Colissimo",
      events: [
        { label: "Votre colis est en cours de livraison", at: "2026-10-24T06:12:00.000Z" },
        { label: "Votre colis est pris en charge par La Poste", at: "2026-10-22T16:40:00.000Z", location: "Lyon" },
      ],
      estimatedDelivery: "2026-10-24",
      source: "ship24",
    });
    await tracker.track(COLISSIMO);
    expect(seen.filter((q) => q.url.endsWith("/couriers"))).toHaveLength(1);
  });

  test("Ship24 out of quota or refusing the key is an error, so the chain asks 17TRACK", async () => {
    const quota = new Ship24Tracker("k", async () => json({ errors: [{ code: "quota_limit_reached", message: "Quota reached" }], data: null }, 403));
    expect(quota.track(COLISSIMO)).rejects.toThrow("quota Ship24 du mois atteint");
    const refused = new Ship24Tracker("k", async () => json({ errors: [{ code: "unauthorized" }] }, 401));
    expect(refused.track(COLISSIMO)).rejects.toThrow("clé Ship24 (NUO_SHIP24_API_KEY) refusée");
    const fallback: Tracker = { track: async () => ({ status: "in_transit", events: [], source: "17track" }) };
    expect(await new TrackerChain([quota, fallback]).track(COLISSIMO)).toMatchObject({ status: "in_transit", source: "17track" });
  });

  test("without a key, La Poste is asked through the public endpoint of its tracking page", async () => {
    const seen: Request[] = [];
    const tracker = new LaPosteTracker(undefined, async (input, init) => {
      seen.push(new Request(String(input), init));
      if (String(input).includes("LU680211095FR")) {
        return json(
          {
            title: "Error on idShip LU680211095FR",
            detail: "La Poste est prête à prendre en charge votre envoi.",
            status: 404,
            response: { lang: "fr_FR", returnCode: 104, returnMessage: "La Poste est prête à prendre en charge votre envoi.", idShip: "LU680211095FR" },
          },
          404,
        );
      }
      if (String(input).includes("6A99999999999")) return json({ title: "Error on idShip 6A99999999999", detail: "Le numéro que vous avez saisi n’est pas valide.", status: 400 }, 400);
      return json([{ lang: "fr_FR", returnCode: 200, shipment: { product: "colissimo", event: [{ code: "DI1", label: "Votre colis est livré", date: "2026-10-25T11:30:00+02:00" }] } }]);
    });
    expect(await tracker.track(COLISSIMO, "laposte")).toMatchObject({ status: "delivered", carrierName: "Colissimo", events: [{ label: "Votre colis est livré", at: "2026-10-25T09:30:00.000Z" }] });
    expect(seen[0]!.url).toBe(`https://www.laposte.fr/ssu/sun/back/suivi-unifie/${COLISSIMO}?lang=fr`);
    expect(seen[0]!.headers.get("x-okapi-key")).toBeNull();
    expect(seen[0]!.headers.get("user-agent")).toContain("Mozilla/5.0");
    expect(await tracker.track("LU680211095FR", "laposte")).toMatchObject({ status: "pending" });
    expect(tracker.track("6A99999999999", "laposte")).rejects.toThrow("Le numéro que vous avez saisi n’est pas valide.");
  });

  test("La Poste comes first and only for its own numbers, Ship24 takes every other one", async () => {
    const asked: string[] = [];
    const chain = trackerFromEnv({ NUO_SHIP24_API_KEY: "ship24-test-key" }, async (input) => {
      const url = String(input);
      asked.push(new URL(url).host);
      if (url.includes("laposte")) return json({ shipment: { product: "colissimo", event: [{ code: "PC1", label: "Pris en charge", date: "2026-10-22T18:40:00+02:00" }] } });
      if (url.endsWith("/couriers")) return json({ data: { couriers: [] } });
      return json({ data: { trackings: [{ shipment: { statusMilestone: "in_transit" }, events: [] }] } });
    });
    expect(await chain.track(COLISSIMO, "laposte")).toMatchObject({ source: "laposte", status: "in_transit" });
    expect(await chain.track("1Z999AA10123456784", "ups")).toMatchObject({ source: "ship24" });
    expect(asked).toEqual(["www.laposte.fr", "api.ship24.com"]);
  });

  test("17TRACK registers once (already registered is fine) then reads the events, newest first", async () => {
    const paths: string[] = [];
    const tracker = new SeventeenTrackTracker("17-test-key", async (input, init) => {
      const url = String(input);
      paths.push(url.split("/").pop()!);
      expect(new Headers(init?.headers).get("17token")).toBe("17-test-key");
      if (url.endsWith("/register")) {
        return json({ code: 0, data: { accepted: [], rejected: [{ number: "RR123456789CN", error: { code: -18019901, message: "already registered" } }] } });
      }
      return json({
        code: 0,
        data: {
          accepted: [
            {
              number: "RR123456789CN",
              carrier: 3011,
              track_info: {
                latest_status: { status: "InTransit", sub_status: "InTransit_Other" },
                time_metrics: { estimated_delivery_date: { source: "17TRACK", from: "2026-10-28T00:00:00Z", to: "2026-10-30T00:00:00Z" } },
                tracking: {
                  providers: [
                    { provider: { key: 6051, name: "La Poste" }, events: [{ time_iso: "2026-10-25T09:00:00+02:00", description: "Arrivé en France", location: "Roissy" }] },
                    { provider: { key: 3011, name: "China Post" }, events: [{ time_iso: "2026-10-20T10:00:00+08:00", description: "Départ de Shenzhen", location: null }] },
                  ],
                },
              },
            },
          ],
          rejected: [],
        },
      });
    });
    const r = await tracker.track("RR123456789CN");
    expect(paths).toEqual(["register", "gettrackinfo"]);
    expect(r).toEqual({
      status: "in_transit",
      carrierName: "La Poste",
      events: [
        { label: "Arrivé en France", at: "2026-10-25T07:00:00.000Z", location: "Roissy" },
        { label: "Départ de Shenzhen", at: "2026-10-20T02:00:00.000Z" },
      ],
      estimatedDelivery: "2026-10-30",
      source: "17track",
    });
  });

  test("a refused number or key is an error, the chain falls back to the next tracker", async () => {
    const refused = new SeventeenTrackTracker("k", async () => json({ code: 0, data: { accepted: [], rejected: [{ number: "X", error: { code: -18010012, message: "The format of 'X' is invalid." } }] } }));
    expect(refused.track("X")).rejects.toThrow("The format of 'X' is invalid.");
    const failing: Tracker = { track: async () => Promise.reject(new Error("Ship24 injoignable")) };
    const fallback: Tracker = { track: async () => ({ status: "delivered", events: [], source: "17track" }) };
    expect(await new TrackerChain([failing, fallback]).track(COLISSIMO, "laposte")).toMatchObject({ status: "delivered" });
    expect(new TrackerChain([failing]).track(COLISSIMO, "laposte")).rejects.toThrow("Ship24 injoignable");
    expect(new TrackerChain([]).configured).toBe(false);
  });
});

/** Answers each number with the next status of its script. */
class ScriptedTracker implements Tracker {
  calls: string[] = [];
  constructor(private script: Record<string, TrackingResult[]>) {}
  async track(number: string) {
    this.calls.push(number);
    const queue = this.script[number];
    if (!queue?.length) return undefined;
    return queue.length > 1 ? queue.shift()! : queue[0]!;
  }
}

const inTransit: TrackingResult = { status: "in_transit", carrierName: "Colissimo", events: [{ label: "Votre colis est pris en charge par La Poste", at: "2026-10-22T16:40:00.000Z" }], source: "laposte" };
const delivered: TrackingResult = {
  status: "delivered",
  carrierName: "Colissimo",
  events: [{ label: "Votre colis est livré", at: "2026-10-25T09:30:00.000Z" }, ...inTransit.events],
  source: "ship24",
};

describe("parcels", () => {
  let dir: string;
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  function setup(tracker: Tracker & { configured?: boolean }, now = Date.parse("2026-10-25T10:00:00Z"), o: ParcelOptions = {}) {
    dir = mkdtempSync(join(tmpdir(), "nuo-parcels-"));
    const db = openDataDb(join(dir, "data.db"));
    const pusher = new FakePusher();
    const clock = { now };
    const parcels = new Parcels(db, tracker, pusher, () => [{ id: "iphone", name: "iPhone d'Alex", apnsToken: "ab", apnsEnvironment: "development" } as any], { clock: () => clock.now, autoStart: false, ...o });
    return { db, pusher, parcels, clock };
  }

  test("a long label is cut before an emoji, not inside it", async () => {
    const { parcels } = setup(new ScriptedTracker({ [COLISSIMO]: [inTransit] }));
    // 119 characters, then 🎁 across the 120-character cut.
    const label = "Chaussures de trail pour l'anniversaire de Julie Martin, à cacher avant samedi, ".repeat(2).slice(0, 119);
    const p = await parcels.add({ number: COLISSIMO, label: `${label}🎁 merci` });
    expect(p.label).toBe(label);
    expect(p.label!.isWellFormed()).toBe(true);
  });

  test("adding asks the carrier right away and stores the parcel in the Colis collection, without a push", async () => {
    const { db, pusher, parcels } = setup(new ScriptedTracker({ [COLISSIMO]: [inTransit] }));
    const p = await parcels.add({ number: " 6a12345678901 ", label: "Chaussures de trail" });
    expect(p).toMatchObject({
      number: COLISSIMO,
      label: "Chaussures de trail",
      carrier: "laposte",
      carrierName: "Colissimo",
      status: "in_transit",
      statusLabel: "En transit",
      lastEvent: { label: "Votre colis est pris en charge par La Poste", at: "2026-10-22T16:40:00.000Z" },
      url: `https://www.laposte.fr/outils/suivre-vos-envois?code=${COLISSIMO}`,
      checkedAt: "2026-10-25T10:00:00.000Z",
    });
    expect(pusher.sent).toHaveLength(0);
    expect(db.query("SELECT numero, statut, transporteur FROM v_colis").all()).toEqual([{ numero: COLISSIMO, statut: "En transit", transporteur: "Colissimo" }]);
    expect((db.query("SELECT count(*) AS n FROM _history WHERE table_name = 'colis'").get() as { n: number }).n).toBeGreaterThan(0);
  });

  test("the same number is renamed, not tracked twice; a bad number is refused", async () => {
    const { parcels } = setup(new ScriptedTracker({ [COLISSIMO]: [inTransit] }));
    const first = await parcels.add({ number: COLISSIMO });
    const again = await parcels.add({ number: COLISSIMO, label: "Cadeau de Julie" });
    expect(again.id).toBe(first.id);
    expect(again.label).toBe("Cadeau de Julie");
    expect(parcels.list()).toHaveLength(1);
    expect(parcels.add({ number: "abc" })).rejects.toMatchObject({ status: 400 });
  });

  test("a change of status is pushed once, with a link to the parcel", async () => {
    const tracker = new ScriptedTracker({ [COLISSIMO]: [inTransit, delivered] });
    const { pusher, parcels } = setup(tracker);
    const p = await parcels.add({ number: COLISSIMO, label: "Chaussures de trail" });
    const after = await parcels.refresh(p.id);
    expect(after).toMatchObject({ status: "delivered", deliveredAt: "2026-10-25T09:30:00.000Z" });
    await parcels.refresh(p.id);
    expect(pusher.sent).toHaveLength(1);
    expect(pusher.sent[0]!.payload).toMatchObject({
      title: "📦 Chaussures de trail : livré",
      body: "Votre colis est livré",
      category: "nuo.parcel",
      destination: { kind: "link", url: `nuo://data/colis/${p.id}` },
    });
  });

  test("the refresher only asks again for stale parcels still on their way", async () => {
    const tracker = new ScriptedTracker({ [COLISSIMO]: [inTransit, delivered], "1Z999AA10123456784": [delivered] });
    const { parcels, clock } = setup(tracker);
    await parcels.add({ number: COLISSIMO });
    await parcels.add({ number: "1Z999AA10123456784" });
    tracker.calls = [];
    expect(await parcels.tick()).toBe(0);
    clock.now += 3 * 3600_000;
    expect(await parcels.tick()).toBe(1);
    expect(tracker.calls).toEqual([COLISSIMO]);
    expect(parcels.list().map((p) => p.number)).toEqual([]);
    expect(parcels.list({ includeDone: true }).map((p) => p.status)).toEqual(["delivered", "delivered"]);
  });

  test("a carrier failure is kept on the parcel; without any key the parcel is saved with its link", async () => {
    const { parcels } = setup({ track: async () => Promise.reject(new Error("La Poste injoignable : timeout")) });
    expect(await parcels.add({ number: COLISSIMO })).toMatchObject({ status: "unknown", error: "La Poste injoignable : timeout" });
    rmSync(dir, { recursive: true, force: true });
    const off = setup(new TrackerChain([]));
    expect(await off.parcels.add({ number: "1Z999AA10123456784" })).toMatchObject({ status: "unknown", carrierName: "UPS", url: "https://www.ups.com/track?loc=fr_FR&tracknum=1Z999AA10123456784" });
    expect(await off.parcels.tick()).toBe(0);
  });

  test("a check that learns nothing writes no history, and the next one is still due two hours later", async () => {
    const tracker = new ScriptedTracker({ [COLISSIMO]: [inTransit] });
    const { db, parcels, clock } = setup(tracker);
    const p = await parcels.add({ number: COLISSIMO });
    const history = () => (db.query("SELECT count(*) AS n FROM _history WHERE table_name = 'colis'").get() as { n: number }).n;
    const before = history();
    clock.now += 3 * 3600_000;
    expect(await parcels.tick()).toBe(1);
    expect(history()).toBe(before);
    expect(parcels.get(p.id)!.checkedAt).toBe("2026-10-25T13:00:00.000Z");
    clock.now += 3600_000;
    expect(await parcels.tick()).toBe(0);
  });

  test("a carrier losing the number for a while keeps the known status and pushes nothing twice", async () => {
    const lost: TrackingResult = { status: "pending", events: [], source: "17track" };
    const { pusher, parcels } = setup(new ScriptedTracker({ [COLISSIMO]: [inTransit, lost, inTransit, delivered] }));
    const p = await parcels.add({ number: COLISSIMO });
    expect((await parcels.refresh(p.id))!.status).toBe("in_transit");
    expect((await parcels.refresh(p.id))!.status).toBe("in_transit");
    await parcels.refresh(p.id);
    expect(pusher.sent.map((s) => s.payload.title)).toEqual(["📦 6A12345678901 : livré"]);
  });

  test("simultaneous refreshes share one carrier call and one push", async () => {
    const tracker = new ScriptedTracker({ [COLISSIMO]: [inTransit, delivered] });
    const { pusher, parcels } = setup(tracker);
    const p = await parcels.add({ number: COLISSIMO });
    tracker.calls = [];
    await Promise.all([parcels.refresh(p.id), parcels.refresh(p.id)]);
    expect(tracker.calls).toEqual([COLISSIMO]);
    expect(pusher.sent).toHaveLength(1);
  });

  test("a manual refresh right after a check answers from it, and the number of parcels on their way is capped", async () => {
    const tracker = new ScriptedTracker({ [COLISSIMO]: [inTransit], "1Z999AA10123456784": [inTransit] });
    const { parcels, clock } = setup(tracker, undefined, { maxActive: 1 });
    const p = await parcels.add({ number: COLISSIMO });
    tracker.calls = [];
    await parcels.refresh(p.id, { manual: true });
    expect(tracker.calls).toEqual([]);
    clock.now += 10 * 60_000;
    await parcels.refresh(p.id, { manual: true });
    expect(tracker.calls).toEqual([COLISSIMO]);
    expect(parcels.add({ number: "1Z999AA10123456784" })).rejects.toMatchObject({ status: 429 });
  });

  test("an impossible delivery date or event date is dropped, not the whole tracking", async () => {
    const odd: TrackingResult = { ...inTransit, estimatedDelivery: "2026-02-30" };
    const { parcels } = setup(new ScriptedTracker({ [COLISSIMO]: [odd] }));
    const p = await parcels.add({ number: COLISSIMO });
    expect(p).toMatchObject({ status: "in_transit" });
    expect(p.estimatedDelivery).toBeUndefined();
    expect(p.error).toBeUndefined();
  });

  test("archiving hides the parcel and frees its number", async () => {
    const { parcels } = setup(new ScriptedTracker({ [COLISSIMO]: [inTransit] }));
    const p = await parcels.add({ number: COLISSIMO });
    parcels.archive(p.id);
    expect(parcels.list({ includeDone: true })).toEqual([]);
    expect((await parcels.add({ number: COLISSIMO })).id).not.toBe(p.id);
    expect(() => parcels.archive(p.id)).toThrow("colis introuvable");
  });
});

describe("scanner", () => {
  let dir: string;
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  function scanner(fetcher: Fetch = productBases()) {
    dir = mkdtempSync(join(tmpdir(), "nuo-scan-"));
    const parcels = new Parcels(openDataDb(join(dir, "data.db")), new TrackerChain([]), new FakePusher(), () => [], { autoStart: false });
    return { scanner: new Scanner(new ProductLookup(fetcher), parcels), parcels };
  }

  test("detects a food, a cosmetic and a parcel on its own", async () => {
    const { scanner: s } = scanner();
    expect(await s.scan(NUTELLA, { symbology: "ean13" })).toMatchObject({ kind: "food", candidates: ["food"], food: { name: "Nutella" } });
    expect(await s.scan(CERAVE)).toMatchObject({ kind: "cosmetic", cosmetic: { brand: "CeraVe", analysis: { verdict: "bad" } } });
    expect(await s.scan("%0075010 6A12345678901 250", { symbology: "code128" })).toEqual({
      code: "%00750106A12345678901250",
      kind: "parcel",
      candidates: ["parcel"],
      parcel: { number: COLISSIMO, carrier: "laposte", carrierName: "La Poste / Colissimo", url: `https://www.laposte.fr/outils/suivre-vos-envois?code=${COLISSIMO}` },
    });
  });

  test("asks when unsure: an unknown product, a bare number, or bases out of reach", async () => {
    const { scanner: s } = scanner();
    expect(await s.scan("3760000000017")).toEqual({ code: "3760000000017", kind: "unknown", candidates: ["food", "cosmetic", "parcel"] });
    expect(await s.scan("12345678901", { symbology: "code128" })).toMatchObject({ kind: "parcel", parcel: { carrier: "gls" } });
    expect(await s.scan("12345678901", { symbology: "ean13" })).toMatchObject({ kind: "unknown", candidates: ["parcel", "food", "cosmetic"] });
    const { scanner: offline } = scanner(async () => {
      throw new TypeError("fetch failed");
    });
    expect(await offline.scan(NUTELLA)).toMatchObject({ kind: "unknown", error: expect.stringContaining("injoignable") });
  });

  test("the user's choice is followed, and a parcel already tracked comes back", async () => {
    const { scanner: s, parcels } = scanner();
    expect(await s.scan(CERAVE, { kind: "food" })).toEqual({ code: CERAVE, kind: "food", candidates: ["food"] });
    expect(await s.scan("12345678901", { kind: "parcel" })).toMatchObject({ kind: "parcel", parcel: { number: "12345678901" } });
    const tracked = await parcels.add({ number: COLISSIMO, label: "Chaussures de trail" });
    expect((await s.scan(COLISSIMO)).parcel?.tracked).toMatchObject({ id: tracked.id, label: "Chaussures de trail" });
  });
});

test("a tracking number typed with spaces is glued back before the label", () => {
  expect(splitNumber("6A", "123 456 789 01 Chaussures de trail")).toEqual({ number: "6A 123 456 789 01", label: "Chaussures de trail" });
  expect(splitNumber("6A12345678901", "Commande 2")).toEqual({ number: "6A12345678901", label: "Commande 2" });
  expect(splitNumber("6A12345678901", "2 paires")).toEqual({ number: "6A12345678901", label: "2 paires" });
  expect(splitNumber("6A12345678901", undefined)).toEqual({ number: "6A12345678901" });
});

describe("api, tools and the /colis command", () => {
  let t: TestApp;
  let sock: Socket | undefined;
  afterEach(async () => {
    sock?.close();
    sock = undefined;
    await t?.close();
  });

  const tracker = () => new ScriptedTracker({ [COLISSIMO]: [inTransit] });

  test("scan and parcel routes for the app", async () => {
    t = await startTestApp({ scan: { tracker: tracker(), fetcher: productBases() } });
    expect((await t.api("GET", `/api/scan/${CERAVE}?symbology=ean13`)).data).toMatchObject({ kind: "cosmetic", cosmetic: { name: "Hydrating Foaming Oil Cleanser" } });
    expect((await t.api("GET", `/api/scan/${NUTELLA}?kind=parcel`)).data).toMatchObject({ kind: "parcel" });
    expect((await t.api("GET", `/api/scan/${NUTELLA}?kind=shoes`)).status).toBe(400);

    const added = await t.api("POST", "/api/parcels", { number: COLISSIMO, label: "Chaussures de trail" });
    expect(added.data).toMatchObject({ number: COLISSIMO, status: "in_transit" });
    expect((await t.api("POST", "/api/parcels", { number: "?" })).status).toBe(400);
    expect((await t.api("GET", "/api/parcels")).data).toMatchObject({ trackingConfigured: true, parcels: [{ id: added.data.id }] });
    expect((await t.api("POST", `/api/parcels/${added.data.id}/refresh`)).data).toMatchObject({ status: "in_transit" });
    expect((await t.api("GET", "/api/data/collections/colis/rows")).data.total).toBe(1);
    expect((await t.api("DELETE", `/api/parcels/${added.data.id}`)).status).toBe(204);
    expect((await t.api("GET", `/api/parcels/${added.data.id}`)).status).toBe(404);
    expect((await t.api("GET", "/api/parcels")).data.parcels).toEqual([]);
  });

  test("bots reach the tools with the local token only", async () => {
    t = await startTestApp({ localToken: "local-test-token", scan: { tracker: tracker(), fetcher: productBases() } });
    const call = (name: string, args: unknown, token = "local-test-token") => t.api("POST", `/api/scan/tools/${name}`, args, token);
    const tracked = await call("parcel_track", { number: COLISSIMO, label: "Chaussures de trail" });
    expect(tracked.data.text).toStartWith("::parcel ");
    expect(JSON.parse(tracked.data.text.split("\n")[0].slice("::parcel ".length))).toMatchObject({ number: COLISSIMO, label: "Chaussures de trail", statusLabel: "En transit" });
    expect((await call("parcel_list", {})).data.text).toContain(`Chaussures de trail · ${COLISSIMO} (Colissimo) : En transit`);
    const cosmetic = (await call("product_lookup", { barcode: CERAVE })).data.text as string;
    expect(cosmetic).toStartWith("::cosmetic ");
    expect(cosmetic).toContain("Propylparaben : risque élevé");
    expect((await call("product_lookup", { barcode: NUTELLA })).data.text).toStartWith(`::product {"barcode":"${NUTELLA}"}`);
    expect((await call("parcel_track", {})).status).toBe(400);
    expect((await call("nope", {})).status).toBe(404);
    expect((await call("parcel_list", {}, t.token)).status).toBe(404);
  });

  test("/colis tracks a parcel without starting the agent", async () => {
    t = await startTestApp({ localToken: "local-test-token", scan: { tracker: tracker(), fetcher: productBases() } });
    const bot = (await t.api("POST", "/api/bots", { name: "Cobot" })).data;
    const commands = [
      { name: "colis", description: "Suivre un colis 📦", args: "<numéro> [libellé]", action: { type: "tool", server: "nuo", tool: "parcel_track", params: ["number", "label"] } },
      { name: "mes_colis", description: "Colis en cours", action: { type: "tool", server: "nuo", tool: "parcel_list" } },
    ];
    expect((await t.api("PUT", `/api/bots/${bot.id}/draft`, botConfig({ name: "Cobot", commands }))).status).toBe(200);
    const bad = await t.api("PUT", `/api/bots/${bot.id}/draft`, botConfig({ commands: [{ name: "x", description: "x", action: { type: "tool", server: "nuo", tool: "memory_write" } }] }));
    expect(bad.data.error).toContain(`tool "memory_write" is not one of the gateway's tools`);
    await t.api("POST", `/api/bots/${bot.id}/publish`, {});
    const conv = (await t.api("POST", "/api/conversations", { botId: bot.id })).data;
    sock = await Socket.open(t);
    sock.send({ type: "prompt", conversationId: conv.id, text: "/colis 6A 123 456 789 01 Chaussures de trail" });
    expect(await sock.next("message.end", 10_000)).toMatchObject({ stopReason: "end_turn" });
    const msgs = (await t.api("GET", `/api/conversations/${conv.id}/messages`)).data;
    expect(msgs[1].text).toStartWith("::parcel ");
    expect(msgs[1].text).toContain('"label":"Chaussures de trail"');
    expect(t.runtime.starts).toHaveLength(0);
    expect(t.app.scan.parcels.list()).toMatchObject([{ number: COLISSIMO, label: "Chaussures de trail" }]);
  });
});
