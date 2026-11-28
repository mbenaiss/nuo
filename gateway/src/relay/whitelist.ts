import { DEFAULT_UI_LANGUAGE, t, type UiLanguage } from "../i18n/language";
import type { MessageKey } from "../i18n/messages";
import { head } from "../text";

/**
 * What a bot may do during a turn the relay passed on (the watch's request while the iPhone is locked): add, and
 * nothing else (docs/security.md, "Relay access"). Every tool a bot session can be offered is named here; the
 * gateway refuses the rest wherever it can see it: the agent's permission request, the `nuo` server's own calls,
 * and the local routes those calls reach.
 */

/** What a refused tool answers the bot, word for word: the request waits for the iPhone to be unlocked. */
export const RELAY_REFUSAL = "to do from the unlocked iPhone";

export type RelayRule = "add" | "refused";

/** The tools of the gateway's own `nuo` server. A new one fails the test until it is classified. */
export const NUO_TOOL_RULES: Record<string, RelayRule> = {
  // Added for the relay only: each writes one new thing and reads only what that needs.
  reminder_add: "add",
  reminder_done: "add",
  note_add: "add",
  collection_add: "add",
  // Calendars: a new event; moving one only if this turn created it; Google invitations are e-mails, so none.
  apple_event_create: "add",
  apple_event_update: "add",
  calendar_create: "add",
  // A request to another bot in a new conversation of its own; that turn is a relay turn too.
  bot_ask: "add",

  // Scheduled tasks run later, as the bot, without the relay's limits.
  schedule_create: "refused",
  schedule_update: "refused",
  schedule_delete: "refused",
  schedule_list: "refused",
  notify_user: "refused",
  memory_read: "refused",
  memory_add: "refused",
  memory_write: "refused",
  // Google: mail and Drive are personal data, sending is sending.
  google_accounts: "refused",
  gmail_search: "refused",
  gmail_read: "refused",
  gmail_draft: "refused",
  gmail_send: "refused",
  drive_search: "refused",
  drive_read: "refused",
  calendar_list: "refused",
  calendar_events: "refused",
  calendar_delete: "refused",
  // The iPhone and the Mac: reading calendars, files, the location; changing or deleting what exists.
  apple_calendars: "refused",
  apple_events: "refused",
  apple_event_delete: "refused",
  apple_calendar_create: "refused",
  apple_calendar_update: "refused",
  apple_calendar_delete: "refused",
  device_location: "refused",
  weather: "refused",
  // Health: the most personal data the iPhone holds, and a session put on the watch is not an "add" of this kind.
  health_summary: "refused",
  health_activity: "refused",
  health_heart: "refused",
  health_sleep: "refused",
  health_workouts: "refused",
  health_body: "refused",
  workout_schedule: "refused",
  workout_scheduled: "refused",
  workout_cancel: "refused",
  maps_search: "refused",
  maps_route: "refused",
  mac_folders: "refused",
  mac_files_list: "refused",
  mac_files_search: "refused",
  mac_file_read: "refused",
  mac_file_write: "refused",
  parcel_track: "refused",
  parcel_list: "refused",
  product_lookup: "refused",
  // The overview bot's reading tools.
  bots_list: "refused",
  conversations_search: "refused",
  conversation_read: "refused",
};

/**
 * Claude Code's built-in tools that bots get (BOT_BUILTIN_TOOLS). A relay session is offered only the loader of the
 * `nuo` server's schemas; the shell, files, web and subagents are not offered at all.
 */
export const BUILTIN_TOOL_RULES: Record<string, "offered" | "refused"> = {
  ToolSearch: "offered",
  Bash: "refused",
  Read: "refused",
  Edit: "refused",
  Write: "refused",
  WebFetch: "refused",
  WebSearch: "refused",
  Agent: "refused",
  SendMessage: "refused",
  Monitor: "refused",
  TaskStop: "refused",
  Skill: "refused",
};

export const RELAY_BUILTIN_TOOLS = Object.keys(BUILTIN_TOOL_RULES).filter((n) => BUILTIN_TOOL_RULES[n] === "offered");

/** The only MCP server of a relay session. */
export const RELAY_SERVER = "nuo";

export interface RelayToolCall {
  /** The MCP server; none for a built-in tool. */
  server?: string;
  name: string;
  input?: Record<string, unknown>;
}

/** What the current relay turn did, for the tools allowed only on its own work. */
export interface RelayTurnFacts {
  createdEvents: ReadonlySet<string>;
}

/** For the bot, which tells the user in their language. */
export function relayRefusalText(name: string): string {
  return `"${name || "this tool"}": ${RELAY_REFUSAL}. While the iPhone is locked, I can only add a reminder, an event, a note or a collection item, or pass a message to a bot.`;
}

