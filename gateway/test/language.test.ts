import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { forcedLanguages, languageName, parseAcceptLanguage, t, uiLanguage, withLanguage } from "../src/i18n/language";
import { CATALOGS } from "../src/i18n/messages";
import { openDb } from "../src/store/db";
import { Store } from "../src/store/store";

const dirs: string[] = [];
afterEach(() => {
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
});

function storeWith(forced?: string[]) {
  const dir = mkdtempSync(join(tmpdir(), "nuo-language-"));
  dirs.push(dir);
  const store = new Store(openDb(dir), forced);
  const add = (id: string, name: string, lastSeen: string) =>
    store.db.query("INSERT INTO devices (id, name, public_key, created_at, last_seen_at) VALUES (?, ?, 'key', ?, ?)").run(id, name, "2026-11-02T08:00:00.000Z", lastSeen);
  add("iphone-julie", "iPhone de Julie", "2026-11-28T07:45:00.000Z");
  add("mac-julie", "MacBook de Julie", "2026-11-27T18:10:00.000Z");
  return store;
}

describe("Accept-Language", () => {
  test("an absent or empty header names no language", () => {
    expect(parseAcceptLanguage(null)).toEqual([]);
    expect(parseAcceptLanguage("")).toEqual([]);
    expect(uiLanguage(parseAcceptLanguage(undefined))).toBe("en");
  });

  test("tags come by decreasing weight, without `*`, refused or malformed entries", () => {
    expect(parseAcceptLanguage("fr-FR,fr;q=0.9,en-US;q=0.8")).toEqual(["fr-FR", "fr", "en-US"]);
    expect(parseAcceptLanguage("en;q=0.5, de-de, *;q=0.1, it;q=0, x_y, es;q=2")).toEqual(["de-DE", "en"]);
  });

  test("the gateway writes French for fr-FR, English for en-US and English for a language it has no texts for", () => {
    expect(uiLanguage(parseAcceptLanguage("fr-FR"))).toBe("fr");
    expect(uiLanguage(parseAcceptLanguage("en-US"))).toBe("en");
    expect(uiLanguage(parseAcceptLanguage("es-ES"))).toBe("en");
    expect(uiLanguage(parseAcceptLanguage("es-ES, fr-CA;q=0.8"))).toBe("fr");
  });

  test("bots read the language by its English name", () => {
    expect(languageName("fr-CA")).toBe("French");
    expect(languageName("es-ES")).toBe("Spanish");
    expect(languageName("qaa")).toBeUndefined();
    expect(languageName(undefined)).toBeUndefined();
  });
});

describe("forced language", () => {
  test("NUO_LANGUAGE sets every profile, NUO_LANGUAGE_<PROFILE> one of them", () => {
    expect(forcedLanguages("owner", {})).toBeUndefined();
    expect(forcedLanguages("owner", { NUO_LANGUAGE: "fr" })).toEqual(["fr"]);
    expect(forcedLanguages("julie-martin", { NUO_LANGUAGE: "fr", NUO_LANGUAGE_JULIE_MARTIN: "en-GB, fr;q=0.5" })).toEqual(["en-GB", "fr"]);
    expect(forcedLanguages("owner", { NUO_LANGUAGE: "fr", NUO_LANGUAGE_JULIE_MARTIN: "en-GB" })).toEqual(["fr"]);
  });

  test("a value that names no language stops the gateway at startup", () => {
    expect(() => forcedLanguages("owner", { NUO_LANGUAGE: "français" })).toThrow("NUO_LANGUAGE must be language tags");
  });
});

describe("user languages of a profile", () => {
  test("are those of the device seen last, and empty until an app has sent them", () => {
    const store = storeWith();
    expect(store.userLanguages()).toEqual([]);
    expect(store.uiLanguage()).toBe("en");
    store.setDeviceLanguages("mac-julie", ["en-US"]);
    expect(store.userLanguages()).toEqual(["en-US"]);
    store.setDeviceLanguages("iphone-julie", ["fr-FR", "en-US"]);
    expect(store.userLanguages()).toEqual(["fr-FR", "en-US"]);
    expect(store.uiLanguage()).toBe("fr");
    store.setDeviceLanguages("iphone-julie", []);
    expect(store.userLanguages()).toEqual(["fr-FR", "en-US"]);
  });

  test("the forced languages win over the devices'", () => {
    const store = storeWith(["en"]);
    store.setDeviceLanguages("iphone-julie", ["fr-FR"]);
    expect(store.userLanguages()).toEqual(["en"]);
    expect(store.uiLanguage()).toBe("en");
  });
});

describe("catalogs", () => {
  test("every catalog has the keys of the English one, with the same placeholders", () => {
    const placeholders = (text: string) => [...text.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();
    for (const [lang, catalog] of Object.entries(CATALOGS)) {
      for (const [key, text] of Object.entries(CATALOGS.en)) {
        const translated = (catalog as Record<string, string>)[key];
        expect(translated, `${lang}: ${key}`).toBeString();
        expect(placeholders(translated!), `${lang}: ${key}`).toEqual(placeholders(text));
      }
    }
  });

  test("a text is in the language asked, else that of the request, else English", () => {
    expect(t("locale", {}, "fr")).toBe("fr-FR");
    expect(t("locale")).toBe("en-US");
    expect(withLanguage("fr", () => t("locale"))).toBe("fr-FR");
  });
});
