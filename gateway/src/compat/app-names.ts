/**
 * The app's name in every identifier the gateway and the apps share: signed messages (`nuo-auth:v1:`,
 * `nuo-action:v1:`), headers (`x-nuo-…`), notification categories (`nuo.answer`) and links (`nuo://`).
 *
 * After a rename, apps installed before it keep the old name in those identifiers until each one is updated.
 * NUO_LEGACY_APP_PREFIX holds that old name: while it is set the gateway accepts both names from the apps and
 * answers each device in the name it last signed with (docs/install.md, « Apps built under an earlier name »).
 * Unset, only APP_NAME exists and nothing here changes a request or an answer.
 */
export const APP_NAME = "nuo";

/** Letters and digits only: no `-`, `:`, `.` or `/` that could make one signed message read as another. */
const PREFIX = /^[a-z][a-z0-9]{1,31}$/;

export function legacyAppPrefix(env: Record<string, string | undefined> = process.env): string | undefined {
  const raw = env.NUO_LEGACY_APP_PREFIX?.trim();
  if (!raw) return undefined;
  if (!PREFIX.test(raw) || raw === APP_NAME) throw new Error(`NUO_LEGACY_APP_PREFIX must be 2 to 32 lowercase letters and digits, other than "${APP_NAME}"`);
  return raw;
}

/** The names a device may use, the current one first. */
export function acceptedAppNames(env: Record<string, string | undefined> = process.env): string[] {
  const legacy = legacyAppPrefix(env);
  return legacy ? [APP_NAME, legacy] : [APP_NAME];
}

/**
 * Which name a device last signed with. A device without one (NULL in the table) was paired before the gateway
 * kept track, that is by an app of the old name.
 */
export type AppNaming = "current" | "legacy";

export const namingOf = (name: string): AppNaming => (name === APP_NAME ? "current" : "legacy");

/** The name to answer a device in. */
export function appNameFor(naming: AppNaming | undefined, env: Record<string, string | undefined> = process.env): string {
  const legacy = legacyAppPrefix(env);
  return legacy && naming !== "current" ? legacy : APP_NAME;
}

/** `nuo://data/colis/42` in `name`'s scheme; any other link is returned as is. */
export function appLink(url: string, name: string): string {
  return name !== APP_NAME && url.startsWith(`${APP_NAME}://`) ? `${name}://${url.slice(APP_NAME.length + 3)}` : url;
}

/** `nuo.answer` in `name`'s namespace; any other category is returned as is. */
export function appCategory(category: string, name: string): string {
  return name !== APP_NAME && category.startsWith(`${APP_NAME}.`) ? `${name}.${category.slice(APP_NAME.length + 1)}` : category;
}

/** A link a device or a script sent in an accepted name, in the current one; undefined when it is not an app link. */
export function currentAppLink(url: string, env: Record<string, string | undefined> = process.env): string | undefined {
  const name = acceptedAppNames(env).find((n) => url.startsWith(`${n}://`));
  return name === undefined ? undefined : `${APP_NAME}://${url.slice(name.length + 3)}`;
}

/** The value of the first accepted `x-<name>-<suffix>` header present, and the name it came under. */
export function appHeader(headers: Headers, suffix: string, env: Record<string, string | undefined> = process.env): { value: string; name: string } | undefined {
  for (const name of acceptedAppNames(env)) {
    const value = headers.get(`x-${name}-${suffix}`);
    if (value !== null) return { value, name };
  }
  return undefined;
}