/** Undefined when the call may go on to its confirmation; otherwise the answer the bot gets. */
export function relayRefusal(call: RelayToolCall, facts: RelayTurnFacts): string | undefined {
  const refuse = () => relayRefusalText(call.name);
  if (!call.server) return BUILTIN_TOOL_RULES[call.name] === "offered" ? undefined : refuse();
  if (call.server !== RELAY_SERVER || NUO_TOOL_RULES[call.name] !== "add") return refuse();
  const input = call.input ?? {};
  // Only a local time as the watch shows it: no time zone or whole day that would put it elsewhere than shown.
  if ((LOCAL_TIME_FIELDS[call.name] ?? []).some((f) => present(input[f]) && !(typeof input[f] === "string" && LOCAL_TIME.test(input[f] as string)))) return refuse();
  switch (call.name) {
    case "bot_ask":
      // Taking up an existing conversation reads it back.
      return present(input.conversation) || present(input.conversationId) ? refuse() : undefined;
    case "calendar_create":
      // Google reads guests from a list or a comma-separated string, and e-mails each: none, in any form.
      return Object.hasOwn(input, "attendees") ? refuse() : undefined;
    case "apple_event_update":
      return typeof input.id === "string" && facts.createdEvents.has(input.id) ? undefined : refuse();
    default:
      return undefined;
  }
}

/** `YYYY-MM-DDTHH:MM`, exactly. */
export const LOCAL_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/;
const LOCAL_TIME_FIELDS: Record<string, string[]> = {
  reminder_add: ["at"],
  apple_event_create: ["start", "end"],
  apple_event_update: ["start", "end", "occurrence_start"],
  calendar_create: ["start", "end"],
};

/**
 * What a relay call may not choose: the account or the calendar (the default one only, whose name the relay never
 * learns), nor Google guests. Dropped from what the gateway passes on.
 */
export const RELAY_DROPPED_FIELDS = ["attendees", "account", "calendar_id", "calendar"] as const;

function present(v: unknown): boolean {
  return typeof v === "string" ? v.trim() !== "" : v !== undefined && v !== null;
}

const MCP_NAME = /^mcp__([A-Za-z0-9_.-]+?)__([A-Za-z0-9_-]+)$/;

/**
 * The tool an ACP permission request is about: Claude names it in `_meta.claudeCode.toolName`; otherwise only a title
 * that is exactly `mcp__<server>__<tool>`, on a call that is neither a command nor an edit (their titles quote what
 * they run). Undefined when nothing says (then refused like any unknown tool).
 */
export function toolFromAcp(toolCall: unknown): RelayToolCall | undefined {
  if (!toolCall || typeof toolCall !== "object") return undefined;
  const call = toolCall as { title?: unknown; kind?: unknown; rawInput?: unknown; _meta?: { claudeCode?: { toolName?: unknown } } };
  const input = call.rawInput && typeof call.rawInput === "object" && !Array.isArray(call.rawInput) ? (call.rawInput as Record<string, unknown>) : undefined;
  const named = call._meta?.claudeCode?.toolName;
  if (typeof named === "string" && named) {
    const m = MCP_NAME.exec(named);
    return m ? { server: m[1]!, name: m[2]!, input } : { name: named, input };
  }
  if (call.kind === "execute" || call.kind === "edit" || typeof call.title !== "string") return undefined;
  const m = MCP_NAME.exec(call.title);
  return m ? { server: m[1]!, name: m[2]!, input } : undefined;
}

const SUMMARY_MAX = 90;

function said(v: unknown, max = SUMMARY_MAX): string {
  if (typeof v !== "string" && typeof v !== "number") return "";
  const t = String(v).replace(/\s+/g, " ").trim();
  return t.length > max ? `${head(t, max - 1).trimEnd()}…` : t;
}

/** `2026-11-16T10:00` (Paris time, as the tools take it) as "Mon, Nov 16, 10:00"; anything else as written. */
function when(v: unknown, lang: UiLanguage, withYear = false): string {
  const raw = said(v, 40);
  const m = raw.match(/^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}))?/);
  if (!m) return raw;
  const day = new Date(Date.UTC(+m[1]!, +m[2]! - 1, +m[3]!, 12));
  const date = new Intl.DateTimeFormat(t("locale", {}, lang), { timeZone: "UTC", weekday: "short", day: "numeric", month: "short", ...(withYear ? { year: "numeric" } : {}) }).format(day);
  return m[4] ? `${date}, ${m[4]}:${m[5]}` : date;
}

const quoted = (v: unknown, lang: UiLanguage) => (said(v) ? t("relay.quoted", { text: said(v) }, lang) : "");

