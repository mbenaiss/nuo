import type { Server, ServerWebSocket } from "bun";
import { HttpError, type BotService } from "../bots/service";
import type { ToolCatalog } from "../bots/catalog";
import type { MachineToolSource } from "../machine/discovery";
import type { AgentId, Attachment, ClientEvent, ServerEvent } from "../protocol";
import type { PushDestination, Pusher } from "../push/apns";
import type { Hub, SocketData } from "../runner/hub";
import type { Runner } from "../runner/runner";
import { redactForBot, type Scheduler, type TaskInput } from "../scheduler/scheduler";
import type { AgentDirectory } from "../runner/runtimes";
import type { MediaStore } from "../store/media";
import type { Device, StoredConversation, Store } from "../store/store";
import { Gate, MAX_PROMPT_BODY, secure, type GateDeps } from "../auth/gate";
import { DEFAULT_NETWORK, type NetworkConfig, type Origin } from "../auth/network";
import { SOCKET_EVENTS, type Scope } from "../auth/policy";
import type { AuthService } from "../auth/service";
import { dataRoutes } from "../data/routes";
import type { DataServices } from "../data/service";
import { calendarRoutes } from "../calendar/routes";
import { requestHost } from "../calendar/public";
import type { CalendarServices } from "../calendar/service";
import type { BrowserManager } from "../browser/manager";
import type { ProfileSet } from "../profiles/set";
import { browserLocalRoutes, browserRoutes } from "../browser/routes";
import { BrowserViewer } from "../browser/viewer";
import type { GoogleAccounts } from "../google/accounts";
import { CALLBACK_PATH, type GoogleOAuth } from "../google/oauth";
import { googleCallback, googleLocalRoutes, googleRoutes } from "../google/routes";
import type { DeviceBridge } from "../device/bridge";
import { deviceLocalRoutes, deviceRoutes } from "../device/routes";
import { secretsRoutes } from "../secrets/routes";
import type { SecretStore } from "../secrets/store";
import { scanLocalRoutes, scanRoutes } from "../scan/routes";
import type { ScanServices } from "../scan/service";
import { SECRETS_PATH } from "../auth/policy";
import type { ProfileTranscriptions } from "../transcription/service";
import { latencyReport } from "../metrics/latency";
import { overviewCaller, overviewLocalRoutes, SEARCH_PATH, searchConversations } from "./overview";
import { relayRoute } from "./relay";
import { CALLER_HEADER } from "../mcp/overview-tools";
import { RELAY_ADD_TOOL_NAMES, runRelayTool } from "../relay/tools";
import { RELAY_DROPPED_FIELDS, RELAY_REFUSAL, relayRefusal, relayRefusalText } from "../relay/whitelist";
import { resolveBot } from "../scheduler/scheduler";
import { isTrue } from "../transcription/service";

export const VERSION = "0.1.0";

/** One profile's services: every route works on these only. */
export interface ProfileDeps {
  id: string;
  profile: { id: string; name: string };
  store: Store;
  auth: AuthService;
  bots: BotService;
  catalog: ToolCatalog;
  agents: AgentDirectory;
  runner: Runner;
  hub: Hub;
  media: MediaStore;
  pusher: Pusher;
  machine: MachineToolSource;
  scheduler: Scheduler;
  data?: DataServices;
  calendar?: CalendarServices;
  browser?: BrowserManager;
  google?: GoogleAccounts;
  device?: DeviceBridge;
  secrets?: SecretStore;
  scan?: ScanServices;
  /** Speech to text for dictation and meetings; without it the apps transcribe on the device only. */
  transcription?: ProfileTranscriptions;
}

export interface ServerDeps {
  port: number;
  hostname?: string;
  profiles: ProfileSet;
  network?: NetworkConfig;
  cfAccess?: GateDeps["cfAccess"];
  google?: GoogleOAuth;
}

type Handler = (ctx: { req: Request; params: string[]; device: Device; url: URL; scope?: Scope }) => Promise<Response | unknown> | Response | unknown;
/** Schedule and memory routes also serve the gateway's own `nuo` MCP server, which has the local token and no device. */
type ScheduleHandler = (ctx: { req: Request; params: string[]; url: URL; local: boolean }) => Promise<Response | unknown> | Response | unknown;
type Route<H> = [string, RegExp, H];

async function dispatch<C extends { req: Request }>(routes: Route<(ctx: C & { params: string[] }) => unknown>[], path: string, method: string, ctx: C): Promise<Response | undefined> {
  let pathMatched = false;
  for (const [m, re, handler] of routes) {
    const match = path.match(re);
    if (!match) continue;
    pathMatched = true;
    if (m !== method) continue;
    const out = await handler({ ...ctx, params: match.slice(1).map(decodeURIComponent) });
    return out instanceof Response ? out : reply(ctx.req, out);
  }
  return pathMatched ? fail(405, "method not allowed") : undefined;
}

const json = (data: unknown, status = 200) => Response.json(data, { status });
const fail = (status: number, error: string) => json({ error }, status);
const noContent = () => new Response(null, { status: 204 });
const TRANSCRIPTION_JOB = /^\/api\/transcriptions\/([0-9a-f-]{36})$/;

const GZIP_MIN_BYTES = 1024;
const JSON_TYPE = "application/json;charset=utf-8";

function acceptsGzip(header: string | null): boolean {
  return !!header?.split(",").some((part) => {
    const [name, ...params] = part.trim().toLowerCase().split(";");
    if (name !== "gzip") return false;
    const q = params.map((p) => p.trim()).find((p) => p.startsWith("q="));
    return !q || Number(q.slice(2)) > 0;
  });
}

