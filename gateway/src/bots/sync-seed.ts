import { readFileSync } from "node:fs";
import type { BotCommand, BotConfig } from "../protocol";
import { t } from "../i18n/language";
import type { Store } from "../store/store";
import type { ToolCatalog } from "./catalog";
import { validateCommands } from "./commands";


export interface SyncResult {
  name: string;
  status: "published" | "unchanged" | "missing" | "invalid";
  version?: number;
  detail?: string;
}

/** Seed commands replace same-named ones; commands added by hand are kept. */
export function mergeCommands(current: BotCommand[] | undefined, seed: BotCommand[]): BotCommand[] {
  const names = new Set(seed.map((c) => c.name));
  return [...seed, ...(current ?? []).filter((c) => !names.has(c.name))];
}

/**
 * Publishes a new version of every seed bot (matched by name) whose commands differ from the seed's.
 * Only `commands` changes; a pending draft gets the same commands so publishing it later keeps them.
 */
export function syncSeedCommands(store: Store, catalog: ToolCatalog, seedPath: string): SyncResult[] {
  const entries = JSON.parse(readFileSync(seedPath, "utf8")) as { config: BotConfig }[];
  const bots = store.bots();
  return entries.map(({ config: seed }): SyncResult => {
    const name = seed.name;
    const bot = bots.find((b) => b.published?.config.name === name);
    if (!bot?.published) return { name, status: "missing" };
    const current = bot.published.config;
    const errors: string[] = [];
    const commands = mergeCommands(current.commands, validateCommands(seed.commands ?? [], current.toolServers, catalog, errors) ?? []);
    if (errors.length) return { name, status: "invalid", detail: errors.join("; ") };
    if (JSON.stringify(current.commands ?? []) === JSON.stringify(commands)) return { name, status: "unchanged", version: bot.published.version };
    const version = store.publish(bot.id, { ...current, commands }, t("bots.commandsAdded", {}, store.uiLanguage()), false);
    if (bot.draft) store.setDraft(bot.id, { ...bot.draft, commands: mergeCommands(bot.draft.commands, commands) });
    return { name, status: "published", version };
  });
}