/** ", Mon, Nov 16, 10:00-11:00", or with the end's day when it is another one: how long it lasts shows. */
function span(start: unknown, end: unknown, lang: UiLanguage): string {
  const from = when(start, lang);
  if (!from) return "";
  const s = said(start, 40);
  const e = said(end, 40);
  if (!e) return `, ${from}`;
  const sameDay = s.slice(0, 10) === e.slice(0, 10) && /T\d{2}:\d{2}$/.test(e);
  return sameDay ? `, ${from}-${e.slice(11, 16)}` : `, ${t("relay.until", { from, to: when(e, lang, s.slice(0, 4) !== e.slice(0, 4)) }, lang)}`;
}

const place = (v: unknown, lang: UiLanguage) => (said(v, 60) ? `, ${t("relay.at", { place: quoted(said(v, 60), lang) }, lang)}` : "");

/** ", alerts 10 and 60 min before"; "at the time of the event" for 0. */
function alerts(v: unknown, lang: UiLanguage): string {
  if (!Array.isArray(v) || !v.length) return "";
  const each = v.filter((m): m is number => typeof m === "number").map((m) => (m === 0 ? t("relay.alertOnTime", {}, lang) : t("relay.alertBefore", { minutes: Math.round(m) }, lang)));
  if (!each.length) return "";
  const list = each.length > 1 ? t("relay.list", { items: each.slice(0, -1).join(", "), last: each.at(-1)! }, lang) : each[0]!;
  return `, ${t(each.length > 1 ? "relay.alerts" : "relay.alert", { list }, lang)}`;
}

/**
 * What a relay confirmation is about, in words: the watch shows it above its Allow button, so the yes is given for
 * this reminder or this event, not for a tool name. In the user's language (`lang`, the profile's).
 */
export function relayConfirmationTitle(call: RelayToolCall, lang: UiLanguage = DEFAULT_UI_LANGUAGE): string {
  const a = call.input ?? {};
  const q = (v: unknown) => quoted(v, lang);
  const parts = (...p: string[]) => p.filter(Boolean).join(" ");
  const labelled = (label: string, value: string) => (value ? t("relay.labelled", { label, value }, lang) : label);
  const at = (v: unknown) => (when(v, lang) ? `, ${when(v, lang)}` : "");
  const extras = (...texts: unknown[]) =>
    (a.all_day === true ? `, ${t("relay.allDay", {}, lang)}` : "") + repeats(a.recurrence, lang) + (texts.some((x) => said(x)) ? ` ${t("relay.attachedText", {}, lang)}` : "");
  const event = (key: MessageKey) => parts(t(key, {}, lang), q(a.title)) + span(a.start, a.end, lang) + place(a.location, lang);
  switch (call.server === RELAY_SERVER ? call.name : "") {
    case "reminder_add":
      return parts(t("relay.reminderAdd", {}, lang), q(a.title)) + at(a.at) + extras(a.notes);
    case "reminder_done":
      return parts(t("relay.reminderDone", {}, lang), q(a.title));
    case "note_add":
      return parts(t("relay.noteAdd", {}, lang), q(a.title)) + extras(a.content);
    case "collection_add": {
      const values = a.values && typeof a.values === "object" && !Array.isArray(a.values) ? Object.values(a.values as Record<string, unknown>) : [];
      return labelled(t("relay.collectionAdd", { collection: said(a.collection, 40) || t("relay.aCollection", {}, lang) }, lang), q(values.find((v) => said(v))));
    }
    case "apple_event_create":
      return event("relay.eventAdd") + alerts(a.alarms, lang) + extras(a.notes, a.url);
    case "calendar_create":
      return event("relay.googleEventAdd") + extras(a.description);
    case "apple_event_update":
      return event("relay.eventUpdate") + alerts(a.alarms, lang) + extras(a.notes, a.url);
    case "bot_ask":
      return labelled(t("relay.botAsk", { bot: said(a.bot, 40) || t("relay.aBot", {}, lang) }, lang), q(a.prompt));
    default:
      return call.server ? `mcp__${call.server}__${call.name}` : call.name;
  }
}

const EVERY: Record<string, [MessageKey, MessageKey]> = {
  daily: ["relay.everyDay", "relay.everyDays"],
  weekly: ["relay.everyWeek", "relay.everyWeeks"],
  monthly: ["relay.everyMonth", "relay.everyMonths"],
  yearly: ["relay.everyYear", "relay.everyYears"],
};

/** ", every week", ", every 2 weeks"; nothing for no recurrence. Unknown values are said as they are. */
function repeats(r: unknown, lang: UiLanguage): string {
  if (!r || typeof r !== "object") return "";
  const { frequency, interval } = r as { frequency?: unknown; interval?: unknown };
  if (frequency === "none" || frequency === undefined) return "";
  const every = typeof frequency === "string" ? EVERY[frequency] : undefined;
  if (!every) return `, ${t("relay.repeated", { frequency: said(frequency, 20) || "?" }, lang)}`;
  const n = typeof interval === "number" && interval > 1 ? Math.round(interval) : 1;
  return `, ${n > 1 ? t(every[1], { n }, lang) : t(every[0], {}, lang)}`;
}