/** Messages, rows and calendar months are large and repetitive JSON; URLSession and fetch inflate gzip transparently. */
function reply(req: Request, data: unknown): Response {
  const text = JSON.stringify(data);
  if (text === undefined) return json(data);
  if (text.length < GZIP_MIN_BYTES || !acceptsGzip(req.headers.get("accept-encoding"))) return new Response(text, { headers: { "content-type": JSON_TYPE } });
  return new Response(Bun.gzipSync(Buffer.from(text), { level: 4 }), { headers: { "content-type": JSON_TYPE, "content-encoding": "gzip", vary: "accept-encoding" } });
}

async function body<T = Record<string, unknown>>(req: Request): Promise<T> {
  try {
    const b = await req.json();
    if (b && typeof b === "object") return b as T;
  } catch {}
  throw new HttpError(400, "invalid JSON body");
}

const publicConversation = ({ agentId, agentSessionId, agentSessions, ...c }: StoredConversation) => c;
const SNAPSHOT_SCOPES = new Set(["app", "watch"]);
const MEMORY_PATH = /^\/api\/bots\/[^/]+\/memory$/;

/** A token other than the paired app's own (share, widgets, watch, machine). */
const isExtension = (scope: Scope | undefined) => !!scope && scope !== "app";

/** The routes of one profile, built once per profile. */
function profileApi(d: ProfileDeps) {
  const conversation = (id: string) => {
    const c = d.store.conversation(id);
    if (!c) throw new HttpError(404, "conversation not found");
    return c;
  };
  /**
   * A bot in `auto` runs any tool without asking, secrets included: only the app itself may talk to it. A widget,
   * share or watch token lives 30 days on less protected devices and must not be able to drive it.
   */
  const checkExtensionPrompt = (scope: Scope | undefined, conversationId: string) => {
    if (!scope || scope === "app") return;
    const c = conversation(conversationId);
    const bot = d.store.bot(c.botId);
    const config = c.useDraft ? (bot?.draft ?? bot?.published?.config) : bot?.published?.config;
    if (config?.permissionPolicy === "auto") throw new HttpError(403, "this bot has full access: open Nuo to talk to it");
    // It can ask any bot, those with full access included, so a token kept away from them must not reach it either.
    if (config?.overview) throw new HttpError(403, "this bot can reach every bot: open Nuo to talk to it");
  };
  const listedConversation = (c: StoredConversation) => {
    const activeTurn = d.runner.activeTurn(c.id);
    return { ...publicConversation(c), ...(activeTurn ? { activeTurn } : {}) };
  };
  const withTurns = <B extends { id: string }>(bot: B, active = d.runner.activeTurnsByBot()) => {
    const a = active.get(bot.id);
    return a ? { ...bot, activeTurns: a.count, activeConversationId: a.conversationId } : { ...bot, activeTurns: 0 };
  };

  /**
   * A bot's scheduled task runs later as the bot it names, with that bot's policy: a bot without full access never
   * creates, rewrites or starts a task of a bot that has it (that would lend it the power), from any conversation.
   */
  const policyOf = (botId: string | undefined) => {
    const bot = botId ? d.store.bot(botId) : undefined;
    return (bot?.published?.config ?? bot?.draft)?.permissionPolicy;
  };
  /** The policy the calling session runs with: a draft conversation runs on the draft, like the runner's. */
  const callerPolicy = (req: Request) => {
    const conv = d.store.conversation(req.headers.get(CALLER_HEADER) ?? "");
    const bot = conv ? d.store.bot(conv.botId) : undefined;
    return (conv?.useDraft ? (bot?.draft ?? bot?.published?.config) : bot?.published?.config)?.permissionPolicy;
  };
  const guardBotTask = (req: Request, local: boolean, ...targets: (string | undefined)[]) => {
    if (!local) return;
    if (callerPolicy(req) === "auto") return;
    for (const target of targets) {
      const bot = typeof target === "string" ? resolveBot(d.store, target) : undefined;
      if (policyOf(bot?.id) === "auto") throw new HttpError(403, "seul un bot à accès complet peut programmer ou lancer une tâche d'un bot à accès complet");
    }
  };
  const taskBot = (id: string) => d.scheduler.list().find((t) => t.id === id)?.botId;

  const scheduleRoutes: Route<ScheduleHandler>[] = [
    [
      "GET",
      /^\/api\/schedules$/,
      ({ url, local }) => {
        const tasks = d.scheduler.list(url.searchParams.get("botId") || undefined);
        return local ? tasks.map(redactForBot) : tasks;
      },
    ],
    [
      "POST",
      /^\/api\/schedules$/,
      async ({ req, local }) => {
        const input = await body<TaskInput>(req);
        guardBotTask(req, local, typeof input.botId === "string" ? input.botId : undefined);
        return d.scheduler.create(input, local ? "bot" : "user");
      },
    ],
    [
      "PATCH",
      /^\/api\/schedules\/([^/]+)$/,
      async ({ req, params, local }) => {
        const input = await body<TaskInput>(req);
        guardBotTask(req, local, taskBot(params[0]!), typeof input.botId === "string" ? input.botId : undefined);
        return d.scheduler.update(params[0]!, input, local);
      },
    ],
    [
      "DELETE",
      /^\/api\/schedules\/([^/]+)$/,
      ({ params, local }) => {
        d.scheduler.remove(params[0]!, local);
        return noContent();
      },
    ],
    [
      "POST",
      /^\/api\/schedules\/([^/]+)\/run$/,
      ({ req, params, local }) => {
        guardBotTask(req, local, taskBot(params[0]!));
        return d.scheduler.runNow(params[0]!, local);
      },
    ],
    ["GET", /^\/api\/schedules\/([^/]+)\/runs$/, ({ params }) => d.scheduler.runs(params[0]!)],
  ];

  /** Also served to the `nuo` MCP server, which passes its own bot id (NUO_BOT_ID). */
  const memoryRoutes: Route<ScheduleHandler>[] = [
    ["GET", /^\/api\/bots\/([^/]+)\/memory$/, ({ params }) => d.bots.readMemory(params[0]!)],
    ["PUT", /^\/api\/bots\/([^/]+)\/memory$/, async ({ req, params }) => d.bots.writeMemory(params[0]!, (await body(req)).content)],
    ["POST", /^\/api\/bots\/([^/]+)\/memory$/, async ({ req, params }) => d.bots.addMemory(params[0]!, (await body(req)).fact)],
  ];

  const routes: Route<Handler>[] = [
    ["GET", /^\/api\/agents$/, () => d.agents.info()],
    ["GET", /^\/api\/tools$/, () => d.catalog.list()],
    ["GET", /^\/api\/machine\/tools$/, () => d.machine.list()],
    [
      "GET",
      /^\/api\/metrics\/latency$/,
      ({ url }) => {
        const days = Number(url.searchParams.get("days") ?? 7);
        const scheduled = ["1", "true"].includes(url.searchParams.get("scheduled") ?? "");
        return latencyReport(d.store, { days: Number.isFinite(days) ? days : 7, scheduled });
      },
    ],
    [
      "GET",
      /^\/api\/bots$/,
      () => {
        const active = d.runner.activeTurnsByBot();
        return d.store.bots().map((b) => withTurns(b, active));
      },
    ],
    [
      "POST",
      /^\/api\/bots$/,
      async ({ req }) => {
        const b = await body<{ name?: string; fromBotId?: string }>(req);
        return d.bots.create(b.name, b.fromBotId || undefined);
      },
    ],
    ["GET", /^\/api\/bots\/([^/]+)$/, ({ params }) => withTurns(d.bots.get(params[0]!))],
    ["PUT", /^\/api\/bots\/([^/]+)\/draft$/, async ({ req, params }) => d.bots.saveDraft(params[0]!, await body(req))],
    ["DELETE", /^\/api\/bots\/([^/]+)\/draft$/, ({ params }) => d.bots.discardDraft(params[0]!)],
    [
      "POST",
      /^\/api\/bots\/([^/]+)\/publish$/,
      async ({ req, params }) => {
        const b = req.headers.get("content-length") === "0" ? {} : await body<{ note?: string }>(req).catch(() => ({}) as { note?: string });
        return d.bots.publish(params[0]!, typeof b.note === "string" && b.note.trim() ? b.note.trim() : undefined);
      },
    ],
    ["PUT", /^\/api\/bots\/([^/]+)\/permissions$/, async ({ req, params }) => d.bots.setPermissions(params[0]!, (await body(req)).permissionPolicy)],
    ["PUT", /^\/api\/bots\/([^/]+)\/no-tools$/, async ({ req, params }) => d.bots.setNoTools(params[0]!, (await body(req)).noTools)],
    ["GET", /^\/api\/bots\/([^/]+)\/versions$/, ({ params }) => (d.bots.get(params[0]!), d.store.versions(params[0]!))],
    ["POST", /^\/api\/bots\/([^/]+)\/rollback$/, async ({ req, params }) => d.bots.rollback(params[0]!, (await body(req)).version)],
    [
      "DELETE",
      /^\/api\/bots\/([^/]+)$/,
      async ({ params }) => {
        d.bots.get(params[0]!);
        await d.runner.closeBot(params[0]!);
        d.bots.delete(params[0]!);
        return noContent();
      },
    ],
    [
      "GET",
      /^\/api\/conversations$/,
      ({ url }) => {
        // A task without notification works out of sight: each « nothing found » would otherwise fill the list.
        const background = d.store.backgroundConversationIds();
        return d.store
          .conversations(url.searchParams.get("botId") || undefined)
          .filter((c) => !background.has(c.id))
          .map(listedConversation);
      },
    ],
    ["GET", SEARCH_PATH, ({ url }) => searchConversations(d.store, url)],
    [
      "GET",
      /^\/api\/conversations\/([^/]+)$/,
      ({ params }) => {
        const c = conversation(params[0]!);
        const activeTurn = d.runner.activeTurn(c.id, true);
        const turn = d.runner.snapshots(c.id)[0];
        return { ...publicConversation(c), ...(activeTurn ? { activeTurn } : {}), ...(turn ? { turn } : {}) };
      },
    ],
    [
      "POST",
      /^\/api\/conversations$/,
      async ({ req }) => {
        const b = await body<{ botId?: string; useDraft?: boolean }>(req);
        const bot = d.bots.get(String(b.botId ?? ""));
        const useDraft = !!b.useDraft;
        if (useDraft && !bot.draft && !bot.published) throw new HttpError(400, "this bot has no configuration");
        if (!useDraft && !bot.published) throw new HttpError(400, "this bot has no published version; publish it or use the draft");
        return publicConversation(d.store.createConversation(bot.id, useDraft, "Nouvelle conversation"));
      },
    ],
    [
      "POST",
      /^\/api\/conversations\/([^/]+)\/prompt$/,
      async ({ req, params, scope }) => {
        const id = conversation(params[0]!).id;
        checkExtensionPrompt(scope, id);
        const b = await body<{ text?: unknown; attachments?: unknown; agent?: unknown; model?: unknown; effort?: unknown }>(req);
        const str = (v: unknown) => (typeof v === "string" && v ? v : undefined);
        try {
          const { messageId } = await d.runner.prompt(
            {
              conversationId: id,
              text: typeof b.text === "string" ? b.text : "",
              attachments: b.attachments as Attachment[] | undefined,
              agent: str(b.agent) as AgentId | undefined,
              model: str(b.model),
              effort: str(b.effort),
            },
            { untrusted: isExtension(scope) },
          );
          return json({ messageId }, 202);
        } catch (e) {
          throw new HttpError(400, (e as Error)?.message ?? String(e));
        }
      },
    ],
    ["GET", /^\/api\/conversations\/([^/]+)\/messages$/, ({ params }) => d.store.messages(conversation(params[0]!).id)],
    [
      "DELETE",
      /^\/api\/conversations\/([^/]+)$/,
      async ({ params }) => {
        conversation(params[0]!);
        await d.runner.closeConversation(params[0]!);
        d.store.deleteConversation(params[0]!);
        return noContent();
      },
    ],
    ["GET", /^\/api\/alerts$/, () => d.store.alerts()],
    [
      "DELETE",
      /^\/api\/alerts$/,
      ({ url }) => {
        d.store.deleteAlerts(["1", "true"].includes(url.searchParams.get("read") ?? ""));
        return noContent();
      },
    ],
    [
      "DELETE",
      /^\/api\/alerts\/([^/]+)$/,
      ({ params }) => {
        if (!d.store.deleteAlert(params[0]!)) throw new HttpError(404, "alert not found");
        return noContent();
      },
    ],
    [
      "POST",
      /^\/api\/alerts\/read$/,
      async ({ req }) => {
        const raw = (await req.text()).trim();
        let ids: unknown;
        if (raw) {
          try {
            ids = (JSON.parse(raw) as { ids?: unknown } | null)?.ids;
          } catch {
            throw new HttpError(400, "invalid JSON body");
          }
        }
        if (ids !== undefined && (!Array.isArray(ids) || !ids.every((id) => typeof id === "string"))) throw new HttpError(400, "ids must be an array of strings");
        d.store.markAlertsRead(ids as string[] | undefined);
        return noContent();
      },
    ],
    [
      "POST",
      /^\/api\/devices$/,
      async ({ req, device }) => {
        const b = await body<{ apnsToken?: string; environment?: string }>(req);
        if (typeof b.apnsToken !== "string" || !/^[0-9a-fA-F]{32,200}$/.test(b.apnsToken)) throw new HttpError(400, "apnsToken must be a hex string");
        if (b.environment !== "development" && b.environment !== "production") throw new HttpError(400, 'environment must be "development" or "production"');
        d.store.setApnsToken(device.id, b.apnsToken.toLowerCase(), b.environment);
        return noContent();
      },
    ],
    [
      "POST",
      /^\/api\/live-activities$/,
      async ({ req, device }) => {
        const b = await body<{ conversationId?: string; pushToken?: string; environment?: string }>(req);
        if (typeof b.conversationId !== "string") throw new HttpError(400, "conversationId is required");
        conversation(b.conversationId);
        if (typeof b.pushToken !== "string" || !/^[0-9a-fA-F]{32,200}$/.test(b.pushToken)) throw new HttpError(400, "pushToken must be a hex string");
        if (b.environment !== "development" && b.environment !== "production") throw new HttpError(400, 'environment must be "development" or "production"');
        d.runner.registerLiveActivity(b.conversationId, device.id, { pushToken: b.pushToken.toLowerCase(), environment: b.environment });
        return noContent();
      },
    ],
    [
      "GET",
      /^\/api\/media\/([^/]+)$/,
      async ({ params }) => {
        const f = d.media.file(params[0]!);
        if (!f || !(await f.exists())) throw new HttpError(404, "media not found");
        return new Response(f, { headers: { "cache-control": "private, max-age=31536000, immutable" } });
      },
    ],
  ];

  /** Same `key`: one notification per window. */
  const NOTIFY_REPEAT_HOURS = 24;
  const notify = async (req: Request) => {
    const b = await body<{ title?: string; body?: string; botId?: string; conversationId?: unknown; url?: string; key?: unknown; repeatHours?: unknown }>(req);
    if (typeof b.title !== "string" || typeof b.body !== "string") throw new HttpError(400, "title and body are required");
    if (b.url !== undefined && (typeof b.url !== "string" || !b.url.startsWith("nuo://"))) throw new HttpError(400, "url must be a nuo:// link");
    if (b.key !== undefined && (typeof b.key !== "string" || !b.key.trim() || b.key.length > 200)) throw new HttpError(400, "key must be a short string");
    const botId = typeof b.botId === "string" && b.botId ? b.botId : undefined;
    const url = b.url || undefined;
    if (typeof b.key === "string") {
      // A watcher that finds the same thing every hour alerts once, not every hour.
      const metaKey = `notify.once.${botId ?? "-"}.${b.key.trim()}`;
      const hours = typeof b.repeatHours === "number" && b.repeatHours > 0 ? Math.min(b.repeatHours, 24 * 30) : NOTIFY_REPEAT_HOURS;
      const last = Number(d.store.getMeta(metaKey));
      if (last && Date.now() - last < hours * 3_600_000) return json({ sent: false, lastSentAt: new Date(last).toISOString() });
      d.store.setMeta(metaKey, String(Date.now()));
    }
    // A bot alerting from a conversation opens that one, not the bot's list: a bot has many conversations.
    const conv = typeof b.conversationId === "string" && botId ? d.store.conversation(b.conversationId) : undefined;
    const conversationId = conv && conv.botId === botId ? conv.id : undefined;
    const destination: PushDestination = url
      ? { kind: "link", url }
      : conversationId && botId
        ? { kind: "conversation", id: conversationId, botId }
        : botId
          ? { kind: "bot", id: botId }
          : { kind: "home" };
    if (conversationId) d.store.recordAlert(conversationId, b.title, b.body);
    d.hub.broadcast({ type: "notification", title: b.title, body: b.body, ...(botId ? { botId } : {}), ...(conversationId ? { conversationId } : {}) });
    await Promise.all(d.store.devices().map((dev) => d.pusher.send(dev, { title: b.title!, body: b.body!, botId, conversationId, url, destination })));
    return noContent();
  };

  const dataApi = d.data ? dataRoutes(d.data) : undefined;
  const calendarApi = d.calendar ? calendarRoutes(d.calendar) : undefined;
  const browserApi = d.browser ? browserRoutes(d.browser) : undefined;
  const browserLocalApi = d.browser ? browserLocalRoutes(d.browser) : undefined;
  const googleApi = d.google ? googleRoutes(d.google) : undefined;
  const googleLocalApi = d.google ? googleLocalRoutes(d.google) : undefined;
  const deviceApi = d.device ? deviceRoutes(d.device) : undefined;
  const deviceLocalApi = d.device ? deviceLocalRoutes(d.device) : undefined;
  const secretsApi = d.secrets ? secretsRoutes(d.secrets, d.auth) : undefined;
  const scanApi = d.scan ? scanRoutes(d.scan) : undefined;
  const scanLocalApi = d.scan ? scanLocalRoutes(d.scan) : undefined;
  const overviewLocalApi = overviewLocalRoutes(d);
  /** Sent right after authentication: a reconnecting client rebuilds the running turns without missing a delta. */
  const sendSnapshot = (ws: ServerWebSocket<SocketData>) => {
    if (!SNAPSHOT_SCOPES.has(ws.data.scope ?? "app")) return;
    ws.send(JSON.stringify({ type: "turns.snapshot", turns: d.runner.snapshots() } satisfies ServerEvent));
  };
  return { d, scheduleRoutes, memoryRoutes, routes, notify, dataApi, calendarApi, browserApi, browserLocalApi, googleApi, googleLocalApi, deviceApi, deviceLocalApi, secretsApi, scanApi, scanLocalApi, overviewLocalApi, sendSnapshot, checkExtensionPrompt };
}

