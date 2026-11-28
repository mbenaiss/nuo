import { t, type UiLanguage } from "../i18n/language";
import type { MessageKey } from "../i18n/messages";

/**
 * Ingredient analysis of a cosmetic, in the spirit of Yuka: each INCI ingredient gets a risk level and the
 * product score is capped by its worst ingredient. The list covers the substances most often flagged by the
 * ANSM, the EU SCCS and consumer associations (endocrine disruptors, formaldehyde releasers, strong allergens).
 */

export type IngredientRisk = "high" | "moderate" | "low" | "none";

interface Rule {
  re: RegExp;
  risk: Exclude<IngredientRisk, "none">;
  reason: MessageKey;
}

const RULES: Rule[] = [
  { re: /\b(butyl|propyl|isobutyl|isopropyl|benzyl|pentyl|phenyl)paraben\b/, risk: "high", reason: "scan.risk.endocrine" },
  { re: /\b(methyl|ethyl)paraben\b/, risk: "moderate", reason: "scan.risk.weakHormonal" },
  { re: /\b(bha|butylated hydroxyanisole)\b/, risk: "high", reason: "scan.risk.endocrineCarcinogen" },
  { re: /\b(bht|butylated hydroxytoluene)\b/, risk: "moderate", reason: "scan.risk.endocrine" },
  { re: /\btriclosan\b/, risk: "high", reason: "scan.risk.endocrine" },
  { re: /\btriclocarban\b/, risk: "high", reason: "scan.risk.endocrine" },
  { re: /\b(benzophenone-[1-4]|oxybenzone)\b/, risk: "high", reason: "scan.risk.uvEndocrine" },
  { re: /\b(ethylhexyl methoxycinnamate|octinoxate)\b/, risk: "high", reason: "scan.risk.uvEndocrine" },
  { re: /\b(4-methylbenzylidene camphor|enzacamene)\b/, risk: "high", reason: "scan.risk.uvEndocrine" },
  { re: /\bhomosalate\b/, risk: "high", reason: "scan.risk.uvEndocrine" },
  { re: /\boctocrylene\b/, risk: "moderate", reason: "scan.risk.uvBenzophenone" },
  { re: /\bcyclotetrasiloxane\b/, risk: "high", reason: "scan.risk.d4" },
  { re: /\b(cyclopentasiloxane|cyclohexasiloxane|cyclomethicone)\b/, risk: "moderate", reason: "scan.risk.cyclicSilicone" },
  { re: /\b(dmdm hydantoin|imidazolidinyl urea|diazolidinyl urea|quaternium-15|sodium hydroxymethylglycinate|2-bromo-2-nitropropane-1,3-diol|bronopol|formaldehyde|methylene glycol)\b/, risk: "high", reason: "scan.risk.formaldehyde" },
  { re: /\b(methylisothiazolinone|methylchloroisothiazolinone)\b/, risk: "high", reason: "scan.risk.contactAllergen" },
  { re: /\b(butylphenyl methylpropional|lilial)\b/, risk: "high", reason: "scan.risk.lilial" },
  { re: /\bhydroquinone\b/, risk: "high", reason: "scan.risk.hydroquinone" },
  { re: /\b(p-phenylenediamine|toluene-2,5-diamine)\b/, risk: "high", reason: "scan.risk.hairDye" },
  { re: /\bresorcinol\b/, risk: "high", reason: "scan.risk.endocrine" },
  { re: /\b(sodium lauryl sulfate|ammonium lauryl sulfate)\b/, risk: "moderate", reason: "scan.risk.irritatingSurfactant" },
  { re: /\b(polyethylene|polypropylene|nylon-(6|12)|polymethyl methacrylate|polystyrene|acrylates crosspolymer)\b/, risk: "moderate", reason: "scan.risk.microplastic" },
  { re: /\b(aluminum|aluminium) (chlorohydrate|zirconium\b.*|sesquichlorohydrate|chloride)\b/, risk: "moderate", reason: "scan.risk.aluminium" },
  { re: /\[nano\]|\bnano\b/, risk: "moderate", reason: "scan.risk.nano" },
  { re: /\btitanium dioxide\b.*\bnano\b/, risk: "moderate", reason: "scan.risk.titaniumNano" },
  { re: /\b(triethanolamine|diethanolamine)\b|(^|[\s(])(tea|dea)(-|$)/, risk: "moderate", reason: "scan.risk.nitrosamines" },
  { re: /\bbenzyl salicylate\b/, risk: "moderate", reason: "scan.risk.allergenDisruptor" },
  { re: /\bphenoxyethanol\b/, risk: "low", reason: "scan.risk.phenoxyethanol" },
  { re: /\b(peg|ppg)-\d+/, risk: "low", reason: "scan.risk.dioxane" },
  { re: /\b(paraffinum liquidum|mineral oil|petrolatum|paraffin|cera microcristallina|microcrystalline wax)\b/, risk: "low", reason: "scan.risk.petroleum" },
  { re: /\b(parfum|fragrance|aroma)\b/, risk: "low", reason: "scan.risk.fragrance" },
  {
    re: /\b(limonene|linalool|citronellol|geraniol|coumarin|eugenol|isoeugenol|citral|hexyl cinnamal|cinnamal|cinnamyl alcohol|benzyl alcohol|benzyl benzoate|benzyl cinnamate|farnesol|hydroxycitronellal|amyl cinnamal|amylcinnamyl alcohol|anise alcohol|alpha-isomethyl ionone|methyl 2-octynoate|evernia prunastri|evernia furfuracea)\b/,
    risk: "low",
    reason: "scan.risk.allergen",
  },
  { re: /\bsodium laureth sulfate\b/, risk: "low", reason: "scan.risk.mildSurfactant" },
];

const LEVELS: Record<IngredientRisk, number> = { high: 3, moderate: 2, low: 1, none: 0 };

export interface AnalyzedIngredient {
  name: string;
  risk: IngredientRisk;
  reason?: string;
}

export interface CosmeticAnalysis {
  /** 0 to 100; absent when the ingredients are unknown. */
  score?: number;
  verdict: "excellent" | "good" | "poor" | "bad" | "unknown";
  ingredients: AnalyzedIngredient[];
  counts: Record<Exclude<IngredientRisk, "none">, number>;
}

/** `reason` in `lang`, by default the language of the request being answered (the app's, or English for a bot). */
export function assessIngredient(name: string, lang?: UiLanguage): AnalyzedIngredient {
  const key = name.toLowerCase().replace(/\s+/g, " ").trim();
  let best: Rule | undefined;
  for (const r of RULES) if (r.re.test(key) && (!best || LEVELS[r.risk] > LEVELS[best.risk])) best = r;
  return best ? { name, risk: best.risk, reason: t(best.reason, {}, lang) } : { name, risk: "none" };
}

/** Splits an INCI list on commas, keeping parentheses together ("Parfum (Fragrance)", "CI 77491 (Iron Oxides)"). */
export function splitIngredients(text: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let cur = "";
  for (const ch of text.replace(/\s*\n\s*/g, " ")) {
    if (ch === "(" || ch === "[") depth++;
    if ((ch === ")" || ch === "]") && depth > 0) depth--;
    if ((ch === "," || ch === ";" || ch === "•") && depth === 0) {
      out.push(cur);
      cur = "";
    } else cur += ch;
  }
  out.push(cur);
  return out
    .map((s) => s.replace(/^\s*(ingredients?|ingrédients?|composition)\s*:\s*/i, "").replace(/[.*]+$/, "").trim())
    .filter((s) => s.length > 1 && s.length < 120);
}

function verdictOf(score: number): CosmeticAnalysis["verdict"] {
  return score >= 75 ? "excellent" : score >= 50 ? "good" : score >= 25 ? "poor" : "bad";
}

/**
 * Yuka's rule of thumb: one high-risk ingredient caps the product at 25, a moderate one at 50, a low one at
 * 75; each further flagged ingredient takes a few more points.
 */
export function analyzeCosmetic(ingredientNames: string[], lang?: UiLanguage): CosmeticAnalysis {
  const ingredients = ingredientNames.map((name) => assessIngredient(name, lang));
  const counts = { high: 0, moderate: 0, low: 0 };
  for (const i of ingredients) if (i.risk !== "none") counts[i.risk]++;
  if (!ingredients.length) return { verdict: "unknown", ingredients, counts };
  const flagged = counts.high + counts.moderate + counts.low;
  const cap = counts.high ? 25 : counts.moderate ? 50 : counts.low ? 75 : 100;
  const penalty = Math.max(0, flagged - 1) * (counts.high || counts.moderate ? 4 : 3);
  const score = Math.max(0, cap - penalty);
  return { score, verdict: verdictOf(score), ingredients, counts };
}
