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
    description: "Liste tous les bots de l'utilisateur : id, nom, description et dernière activité.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "conversations_search",
    description:
      "Cherche dans toutes les conversations de tous les bots, par titre et par contenu des messages (mots entiers ou débuts de mots, sans casse ni accents, tous requis). Renvoie les conversations les plus pertinentes avec l'extrait trouvé.",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Quelques mots du sujet, ex. « facture edf », « vol lisbonne »." },
        bot: { type: "string", description: "Limiter à un bot (id, slug ou nom)." },
        limit: { type: "number", description: "Nombre de conversations, 10 par défaut, 30 au plus." },
      },
      required: ["query"],
    },
  },
  {
    name: "conversation_read",
    description: "Lit les derniers messages d'une conversation de n'importe quel bot (id obtenu avec conversations_search ou bot_ask).",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string", description: "Id de la conversation." },
        limit: { type: "number", description: "Nombre de derniers messages, 20 par défaut, 200 au plus." },
      },
      required: ["id"],
    },
  },
  {
    name: "bot_ask",
    description:
      "Pose une question ou confie une demande à un autre bot, qui y répond avec ses propres outils, données et mémoire, et attend sa réponse. Il répond dans une nouvelle conversation à lui, ou dans `conversation` pour reprendre un fil existant ; l'utilisateur la retrouve dans l'app.",
    inputSchema: {
      type: "object",
      properties: {
        bot: { type: "string", description: "Le bot (id, slug ou nom)." },
        prompt: { type: "string", description: "La demande, complète et autonome : l'autre bot ne voit pas ta conversation." },
        conversation: { type: "string", description: "Id d'une conversation de ce bot à reprendre (facultatif)." },
        wait_seconds: { type: "number", description: "Attente maximale de la réponse, 240 s par défaut, 900 au plus." },
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
  return new Intl.DateTimeFormat("fr-FR", { timeZone: "Europe/Paris", dateStyle: "medium", timeStyle: "short" }).format(new Date(iso));
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
  if (!found) throw new OverviewToolError(`aucun bot « ${ref} » : ${bots.map((b) => `${b.name} (${b.slug})`).join(", ") || "aucun bot"}`);
  return found;
}

export async function callOverviewTool(api: Api, self: { botId: string; conversationId?: string }, name: string, a: Args): Promise<string> {
  const bots = async () => (await api("GET", "/api/bots")) as BotSummary[];
  switch (name) {
    case "bots_list": {
      const all = await bots();
      if (!all.length) return "Aucun bot.";
      return all
        .map(
          (b) =>
            `- ${b.emoji} ${b.name} [id ${b.id}, slug ${b.slug}]${b.id === self.botId ? " (toi)" : ""}${b.published ? "" : " (brouillon)"}` +
            `${b.description ? ` : ${clip(b.description, 160)}` : ""}${b.lastMessageAt ? ` · dernière activité ${day(b.lastMessageAt)}` : ""}`,
        )
        .join("\n");
    }
    case "conversations_search": {
      const query = typeof a.query === "string" ? a.query.trim() : "";
      if (!query) throw new OverviewToolError("query requis");
      const all = await bots();
      const bot = typeof a.bot === "string" && a.bot.trim() ? findBot(all, a.bot.trim()) : undefined;
      const params = new URLSearchParams({ q: query, limit: String(count(a.limit, 10, 30)) });
      if (bot) params.set("botId", bot.id);
      const hits = (await api("GET", `/api/conversations/search?${params}`)) as ConversationSearchHit[];
      if (!hits.length) return `Aucune conversation ne contient « ${query} ». Essaie d'autres mots, moins nombreux.`;
      const names = new Map(all.map((b) => [b.id, `${b.emoji} ${b.name}`.trim()]));
      return hits
        .map(({ conversation: c, snippet, role }) => {
          const where = c.id === self.conversationId ? " (cette conversation)" : "";
          const excerpt = snippet ? `\n  ${role === "user" ? "utilisateur" : "bot"} : ${snippet.replace(/\s+/g, " ")}` : "";
          return `- « ${c.title} »${where} [id ${c.id}, bot ${names.get(c.botId) ?? c.botId} (${c.botId})] · ${day(c.updatedAt)}${excerpt}`;
        })
        .join("\n");
    }
    case "conversation_read": {
      if (typeof a.id !== "string" || !a.id.trim()) throw new OverviewToolError("id requis");
      const r = (await api("GET", `/api/conversations/${encodeURIComponent(a.id.trim())}/messages?limit=${count(a.limit, 20, 200)}`)) as {
        conversation: { id: string; botId: string; title: string };
        total: number;
        messages: ReadMessage[];
        running?: boolean;
      };
      const all = await bots().catch(() => [] as BotSummary[]);
      const bot = all.find((b) => b.id === r.conversation.botId);
      const head = `« ${r.conversation.title} » avec ${bot ? `${bot.emoji} ${bot.name}`.trim() : r.conversation.botId} · ${r.messages.length} message(s) sur ${r.total}${r.running ? " · une réponse est en cours" : ""}`;
      const body = r.messages.map((m) => {
        const files = m.attachments?.length ? ` [pièces jointes : ${m.attachments.join(", ")}]` : "";
        return `[${day(m.createdAt)}] ${m.role === "user" ? "Utilisateur" : "Bot"}${files} :\n${clip(m.text, MESSAGE_MAX)}`;
      });
      return [head, ...body, conversationCard(r.conversation.id, r.conversation.botId, r.conversation.title)].join("\n\n");
    }
    case "bot_ask": {
      const prompt = typeof a.prompt === "string" ? a.prompt.trim() : "";
      if (typeof a.bot !== "string" || !a.bot.trim() || !prompt) throw new OverviewToolError("bot et prompt requis");
      const bot = findBot(await bots(), a.bot.trim());
      if (bot.id === self.botId) throw new OverviewToolError("c'est toi : réponds directement");
      const conversationId = typeof a.conversation === "string" && a.conversation.trim() ? a.conversation.trim() : undefined;
      if (conversationId && conversationId === self.conversationId) throw new OverviewToolError("c'est ta propre conversation");
      const r = (await api("POST", `/api/bots/${encodeURIComponent(bot.id)}/ask`, {
        prompt,
        ...(conversationId ? { conversationId } : {}),
        ...(a.wait_seconds !== undefined ? { waitSeconds: Number(a.wait_seconds) } : {}),
      })) as { conversationId: string; status: "done" | "running" | "error"; text?: string; error?: string };
      const card = conversationCard(r.conversationId, bot.id, clip(prompt.replace(/\s+/g, " "), 60));
      const who = `${bot.emoji} ${bot.name}`.trim();
      if (r.status === "running") return `${who} travaille encore (conversation ${r.conversationId}). Relis-la plus tard avec conversation_read.\n${card}`;
      if (r.status === "error") return `${who} n'a pas pu répondre : ${r.error ?? "erreur"}.${r.text ? `\nDébut de réponse :\n${r.text}` : ""}\n${card}`;
      return `Réponse de ${who} (conversation ${r.conversationId}) :\n\n${r.text ?? ""}\n\n${card}`;
    }
    default:
      throw new OverviewToolError(`outil inconnu ${name}`);
  }
}
