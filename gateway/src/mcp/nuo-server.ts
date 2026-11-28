// Built-in stdio MCP server injected into every bot session: lets the agent manage its scheduled tasks
// and its persistent memory by calling the gateway REST API with the local token.
import { existsSync, readFileSync } from "node:fs";
import { readFile, stat } from "node:fs/promises";
import { extname, resolve } from "node:path";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import type { BotMemory, ScheduledTask, TaskSchedule } from "../protocol";
import { isValidTimeZone, tzOffset, zonedToUtc } from "../scheduler/cron";
import { GOOGLE_TOOL_NAMES, GOOGLE_TOOLS } from "../google/tools";
import { DEVICE_TOOL_NAMES, DEVICE_TOOLS, MAX_MAC_FILE_BYTES } from "../device/tools";
import { SCAN_TOOL_NAMES, SCAN_TOOLS } from "../scan/tools";
import { parseDotenv } from "../bots/catalog";
import { CALLER_HEADER, callOverviewTool, OVERVIEW_TOOL_NAMES, OVERVIEW_TOOLS, OverviewToolError } from "./overview-tools";
import { RELAY_ADD_TOOL_NAMES, RELAY_ADD_TOOLS } from "../relay/tools";
import { NUO_TOOL_RULES, RELAY_DROPPED_FIELDS, relayRefusalText } from "../relay/whitelist";

const DEFAULT_TIMEZONE = "Europe/Paris";

export interface NuoEnv {
  url: string;
  token: string;
  botId: string;
  conversationId?: string;
  /** The bot sees every bot and conversation (BotConfig.overview). */
  overview?: boolean;
  /** A session the relay started: only the tools that add (src/relay/whitelist.ts). */
  relay?: boolean;
}

type Args = Record<string, unknown>;

class ToolError extends Error {}

export function describeNow(tz: string, now = Date.now()): string {
  const date = new Intl.DateTimeFormat("en-GB", { timeZone: tz, dateStyle: "full", timeStyle: "short" }).format(new Date(now));
  const off = tzOffset(now, tz) / 60_000;
  const sign = off < 0 ? "-" : "+";
  const hh = String(Math.floor(Math.abs(off) / 60)).padStart(2, "0");
  const mm = String(Math.abs(off) % 60).padStart(2, "0");
  return `${date} (${tz}, UTC${sign}${hh}:${mm})`;
}

function formatInstant(iso: string | undefined, tz: string): string {
  if (!iso) return "none";
  return new Intl.DateTimeFormat("en-GB", { timeZone: tz, dateStyle: "full", timeStyle: "short" }).format(new Date(iso));
}

/** A date without offset is a wall-clock time in `tz`, which is what an agent naturally writes. */
export function parseAt(at: string, tz: string): string {
  const m = at.trim().match(/^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?$/);
  if (m) return new Date(zonedToUtc(+m[1]!, +m[2]!, +m[3]!, +m[4]!, +m[5]!, tz) + Number(m[6] ?? 0) * 1000).toISOString();
  const t = Date.parse(at);
  if (!Number.isFinite(t)) throw new ToolError(`invalid date "${at}": use the format 2026-10-18T07:00`);
  return new Date(t).toISOString();
}

function scheduleFrom(a: Args, fallbackTz: string, now: number): TaskSchedule | undefined {
  const tz = typeof a.timezone === "string" && a.timezone ? a.timezone : fallbackTz;
  if (!isValidTimeZone(tz)) throw new ToolError(`unknown time zone "${tz}"`);
  const given = [a.cron, a.at, a.in_minutes].filter((v) => v !== undefined && v !== null && v !== "").length;
  if (given > 1) throw new ToolError("give only one of cron, at or in_minutes");
  if (typeof a.cron === "string" && a.cron.trim()) return { kind: "cron", expr: a.cron.trim(), timezone: tz };
  if (typeof a.at === "string" && a.at.trim()) return { kind: "once", at: parseAt(a.at, tz) };
  if (a.in_minutes !== undefined && a.in_minutes !== null && a.in_minutes !== "") {
    const n = Number(a.in_minutes);
    if (!Number.isFinite(n) || n < 1) throw new ToolError("in_minutes must be a number of minutes ≥ 1");
    return { kind: "once", at: new Date(now + Math.round(n) * 60_000).toISOString() };
  }
  return undefined;
}