type ProfileApi = ReturnType<typeof profileApi>;

export function startServer(s: ServerDeps): Server<SocketData> {
  const apis = new WeakMap<ProfileDeps, ProfileApi>();
  const apiOf = (id: string | undefined): ProfileApi | undefined => {
    const stack = id ? s.profiles.stack(id) : undefined;
    if (!stack) return undefined;
    let a = apis.get(stack);
    if (!a) apis.set(stack, (a = profileApi(stack)));
    return a;
  };
  const gate = new Gate({ auth: s.profiles, network: s.network ?? DEFAULT_NETWORK, cfAccess: s.cfAccess });
  const BROWSER_PATH = /^\/api\/browser(\/|$)/;
  const GOOGLE_PATH = /^\/api\/google\//;
  const DEVICE_PATH = /^\/api\/device\//;
  const SCAN_TOOLS_PATH = /^\/api\/scan\/tools\//;
  const OVERVIEW_PATH = /^\/api\/(bots|conversations)(\/|$)/;
  const viewers = new WeakMap<ServerWebSocket<SocketData>, BrowserViewer>();

  /**
   * The local routes a relay session's `nuo` server may call (src/relay/whitelist.ts): adding, each call let through
   * once per yes given to that tool in the running relay turn, and the bots' names for `bot_ask`. Anything else is
   * refused with the unlock message, and the request waits for the unlocked iPhone.
   */
  const relayLocal = async (a: ProfileApi, path: string, req: Request, url: URL, caller: string): Promise<Response> => {
    const runner = a.d.runner;
    const refuse = (name: string) => {
      runner.relayRefusedTool(caller, name);
      return fail(403, relayRefusalText(name));
    };
    const read = async () => {
      const text = await req.text();
      try {
        const b = text ? JSON.parse(text) : {};
        return b && typeof b === "object" && !Array.isArray(b) ? (b as Record<string, unknown>) : {};
      } catch {
        return {} as Record<string, unknown>;
      }
    };
    // What was checked is what goes on, never the raw body: no guests, and the default account and calendar only.
    const passOn = (input: Record<string, unknown>) => {
      const rest = Object.fromEntries(Object.entries(input).filter(([k]) => !(RELAY_DROPPED_FIELDS as readonly string[]).includes(k)));
      const headers = new Headers(req.headers);
      headers.delete("content-length");
      return new Request(req.url, { method: "POST", headers, body: JSON.stringify(rest) });
    };
    const confirmed = (name: string) => runner.takeRelayApproval(caller, name);
    const unconfirmed = (name: string) => fail(403, `« ${name} » attend une confirmation : demande-la avant d'utiliser l'outil`);
    try {
      if (path === "/api/bots" && req.method === "GET" && overviewCaller(a.d.store, req)) {
        // What `bot_ask` needs to find a bot by name: nothing of what it said or how it is set up.
        return json(
          a.d.store
            .bots()
            .filter((b) => b.published)
            .map((b) => ({ id: b.id, slug: b.slug, name: b.published!.config.name, emoji: b.published!.config.emoji })),
        );
      }
      const ask = path.match(/^\/api\/bots\/([^/]+)\/ask$/);
      if (ask && req.method === "POST" && overviewCaller(a.d.store, req)) {
        const input = await read();
        if (relayRefusal({ server: "nuo", name: "bot_ask", input }, runner.relayTurnFacts(caller))) return refuse("bot_ask");
        if (!confirmed("bot_ask")) return unconfirmed("bot_ask");
        return (await dispatch(a.overviewLocalApi, path, req.method, { req: passOn(input), url })) ?? fail(404, "not found");
      }
      const tool = path.match(/^\/api\/(relay|device|google)\/tools\/([a-z_]+)$/);
      if (tool && req.method === "POST") {
        const [, kind, name] = tool as unknown as [string, string, string];
        const known = kind === "relay" ? RELAY_ADD_TOOL_NAMES.has(name) : kind === "device" ? name.startsWith("apple_event_") : name === "calendar_create";
        const input = await read();
        if (!known || relayRefusal({ server: "nuo", name, input }, runner.relayTurnFacts(caller))) return refuse(name);
        if (!confirmed(name)) return unconfirmed(name);
        if (kind === "relay") {
          if (!a.d.data) return fail(404, "data is not configured");
          return json({ text: await runRelayTool(a.d.data, name, input) });
        }
        const api = kind === "device" ? a.deviceLocalApi : a.googleLocalApi;
        if (!api) return fail(404, "not found");
        let res: Response;
        try {
          res = (await dispatch(api, path, "POST", { req: passOn(input), url })) ?? fail(404, "not found");
        } catch (e) {
          if (!(e instanceof HttpError)) throw e;
          res = fail(e.status, e.message);
        }
        // An account's or a device's error may name accounts or calendars: the relay learns only that it failed.
        if (!res.ok) {
          runner.relayRefusedTool(caller, name);
          return fail(res.status, `« ${name} » n'a pas abouti : ${RELAY_REFUSAL}.`);
        }
        const out = ((await res.json().catch(() => undefined)) ?? {}) as { text?: unknown };
        const text = typeof out.text === "string" ? out.text : "";
        if (kind === "google") return json({ text: relayGoogleAnswer(text) });
        const event = relayDeviceEvent(text);
        // The event this turn created: the only one it may move afterwards.
        if (name === "apple_event_create" && typeof event?.id === "string") runner.relayCreatedEvent(caller, event.id);
        return json({ text: event ? JSON.stringify(event) : `« ${name} » : fait.` });
      }
      return refuse(path.match(/\/tools\/([a-z_]+)$/)?.[1] ?? RELAY_ROUTE_NAMES.find(([re]) => re.test(path))?.[1] ?? "cet outil");
    } catch (e) {
      if (e instanceof HttpError) return fail(e.status, e.message);
      throw e;
    }
  };

  const handle = async (req: Request, server: Server<SocketData>, path: string, url: URL, origin: Origin): Promise<{ res?: Response; deviceId?: string; profileId?: string }> => {
    if (path === "/api/health" && req.method === "GET") {
      // Version and agent details are for the home network and paired devices only.
      if (origin.zone === "internet") return { res: json({ ok: true }) };
      return { res: json({ ok: true, version: VERSION, agents: await s.profiles.owner.agents.info() }) };
    }
    const g = await gate.check(req, path, origin);
    if (g.kind === "response") return { res: g.response, deviceId: g.ctx?.deviceId, profileId: g.ctx?.profileId };
    if (g.kind === "ws-pending") {
      if (server.upgrade(req, { data: { deviceId: "", pending: true, zone: origin.zone, ip: origin.ip } })) return {};
      return { res: fail(400, "expected a WebSocket upgrade") };
    }
    if (g.kind === "local") {
      const a = apiOf(g.profileId);
      if (!a) return { res: fail(401, "unauthorized") };
      // The bot's `nuo` server names the conversation it runs in: a relay session reaches only the add routes.
      const caller = req.headers.get(CALLER_HEADER);
      if (caller && a.d.runner.relaySession(caller)) return { res: await relayLocal(a, path, req, url, caller) };
      if (path === "/api/notify" && req.method === "POST") return { res: await a.notify(req) };
      if (/^\/api\/schedules(\/|$)/.test(path)) return { res: (await dispatch(a.scheduleRoutes, path, req.method, { req, url, local: true })) ?? fail(404, "not found") };
      if (MEMORY_PATH.test(path)) return { res: (await dispatch(a.memoryRoutes, path, req.method, { req, url, local: true })) ?? fail(404, "not found") };
      if (a.browserLocalApi && BROWSER_PATH.test(path)) return { res: (await dispatch(a.browserLocalApi, path, req.method, { req, url })) ?? fail(404, "not found") };
      if (a.googleLocalApi && GOOGLE_PATH.test(path)) return { res: (await dispatch(a.googleLocalApi, path, req.method, { req, url })) ?? fail(404, "not found") };
      if (a.deviceLocalApi && DEVICE_PATH.test(path)) return { res: (await dispatch(a.deviceLocalApi, path, req.method, { req, url })) ?? fail(404, "not found") };
      if (a.scanLocalApi && SCAN_TOOLS_PATH.test(path)) return { res: (await dispatch(a.scanLocalApi, path, req.method, { req, url })) ?? fail(404, "not found") };
      if (OVERVIEW_PATH.test(path) && overviewCaller(a.d.store, req)) return { res: (await dispatch(a.overviewLocalApi, path, req.method, { req, url })) ?? fail(404, "not found") };
      return { res: fail(401, "unauthorized") };
    }
    const { ctx } = g;
    const a = apiOf(ctx.profileId);
    const ids = { deviceId: ctx.deviceId, profileId: ctx.profileId };
    if (!a) return { res: fail(401, "unauthorized"), ...ids };
    const device: Device = { id: ctx.deviceId, name: ctx.deviceName };
    const data: SocketData = { profileId: ctx.profileId, deviceId: device.id, scope: ctx.scope, expiresAt: ctx.expiresAt, zone: origin.zone, ip: origin.ip };
    if (path === "/api/ws") {
      if (server.upgrade(req, { data })) return ids;
      return { res: fail(400, "expected a WebSocket upgrade"), ...ids };
    }
    if (path === "/api/browser/ws" && a.d.browser) {
      // The gate already refuses extension tokens here; the check stays local to the socket that streams the browser.
      if (ctx.scope !== "app") return { res: fail(403, "forbidden"), ...ids };
      if (server.upgrade(req, { data: { ...data, channel: "browser" } })) return ids;
      return { res: fail(400, "expected a WebSocket upgrade"), ...ids };
    }
    if (path === "/api/me" && req.method === "GET") return { res: json({ deviceId: device.id, profile: { id: a.d.profile.id, name: a.d.profile.name } }), ...ids };
    if (path === "/api/notify" && req.method === "POST") return { res: await a.notify(req), ...ids };
    if (path === "/api/transcriptions" || path.startsWith("/api/transcriptions/")) {
      // Each call is billed by the provider: the paired app only, never an extension. The relay, for a short dictation.
      const relay = ctx.scope === "relay";
      if (ctx.scope !== "app" && !relay) return { res: fail(403, "forbidden"), ...ids };
      const t = a.d.transcription;
      if (!t) return { res: fail(404, "transcription is not configured"), ...ids };
      const jobId = TRANSCRIPTION_JOB.exec(path)?.[1];
      // The relay's jobs are its own, apart from the app's: it never reads or stops a meeting of this device.
      const owner = relay ? `${device.id}:relay` : device.id;
      if (relay && path === "/api/transcriptions" && req.method === "POST") {
        const refusal = await relayDictationRefusal(req);
        a.d.auth.event("relay_transcription", !refusal, { ip: origin.ip, deviceId: device.id, deviceName: device.name, detail: refusal?.message ?? `${req.headers.get("content-length") ?? "?"} B` });
        if (refusal) return { res: fail(refusal.status, refusal.message), ...ids };
      }
      try {
        if (path === "/api/transcriptions/warm" && req.method === "POST") {
          t.warm();
          return { res: json(t.info()), ...ids };
        }
        if (path === "/api/transcriptions" && req.method === "POST") {
          // A dictation waits for its text; Bun's 10 s idle default would cut a slow provider short.
          server.timeout(req, 300);
          const reply = await t.handle(req, owner);
          return { res: json(reply, "id" in reply ? 202 : 200), ...ids };
        }
        if (jobId && req.method === "GET") {
          // A failed job is a 200 too: its error is the job's answer, not one a proxy could have made up.
          const view = t.job(jobId, owner);
          return { res: json(view, view.status === "running" ? 202 : 200), ...ids };
        }
        if (jobId && req.method === "DELETE") {
          await t.delete(jobId, owner);
          return { res: noContent(), ...ids };
        }
        return { res: fail(404, "not found"), ...ids };
      } catch (e) {
        if (e instanceof HttpError) return { res: fail(e.status, e.message), ...ids };
        throw e;
      }
    }
    if (ctx.scope === "relay") {
      // Written out route by route: nothing a relay token asks falls through to the app's routes.
      return { res: await relayRoute({ store: a.d.store, bots: a.d.bots, runner: a.d.runner, auth: a.d.auth }, path, req, ctx, origin.ip), ...ids };
    }
    if (SECRETS_PATH.test(path)) {
      // The gate already refuses extension tokens; checked again here because these routes hand out values.
      if (ctx.scope !== "app") return { res: fail(403, "forbidden"), ...ids };
      return { res: (a.secretsApi ? await dispatch(a.secretsApi, path, req.method, { req, url, device, ip: origin.ip, auth: ctx, zone: origin.zone }) : undefined) ?? fail(404, "not found"), ...ids };
    }
    const res =
      (await dispatch(a.scheduleRoutes, path, req.method, { req, url, local: false })) ??
      (await dispatch(a.memoryRoutes, path, req.method, { req, url, local: false })) ??
      (await dispatch(a.routes, path, req.method, { req, device, url, scope: ctx.scope })) ??
      (a.dataApi ? await dispatch(a.dataApi, path, req.method, { req, url }) : undefined) ??
      (a.calendarApi ? await dispatch(a.calendarApi, path, req.method, { req, url, device }) : undefined) ??
      (a.browserApi ? await dispatch(a.browserApi, path, req.method, { req, url }) : undefined) ??
      (a.googleApi ? await dispatch(a.googleApi, path, req.method, { req, url, device }) : undefined) ??
      (a.deviceApi ? await dispatch(a.deviceApi, path, req.method, { req, url, device }) : undefined) ??
      (a.scanApi ? await dispatch(a.scanApi, path, req.method, { req, url }) : undefined) ??
      fail(404, "not found");
    return { res, ...ids };
  };

  /** Sockets opened without a token must authenticate with their first message within this delay. */
  const SOCKET_AUTH_MS = 5000;
  const timers = new WeakMap<object, ReturnType<typeof setTimeout>>();
  const armExpiry = (ws: ServerWebSocket<SocketData>) => {
    clearTimeout(timers.get(ws));
    const at = ws.data.pending ? Date.now() + SOCKET_AUTH_MS : ws.data.expiresAt;
    if (at === undefined) return;
    // Closing when the access token expires makes the app reconnect with a refreshed one.
    timers.set(ws, setTimeout(() => ws.close(4401, ws.data.pending ? "authentication required" : "access token expired"), Math.max(0, Math.min(at - Date.now(), 2 ** 31 - 1))));
  };

  return Bun.serve<SocketData>({
    port: s.port,
    hostname: s.hostname,
    maxRequestBodySize: MAX_PROMPT_BODY,
    async fetch(req, server) {
      const url = new URL(req.url);
      const path = url.pathname.replace(/\/+$/, "") || "/";
      const origin = gate.origin(server.requestIP(req)?.address, req.headers);
      // Google sends the user's browser here, outside Cloudflare Access and without any gateway credential.
      if (s.google && path === CALLBACK_PATH && req.method === "GET") return googleCallback(s.google, url, (id) => s.profiles.stack(id)?.google);
      // The booking hostname is a separate, unauthenticated site of the owner: it never reaches the gate or any app route.
      const booking = s.profiles.owner.calendar;
      if (booking.bookingHosts.has(requestHost(req))) return booking.site.handle(req, path, url, origin.ip);
      let out: { res?: Response; deviceId?: string; profileId?: string };
      try {
        out = await handle(req, server, path, url, origin);
      } catch (e) {
        if (e instanceof HttpError) out = { res: fail(e.status, e.message) };
        else {
          console.error(`[api] ${req.method} ${path}:`, e);
          out = { res: fail(500, "internal error") };
        }
      }
      if (origin.zone === "internet") s.profiles.logRequest({ ip: origin.ip, method: req.method, path, status: out.res?.status ?? 101, deviceId: out.deviceId, profileId: out.profileId });
      return out.res ? secure(out.res, origin) : undefined;
    },
    websocket: {
      idleTimeout: 120,
      maxPayloadLength: MAX_PROMPT_BODY,
      open(ws) {
        const a = apiOf(ws.data.profileId);
        if (ws.data.channel === "browser") {
          if (!a?.d.browser) return ws.close(4401, "unauthorized");
          a.d.hub.add(ws);
          armExpiry(ws);
          const viewer = new BrowserViewer(a.d.browser, { send: (t) => void ws.send(t), sendBinary: (d) => void ws.send(d), close: (code, reason) => ws.close(code, reason) });
          viewers.set(ws, viewer);
          void viewer.open();
          return;
        }
        if (!ws.data.pending) {
          if (!a) return ws.close(4401, "unauthorized");
          a.d.hub.add(ws);
          a.sendSnapshot(ws);
        }
        armExpiry(ws);
      },
      close(ws) {
        clearTimeout(timers.get(ws));
        apiOf(ws.data.profileId)?.d.hub.remove(ws);
        viewers.get(ws)?.close();
      },
      async message(ws, raw) {
        const viewer = viewers.get(ws);
        if (viewer) return viewer.handle(typeof raw === "string" ? raw : raw.toString());
        const send = (e: ServerEvent) => void ws.send(JSON.stringify(e));
        let e: ClientEvent;
        try {
          e = JSON.parse(typeof raw === "string" ? raw : raw.toString());
        } catch {
          return send({ type: "error", message: "invalid JSON" });
        }
        if (ws.data.pending) {
          const ctx = (e as { type?: string }).type === "auth" ? gate.socketToken((e as { accessToken?: unknown }).accessToken, { zone: ws.data.zone ?? "internet", ip: ws.data.ip ?? "?" }) : undefined;
          const a = ctx ? apiOf(ctx.profileId) : undefined;
          if (!ctx || !a) return ws.close(4401, "unauthorized");
          Object.assign(ws.data, { pending: false, profileId: ctx.profileId, deviceId: ctx.deviceId, scope: ctx.scope, expiresAt: ctx.expiresAt });
          a.d.hub.add(ws);
          a.sendSnapshot(ws);
          armExpiry(ws);
          return;
        }
        const a = apiOf(ws.data.profileId);
        if (!a) return ws.close(4401, "unauthorized");
        try {
          const allowed = SOCKET_EVENTS[(ws.data.scope ?? "app") as Scope];
          if (allowed !== "all" && !allowed.has(e.type)) return send({ type: "error", message: `event ${e.type} is not allowed for this token` });
          switch (e.type) {
            case "ping":
              return send({ type: "pong" });
            case "turns.sync":
              return a.sendSnapshot(ws);
            case "presence":
              ws.data.active = e.active === true;
              return;
            case "prompt":
              a.checkExtensionPrompt(ws.data.scope as Scope | undefined, e.conversationId);
              await a.d.runner.prompt(e, { untrusted: isExtension(ws.data.scope as Scope | undefined) });
              return;
            case "cancel":
              return await a.d.runner.cancel(e.conversationId);
            case "permission":
              if (!a.d.runner.answerPermission(e.requestId, e.optionId)) send({ type: "error", message: "unknown or expired permission request" });
              return;
            default:
              return send({ type: "error", message: `unknown event type ${(e as { type?: string }).type}` });
          }
        } catch (err) {
          const conversationId = "conversationId" in e ? e.conversationId : undefined;
          send({ type: "error", ...(conversationId ? { conversationId } : {}), message: (err as Error)?.message ?? String(err) });
        }
      },
    },
  });
}

