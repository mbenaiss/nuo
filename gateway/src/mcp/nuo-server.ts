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
  const date = new Intl.DateTimeFormat("fr-FR", { timeZone: tz, dateStyle: "full", timeStyle: "short" }).format(new Date(now));
  const off = tzOffset(now, tz) / 60_000;
  const sign = off < 0 ? "-" : "+";
  const hh = String(Math.floor(Math.abs(off) / 60)).padStart(2, "0");
  const mm = String(Math.abs(off) % 60).padStart(2, "0");
  return `${date} (${tz}, UTC${sign}${hh}:${mm})`;
}

function formatInstant(iso: string | undefined, tz: string): string {
  if (!iso) return "aucune";
  return new Intl.DateTimeFormat("fr-FR", { timeZone: tz, dateStyle: "full", timeStyle: "short" }).format(new Date(iso));
}

/** A date without offset is a wall-clock time in `tz`, which is what an agent naturally writes. */
export function parseAt(at: string, tz: string): string {
  const m = at.trim().match(/^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?$/);
  if (m) return new Date(zonedToUtc(+m[1]!, +m[2]!, +m[3]!, +m[4]!, +m[5]!, tz) + Number(m[6] ?? 0) * 1000).toISOString();
  const t = Date.parse(at);
  if (!Number.isFinite(t)) throw new ToolError(`date invalide « ${at} » : utilise le format 2026-10-18T07:00`);
  return new Date(t).toISOString();
}

function scheduleFrom(a: Args, fallbackTz: string, now: number): TaskSchedule | undefined {
  const tz = typeof a.timezone === "string" && a.timezone ? a.timezone : fallbackTz;
  if (!isValidTimeZone(tz)) throw new ToolError(`fuseau horaire inconnu « ${tz} »`);
  const given = [a.cron, a.at, a.in_minutes].filter((v) => v !== undefined && v !== null && v !== "").length;
  if (given > 1) throw new ToolError("donne un seul de cron, at ou in_minutes");
  if (typeof a.cron === "string" && a.cron.trim()) return { kind: "cron", expr: a.cron.trim(), timezone: tz };
  if (typeof a.at === "string" && a.at.trim()) return { kind: "once", at: parseAt(a.at, tz) };
  if (a.in_minutes !== undefined && a.in_minutes !== null && a.in_minutes !== "") {
    const n = Number(a.in_minutes);
    if (!Number.isFinite(n) || n < 1) throw new ToolError("in_minutes doit être un nombre de minutes ≥ 1");
    return { kind: "once", at: new Date(now + Math.round(n) * 60_000).toISOString() };
  }
  return undefined;
}

function describeTask(t: ScheduledTask, self: string): string {
  const tz = t.schedule.kind === "cron" ? t.schedule.timezone : DEFAULT_TIMEZONE;
  const when = t.schedule.kind === "cron" ? `cron « ${t.schedule.expr} » (${t.schedule.timezone})` : `une fois, ${formatInstant(t.schedule.at, tz)}`;
  return [
    `- ${t.title} [id ${t.id}]${t.botId === self ? "" : ` (bot ${t.botId})`}`,
    `  quand : ${when}`,
    `  prochaine exécution : ${t.enabled ? formatInstant(t.nextRunAt, tz) : "désactivée"}`,
    t.action?.type === "command"
      ? `  commande (lecture seule, gérée depuis l'app) : ${clip(t.action.command, 200)}${t.action.cwd ? ` · dossier : ${t.action.cwd}` : ""}${t.lastStatus ? ` · dernier statut : ${t.lastStatus}` : ""}`
      : `  conversation : ${t.conversation === "new" ? "nouvelle à chaque fois" : "dédiée"} · notification : ${t.notify ? "oui" : "non"}${t.lastStatus ? ` · dernier statut : ${t.lastStatus}` : ""}\n  prompt : ${clip(t.prompt, 200)}`,
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
      throw new ToolError(`un fichier ${ext} ne s'écrit pas en texte : passe le fichier de ton espace de travail dans \`from\`, il est copié tel quel en une seule fois`);
    }
    return a;
  }
  if (typeof a.content === "string") throw new ToolError("donne content ou from, pas les deux");
  const path = resolve(a.from.trim());
  const info = await stat(path).catch(() => undefined);
  if (!info?.isFile()) throw new ToolError(`${path} n'est pas un fichier de ton espace de travail`);
  if (info.size > MAX_MAC_FILE_BYTES) throw new ToolError(`${path} fait ${Math.ceil(info.size / 1024 / 1024)} Mo : 30 Mo au plus`);
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
      .map(([k, v]) => [k, ["start", "end", "at", "occurrence_start"].includes(k) ? { ...v, description: "Date-heure locale, exactement AAAA-MM-JJTHH:MM, sans fuseau." } : v]),
  );
  return { ...tool, inputSchema: { ...schema, properties } };
}