function describeTask(t: ScheduledTask, self: string): string {
  const tz = t.schedule.kind === "cron" ? t.schedule.timezone : DEFAULT_TIMEZONE;
  const when = t.schedule.kind === "cron" ? `cron "${t.schedule.expr}" (${t.schedule.timezone})` : `once, ${formatInstant(t.schedule.at, tz)}`;
  return [
    `- ${t.title} [id ${t.id}]${t.botId === self ? "" : ` (bot ${t.botId})`}`,
    `  when: ${when}`,
    `  next run: ${t.enabled ? formatInstant(t.nextRunAt, tz) : "disabled"}`,
    t.action?.type === "command"
      ? `  command (read only, managed from the app): ${clip(t.action.command, 200)}${t.action.cwd ? ` · folder: ${t.action.cwd}` : ""}${t.lastStatus ? ` · last status: ${t.lastStatus}` : ""}`
      : `  conversation: ${t.conversation === "new" ? "a new one each time" : "dedicated"} · notification: ${t.notify ? "yes" : "no"}${t.lastStatus ? ` · last status: ${t.lastStatus}` : ""}\n  prompt: ${clip(t.prompt, 200)}`,
  ].join("\n");
}

function clip(s: string, max: number) {
  return s.length > max ? `${s.slice(0, max - 1)}…` : s;
}

const BINARY_EXTENSIONS = new Set([".pdf", ".png", ".jpg", ".jpeg", ".gif", ".heic", ".webp", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".key", ".pages", ".numbers", ".zip", ".gz", ".mp3", ".m4a", ".mp4", ".mov"]);

/**
 * `mac_file_write` with `from`: this server runs as the bot, so it reads the bot's own file and sends its bytes; the
 * agent never has to spell out a PDF.
 */
async function withFileContent(a: Args): Promise<Args> {
  if (typeof a.from !== "string" || !a.from.trim()) {
    // A bot once wrote a PDF as hex text in nine appends; a binary file goes in one copy or not at all.
    const ext = typeof a.path === "string" ? extname(a.path).toLowerCase() : "";
    if (typeof a.content === "string" && BINARY_EXTENSIONS.has(ext)) {
      throw new ToolError(`a ${ext} file is not written as text: pass the file of your workspace in \`from\`, it is copied as it is in one go`);
    }
    return a;
  }
  if (typeof a.content === "string") throw new ToolError("give content or from, not both");
  const path = resolve(a.from.trim());
  const info = await stat(path).catch(() => undefined);
  if (!info?.isFile()) throw new ToolError(`${path} is not a file of your workspace`);
  if (info.size > MAX_MAC_FILE_BYTES) throw new ToolError(`${path} is ${Math.ceil(info.size / 1024 / 1024)} MB: 30 MB at most`);
  const { from: _, ...rest } = a;
  return { ...rest, content_base64: (await readFile(path)).toString("base64") };
}

export function toolDefinitions(now = Date.now(), opts: { overview?: boolean; relay?: boolean } = {}) {
  const all = [...allToolDefinitions(now, opts), ...(opts.relay ? RELAY_ADD_TOOLS : [])];
  return opts.relay ? all.filter((t) => NUO_TOOL_RULES[t.name] === "add").map(forRelay) : all;
}

/** A relay session is not offered what the gateway drops (src/relay/whitelist.ts), and gives times as the watch shows them. */
function forRelay<T extends { inputSchema: unknown }>(tool: T): T {
  const schema = tool.inputSchema as { properties?: Record<string, { description?: string }> };
  if (!schema.properties) return tool;
  const properties = Object.fromEntries(
    Object.entries(schema.properties)
      .filter(([k]) => !(RELAY_DROPPED_FIELDS as readonly string[]).includes(k))
      .map(([k, v]) => [k, ["start", "end", "at", "occurrence_start"].includes(k) ? { ...v, description: "Local date and time, exactly YYYY-MM-DDTHH:MM, without a time zone." } : v]),
  );
  return { ...tool, inputSchema: { ...schema, properties } };
}

