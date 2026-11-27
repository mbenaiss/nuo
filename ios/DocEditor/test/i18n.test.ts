import { afterEach, expect, test } from "bun:test";
import { formatSize } from "../src/bridge";
import { BLOCKS } from "../src/commands";
import { languageOf, locale, setLanguage, t } from "../src/i18n";

afterEach(() => setLanguage("en"));

test("English is the default and French is picked from the browser language", () => {
  expect(languageOf("en-US")).toBe("en");
  expect(languageOf("de-DE")).toBe("en");
  expect(languageOf(undefined)).toBe("en");
  expect(languageOf("fr")).toBe("fr");
  expect(languageOf("fr-CA")).toBe("fr");
  expect(languageOf("frisian")).toBe("en");
});

test("a text is translated once the language is French and falls back to its English wording", () => {
  expect(t("Duplicate")).toBe("Duplicate");
  setLanguage("fr");
  expect(t("Duplicate")).toBe("Dupliquer");
  expect(t("Not a known text")).toBe("Not a known text");
});

test("values fill the numbered holes in both languages", () => {
  expect(t("“{0}” is over 50 MB.", "Bilan 2026.pdf")).toBe("“Bilan 2026.pdf” is over 50 MB.");
  setLanguage("fr");
  expect(t("“{0}” is over 50 MB.", "Bilan 2026.pdf")).toBe("« Bilan 2026.pdf » dépasse 50 Mo.");
  expect(t("Heading {0}", 2)).toBe("Titre 2");
});

test("file sizes use the units and the decimal mark of the language", () => {
  expect(formatSize(undefined)).toBe("");
  expect(formatSize(800)).toBe("800 B");
  expect(formatSize(48 * 1024)).toBe("48 KB");
  expect(formatSize(1.5 * 1024 * 1024)).toBe("1.5 MB");
  setLanguage("fr");
  expect(locale()).toBe("fr-FR");
  expect(formatSize(800)).toBe("800 o");
  expect(formatSize(48 * 1024)).toBe("48 Ko");
  expect(formatSize(1.5 * 1024 * 1024)).toBe("1,5 Mo");
});

test("the slash menu groups keep their wording in both languages", () => {
  setLanguage("fr");
  for (const block of BLOCKS) {
    expect(["Basic blocks", "Media", "Other"]).toContain(block.group);
  }
  expect(t("Basic blocks")).toBe("Blocs de base");
  expect(t("Media")).toBe("Médias");
  expect(t("Other")).toBe("Autres");
});
