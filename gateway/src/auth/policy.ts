/** Who may call what: the scopes of extension tokens and the routes that need a fresh step-up (docs/protocol.md). */

import { existsSync, readFileSync } from "node:fs";

export type Scope = "app" | "share" | "widgets" | "watch" | "machine" | "relay";
export const EXTENSION_SCOPES = ["share", "widgets", "watch"] as const;
export type ExtensionScope = (typeof EXTENSION_SCOPES)[number];

/** Why a route needs a step-up; the app turns it into the Face ID prompt reason. */
export type StepUpReason = "devices" | "finance" | "commands" | "docs" | "secrets" | "bots" | "relay";

/** One confirmation per call: a step-up token cannot reveal or change a second secret. */
export const SINGLE_USE_STEP_UP: ReadonlySet<StepUpReason> = new Set(["secrets", "bots", "relay"]);
/** Taken for that action by name (`reason` in the step-up): a Face ID given for another action does not do. */
export const BOUND_STEP_UP: ReadonlySet<StepUpReason> = new Set(["relay"]);
export const SECRETS_PATH = /^\/api\/secrets(\/|$)/;

type Rule = [method: string, path: RegExp];

const READ_ONLY: Rule[] = [
  ["GET", /^\/api\/bots$/],
  ["GET", /^\/api\/conversations$/],
  ["GET", /^\/api\/reminders$/],
  ["GET", /^\/api\/reminders\/lists$/],
  ["GET", /^\/api\/calendar\/events$/],
];
/** Checking a reminder off from a widget or a complication. */
const REMINDER_DONE: Rule[] = [
  ["POST", /^\/api\/reminders\/[^/]+\/done$/],
  ["POST", /^\/api\/reminders\/[^/]+\/undone$/],
];
const PROMPT: Rule[] = [
  ["POST", /^\/api\/conversations$/],
  ["POST", /^\/api\/conversations\/[^/]+\/prompt$/],
];

/**
 * What a machine token may do (NUO_MACHINE_TOKEN): hold a conversation with a bot, nothing else. It is a
 * standing credential on another host (Forma's server asking its bot to draw a part), so it reads and writes
 * conversations and never touches devices, data, schedules or secrets.
 */
export const MACHINE_RULES: Rule[] = [
  ["GET", /^\/api\/bots$/],
  ["GET", /^\/api\/conversations\/[^/]+$/],
  ["GET", /^\/api\/conversations\/[^/]+\/messages$/],
  ...PROMPT,
];

/**
 * What a relay token may do (docs/security.md, "Relay access"): the iPhone passes on the watch's spoken requests
 * while it is locked. It transcribes a short dictation, opens conversations and prompts in them, reads them and
 * answers their confirmations once; the server further limits each of those to the conversations this relay
 * opened and to its own transcription jobs. Nothing else: no data, docs, devices, secrets, settings or socket.
 */
export const RELAY_RULES: Rule[] = [
  ["POST", /^\/api\/transcriptions$/],
  ["GET", /^\/api\/transcriptions\/[0-9a-f-]{36}$/],
  ["DELETE", /^\/api\/transcriptions\/[0-9a-f-]{36}$/],
  ["GET", /^\/api\/bots$/],
  ["POST", /^\/api\/conversations$/],
  ["GET", /^\/api\/conversations\/[^/]+$/],
  ["GET", /^\/api\/conversations\/[^/]+\/messages$/],
  ["POST", /^\/api\/conversations\/[^/]+\/prompt$/],
  ["POST", /^\/api\/conversations\/[^/]+\/permission$/],
];

export const SCOPE_RULES: Record<ExtensionScope, Rule[]> = {
  share: [["GET", /^\/api\/bots$/], ["GET", /^\/api\/conversations$/], ...PROMPT],
  widgets: [...READ_ONLY, ...REMINDER_DONE],
  watch: [...READ_ONLY, ...REMINDER_DONE, ["GET", /^\/api\/conversations\/[^/]+\/messages$/], ...PROMPT],
};

/** WebSocket events an extension token may send; widgets have no socket. */
export const SOCKET_EVENTS: Record<Scope, ReadonlySet<string> | "all"> = {
  app: "all",
  machine: new Set(),
  relay: new Set(),
  watch: new Set(["ping", "prompt", "cancel", "turns.sync", "presence"]),
  share: new Set(),
  widgets: new Set(),
};