function allToolDefinitions(now: number, opts: { overview?: boolean }) {
  const nowText = describeNow(DEFAULT_TIMEZONE, now);
  const scheduleProps = {
    cron: {
      type: "string",
      description:
        "Recurrence, 5-field cron (minute hour day-of-month month day-of-week) in `timezone`. Examples: \"every day at 7\" → \"0 7 * * *\"; \"weekdays at 7:30\" → \"30 7 * * 1-5\"; \"Mondays and Thursdays at 6 pm\" → \"0 18 * * 1,4\"; \"every 2 hours\" → \"0 */2 * * *\"; \"the 1st of the month at 9\" → \"0 9 1 * *\".",
    },
    at: {
      type: "string",
      description: `Single run: local date and time in \`timezone\`, format YYYY-MM-DDTHH:MM (e.g. "tomorrow at 8" → tomorrow's date + "T08:00"). Now: ${nowText}.`,
    },
    in_minutes: { type: "number", description: "Single run in N minutes (e.g. \"in an hour\" → 60). More reliable than `at` for a short delay." },
    timezone: { type: "string", description: `IANA time zone, ${DEFAULT_TIMEZONE} by default.` },
    notify: { type: "boolean", description: "Send the answer as a push notification (yes by default)." },
  };
  return [
    {
      name: "schedule_create",
      description: `Schedules a task: at the given time, the Nuo gateway sends you \`prompt\` as a message from the user and pushes your answer to them as a notification. Give exactly one of cron, at or in_minutes. Example: "give me a weather update every morning at 7" → title "Morning weather", prompt "Give me today's weather in Boston", cron "0 7 * * *". To tell the user about a finding during a task, use notify_user, not a new task. Now: ${nowText}.`,
      inputSchema: {
        type: "object",
        properties: {
          title: { type: "string", description: "Short title in the user's language (60 characters max), shown in the notification. E.g. \"Today's workout\"." },
          prompt: {
            type: "string",
            description: "The message you will be sent at each run, written as a self-contained request (you will not have today's context). /… commands and #tags allowed.",
          },
          ...scheduleProps,
          conversation: {
            type: "string",
            enum: ["dedicated", "new", "current"],
            description: "Where the task runs: \"dedicated\" (default) a conversation of the task's own, reused each time; \"new\" a new conversation at each run; \"current\" the rest of this very conversation (for a reminder tied to the current exchange).",
          },
          bot: { type: "string", description: "Name of another bot that must run the task, only if the user asks for it. By default: you." },
        },
        required: ["title", "prompt"],
      },
    },
    {
      name: "notify_user",
      description:
        "Tells the user right away with a push notification (iPhone, Mac). This is the tool for an alert or a finding during a scheduled task that does not notify by itself: never schedule_create to send a message. `key` identifies what is reported (e.g. \"illusions-2321184\" for a showing): the same key notifies only once per period, so the same alert is not repeated at each check.",
      inputSchema: {
        type: "object",
        properties: {
          title: { type: "string", description: "Short title (60 characters max), in the user's language." },
          body: { type: "string", description: "The message, complete and self-contained, in the user's language." },
          key: { type: "string", description: "Stable identifier of what is reported; omitted: no deduplication." },
          repeat_hours: { type: "number", description: "With key: delay before the same key can notify again (24 h by default)." },
        },
        required: ["title", "body"],
      },
    },
    {
      name: "schedule_list",
      description: `Lists the scheduled tasks (with their id, their recurrence and their next run). Now: ${nowText}.`,
      inputSchema: {
        type: "object",
        properties: { all_bots: { type: "boolean", description: "Include the other bots' tasks (by default: only yours)." } },
      },
    },
    {
      name: "schedule_update",
      description: `Changes a scheduled task (id from schedule_list). Only the fields given change; cron, at or in_minutes replace the schedule. enabled=false pauses the task. A command task only takes schedule, title, notify and enabled. Now: ${nowText}.`,
      inputSchema: {
        type: "object",
        properties: {
          id: { type: "string" },
          title: { type: "string" },
          prompt: { type: "string" },
          ...scheduleProps,
          enabled: { type: "boolean", description: "false = paused, true = resumed." },
          conversation: { type: "string", enum: ["dedicated", "new"] },
        },
        required: ["id"],
      },
    },
    {
      name: "schedule_delete",
      description: "Deletes a scheduled task for good (id from schedule_list).",
      inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] },
    },
    {
      name: "memory_read",
      description: "Reads your persistent memory (MEMORY.md), shared by all your conversations.",
      inputSchema: { type: "object", properties: {} },
    },
    {
      name: "memory_add",
      description:
        "Adds a lasting fact to your persistent memory (one dated line). Use it as soon as the user gives a preference, a habit or a piece of information to keep. Never a secret (password, token, key, code, card number).",
      inputSchema: {
        type: "object",
        properties: { fact: { type: "string", description: "The fact, in one short self-contained sentence (500 characters max). E.g. \"Prefers morning flights\"." } },
        required: ["fact"],
      },
    },
    {
      name: "memory_write",
      description: "Replaces the whole content of your persistent memory (to clean it up: duplicates, facts no longer true). Read it first with memory_read.",
      inputSchema: {
        type: "object",
        properties: { content: { type: "string", description: "The new complete content, in Markdown (one line \"- YYYY-MM-DD fact\" per fact)." } },
        required: ["content"],
      },
    },
    ...GOOGLE_TOOLS,
    ...DEVICE_TOOLS,
    ...SCAN_TOOLS,
    ...(opts.overview ? OVERVIEW_TOOLS : []),
  ];
}

