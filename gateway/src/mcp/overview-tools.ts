// Tools of a bot with `overview` (BotConfig): every bot and conversation of the profile, through src/api/overview.ts.
import type { ConversationSearchHit } from "../protocol";

type Args = Record<string, unknown>;
type Api = (method: string, path: string, body?: unknown) => Promise<any>;

export class OverviewToolError extends Error {}

/** Sent by the `nuo` MCP server: the conversation whose agent calls the gateway (src/api/overview.ts). */
export const CALLER_HEADER = "x-nuo-conversation";

interface BotSummary {
  id: string;
  slug: string;
  name: string;
  emoji: string;
  description: string;
  published: boolean;
  lastMessageAt?: string;
}

interface ReadMessage {
  id: string;
  role: "user" | "assistant";
  text: string;
  createdAt: string;
  attachments?: string[];
}

const MESSAGE_MAX = 6000;

export const OVERVIEW_TOOLS = [
  {
    name: "bots_list",
    description: "Lists all the user's bots: id, name, description and last activity.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "conversations_search",
    description:
      "Searches all the conversations of all the bots, by title and by message content (whole words or word beginnings, ignoring case and accents, all required). Returns the most relevant conversations with the matching excerpt.",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", description: "A few words of the topic, e.g. \"electricity bill\", \"lisbon flight\". Search in the language the conversations were held in." },
        bot: { type: "string", description: "Limit to one bot (id, slug or name)." },
        limit: { type: "number", description: "Number of conversations, 10 by default, 30 at most." },
      },
      required: ["query"],
    },
  },
  {
    name: "conversation_read",
    description: "Reads the latest messages of a conversation of any bot (id from conversations_search or bot_ask).",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string", description: "Id of the conversation." },
        limit: { type: "number", description: "Number of latest messages, 20 by default, 200 at most." },
      },
      required: ["id"],
    },
  },
  {
    name: "bot_ask",
    description:
      "Asks another bot a question or hands it a request, which it answers with its own tools, data and memory, and waits for its answer. It answers in a new conversation of its own, or in `conversation` to pick up an existing thread; the user finds it in the app.",
    inputSchema: {
      type: "object",
      properties: {
        bot: { type: "string", description: "The bot (id, slug or name)." },
        prompt: { type: "string", description: "The request, complete and self-contained, in the user's language: the other bot does not see your conversation." },
        conversation: { type: "string", description: "Id of a conversation of this bot to pick up (optional)." },
        wait_seconds: { type: "number", description: "Longest wait for the answer, 240 s by default, 900 at most." },
      },
      required: ["bot", "prompt"],
    },
  },
];

export const OVERVIEW_TOOL_NAMES = new Set(OVERVIEW_TOOLS.map((t) => t.name));

function fold(s: string): string {
  return s.normalize("NFD").replace(/\p{M}+/gu, "").toLowerCase().trim();
}

function clip(s: string, max: number) {
  return s.length > max ? `${s.slice(0, max - 1)}…` : s;
}

function count(v: unknown, fallback: number, max: number): number {
  const n = Number(v);
  return Number.isFinite(n) && n >= 1 ? Math.min(Math.floor(n), max) : fallback;
}

function day(iso: string): string {
  return new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/Paris", dateStyle: "medium", timeStyle: "short" }).format(new Date(iso));
}

/** The card the user taps to open a conversation in the app (CARD_GUIDE). */
export function conversationCard(id: string, botId: string, title: string): string {
  return `::conversation ${JSON.stringify({ id, botId, title })}`;
}

/** A bot named by id, slug or name, as an agent naturally writes it. */
export function findBot(bots: BotSummary[], ref: string): BotSummary {
  const want = fold(ref);
  const found =
    bots.find((b) => b.id === ref) ??
    bots.find((b) => b.slug === want) ??
    bots.find((b) => fold(b.name) === want) ??
    (() => {
      const close = bots.filter((b) => fold(b.name).includes(want) || b.slug.includes(want));
      return close.length === 1 ? close[0] : undefined;
    })();
  if (!found) throw new OverviewToolError(`no bot "${ref}": ${bots.map((b) => `${b.name} (${b.slug})`).join(", ") || "no bots"}`);
  return found;
}