/**
 * What a relay session learns from a Google event it created: its id and title, never the account (the answer names
 * it) nor the link (whose `eid` encodes the calendar's address).
 */
export function relayGoogleAnswer(text: string): string {
  const m = text.match(/\(id ([^)\s]+)\) : ([^\n]*)/);
  return m ? `Évènement ajouté à l'agenda Google par défaut (id ${m[1]}) : ${m[2]}` : "Évènement ajouté à l'agenda Google par défaut.";
}

/** The fields of an Apple event a relay session may read back: what it wrote, not the calendar, account or people. */
const RELAY_EVENT_FIELDS = ["id", "title", "start", "end", "allDay", "location", "notes", "url", "recurrence", "occurrenceStart", "alarms", "availability"];

export function relayDeviceEvent(text: string): Record<string, unknown> | undefined {
  try {
    const e = JSON.parse(text) as unknown;
    if (!e || typeof e !== "object" || Array.isArray(e)) return undefined;
    return Object.fromEntries(Object.entries(e as Record<string, unknown>).filter(([k]) => RELAY_EVENT_FIELDS.includes(k)));
  } catch {
    return undefined;
  }
}

/** The tool a refused local route stands for, as the bot knows it. */
const RELAY_ROUTE_NAMES: [RegExp, string][] = [
  [/^\/api\/notify$/, "notify_user"],
  [/^\/api\/schedules(\/|$)/, "schedule"],
  [/\/memory$/, "memory"],
  [/^\/api\/bots\/[^/]+\/ask$/, "bot_ask"],
  [/^\/api\/(bots|conversations)(\/|$)/, "conversation_read"],
  [/^\/api\/browser(\/|$)/, "navigateur"],
];

/** The relay transcribes a short dictation, waited for: no named job, no background job, nothing long. */
export const RELAY_MAX_AUDIO = 4 * 1024 * 1024;
async function relayDictationRefusal(req: Request): Promise<{ status: number; message: string } | undefined> {
  const length = Number(req.headers.get("content-length") ?? "NaN");
  if (!Number.isFinite(length) || length > RELAY_MAX_AUDIO) return { status: 413, message: "the relay sends short dictations only" };
  if (req.headers.get("x-nuo-transcription-id") || new URL(req.url).searchParams.has("id")) return { status: 403, message: "the relay cannot name a transcription job" };
  try {
    const form = await req.clone().formData();
    if (isTrue(form.get("background")) || form.get("id")) return { status: 403, message: "the relay cannot start a background transcription" };
  } catch {
    return { status: 400, message: "invalid form" };
  }
  return undefined;
}
