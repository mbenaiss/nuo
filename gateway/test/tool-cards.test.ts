import { describe, expect, test } from "bun:test";
import { cardsFromToolText } from "../src/runner/tool-cards";

describe("cardsFromToolText", () => {
  test("a titled key-value listing becomes a facts card, other lines stay around it", () => {
    const out = cardsFromToolText(
      "Bilan aujourd'hui :\nAucun repas enregistré.\nPoids (WHOOP) : 77.5 kg\nWHOOP : recovery 37 % · sommeil 86 % · effort 5.2",
    );
    const [note, card] = out.split("\n");
    expect(note).toBe("Aucun repas enregistré.");
    expect(card).toStartWith("::facts ");
    expect(JSON.parse(card!.slice(8))).toEqual({
      title: "Bilan aujourd'hui",
      items: [
        { label: "Poids (WHOOP)", value: "77.5 kg" },
        { label: "WHOOP", value: "recovery 37 % · sommeil 86 % · effort 5.2" },
      ],
    });
  });

  test("bold labels and bullets are accepted", () => {
    const out = cardsFromToolText("- **Calories** : 1 850 kcal\n- **Protéines** : 120 g");
    expect(JSON.parse(out.slice(8)).items).toEqual([
      { label: "Calories", value: "1 850 kcal" },
      { label: "Protéines", value: "120 g" },
    ]);
  });

  test("prose, URLs, single facts and existing cards are left alone", () => {
    const prose = "🛌 **Aujourd'hui samedi : repos.** Pas de séance prévue.\nLundi : sortie longue facile.";
    expect(cardsFromToolText(prose)).toBe(prose);
    expect(cardsFromToolText("Lien : https://x.fr")).toBe("Lien : https://x.fr");
    const card = '::weather {"location":"Paris"}\nVent : 10 km/h\nPluie : 0 mm';
    expect(cardsFromToolText(card)).toBe(card);
  });
});