export async function callOverviewTool(api: Api, self: { botId: string; conversationId?: string }, name: string, a: Args): Promise<string> {
  const bots = async () => (await api("GET", "/api/bots")) as BotSummary[];
  switch (name) {
    case "bots_list": {
      const all = await bots();
      if (!all.length) return "No bots.";
      return all
        .map(
          (b) =>
            `- ${b.emoji} ${b.name} [id ${b.id}, slug ${b.slug}]${b.id === self.botId ? " (you)" : ""}${b.published ? "" : " (draft)"}` +
            `${b.description ? `: ${clip(b.description, 160)}` : ""}${b.lastMessageAt ? ` · last activity ${day(b.lastMessageAt)}` : ""}`,
        )
        .join("\n");
    }
    case "conversations_search": {
      const query = typeof a.query === "string" ? a.query.trim() : "";
      if (!query) throw new OverviewToolError("query is required");
      const all = await bots();
      const bot = typeof a.bot === "string" && a.bot.trim() ? findBot(all, a.bot.trim()) : undefined;
      const params = new URLSearchParams({ q: query, limit: String(count(a.limit, 10, 30)) });
      if (bot) params.set("botId", bot.id);
      const hits = (await api("GET", `/api/conversations/search?${params}`)) as ConversationSearchHit[];
      if (!hits.length) return `No conversation contains "${query}". Try other words, fewer of them.`;
      const names = new Map(all.map((b) => [b.id, `${b.emoji} ${b.name}`.trim()]));
      return hits
        .map(({ conversation: c, snippet, role }) => {
          const where = c.id === self.conversationId ? " (this conversation)" : "";
          const excerpt = snippet ? `\n  ${role === "user" ? "user" : "bot"}: ${snippet.replace(/\s+/g, " ")}` : "";
          return `- "${c.title}"${where} [id ${c.id}, bot ${names.get(c.botId) ?? c.botId} (${c.botId})] · ${day(c.updatedAt)}${excerpt}`;
        })
        .join("\n");
    }
    case "conversation_read": {
      if (typeof a.id !== "string" || !a.id.trim()) throw new OverviewToolError("id is required");
      const r = (await api("GET", `/api/conversations/${encodeURIComponent(a.id.trim())}/messages?limit=${count(a.limit, 20, 200)}`)) as {
        conversation: { id: string; botId: string; title: string };
        total: number;
        messages: ReadMessage[];
        running?: boolean;
      };
      const all = await bots().catch(() => [] as BotSummary[]);
      const bot = all.find((b) => b.id === r.conversation.botId);
      const head = `"${r.conversation.title}" with ${bot ? `${bot.emoji} ${bot.name}`.trim() : r.conversation.botId} · ${r.messages.length} message(s) of ${r.total}${r.running ? " · an answer is in progress" : ""}`;
      const body = r.messages.map((m) => {
        const files = m.attachments?.length ? ` [attachments: ${m.attachments.join(", ")}]` : "";
        return `[${day(m.createdAt)}] ${m.role === "user" ? "User" : "Bot"}${files}:\n${clip(m.text, MESSAGE_MAX)}`;
      });
      return [head, ...body, conversationCard(r.conversation.id, r.conversation.botId, r.conversation.title)].join("\n\n");
    }
    case "bot_ask": {
      const prompt = typeof a.prompt === "string" ? a.prompt.trim() : "";
      if (typeof a.bot !== "string" || !a.bot.trim() || !prompt) throw new OverviewToolError("bot and prompt are required");
      const bot = findBot(await bots(), a.bot.trim());
      if (bot.id === self.botId) throw new OverviewToolError("that is you: answer directly");
      const conversationId = typeof a.conversation === "string" && a.conversation.trim() ? a.conversation.trim() : undefined;
      if (conversationId && conversationId === self.conversationId) throw new OverviewToolError("that is your own conversation");
      const r = (await api("POST", `/api/bots/${encodeURIComponent(bot.id)}/ask`, {
        prompt,
        ...(conversationId ? { conversationId } : {}),
        ...(a.wait_seconds !== undefined ? { waitSeconds: Number(a.wait_seconds) } : {}),
      })) as { conversationId: string; status: "done" | "running" | "error"; text?: string; error?: string };
      const card = conversationCard(r.conversationId, bot.id, clip(prompt.replace(/\s+/g, " "), 60));
      const who = `${bot.emoji} ${bot.name}`.trim();
      if (r.status === "running") return `${who} is still working (conversation ${r.conversationId}). Read it again later with conversation_read.\n${card}`;
      if (r.status === "error") return `${who} could not answer: ${r.error ?? "error"}.${r.text ? `\nStart of the answer:\n${r.text}` : ""}\n${card}`;
      return `Answer from ${who} (conversation ${r.conversationId}):\n\n${r.text ?? ""}\n\n${card}`;
    }
    default:
      throw new OverviewToolError(`unknown tool ${name}`);
  }
}
