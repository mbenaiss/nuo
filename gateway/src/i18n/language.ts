import { AsyncLocalStorage } from "node:async_hooks";
import { CATALOGS, type MessageKey } from "./messages";

/**
 * Two languages, two uses. The user's languages (BCP 47 tags, most preferred first) come from the apps'
 * `Accept-Language`: bots write in the first one, whatever it is. What the gateway writes itself (errors, push
 * notifications, notices in a conversation, public pages) is in the first of them it has a catalog for, English
 * otherwise (docs/protocol.md, "Language").
 */
export type UiLanguage = keyof typeof CATALOGS;
export const DEFAULT_UI_LANGUAGE: UiLanguage = "en";
export const UI_LANGUAGES = Object.keys(CATALOGS) as UiLanguage[];

const MAX_TAGS = 6;

function canonical(tag: string): string | undefined {
  if (!/^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$/.test(tag)) return undefined;
  try {
    return Intl.getCanonicalLocales(tag)[0];
  } catch {
    return undefined;
  }
}

/** The tags of an `Accept-Language` header, highest weight first; `*`, `q=0` and malformed entries are left out. */
export function parseAcceptLanguage(header: string | null | undefined): string[] {
  if (!header) return [];
  const entries: { tag: string; q: number; i: number }[] = [];
  for (const [i, part] of header.split(",").slice(0, 32).entries()) {
    const [raw, ...params] = part.trim().split(";");
    const tag = canonical(raw?.trim() ?? "");
    if (!tag) continue;
    const qParam = params.map((p) => p.trim()).find((p) => p.startsWith("q="));
    const q = qParam === undefined ? 1 : Number(qParam.slice(2));
    if (!Number.isFinite(q) || q <= 0 || q > 1) continue;
    entries.push({ tag, q, i });
  }
  entries.sort((a, b) => b.q - a.q || a.i - b.i);
  return [...new Set(entries.map((e) => e.tag))].slice(0, MAX_TAGS);
}

/** Tags as stored (`fr-FR,en`), back to a list; anything malformed is dropped. */
export function splitTags(stored: string | null | undefined): string[] {
  return (stored ?? "").split(",").map((t) => canonical(t.trim())).filter((t): t is string => !!t).slice(0, MAX_TAGS);
}

const primary = (tag: string) => tag.split("-")[0]!.toLowerCase();

/** The first of `tags` the gateway has texts for; English when none. */
export function uiLanguage(tags: readonly string[] | string | undefined): UiLanguage {
  const list = typeof tags === "string" ? splitTags(tags) : (tags ?? []);
  for (const tag of list) {
    const p = primary(tag);
    if ((UI_LANGUAGES as string[]).includes(p)) return p as UiLanguage;
  }
  return DEFAULT_UI_LANGUAGE;
}

const names = new Intl.DisplayNames(["en"], { type: "language", fallback: "none" });

/** The language a tag names, in English as a bot reads it (`fr-CA` → `French`); undefined when unknown. */
export function languageName(tag: string | undefined): string | undefined {
  if (!tag) return undefined;
  try {
    return names.of(primary(tag)) ?? undefined;
  } catch {
    return undefined;
  }
}

/**
 * NUO_LANGUAGE_<PROFILE> (the profile id in capitals, `-` as `_`), else NUO_LANGUAGE: the user's languages for that
 * profile, whatever the apps send. Same syntax as `Accept-Language` (`fr`, `fr-FR,en`).
 */
export function forcedLanguages(profileId: string, env: Record<string, string | undefined> = process.env): string[] | undefined {
  const own = env[`NUO_LANGUAGE_${profileId.toUpperCase().replace(/-/g, "_")}`]?.trim();
  const raw = own || env.NUO_LANGUAGE?.trim();
  if (!raw) return undefined;
  const tags = parseAcceptLanguage(raw);
  if (!tags.length) throw new Error(`NUO_LANGUAGE must be language tags such as "fr" or "en-US,fr", not "${raw}"`);
  return tags;
}

/** The language of what the gateway answers the request (or socket message) being handled. */
const current = new AsyncLocalStorage<{ lang: UiLanguage }>();

export function withLanguage<T>(lang: UiLanguage, fn: () => T): T {
  return current.run({ lang }, fn);
}

/** Once the request's profile is known, its forced language replaces what the request asked for. */
export function setRequestLanguage(lang: UiLanguage) {
  const scope = current.getStore();
  if (scope) scope.lang = lang;
}

export function requestLanguage(): UiLanguage | undefined {
  return current.getStore()?.lang;
}

/**
 * `key` in `lang`, by default the language of the request being answered, else English; `{name}` takes
 * `params.name`. A key missing from a catalog falls back to English.
 */
export function t(key: MessageKey, params: Record<string, string | number> = {}, lang: UiLanguage = requestLanguage() ?? DEFAULT_UI_LANGUAGE): string {
  const catalog: Partial<Record<MessageKey, string>> = CATALOGS[lang];
  const text = catalog[key] ?? CATALOGS[DEFAULT_UI_LANGUAGE][key];
  return text.replace(/\{(\w+)\}/g, (m, name: string) => (name in params ? String(params[name]) : m));
}
