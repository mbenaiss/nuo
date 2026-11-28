import { en, type MessageKey } from "./catalog/en";
import { fr } from "./catalog/fr";

export type { MessageKey };

/**
 * One catalog per language the gateway writes in. Adding one: a file next to `fr.ts` and a line here; a key it
 * lacks falls back to English.
 */
export const CATALOGS = { en, fr } satisfies Record<string, Partial<Record<MessageKey, string>>>;
