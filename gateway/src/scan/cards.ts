import type { CosmeticProduct } from "./products";

/** The `::cosmetic` card (docs/protocol.md): enough to draw it offline; the app fetches the full list on tap. */
export function cosmeticCard(p: CosmeticProduct): string {
  const flagged = p.analysis.ingredients
    .filter((i) => i.risk !== "none")
    .sort((a, b) => rank(b.risk) - rank(a.risk))
    .slice(0, 6)
    .map((i) => ({ name: i.name, risk: i.risk }));
  const card = {
    barcode: p.barcode,
    name: p.name,
    ...(p.brand ? { brand: p.brand } : {}),
    ...(p.imageUrl ? { image: p.imageUrl } : {}),
    ...(p.analysis.score !== undefined ? { score: p.analysis.score } : {}),
    verdict: p.analysis.verdict,
    counts: p.analysis.counts,
    flagged,
  };
  return `::cosmetic ${JSON.stringify(card)}`;
}

function rank(risk: string): number {
  return risk === "high" ? 3 : risk === "moderate" ? 2 : risk === "low" ? 1 : 0;
}

export type { CosmeticProduct };