function allToolDefinitions(now: number, opts: { overview?: boolean }) {
  const nowText = describeNow(DEFAULT_TIMEZONE, now);
  const scheduleProps = {
    cron: {
      type: "string",
      description:
        "Récurrence, cron à 5 champs (minute heure jour-du-mois mois jour-de-semaine) dans `timezone`. Exemples : « tous les jours à 7h » → \"0 7 * * *\" ; « en semaine à 7h30 » → \"30 7 * * 1-5\" ; « le lundi et le jeudi à 18h » → \"0 18 * * 1,4\" ; « toutes les 2 heures » → \"0 */2 * * *\" ; « le 1er du mois à 9h » → \"0 9 1 * *\".",
    },
    at: {
      type: "string",
      description: `Exécution unique : date et heure locales dans \`timezone\`, format AAAA-MM-JJTHH:MM (ex. « demain à 8h » → la date de demain + "T08:00"). Maintenant : ${nowText}.`,
    },
    in_minutes: { type: "number", description: "Exécution unique dans N minutes (ex. « dans une heure » → 60). Plus fiable que `at` pour un délai court." },
    timezone: { type: "string", description: `Fuseau IANA, par défaut ${DEFAULT_TIMEZONE}.` },
    notify: { type: "boolean", description: "Envoyer la réponse en notification push (par défaut oui)." },
  };
  return [
    {
      name: "schedule_create",
      description: `Programme une tâche : à l'heure dite, la passerelle Nuo t'envoie \`prompt\` comme un message de l'utilisateur et lui pousse ta réponse en notification. Donne exactement un de cron, at ou in_minutes. Exemple : « fais-moi un point météo tous les matins à 7h » → title "Météo du matin", prompt "Donne-moi la météo du jour à Paris", cron "0 7 * * *". Pour prévenir l'utilisateur d'une trouvaille pendant une tâche, utilise notify_user, pas une nouvelle tâche. Maintenant : ${nowText}.`,
      inputSchema: {
        type: "object",
        properties: {
          title: { type: "string", description: "Titre court en français (60 caractères max), affiché dans la notification. Ex. « Séance du jour »." },
          prompt: {
            type: "string",
            description: "Le message qui te sera envoyé à chaque exécution, rédigé comme une demande autonome (tu n'auras pas le contexte d'aujourd'hui). Commandes /… et #tags permis.",
          },
          ...scheduleProps,
          conversation: {
            type: "string",
            enum: ["dedicated", "new", "current"],
            description: "Où s'exécute la tâche : \"dedicated\" (défaut) une conversation propre à la tâche, réutilisée à chaque fois ; \"new\" une nouvelle conversation à chaque exécution ; \"current\" la suite de cette conversation-ci (pour un rappel lié à l'échange en cours).",
          },
          bot: { type: "string", description: "Nom d'un autre bot qui doit exécuter la tâche, seulement si l'utilisateur le demande. Par défaut : toi." },
        },
        required: ["title", "prompt"],
      },
    },
    {
      name: "notify_user",
      description:
        "Prévient l'utilisateur tout de suite par une notification push (iPhone, Mac). C'est l'outil pour une alerte ou une trouvaille pendant une tâche planifiée qui ne notifie pas elle-même : jamais schedule_create pour envoyer un message. `key` identifie ce qui est signalé (ex. « illusions-2321184 » pour une séance) : la même clé ne notifie qu'une fois par période, pour ne pas répéter la même alerte à chaque vérification.",
      inputSchema: {
        type: "object",
        properties: {
          title: { type: "string", description: "Titre court (60 caractères max)." },
          body: { type: "string", description: "Le message, complet et autonome." },
          key: { type: "string", description: "Identifiant stable de ce qui est signalé ; omis : aucune déduplication." },
          repeat_hours: { type: "number", description: "Avec key : délai avant de pouvoir notifier à nouveau la même clé (24 h par défaut)." },
        },
        required: ["title", "body"],
      },
    },
    {
      name: "schedule_list",
      description: `Liste les tâches programmées (avec leur id, leur récurrence et la prochaine exécution). Maintenant : ${nowText}.`,
      inputSchema: {
        type: "object",
        properties: { all_bots: { type: "boolean", description: "Inclure les tâches des autres bots (par défaut : seulement les tiennes)." } },
      },
    },
    {
      name: "schedule_update",
      description: `Modifie une tâche programmée (id obtenu avec schedule_list). Seuls les champs donnés changent ; cron, at ou in_minutes remplacent la planification. enabled=false met la tâche en pause. Une tâche de type commande accepte seulement planification, titre, notify et enabled. Maintenant : ${nowText}.`,
      inputSchema: {
        type: "object",
        properties: {
          id: { type: "string" },
          title: { type: "string" },
          prompt: { type: "string" },
          ...scheduleProps,
          enabled: { type: "boolean", description: "false = en pause, true = réactivée." },
          conversation: { type: "string", enum: ["dedicated", "new"] },
        },
        required: ["id"],
      },
    },
    {
      name: "schedule_delete",
      description: "Supprime définitivement une tâche programmée (id obtenu avec schedule_list).",
      inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] },
    },
    {
      name: "memory_read",
      description: "Lit ta mémoire persistante (MEMORY.md), commune à toutes tes conversations.",
      inputSchema: { type: "object", properties: {} },
    },
    {
      name: "memory_add",
      description:
        "Ajoute un fait durable à ta mémoire persistante (une ligne datée). À utiliser dès que l'utilisateur donne une préférence, une habitude ou une information à retenir. Jamais de secret (mot de passe, token, clé, code, numéro de carte).",
      inputSchema: {
        type: "object",
        properties: { fact: { type: "string", description: "Le fait, en une phrase courte et autonome (500 caractères max). Ex. « Préfère les vols du matin »." } },
        required: ["fact"],
      },
    },
    {
      name: "memory_write",
      description: "Remplace tout le contenu de ta mémoire persistante (pour la nettoyer : doublons, faits devenus faux). Lis-la d'abord avec memory_read.",
      inputSchema: {
        type: "object",
        properties: { content: { type: "string", description: "Le nouveau contenu complet, en Markdown (une ligne « - AAAA-MM-JJ fait » par fait)." } },
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
    if (!res.ok) throw new ToolError(`la passerelle a refusé (${res.status}) : ${data?.error ?? text}`);
    return data;
  }

  private async task(id: unknown): Promise<ScheduledTask> {
    if (typeof id !== "string" || !id) throw new ToolError("id requis");
    const all = (await this.api("GET", "/api/schedules")) as ScheduledTask[];
    const t = all.find((x) => x.id === id);
    if (!t) throw new ToolError(`aucune tâche avec l'id ${id}`);
    return t;
  }

  private async editableTask(id: unknown): Promise<ScheduledTask> {
    const t = await this.task(id);
    if (t.action?.type === "command") throw new ToolError(`« ${t.title} » est une tâche de type commande : elle se supprime uniquement depuis l'app Nuo`);
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
    if (!res.ok) throw new ToolError(data?.error ?? `la passerelle a refusé (${res.status})`);
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
      if (!this.env.overview) throw new ToolError(`${name} est réservé au bot qui a l'accès à tous les bots (Nuo › bot › Initiative)`);
      try {
        return await callOverviewTool((m, p, b) => this.api(m, p, b), this.env, name, a);
      } catch (e) {
        throw e instanceof OverviewToolError ? new ToolError(e.message) : e;
      }
    }
    switch (name) {
      case "schedule_create": {
        const schedule = scheduleFrom(a, DEFAULT_TIMEZONE, now);
        if (!schedule) throw new ToolError("indique cron (récurrent), at ou in_minutes (une fois)");
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
          if (!this.env.conversationId) throw new ToolError("pas de conversation courante");
          body.conversationId = this.env.conversationId;
        }
        const t = (await this.api("POST", "/api/schedules", body)) as ScheduledTask;
        return `Tâche programmée.\n${describeTask(t, this.env.botId)}\n(Maintenant : ${describeNow(DEFAULT_TIMEZONE, now)})`;
      }
      case "notify_user": {
        if (typeof a.title !== "string" || !a.title.trim() || typeof a.body !== "string" || !a.body.trim()) throw new ToolError("title et body requis");
        const r = (await this.api("POST", "/api/notify", {
          title: a.title.trim(),
          body: a.body.trim(),
          botId: this.env.botId,
          ...(this.env.conversationId ? { conversationId: this.env.conversationId } : {}),
          ...(typeof a.key === "string" && a.key.trim() ? { key: a.key.trim() } : {}),
          ...(typeof a.repeat_hours === "number" ? { repeatHours: a.repeat_hours } : {}),
        })) as { sent?: boolean; lastSentAt?: string } | undefined;
        if (r?.sent === false) return `Déjà notifié pour « ${a.key} » (${r.lastSentAt}) : aucune nouvelle notification envoyée. Ne réessaie pas.`;
        return "Notification envoyée.";
      }
      case "schedule_list": {
        const all = (await this.api("GET", a.all_bots === true ? "/api/schedules" : `/api/schedules?botId=${encodeURIComponent(this.env.botId)}`)) as ScheduledTask[];
        const head = `Maintenant : ${describeNow(DEFAULT_TIMEZONE, now)}`;
        if (!all.length) return `Aucune tâche programmée.\n${head}`;
        return `${all.length} tâche(s) programmée(s) :\n${all.map((t) => describeTask(t, this.env.botId)).join("\n")}\n${head}`;
      }
      case "schedule_update": {
        const existing = await this.task(a.id);
        if (existing.action?.type === "command" && (a.prompt !== undefined || a.conversation !== undefined)) {
          throw new ToolError(`« ${existing.title} » est une tâche de type commande : tu peux changer sa planification, son titre, ses notifications ou la mettre en pause, pas ce qu'elle exécute`);
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
        if (!Object.keys(body).length) throw new ToolError("rien à modifier");
        const t = (await this.api("PATCH", `/api/schedules/${encodeURIComponent(existing.id)}`, body)) as ScheduledTask;
        return `Tâche modifiée.\n${describeTask(t, this.env.botId)}`;
      }
      case "schedule_delete": {
        const existing = await this.editableTask(a.id);
        await this.api("DELETE", `/api/schedules/${encodeURIComponent(existing.id)}`);
        return `Tâche « ${existing.title} » supprimée.`;
      }
      case "memory_read": {
        const m = (await this.api("GET", this.memoryPath())) as BotMemory;
        return m.content.trim() ? m.content : "Mémoire vide.";
      }
      case "memory_add": {
        await this.api("POST", this.memoryPath(), { fact: a.fact });
        return "Fait ajouté à la mémoire.";
      }
      case "memory_write": {
        if (typeof a.content !== "string") throw new ToolError("content requis");
        await this.api("PUT", this.memoryPath(), { content: a.content });
        return a.content.trim() ? "Mémoire réécrite." : "Mémoire vidée.";
      }
      default:
        throw new ToolError(`outil inconnu ${name}`);
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
      const message = e instanceof ToolError ? e.message : `erreur : ${(e as Error)?.message ?? String(e)}`;
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