export class NuoTools {
  constructor(
    readonly env: NuoEnv,
    private now: () => number = Date.now,
    /** A slash command's turn: cancelling it drops the call to the gateway. */
    private signal?: AbortSignal,
  ) {}

  private async api(method: string, path: string, body?: unknown): Promise<any> {
    const res = await fetch(this.env.url + path, {
      method,
      headers: {
        authorization: `Bearer ${this.env.token}`,
        "content-type": "application/json",
        ...(this.env.conversationId ? { [CALLER_HEADER]: this.env.conversationId } : {}),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: this.signal,
    });
    const text = await res.text();
    const data = text ? JSON.parse(text) : undefined;
    if (!res.ok) throw new ToolError(`the gateway refused (${res.status}): ${data?.error ?? text}`);
    return data;
  }

  private async task(id: unknown): Promise<ScheduledTask> {
    if (typeof id !== "string" || !id) throw new ToolError("id is required");
    const all = (await this.api("GET", "/api/schedules")) as ScheduledTask[];
    const t = all.find((x) => x.id === id);
    if (!t) throw new ToolError(`no task with the id ${id}`);
    return t;
  }

  private async editableTask(id: unknown): Promise<ScheduledTask> {
    const t = await this.task(id);
    if (t.action?.type === "command") throw new ToolError(`"${t.title}" is a command task: it can only be deleted from the Nuo app`);
    return t;
  }

  /**
   * Google and scan tools run on the gateway (with the profile's tokens and tracking keys), device tools on the
   * user's iPhone or Mac; any refusal is the agent's answer, without the HTTP wrapping.
   */
  private async forward(path: string, a: Args): Promise<string> {
    const res = await fetch(`${this.env.url}${path}`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${this.env.token}`,
        "content-type": "application/json",
        ...(this.env.conversationId ? { [CALLER_HEADER]: this.env.conversationId } : {}),
      },
      body: JSON.stringify(a),
      signal: this.signal,
    });
    const data = (await res.json().catch(() => undefined)) as { text?: string; error?: string } | undefined;
    if (!res.ok) throw new ToolError(data?.error ?? `the gateway refused (${res.status})`);
    return data?.text ?? "";
  }

  private memoryPath() {
    return `/api/bots/${encodeURIComponent(this.env.botId)}/memory`;
  }

  async call(name: string, a: Args): Promise<string> {
    const now = this.now();
    if (this.env.relay) {
      // The gateway refuses it too; said here without a round trip.
      if (NUO_TOOL_RULES[name] !== "add") throw new ToolError(relayRefusalText(name));
      if (RELAY_ADD_TOOL_NAMES.has(name)) return this.forward(`/api/relay/tools/${name}`, a);
    }
    if (GOOGLE_TOOL_NAMES.has(name)) return this.forward(`/api/google/tools/${name}`, a);
    if (DEVICE_TOOL_NAMES.has(name)) return this.forward(`/api/device/tools/${name}`, name === "mac_file_write" ? await withFileContent(a) : a);
    if (SCAN_TOOL_NAMES.has(name)) return this.forward(`/api/scan/tools/${name}`, a);
    if (OVERVIEW_TOOL_NAMES.has(name)) {
      if (!this.env.overview) throw new ToolError(`${name} is reserved for the bot that sees all the bots (Nuo › bot › Initiative)`);
      try {
        return await callOverviewTool((m, p, b) => this.api(m, p, b), this.env, name, a);
      } catch (e) {
        throw e instanceof OverviewToolError ? new ToolError(e.message) : e;
      }
    }
    switch (name) {
      case "schedule_create": {
        const schedule = scheduleFrom(a, DEFAULT_TIMEZONE, now);
        if (!schedule) throw new ToolError("give cron (recurring), at or in_minutes (once)");
        const conversation = a.conversation === "new" ? "new" : "dedicated";
        const body: Args = {
          botId: typeof a.bot === "string" && a.bot.trim() ? a.bot.trim() : this.env.botId,
          title: a.title,
          prompt: a.prompt,
          schedule,
          conversation,
          ...(typeof a.notify === "boolean" ? { notify: a.notify } : {}),
        };
        if (a.conversation === "current") {
          if (!this.env.conversationId) throw new ToolError("no current conversation");
          body.conversationId = this.env.conversationId;
        }
        const t = (await this.api("POST", "/api/schedules", body)) as ScheduledTask;
        return `Task scheduled.\n${describeTask(t, this.env.botId)}\n(Now: ${describeNow(DEFAULT_TIMEZONE, now)})`;
      }
      case "notify_user": {
        if (typeof a.title !== "string" || !a.title.trim() || typeof a.body !== "string" || !a.body.trim()) throw new ToolError("title and body are required");
        const r = (await this.api("POST", "/api/notify", {
          title: a.title.trim(),
          body: a.body.trim(),
          botId: this.env.botId,
          ...(this.env.conversationId ? { conversationId: this.env.conversationId } : {}),
          ...(typeof a.key === "string" && a.key.trim() ? { key: a.key.trim() } : {}),
          ...(typeof a.repeat_hours === "number" ? { repeatHours: a.repeat_hours } : {}),
        })) as { sent?: boolean; lastSentAt?: string } | undefined;
        if (r?.sent === false) return `Already notified for "${a.key}" (${r.lastSentAt}): no new notification sent. Do not try again.`;
        return "Notification sent.";
      }
      case "schedule_list": {
        const all = (await this.api("GET", a.all_bots === true ? "/api/schedules" : `/api/schedules?botId=${encodeURIComponent(this.env.botId)}`)) as ScheduledTask[];
        const head = `Now: ${describeNow(DEFAULT_TIMEZONE, now)}`;
        if (!all.length) return `No scheduled task.\n${head}`;
        return `${all.length} scheduled task(s):\n${all.map((t) => describeTask(t, this.env.botId)).join("\n")}\n${head}`;
      }
      case "schedule_update": {
        const existing = await this.task(a.id);
        if (existing.action?.type === "command" && (a.prompt !== undefined || a.conversation !== undefined)) {
          throw new ToolError(`"${existing.title}" is a command task: you can change its schedule, its title, its notifications or pause it, not what it runs`);
        }
        const fallbackTz = existing.schedule.kind === "cron" ? existing.schedule.timezone : DEFAULT_TIMEZONE;
        const body: Args = {};
        for (const k of ["title", "prompt", "enabled", "notify", "conversation"]) if (a[k] !== undefined) body[k] = a[k];
        const schedule = scheduleFrom(a, fallbackTz, now);
        if (schedule) {
          body.schedule = schedule;
          if (a.enabled === undefined && !existing.enabled) body.enabled = true;
        } else if (typeof a.timezone === "string" && a.timezone && existing.schedule.kind === "cron") {
          body.schedule = { ...existing.schedule, timezone: a.timezone };
        }
        if (!Object.keys(body).length) throw new ToolError("nothing to change");
        const t = (await this.api("PATCH", `/api/schedules/${encodeURIComponent(existing.id)}`, body)) as ScheduledTask;
        return `Task changed.\n${describeTask(t, this.env.botId)}`;
      }
      case "schedule_delete": {
        const existing = await this.editableTask(a.id);
        await this.api("DELETE", `/api/schedules/${encodeURIComponent(existing.id)}`);
        return `Task "${existing.title}" deleted.`;
      }
      case "memory_read": {
        const m = (await this.api("GET", this.memoryPath())) as BotMemory;
        return m.content.trim() ? m.content : "Empty memory.";
      }
      case "memory_add": {
        await this.api("POST", this.memoryPath(), { fact: a.fact });
        return "Fact added to the memory.";
      }
      case "memory_write": {
        if (typeof a.content !== "string") throw new ToolError("content is required");
        await this.api("PUT", this.memoryPath(), { content: a.content });
        return a.content.trim() ? "Memory rewritten." : "Memory emptied.";
      }
      default:
        throw new ToolError(`unknown tool ${name}`);
    }
  }
}

export function createNuoServer(tools: NuoTools, now: () => number = Date.now): Server {
  const server = new Server({ name: "nuo", version: "1.0.0" }, { capabilities: { tools: {} } });
  server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: toolDefinitions(now(), { overview: tools.env.overview, relay: tools.env.relay }) }));
  server.setRequestHandler(CallToolRequestSchema, async (req) => {
    try {
      const text = await tools.call(req.params.name, (req.params.arguments ?? {}) as Args);
      return { content: [{ type: "text", text }] };
    } catch (e) {
      const message = e instanceof ToolError ? e.message : `error: ${(e as Error)?.message ?? String(e)}`;
      return { content: [{ type: "text", text: message }], isError: true };
    }
  });
  return server;
}

/**
 * The gateway's address and local token come from NUO_ENV_FILE: the runner never puts the token in this server's
 * env, which the agent shows on its command line (src/runner/agent-env.ts). Variables set in the env still win.
 */
export function nuoEnv(env: Record<string, string | undefined> = process.env): Record<string, string | undefined> {
  const file = env.NUO_ENV_FILE && existsSync(env.NUO_ENV_FILE) ? parseDotenv(readFileSync(env.NUO_ENV_FILE, "utf8")) : {};
  return {
    ...env,
    NUO_URL: env.NUO_URL || file.NUO_URL,
    NUO_LOCAL_TOKEN: env.NUO_LOCAL_TOKEN || file.NUO_LOCAL_TOKEN,
  };
}

if (import.meta.main) {
  const { NUO_URL, NUO_LOCAL_TOKEN, NUO_BOT_ID, NUO_CONVERSATION_ID, NUO_OVERVIEW, NUO_RELAY } = nuoEnv();
  if (!NUO_URL || !NUO_LOCAL_TOKEN || !NUO_BOT_ID) {
    console.error("nuo MCP server: NUO_URL and NUO_LOCAL_TOKEN (or NUO_ENV_FILE) and NUO_BOT_ID are required");
    process.exit(1);
  }
  const tools = new NuoTools({ url: NUO_URL, token: NUO_LOCAL_TOKEN, botId: NUO_BOT_ID, conversationId: NUO_CONVERSATION_ID || undefined, overview: NUO_OVERVIEW === "1", relay: NUO_RELAY === "1" });
  await createNuoServer(tools).connect(new StdioServerTransport());
}