export function scopeAllows(scope: Scope, method: string, path: string): boolean {
  if (scope === "app") return true;
  if (path === "/api/ws") return SOCKET_EVENTS[scope] !== "all" && (SOCKET_EVENTS[scope] as Set<string>).size > 0;
  const rules = scope === "machine" ? MACHINE_RULES : scope === "relay" ? RELAY_RULES : SCOPE_RULES[scope];
  return rules.some(([m, re]) => m === method && re.test(path));
}

export const FINANCE_COLLECTIONS_FILE = new URL("../../config/finance-collections.json", import.meta.url).pathname;

/** Reads the optional list of collections to protect; an absent file protects only `money` collections. */
export function loadFinanceCollections(path = FINANCE_COLLECTIONS_FILE): ReadonlySet<string> {
  if (!existsSync(path)) return new Set();
  const ids: unknown = JSON.parse(readFileSync(path, "utf8"));
  if (!Array.isArray(ids) || !ids.every((id) => typeof id === "string")) throw new Error(`${path}: expected an array of collection ids`);
  return new Set(ids);
}

/**
 * Collections whose edits need a step-up, listed in `config/finance-collections.json`. Any collection with a `money`
 * column also counts (see `isFinanceCollection` in the server), so new finance tables are covered without a list.
 */
export const FINANCE_COLLECTIONS = loadFinanceCollections();

export interface PolicyLookups {
  isFinanceCollection(id: string): boolean;
  isCommandTask(id: string): boolean;
  /** Publishing this bot's draft would give it `auto` permissions it does not have yet. */
  publishGrantsAuto?(botId: string): boolean;
}

const ROW_WRITE = /^\/api\/data\/collections\/([^/]+)\/rows(?:\/[^/]+(?:\/(?:archive|unarchive))?)?$/;

/** `body` is the parsed JSON body for POST/PATCH /api/schedules, undefined otherwise. */
export function stepUpRequired(method: string, path: string, body: unknown, l: PolicyLookups): StepUpReason | undefined {
  if (method === "DELETE" && /^\/api\/devices\/[^/]+$/.test(path)) return "devices";
  // Each secret call is confirmed by its own Face ID signature (the secrets routes check it); registering the
  // key that makes those signatures takes a regular step-up.
  if (method === "POST" && path === "/api/auth/action-key") return "secrets";
  // A key that obtains tokens while the iPhone is locked: set up with the owner's face only.
  if (method === "POST" && path === "/api/auth/relay") return "relay";
  // A bot in `auto` runs any tool without asking: giving that power needs the owner's face, not just a token.
  if (method === "PUT" && /^\/api\/bots\/[^/]+\/permissions$/.test(path) && (body as { permissionPolicy?: unknown } | undefined)?.permissionPolicy === "auto") return "bots";
  const publish = path.match(/^\/api\/bots\/([^/]+)\/publish$/);
  if (publish && method === "POST" && l.publishGrantsAuto?.(decodeURIComponent(publish[1]!))) return "bots";
  if (method === "DELETE" && (path === "/api/docs/file" || path === "/api/docs/folder")) return "docs";
  if (method !== "GET") {
    const row = path.match(ROW_WRITE);
    if (row && l.isFinanceCollection(decodeURIComponent(row[1]!))) return "finance";
    // The history entry may belong to any collection; reverting is rare enough to always confirm.
    if (/^\/api\/data\/history\/[^/]+\/revert$/.test(path)) return "finance";
  }
  const sentAction = (body as { action?: { type?: unknown } } | undefined)?.action?.type;
  if (method === "POST" && path === "/api/schedules" && sentAction === "command") return "commands";
  const task = path.match(/^\/api\/schedules\/([^/]+)$/);
  if (task && method === "PATCH" && (sentAction === "command" || l.isCommandTask(decodeURIComponent(task[1]!)))) return "commands";
  return undefined;
}

export const needsBody = (method: string, path: string) =>
  (method === "POST" && path === "/api/schedules") || (method === "PATCH" && /^\/api\/schedules\/[^/]+$/.test(path)) || (method === "PUT" && /^\/api\/bots\/[^/]+\/permissions$/.test(path));
