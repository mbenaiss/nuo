import { analyzeCosmetic, splitIngredients, type CosmeticAnalysis } from "./cosmetics";

export type Fetch = (input: string | URL | Request, init?: RequestInit) => Promise<Response>;

const USER_AGENT = "Nuo/1.0 (Nuo Gateway; personal use)";
const TIMEOUT_MS = 8000;

const OFF = "https://world.openfoodfacts.org/api/v2/product";
const OBF = "https://world.openbeautyfacts.org/api/v2/product";
const OPF = "https://world.openproductsfacts.org/api/v2/product";
const INCI_API = "https://inciapi.com/v1/products";
const UPCITEMDB = "https://api.upcitemdb.com/prod/trial/lookup";
const FOOD_FIELDS = "code,product_name,product_name_fr,brands,image_front_url,image_url,quantity,nutriscore_grade,nova_group,ingredients_text,ingredients_text_fr,categories_tags";
const COSMETIC_FIELDS = "code,product_name,product_name_fr,brands,image_front_url,image_url,quantity,ingredients_text,ingredients_text_fr,ingredients,labels_tags,periods_after_opening_tags";

export interface FoodSummary {
  kind: "food";
  barcode: string;
  name: string;
  brand?: string;
  imageUrl?: string;
  quantity?: string;
  nutriscore?: string;
  nova?: number;
}

export interface CosmeticProduct {
  kind: "cosmetic";
  barcode: string;
  name: string;
  brand?: string;
  imageUrl?: string;
  quantity?: string;
  labels: string[];
  /** "12 mois" from the "12M" jar symbol, when known. */
  periodAfterOpening?: string;
  analysis: CosmeticAnalysis;
  url: string;
  /** Where the product was found; "photo" is a list the user photographed, kept for the next scan. */
  source: CosmeticSource;
}

export type CosmeticSource = "openbeautyfacts" | "openfoodfacts" | "inciapi" | "upcitemdb" | "openproductsfacts" | "photo";

/** Ingredient lists the user photographed, by barcode: a product no base knows is known from then on. */
export interface CosmeticMemory {
  get(code: string): { name?: string; brand?: string; ingredients: string } | undefined;
  set(code: string, entry: { name?: string; brand?: string; ingredients: string }): void;
}

export interface ProductSources {
  /** INCI API's free tier (2 000 matches a month; unknown codes are free). */
  inciApiKey?: string;
  memory?: CosmeticMemory;
}

export class LookupError extends Error {}

type Raw = Record<string, unknown>;
const str = (v: unknown) => (typeof v === "string" && v.trim() ? v.trim() : undefined);

/**
 * Open Food Facts and Open Beauty Facts answer 404 or 200 with `status: 0` for an unknown or invalid code; during an
 * outage they answer 404 too, with an HTML page, which must not read as "unknown product".
 */
