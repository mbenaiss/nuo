import { HttpError, type BotService } from "../bots/service";
import type { Bot, ConversationSearchHit, Message } from "../protocol";
import { RelayRefusedError, type Runner, type TurnOutcome } from "../runner/runner";
import type { StoredConversation, Store } from "../store/store";
import { CALLER_HEADER } from "../mcp/overview-tools";

type Ctx = { req: Request; params: string[]; url: URL };
export type OverviewRoute = [string, RegExp, (ctx: Ctx) => unknown];

export interface OverviewDeps {
  store: Store;
  bots: BotService;
  runner: Runner;
}

/** How long `bot_ask` waits for the other bot by default, and at most: past it the answer goes on in its conversation. */
export const ASK_WAIT_S = 240;
export const ASK_WAIT_MAX_S = 900;
const READ_DEFAULT = 30;
const READ_MAX = 200;
const SEARCH_DEFAULT = 30;
const SEARCH_MAX = 100;

export const SEARCH_PATH = /^\/api\/conversations\/search$/;

/**
 * The local token is shared by every bot of the profile: these routes also need the conversation that calls, and that
 * conversation's bot must have `overview`. A bot reading e-mails or web pages never gets to every conversation.
 */
export function overviewCaller(store: Store, req: Request): boolean {
  const id = req.headers.get(CALLER_HEADER);
  const c = id ? store.conversation(id) : undefined;
  if (!c) return false;
  const bot = store.bot(c.botId);
  const config = c.useDraft ? (bot?.draft ?? bot?.published?.config) : bot?.published?.config;
  return config?.overview === true;
}

const publicConversation = ({ agentId, agentSessionId, agentSessions, ...c }: StoredConversation) => c;

/** What a bot shows of itself to another: the published version, or the draft of a bot never published. */
export function botSummary(b: Bot) {
  const c = b.published?.config ?? b.draft;
  return {
    id: b.id,
    slug: b.slug,
    name: c?.name ?? b.slug,
    emoji: c?.emoji ?? "",
    description: c?.description ?? "",
    published: !!b.published,
    ...(b.lastMessageAt ? { lastMessageAt: b.lastMessageAt } : {}),
  };
}

function limitParam(url: URL, fallback: number, max: number): number {
  const n = Number(url.searchParams.get("limit"));
  return Number.isFinite(n) && n >= 1 ? Math.min(Math.floor(n), max) : fallback;
}

/** Only the conversations the user's lists show: a background task's conversation is reached from its runs. */
export function searchConversations(store: Store, url: URL): ConversationSearchHit[] {
  const limit = limitParam(url, SEARCH_DEFAULT, SEARCH_MAX);
  const background = store.backgroundConversationIds();
  return store
    .searchConversations(url.searchParams.get("q") ?? "", { botId: url.searchParams.get("botId") || undefined, limit: limit + background.size })
    .filter((h) => !background.has(h.conversation.id))
    .slice(0, limit)
    .map((h) => ({ ...h, conversation: publicConversation(h.conversation) }));
}

async function json(req: Request): Promise<Record<string, unknown>> {
  try {
    const b = await req.json();
    if (b && typeof b === "object" && !Array.isArray(b)) return b as Record<string, unknown>;
  } catch {}
  throw new HttpError(400, "invalid JSON body");
}

/**
 * For the `nuo` MCP server of a bot with `overview`: every bot and conversation of the profile, read and asked as
 * the user would from the app.
 */
export function overviewLocalRoutes(d: OverviewDeps): OverviewRoute[] {
  const conversation = (id: string) => {
    const c = d.store.conversation(id);
    if (!c) throw new HttpError(404, "conversation not found");
    return c;
  };
  return [
    ["GET", /^\/api\/bots$/, () => d.store.bots().map(botSummary)],
    ["GET", SEARCH_PATH, ({ url }) => searchConversations(d.store, url)],
    [
      "GET",
      /^\/api\/conversations\/([^/]+)\/messages$/,
      ({ params, url }) => {
        const c = conversation(params[0]!);
        const all = d.store.messages(c.id);
        const messages = all.slice(-limitParam(url, READ_DEFAULT, READ_MAX)).map((m: Message) => ({
          id: m.id,
          role: m.role,
          text: m.text,
          createdAt: m.createdAt,
          ...(m.attachments?.length ? { attachments: m.attachments.map((a) => a.name ?? a.mime) } : {}),
        }));
        return { conversation: publicConversation(c), total: all.length, messages, ...(d.runner.activeTurn(c.id) ? { running: true } : {}) };
      },
    ],
    [
      "POST",
      /^\/api\/bots\/([^/]+)\/ask$/,
      async ({ req, params }) => {
        const bot = d.bots.get(params[0]!);
        const b = await json(req);
        const prompt = typeof b.prompt === "string" ? b.prompt.trim() : "";
        if (!prompt) throw new HttpError(400, "prompt required");
        let conv: StoredConversation;
        if (typeof b.conversationId === "string" && b.conversationId) {
          conv = conversation(b.conversationId);
          if (conv.botId !== bot.id) throw new HttpError(400, "this conversation belongs to another bot");
        } else {
          if (!bot.published && !bot.draft) throw new HttpError(400, "this bot has no configuration");
          conv = d.store.createConversation(bot.id, !bot.published, "Nouvelle conversation");
        }
        const wait = Math.min(Math.max(Number(b.waitSeconds) || ASK_WAIT_S, 1), ASK_WAIT_MAX_S);
        let done: Promise<TurnOutcome>;
        // Asked in a relay session: the other bot's turn is a relay turn too (whitelist, `ask` whatever its policy).
        const caller = req.headers.get(CALLER_HEADER);
        const relay = caller ? d.runner.relaySession(caller) : undefined;
        try {
          ({ done } = await d.runner.prompt({ conversationId: conv.id, text: prompt }, { untrusted: true, ...(relay ? { relay } : {}) }));
        } catch (e) {
          if (e instanceof RelayRefusedError) {
            // A bot the relay cannot narrow (another agent than Claude): the watch's request waits for the unlock.
            if (caller && e.status === 409) d.runner.relayRefusedTool(caller, "bot_ask");
            throw new HttpError(e.status, e.message);
          }
          throw new HttpError(400, (e as Error)?.message ?? String(e));
        }
        const timeout = new Promise<undefined>((r) => {
          const timer = setTimeout(r, wait * 1000);
          void done.finally(() => clearTimeout(timer));
        });
        const outcome = await Promise.race([done, timeout]);
        const base = { botId: bot.id, conversationId: conv.id };
        if (!outcome) return { ...base, status: "running" };
        if (outcome.stopReason === "end_turn") return { ...base, status: "done", text: outcome.text };
        return { ...base, status: "error", text: outcome.text, error: outcome.stopReason === "cancelled" ? "annulée" : outcome.error || "erreur inconnue" };
      },
    ],
  ];
}