async function fetchProduct(fetcher: Fetch, base: string, code: string, fields: string): Promise<Raw | undefined> {
  let res: Response;
  try {
    res = await fetcher(`${base}/${encodeURIComponent(code)}.json?fields=${fields}`, {
      headers: { "user-agent": USER_AGENT, accept: "application/json" },
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch (e) {
    throw new LookupError(`${new URL(base).hostname} injoignable : ${(e as Error)?.message ?? e}`);
  }
  if (res.status !== 404 && !res.ok) throw new LookupError(`${new URL(base).hostname} a répondu ${res.status}`);
  const body = (await res.json().catch(() => undefined)) as { status?: number; product?: Raw } | undefined;
  if (!body) throw new LookupError(`${new URL(base).hostname} est indisponible (réponse ${res.status} sans données)`);
  return body.status === 1 && body.product ? body.product : undefined;
}

function nameOf(p: Raw): string | undefined {
  return str(p.product_name_fr) ?? str(p.product_name);
}

function firstBrand(p: Raw): string | undefined {
  return str(p.brands)?.split(",")[0]?.trim() || undefined;
}

export function foodSummary(code: string, p: Raw): FoodSummary | undefined {
  const name = nameOf(p);
  if (!name) return undefined;
  const nova = Number(p.nova_group);
  return {
    kind: "food",
    barcode: code,
    name,
    ...(firstBrand(p) ? { brand: firstBrand(p) } : {}),
    ...(str(p.image_front_url) ? { imageUrl: str(p.image_front_url) } : {}),
    ...(str(p.quantity) ? { quantity: str(p.quantity) } : {}),
    ...(str(p.nutriscore_grade) && /^[a-e]$/.test(str(p.nutriscore_grade)!) ? { nutriscore: str(p.nutriscore_grade) } : {}),
    ...(Number.isInteger(nova) && nova >= 1 && nova <= 4 ? { nova } : {}),
  };
}

/** The free text is the INCI list as printed; `ingredients[].text` is the fallback when only the parsed list exists. */
function ingredientNames(p: Raw): string[] {
  const text = str(p.ingredients_text) ?? str(p.ingredients_text_fr);
  if (text) return splitIngredients(text);
  const parsed = Array.isArray(p.ingredients) ? (p.ingredients as Raw[]) : [];
  return parsed.map((i) => str(i.text)).filter((s): s is string => !!s);
}

export function cosmeticProduct(code: string, p: Raw): CosmeticProduct | undefined {
  const name = nameOf(p);
  if (!name) return undefined;
  const labels = (Array.isArray(p.labels_tags) ? (p.labels_tags as unknown[]) : [])
    .map((t) => (typeof t === "string" ? t.replace(/^[a-z]{2}:/, "").replace(/-/g, " ") : ""))
    .filter(Boolean);
  const pao = (Array.isArray(p.periods_after_opening_tags) ? (p.periods_after_opening_tags as unknown[]) : [])
    .map((t) => (typeof t === "string" ? t.match(/(\d+)-months?/)?.[1] : undefined))
    .find(Boolean);
  return {
    kind: "cosmetic",
    barcode: code,
    name,
    ...(firstBrand(p) ? { brand: firstBrand(p) } : {}),
    ...(str(p.image_front_url) ?? str(p.image_url) ? { imageUrl: str(p.image_front_url) ?? str(p.image_url) } : {}),
    ...(str(p.quantity) ? { quantity: str(p.quantity) } : {}),
    labels,
    ...(pao ? { periodAfterOpening: `${pao} mois` } : {}),
    analysis: analyzeCosmetic(ingredientNames(p)),
    url: obfPage(code),
    source: "openbeautyfacts",
  };
}

/**
 * Cosmetics filed in Open Food Facts by mistake (a SVR cleanser as « Spaghetti ») keep their INCI list there: water
 * written « aqua », perfume « parfum », or several ingredients no food lists.
 */
export function looksLikeInci(text: string | undefined): boolean {
  if (!text) return false;
  if (/\b(aqua|parfum)\b/i.test(text)) return true;
  const markers = text.match(/\b(glycerin|sodium laureth sulfate|sodium lauryl sulfate|cetearyl alcohol|dimethicone|phenoxyethanol|tocopheryl acetate|ci \d{5}|cocamidopropyl betaine|coco-betaine|decyl glucoside|carbomer|polysorbate \d+|peg-\d+|paraffinum liquidum|butyrospermum parkii|caprylic\/capric triglyceride|ethylhexylglycerin)\b/gi);
  return new Set((markers ?? []).map((m) => m.toLowerCase())).size >= 2;
}

/** The cosmetic hidden in a food record; its food name and categories were written for the wrong product. */
function misfiledCosmetic(code: string, p: Raw): CosmeticProduct | undefined {
  const text = str(p.ingredients_text) ?? str(p.ingredients_text_fr);
  if (!looksLikeInci(text)) return undefined;
  const brand = firstBrand(p);
  const categorised = Array.isArray(p.categories_tags) && p.categories_tags.length > 0;
  const name = categorised || !nameOf(p) ? (brand ? `Cosmétique ${brand}` : "Cosmétique") : nameOf(p)!;
  return namedCosmetic(code, "openfoodfacts", name, brand, splitIngredients(text!), str(p.image_front_url) ?? str(p.image_url));
}

const obfPage = (code: string) => `https://world.openbeautyfacts.org/product/${encodeURIComponent(code)}`;

function namedCosmetic(code: string, source: CosmeticSource, name: string, brand: string | undefined, ingredients: string[], imageUrl?: string): CosmeticProduct {
  return {
    kind: "cosmetic",
    barcode: code,
    name,
    ...(brand ? { brand } : {}),
    ...(imageUrl ? { imageUrl } : {}),
    labels: [],
    analysis: analyzeCosmetic(ingredients),
    url: obfPage(code),
    source,
  };
}

async function getJson(fetcher: Fetch, url: string, headers: Record<string, string> = {}): Promise<{ status: number; body?: Raw }> {
  let res: Response;
  try {
    res = await fetcher(url, { headers: { "user-agent": USER_AGENT, accept: "application/json", ...headers }, signal: AbortSignal.timeout(TIMEOUT_MS) });
  } catch (e) {
    throw new LookupError(`${new URL(url).hostname} injoignable : ${(e as Error)?.message ?? e}`);
  }
  return { status: res.status, body: (await res.json().catch(() => undefined)) as Raw | undefined };
}

/** INCI API: `{product: {name, brand, ingredients, details: {inci}}}`; 404 for an unknown code. */
async function inciApi(fetcher: Fetch, key: string, code: string): Promise<CosmeticProduct | undefined> {
  const { status, body } = await getJson(fetcher, `${INCI_API}/${encodeURIComponent(code)}`, { "x-api-key": key });
  if (status === 404) return undefined;
  if (status !== 200 || !body) throw new LookupError(`inciapi.com a répondu ${status}`);
  const p = body.product as Raw | undefined;
  const name = p && str(p.name);
  if (!p || !name) return undefined;
  const details = p.details as Raw | undefined;
  const listed = Array.isArray(details?.inci) ? (details!.inci as unknown[]).map(str).filter((s): s is string => !!s) : [];
  const ingredients = listed.length ? listed : str(p.ingredients) ? splitIngredients(str(p.ingredients)!) : [];
  const image = Array.isArray(p.imageUrls) ? str((p.imageUrls as unknown[])[0]) : undefined;
  return namedCosmetic(code, "inciapi", name, str(p.brand), ingredients, image);
}

/** UPCitemdb's free trial (100 lookups a day): any retail product, name and brand only. */
async function upcItemDb(fetcher: Fetch, code: string): Promise<CosmeticProduct | undefined> {
  const { status, body } = await getJson(fetcher, `${UPCITEMDB}?upc=${encodeURIComponent(code)}`);
  if (status === 404 || status === 400) return undefined;
  if (status !== 200 || !body) throw new LookupError(`upcitemdb.com a répondu ${status}`);
  const item = Array.isArray(body.items) ? (body.items[0] as Raw | undefined) : undefined;
  const name = item && str(item.title);
  if (!item || !name) return undefined;
  const image = Array.isArray(item.images) ? str((item.images as unknown[])[0]) : undefined;
  return namedCosmetic(code, "upcitemdb", name, str(item.brand), [], image);
}

export class ProductLookup {
  constructor(
    private fetcher: Fetch = fetch,
    private sources: ProductSources = {},
  ) {}

  async food(code: string): Promise<FoodSummary | undefined> {
    const p = await this.foodRecord(code);
    return p ? foodSummary(code, p) : undefined;
  }

  private foodRecord(code: string): Promise<Raw | undefined> {
    return fetchProduct(this.fetcher, OFF, code, FOOD_FIELDS);
  }

  /** Open Beauty Facts and INCI API, the bases with ingredient lists, after a list the user photographed. */
  async cosmetic(code: string, record?: Promise<Raw | undefined>): Promise<CosmeticProduct | undefined> {
    const remembered = this.remembered(code);
    if (remembered) return remembered;
    const foodRecord = record ?? this.foodRecord(code);
    const [obf, inci, off] = await Promise.allSettled([
      fetchProduct(this.fetcher, OBF, code, COSMETIC_FIELDS).then((p) => (p ? cosmeticProduct(code, p) : undefined)),
      this.sources.inciApiKey ? inciApi(this.fetcher, this.sources.inciApiKey, code) : Promise.resolve(undefined),
      foodRecord.then((p) => (p ? misfiledCosmetic(code, p) : undefined)),
    ]);
    return pick([obf, inci, off]);
  }

  /**
   * Every free base, for a code the user says is a cosmetic: when none has its ingredients, UPCitemdb or Open
   * Products Facts may still name it, and the app then asks for a photo of the list.
   */
  async cosmeticAnywhere(code: string): Promise<CosmeticProduct | undefined> {
    let failure: unknown;
    let found: CosmeticProduct | undefined;
    try {
      found = await this.cosmetic(code);
    } catch (e) {
      failure = e;
    }
    if (found?.analysis.ingredients.length) return found;
    const named = await Promise.allSettled([
      upcItemDb(this.fetcher, code),
      fetchProduct(this.fetcher, OPF, code, "code,product_name,product_name_fr,brands,image_front_url").then((p) =>
        p && nameOf(p) ? namedCosmetic(code, "openproductsfacts", nameOf(p)!, firstBrand(p), [], str(p.image_front_url)) : undefined,
      ),
    ]);
    const other = named.map((r) => (r.status === "fulfilled" ? r.value : undefined)).find(Boolean);
    if (found ?? other) return found ?? other;
    if (failure) throw failure;
    return undefined;
  }

  /** A list photographed and read on the phone: analysed now, and found by the next scan of the same code. */
  rememberIngredients(code: string, entry: { name?: string; brand?: string; ingredients: string }): CosmeticProduct {
    const ingredients = splitIngredients(entry.ingredients);
    if (!ingredients.length) throw new LookupError("aucun ingrédient reconnu dans ce texte");
    this.sources.memory?.set(code, entry);
    return namedCosmetic(code, "photo", entry.name?.trim() || "Cosmétique", entry.brand?.trim() || undefined, ingredients);
  }

  private remembered(code: string): CosmeticProduct | undefined {
    const m = this.sources.memory?.get(code);
    return m ? namedCosmetic(code, "photo", m.name || "Cosmétique", m.brand, splitIngredients(m.ingredients)) : undefined;
  }

  /**
   * Both bases are asked at once; a product filed in both (it happens for soaps and toothpastes) is taken as
   * a cosmetic only when it has an ingredient list there. One base down does not hide the other's answer.
   */
  async any(code: string): Promise<FoodSummary | CosmeticProduct | undefined> {
    const record = this.foodRecord(code);
    // A food record with an INCI list is a cosmetic filed in the wrong base: it is not offered as food.
    const asFood = record.then((p) => (p && !misfiledCosmetic(code, p) ? foodSummary(code, p) : undefined));
    const [food, cosmetic] = await Promise.allSettled([asFood, this.cosmetic(code, record)]);
    const f = food.status === "fulfilled" ? food.value : undefined;
    const c = cosmetic.status === "fulfilled" ? cosmetic.value : undefined;
    if (c && (!f || c.analysis.ingredients.length)) return c;
    if (f) return f;
    const failure = [food, cosmetic].find((r): r is PromiseRejectedResult => r.status === "rejected");
    if (failure) throw failure.reason;
    return undefined;
  }
}

/** The answer with an ingredient list wins; then any answer; an error only when no base answered. */
function pick(results: PromiseSettledResult<CosmeticProduct | undefined>[]): CosmeticProduct | undefined {
  const found = results.map((r) => (r.status === "fulfilled" ? r.value : undefined)).filter((p): p is CosmeticProduct => !!p);
  const best = found.find((p) => p.analysis.ingredients.length) ?? found[0];
  if (best) return best;
  const failure = results.find((r): r is PromiseRejectedResult => r.status === "rejected");
  if (failure) throw failure.reason;
  return undefined;
}
