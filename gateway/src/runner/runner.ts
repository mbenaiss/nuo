import { head, tail } from "../text";
import { basename, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  contextWindow,
  estimateConversationTokens,
  estimateTokens,
  handoffTranscript,
  isNotice,
  NOTICE_PREFIX,
  noticeLine,
  type CompactedNotice,
  type Notice,
} from "../agents/context";
import { neutralizeCommand, neutralizeMentions } from "../agents/mentions";
import type { AgentSession, McpServerSpec, PermissionAsk, RunEvent, SessionOptions, UnpromptedWork, UsageReport } from "../agents/types";
import type { BotService } from "../bots/service";
import type { ToolCatalog } from "../bots/catalog";
import { BUILTIN_TOOL_SERVER, expandTemplate, parseCommand, toolArguments } from "../bots/commands";
import { NuoTools } from "../mcp/nuo-server";
import { relayConfirmationTitle, relayRefusal, type RelayToolCall } from "../relay/whitelist";
import { prepareWorkspace, relayInstructions, unattendedLanguageHint, VOICE_PREFIX } from "../bots/instructions";
import { languageName } from "../i18n/language";
import { GOAL_CONFIRMATION_TIMEOUT_MS, GOAL_PREFIX, goalConfirmation } from "./goal";
import type { MachineToolSource } from "../machine/discovery";
import { taggedTools, toolHint } from "../machine/tags";
import type {
  ActiveTurn as ActiveTurnInfo,
  AgentId,
  Attachment,
  BotCommandAction,
  BotConfig,
  ContextUsage,
  Message,
  MessageTask,
  MessageWake,
  PermissionOption,
  PermissionRequest,
  ServerEvent,
  SubagentInfo,
  ToolRule,
  ToolStep,
  TurnPhase,
  TurnSnapshot,
} from "../protocol";
import { offeredRules, ruleFor, toolRuleKey } from "../bots/tool-rules";
import type { LiveActivityTarget, Pusher } from "../push/apns";
import type { MediaStore } from "../store/media";
import { newId, now, preview, type StoredConversation, type Store } from "../store/store";
import { cardsFromToolText } from "./tool-cards";
import { decodeAttachments, filesNote, saveWorkspaceFile, type SavedFile } from "./attachments";
import { folderNote } from "../device/folder";
import { publishArtifacts } from "./artifacts";
import type { Hub } from "./hub";
import { MCP_IDLE_MS, McpPool, type ToolContent } from "./mcp";
import { AgentEnv } from "./agent-env";
import type { Runtimes } from "./runtimes";
import type { SecretMask } from "../secrets/mask";

export interface RunnerOptions {
  maxSessions: number;
  idleMs: number;
  permissionTimeoutMs: number;
  mcpIdleMs?: number;
  /** Compact before a prompt when the context is fuller than AUTO_COMPACT_RATIO; defaults to NUO_AUTO_COMPACT != "0". */
  autoCompact?: boolean;
  /** With autoCompact: a conversation left with more than `minTokens` of context is compacted after `afterMs` without a message. */
  idleCompact?: { afterMs: number; minTokens: number };
  /** How the agents of this profile start the built-in `nuo` MCP server, and its HOME (profiles run as another user). */
  nuoMcp?: { command: string; args: string[]; home?: string };
  /** CODEX_HOME of this profile's agents, for context window sizes. */
  codexHome?: string;
  /** Hides secret values in everything the bots write (answers, thoughts, steps, subagents). */
  mask?: SecretMask;
  /** A real browser every bot gets, whatever its permissions: the lightpanda MCP server. */
  browserMcp?: McpServerSpec;
  /** Where the MCP servers' secrets go (src/runner/agent-env.ts); a private temporary folder when unset. */
  agentEnv?: { dir: string; shared?: boolean };
}

export const DEFAULT_RUNNER_OPTIONS: RunnerOptions = {
  maxSessions: 3,
  idleMs: 30 * 60 * 1000,
  permissionTimeoutMs: 5 * 60 * 1000,
};

export interface PromptInput {
  conversationId: string;
  text: string;
  attachments?: Attachment[];
  /** Switches the conversation to this agent from now on; `model`/`effort` then belong to it. */
  agent?: AgentId;
  model?: string;
  effort?: string;
  voice?: boolean;
  /** « Objectif »: the bot works without asking at each step (src/runner/goal.ts). Ignored from an extension or the relay. */
  goal?: boolean;
  /** « Envoyer maintenant »: into the running turn when the agent can take it, else after stopping that turn. */
  steer?: boolean;
  folder?: unknown;
}

/** The agent and model a conversation's next turn runs on. */
interface Brain {
  agent: AgentId;
  model: string;
}

interface Live {
  session: AgentSession;
  key: string;
  model: string;
  effort?: string;
  lastUsed: number;
  /** Started for a relay turn: everything it does, its unprompted work included, stays under the relay's limits. */
  relay?: RelayOrigin;
}

/** Where a relay turn comes from: the device whose relay key passed it on, and the conversation the relay opened. */
export interface RelayOrigin {
  deviceId: string;
  conversationId: string;
}

/** A relay request the gateway turns down before any turn; `status` is the HTTP answer. */
export class RelayRefusedError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
  }
}

/** What the agent reads before a relay turn's request, not kept in the transcript. */
export const RELAY_HINT =
  "[Nuo] Demande passée par la montre pendant que l'iPhone est verrouillé : tu peux seulement ajouter un rappel, un évènement, une note ou un élément de collection, ou passer un message à un bot. Pour tout le reste, dis que c'est « à faire depuis l'iPhone déverrouillé ».\n\n";

/** A slash command however it is padded (spaces, BOM, zero-width or invisible characters before it). */
export function isSlashCommand(text: string): boolean {
  return text.replace(/^[\s\p{Cf}]+/u, "").startsWith("/");
}

/** How a queued turn ended, for callers that wait on it (scheduled tasks). */
export interface TurnOutcome {
  /** The answer's message, when the turn wrote one. */
  messageId?: string;
  text: string;
  stopReason: NonNullable<Message["stopReason"]>;
  error?: string;
}

export interface PromptOptions {
  /** A turn the user did not trigger: the conversation keeps its title and the caller handles the push. */
  scheduled?: boolean;
  /** The scheduled task this prompt comes from, kept on the user message so the apps show its title instead. */
  task?: MessageTask;
  /** The webhook or mail this prompt was written from, kept on the user message so the apps show it instead. */
  wake?: MessageWake;
  /** Sent to the agent only, without a user message in the transcript (resuming after a restart). */
  silent?: boolean;
  /**
   * Text the owner did not type in the app (a share, the watch, a machine token, another bot): it cannot attach a
   * file by an `@path` mention nor run one of Claude Code's commands. Kept so in the transcript too, which a later
   * turn may hand to another agent.
   */
  untrusted?: boolean;
  /**
   * Passed on by the relay (the watch's request while the iPhone is locked), or asked by a bot during such a turn:
   * the session only adds (src/relay/whitelist.ts), with `ask` for each tool whatever the bot's policy.
   */
  relay?: RelayOrigin;
}

const INTERRUPTED_KEY = "runner.interrupted";
/** Relay turns the last shutdown cut, with where they came from: never started again as the app's. */
const INTERRUPTED_RELAY_KEY = "runner.interruptedRelay";
const RESUMED_TEXT = "Reprise après le redémarrage de la passerelle";
export const RELAY_INTERRUPTED_TEXT = "Coupée par le redémarrage de la passerelle : la demande attend le déverrouillage de l'iPhone";
/** A relay session's native session, kept apart from the app's: neither ever resumes the other's. */
export const relayNativeKey = (agent: string) => `${agent}:relay`;
const RESUME_PROMPT =
  "[Nuo] La passerelle a redémarré pendant ta réponse ou pendant que tes tâches de fond (sous-agents, commandes) tournaient : tout a été coupé. Reprends exactement là où tu t'es arrêté, relance ce qui n'était pas fini sans refaire ce qui est déjà fait, et termine la demande de l'utilisateur.";
/** How long shutdown waits for the interrupted turns to save what they had. */
const SHUTDOWN_SETTLE_MS = 5_000;

/** Where the built-in `nuo` MCP server reaches the gateway. */
export interface NuoEndpoint {
  url: string;
  token: string;
}

export const NUO_MCP_SERVER = fileURLToPath(new URL("../mcp/nuo-server.ts", import.meta.url));

interface ModelOverride {
  model?: string;
  effort?: string;
}

interface ActiveTurn {
  session?: AgentSession;
  cancelled: boolean;
  abort?: () => void;
}

interface CompactResult {
  before?: number;
  after?: number;
  maxTokens?: number;
  model?: string;
}

/** What clients need to show a running turn; rebuilt from the events the runner emits. */
interface TurnState {
  conversationId: string;
  botId: string;
  messageId: string;
  startedAt: number;
  phase: TurnPhase;
  text: string;
  thoughts: string;
  steps: ToolStep[];
  subagents: SubagentInfo[];
  permission?: PermissionRequest;
}

interface TurnStart {
  messageId: string;
  startedAt: number;
  at: string;
}

const PARTIAL_TEXT_MAX = 200;
const SUBAGENT_TEXT_MAX = 6000;
const SUBAGENT_DESCRIPTION_MAX = 2000;
const SUBAGENT_STEPS_MAX = 80;
/** A subagent's streamed text is sent at most this often; its steps and state go out at once. */
const SUBAGENT_TEXT_THROTTLE_MS = 400;

interface PendingPermission {
  conversationId: string;
  title: string;
  options: PermissionOption[];
  /** Asked in a relay session: the only confirmations the relay may answer. */
  relay: boolean;
  /** The tool a relay confirmation is for, as the audit log names it. */
  tool?: string;
  /** What the card may remember for its tool, on which bot. */
  remember?: { botId: string; key: string; rules: ToolRule[] };
  resolve: (optionId: string) => void;
}

/** What one relay turn did: the events it created, the tools a confirmation let through (each used once). */
interface RelayFacts {
  createdEvents: Set<string>;
  approvals: string[];
}

export const TITLE_MAX = 60;
export const AUTO_COMPACT_RATIO = 0.85;
/**
 * A 1M window never reaches AUTO_COMPACT_RATIO, yet every resume of a session reloads its whole context: a big one
 * is compacted while the user is away, on a session still alive, so the next answer starts light.
 */
export const IDLE_COMPACT = { afterMs: 2 * 60 * 1000, minTokens: 150_000 };
const LIVE_ACTIVITY_THROTTLE_MS = 8_000;
const LIVE_ACTIVITY_DISMISS_S = 15 * 60;
/** Swift decodes `Date` in a Live Activity content state as seconds since 2001-01-01. */
const APPLE_EPOCH_S = 978_307_200;

interface LiveActivity extends LiveActivityTarget {
  deviceId: string;
  lastPushAt: number;
}

interface LiveActivityState {
  phase: "thinking" | "working" | "answering" | "done" | "failed" | "cancelled";
  steps: number;
  currentTool?: string;
  answer?: string;
  startedAt: number;
  endedAt?: number;
}

function activityContentState(s: LiveActivityState): Record<string, unknown> {
  const date = (ms: number) => ms / 1000 - APPLE_EPOCH_S;
  return {
    phase: s.phase,
    steps: s.steps,
    ...(s.currentTool ? { currentTool: s.currentTool } : {}),
    ...(s.answer ? { answer: s.answer } : {}),
    startedAt: date(s.startedAt),
    ...(s.endedAt ? { endedAt: date(s.endedAt) } : {}),
  };
}

const COMPACT_RE = /^\s*\/(?:compact|compress)(?:\s+([\s\S]*))?$/i;
const NATIVE_COMPACT = ["compact", "compress"];
export const COMPACTED_TEXT = "Conversation compactée";

export const SUMMARY_PROMPT = `[Nuo] La conversation va être compactée. Rédige un résumé dense, en français, de toute notre conversation jusqu'ici : il sera ton seul contexte pour la suite. Garde les décisions prises, les faits établis, les tâches ouvertes, les préférences de l'utilisateur, les chemins de fichiers et identifiants utiles. Moins de 800 mots, texte simple, sans cartes ni outils. Réponds uniquement par le résumé.`;
export const SEED_PREFIX = `[Nuo] Cette conversation a été compactée. Voici le résumé de l'échange précédent, à garder comme contexte pour la suite. Réponds seulement « OK ».\n\n`;

export function shouldAutoCompact(context: ContextUsage | undefined, ratio = AUTO_COMPACT_RATIO): boolean {
  return !!context?.maxTokens && context.usedTokens > ratio * context.maxTokens;
}

export class Runner {
  private lives = new Map<string, Live>();
  private queues = new Map<string, Promise<void>>();
  private active = new Map<string, ActiveTurn>();
  private permissions = new Map<string, PendingPermission>();
  /** Conversations whose current turn came through the relay (see `PromptOptions.relay`). */
  private relayTurns = new Map<string, RelayOrigin>();
  private relayFacts = new Map<string, RelayFacts>();
  /** Relay conversations where a tool was refused: the iPhone sends the request again once unlocked. */
  private relayRefused = new Set<string>();
  /** Bumped when a device's relay access is revoked: its queued relay turns never start. */
  private relayEpochs = new Map<string, number>();
  /** Relay prompts queued or running, per conversation: a shutdown notes them apart (`INTERRUPTED_RELAY_KEY`). */
  private relayPending = new Map<string, { origin: RelayOrigin; n: number }>();
  /** Told of each tool refused to a relay session, for the audit log (set by the profile, which owns it). */
  onRelayRefused?: (origin: RelayOrigin, tool: string, conversationId: string) => void;
  private sweeper: ReturnType<typeof setInterval>;
  private mcp: McpPool;
  private autoCompact: boolean;
  private outcomes = new Map<string, TurnOutcome>();
  private scheduled = new Set<string>();
  /** Conversations whose running turn is a goal turn. */
  private goals = new Set<string>();
  private liveActivities = new Map<string, LiveActivity[]>();
  private turnStates = new Map<string, TurnState>();
  private nuo?: NuoEndpoint;
  private agentEnv: AgentEnv;
  private idleCompactTimers = new Map<string, ReturnType<typeof setTimeout>>();
  private stopping = false;
  /** What the coming stop cuts, with the relay origin of each, noted by `noteInterrupted` before anything stops. */
  private cut?: Map<string, RelayOrigin | undefined>;
  /** Background compactions running: not a turn of the user's, so never resumed after a restart. */
  private idleCompactions = new Map<string, ActiveTurn>();
  private nuoEnvFile?: string;

  constructor(
    private store: Store,
    private bots: BotService,
    private catalog: ToolCatalog,
    private runtimes: Runtimes,
    private media: MediaStore,
    private hub: Hub,
    private pusher: Pusher,
    private opts: RunnerOptions = DEFAULT_RUNNER_OPTIONS,
    private machine?: MachineToolSource,
  ) {
    this.sweeper = setInterval(() => this.closeIdle(), Math.min(30_000, opts.idleMs));
    this.sweeper.unref?.();
    this.mcp = new McpPool(opts.mcpIdleMs ?? MCP_IDLE_MS);
    this.autoCompact = opts.autoCompact ?? process.env.NUO_AUTO_COMPACT !== "0";
    this.agentEnv = new AgentEnv(opts.agentEnv);
  }

  /** The app started a Live Activity for the running turn; the gateway updates and ends it by push. */
  registerLiveActivity(conversationId: string, deviceId: string, target: LiveActivityTarget) {
    const list = (this.liveActivities.get(conversationId) ?? []).filter((a) => a.deviceId !== deviceId);
    list.push({ ...target, deviceId, lastPushAt: 0 });
    this.liveActivities.set(conversationId, list);
  }

  get liveCount() {
    return this.lives.size;
  }

  /** Conversations with a queued or running turn. */
  get busyCount() {
    return this.queues.size;
  }

  get maxSessions() {
    return this.opts.maxSessions;
  }

  setNuoEndpoint(endpoint: NuoEndpoint) {
    this.nuo = endpoint;
    this.nuoEnvFile = this.agentEnv.writeNuo(endpoint);
  }

  /** Running turns with everything streamed so far, for `turns.snapshot` and `GET /api/conversations/:id`. */
  snapshots(conversationId?: string): TurnSnapshot[] {
    const states = conversationId ? [this.turnStates.get(conversationId)].filter((s) => !!s) : [...this.turnStates.values()];
    return states.map((s) => ({
      conversationId: s.conversationId,
      botId: s.botId,
      messageId: s.messageId,
      startedAt: new Date(s.startedAt).toISOString(),
      phase: s.phase,
      ...(currentTool(s) ? { currentTool: currentTool(s) } : {}),
      text: s.text,
      ...(s.thoughts ? { thoughts: s.thoughts } : {}),
      steps: s.steps.map((step) => ({ ...step })),
      ...(s.subagents.length ? { subagents: s.subagents } : {}),
      ...(s.permission ? { permission: s.permission } : {}),
    }));
  }

  /** `full` keeps the whole partial text instead of its last characters. */
  activeTurn(conversationId: string, full = false): ActiveTurnInfo | undefined {
    const s = this.turnStates.get(conversationId);
    if (!s) return undefined;
    const tool = currentTool(s);
    const partial = full || s.text.length <= PARTIAL_TEXT_MAX ? s.text : `…${tail(s.text, PARTIAL_TEXT_MAX)}`;
    return {
      messageId: s.messageId,
      startedAt: new Date(s.startedAt).toISOString(),
      phase: s.phase,
      ...(tool ? { currentTool: tool } : {}),
      steps: s.steps.length,
      ...(partial ? { partialText: partial } : {}),
    };
  }

  /** Per bot: how many conversations have a running turn, and the one started last. */
  activeTurnsByBot(): Map<string, { count: number; conversationId: string }> {
    const out = new Map<string, { count: number; conversationId: string; startedAt: number }>();
    for (const s of this.turnStates.values()) {
      const prev = out.get(s.botId);
      out.set(s.botId, {
        count: (prev?.count ?? 0) + 1,
        conversationId: !prev || s.startedAt >= prev.startedAt ? s.conversationId : prev.conversationId,
        startedAt: Math.max(prev?.startedAt ?? 0, s.startedAt),
      });
    }
    return out;
  }

  /**
   * Persists the user message right away, then queues the agent turn behind any running one.
   * `done` resolves when that turn ends.
   */
  async prompt(input: PromptInput, popts: PromptOptions = {}): Promise<{ messageId: string; done: Promise<TurnOutcome> }> {
    const conv = this.store.conversation(input.conversationId);
    if (!conv) throw new Error("conversation not found");
    const typed = typeof input.text === "string" ? input.text : "";
    // A relay turn is never the owner typing in the app, whoever passes it on.
    const untrusted = popts.untrusted || !!popts.relay;
    const mentioned = untrusted ? neutralizeMentions(typed) : typed;
    const config = this.configFor(conv);
    // The gateway's own commands (the bot's, compaction) still work; anything else would go to Claude Code's.
    const ownCommand = COMPACT_RE.test(mentioned) || !!parseCommand(mentioned, config);
    const text = (untrusted || config?.noTools) && !ownCommand ? neutralizeCommand(mentioned) : mentioned;
    if (popts.relay) this.checkRelayPrompt(conv, typed, input);
    // A turn of the app (unlocked) in a conversation the relay opened: from now on the relay token neither reads nor
    // prompts it, so what that full-access turn does never reaches the relay.
    else this.store.db.query("DELETE FROM relay_conversations WHERE conversation_id = ?").run(conv.id);
    const decoded = decodeAttachments(input.attachments);
    if (!text.trim() && decoded.length === 0) throw new Error("empty prompt");
    if (input.agent && !this.runtimes.get(input.agent)) throw new Error(`unknown agent ${input.agent}`);

    const attachments: Attachment[] = [];
    const forAgent: Attachment[] = [];
    const files: SavedFile[] = [];
    for (const a of decoded) {
      const url = `/api/media/${await this.media.saveBytes(a.mime, a.bytes, a.name)}`;
      if (a.kind === "image") {
        const saved: Attachment = { kind: "image", mime: a.mime, ...(a.name ? { name: a.name } : {}), size: a.bytes.length, url };
        attachments.push(saved);
        forAgent.push({ ...saved, dataBase64: a.dataBase64 });
      } else {
        const path = await saveWorkspaceFile(this.bots.attachmentsRoot(conv.botId), a.name, a.bytes);
        attachments.push({ kind: "file", mime: a.mime, name: basename(path), size: a.bytes.length, url });
        files.push({ path, mime: a.mime, size: a.bytes.length });
      }
    }
    const notes = filesNote(files) + folderNote(input.folder);
    const note = untrusted ? neutralizeMentions(notes) : notes;
    const first = this.store.messageCount(conv.id) === 0;
    await this.applyBrainChoice(conv, input, first);
    const messageId = newId();
    if (!popts.silent) {
      const message: Message = {
        id: messageId,
        conversationId: conv.id,
        role: "user",
        text,
        attachments,
        ...(popts.task ? { task: popts.task } : {}),
        ...(popts.wake ? { wake: popts.wake } : {}),
        createdAt: now(),
      };
      this.store.addMessage(message);
      // The app shows what it typed itself; a message nobody typed in it would only appear on the next reload.
      if (popts.wake) this.emit({ type: "message.user", conversationId: conv.id, botId: conv.botId, message });
      if (first && text.trim() && !popts.scheduled) this.store.updateConversation(conv.id, { title: truncate(text, TITLE_MAX) });
    }

    this.stopIdleCompaction(conv.id);
    const running = input.steer ? this.active.get(conv.id) : undefined;
    if (running?.session?.steer && !running.cancelled && (await running.session.steer(text + note, forAgent))) {
      return { messageId, done: Promise.resolve({ text: "", stopReason: "end_turn" }) };
    }

    const goal = !!input.goal && !untrusted;
    const relayEpoch = popts.relay ? this.relayEpoch(popts.relay.deviceId) : 0;
    // A new request in this conversation, through the relay or the app: the previous refusal is answered by it.
    this.relayRefused.delete(conv.id);
    if (popts.relay) this.relayPending.set(conv.id, { origin: popts.relay, n: (this.relayPending.get(conv.id)?.n ?? 0) + 1 });
    const prev = this.queues.get(conv.id) ?? Promise.resolve();
    let resolveDone!: (o: TurnOutcome) => void;
    const done = new Promise<TurnOutcome>((r) => (resolveDone = r));
    const next = prev
      .then(async () => {
        this.outcomes.delete(conv.id);
        if (popts.relay && this.relayEpoch(popts.relay.deviceId) !== relayEpoch) {
          this.outcomes.set(conv.id, { text: "", stopReason: "cancelled", error: "accès de relais révoqué" });
          return;
        }
        if (popts.scheduled) this.scheduled.add(conv.id);
        if (goal) this.goals.add(conv.id);
        if (popts.relay) {
          this.relayTurns.set(conv.id, popts.relay);
          this.relayFacts.set(conv.id, { createdEvents: new Set(), approvals: [] });
        }
        try {
          await this.turn(conv.id, text, forAgent, !!input.voice, note, popts.silent ? undefined : messageId);
        } finally {
          this.scheduled.delete(conv.id);
          this.goals.delete(conv.id);
          this.relayTurns.delete(conv.id);
          this.relayFacts.delete(conv.id);
        }
      })
      .catch((e) => {
        console.error(`[runner] ${conv.id}:`, e);
        this.outcomes.set(conv.id, { text: "", stopReason: "error", error: (e as Error)?.message ?? String(e) });
      })
      .finally(() => {
        if (popts.relay) {
          const pending = this.relayPending.get(conv.id);
          if (pending && --pending.n <= 0) this.relayPending.delete(conv.id);
        }
        const outcome = this.outcomes.get(conv.id) ?? { text: "", stopReason: "error" as const, error: "conversation introuvable" };
        this.outcomes.delete(conv.id);
        resolveDone(outcome);
      });
    this.queues.set(conv.id, next);
    next.finally(() => {
      if (this.queues.get(conv.id) === next) this.queues.delete(conv.id);
    });
    // Agents that cannot take a message mid-turn (Grok, Antigravity): stop the turn, the new one starts right after.
    if (running && !running.cancelled) await this.cancel(conv.id);
    return { messageId, done };
  }

  /**
   * The agent works again by itself (Claude once a background command finished): that work becomes an answer of its
   * own, queued like a message so it never overlaps a turn.
   */
  private unprompted(conversationId: string, live: Live, work: UnpromptedWork) {
    this.stopIdleCompaction(conversationId);
    const prev = this.queues.get(conversationId) ?? Promise.resolve();
    const next = prev
      .then(async () => {
        if (this.lives.get(conversationId) !== live) return void work.run(() => {}, async (ask) => rejectOption(ask.options));
        await this.run(conversationId, "", [], undefined, undefined, undefined, work);
      })
      .catch((e) => console.error(`[runner] ${conversationId} (follow-up):`, e));
    this.queues.set(conversationId, next);
    next.finally(() => {
      if (this.queues.get(conversationId) === next) this.queues.delete(conversationId);
    });
  }

  async cancel(conversationId: string) {
    const a = this.active.get(conversationId);
    if (!a) return;
    a.cancelled = true;
    a.abort?.();
    this.rejectPermissions(conversationId);
    await a.session?.cancel().catch((e) => console.warn(`[runner] cancel failed: ${e?.message ?? e}`));
  }

  /** A confirmation waiting for its answer: whose conversation, what it is about, the options, and whether a relay session asked it. */
  pendingPermission(requestId: string): { conversationId: string; title: string; options: PermissionOption[]; relay: boolean; tool?: string } | undefined {
    const p = this.permissions.get(requestId);
    return p ? { conversationId: p.conversationId, title: p.title, options: p.options, relay: p.relay, ...(p.tool ? { tool: p.tool } : {}) } : undefined;
  }

  /**
   * Where this conversation's relay work comes from, while its turn came through the relay or its session was started
   * for one (that session's unprompted work included); undefined otherwise.
   */
  relaySession(conversationId: string): RelayOrigin | undefined {
    return this.relayTurns.get(conversationId) ?? this.lives.get(conversationId)?.relay;
  }

  /** A tool was refused during this relay conversation's last request: it waits for the unlocked iPhone. */
  relayWaitsForUnlock(conversationId: string): boolean {
    return this.relayRefused.has(conversationId);
  }

  /**
   * A local call of the `nuo` server during a relay session, for a tool that needs a confirmation: true once per
   * yes given to that tool in the running relay turn.
   */
  takeRelayApproval(conversationId: string, tool: string): boolean {
    const facts = this.relayFacts.get(conversationId);
    const i = facts?.approvals.indexOf(tool) ?? -1;
    if (!facts || i < 0) return false;
    facts.approvals.splice(i, 1);
    return true;
  }

  /** The current relay turn's facts, for the tools allowed only on its own work. */
  relayTurnFacts(conversationId: string): { createdEvents: ReadonlySet<string> } {
    return this.relayFacts.get(conversationId) ?? { createdEvents: new Set() };
  }

  /** An event this relay turn created: it may move it. */
  relayCreatedEvent(conversationId: string, eventId: string) {
    this.relayFacts.get(conversationId)?.createdEvents.add(eventId);
  }

  /** A tool refused in a relay session: the request it belongs to waits for the unlock, and the refusal is audited. */
  relayRefusedTool(conversationId: string, tool: string) {
    const origin = this.relaySession(conversationId);
    if (!origin) return;
    this.relayRefused.add(origin.conversationId);
    this.onRelayRefused?.(origin, tool || "?", conversationId);
  }

  /** The device's relay access was revoked: its running relay turns stop, their sessions close, queued ones never start. */
  async cancelRelay(deviceId: string) {
    this.relayEpochs.set(deviceId, this.relayEpoch(deviceId) + 1);
    const ids = new Set<string>();
    for (const [id, origin] of this.relayTurns) if (origin.deviceId === deviceId) ids.add(id);
    for (const [id, live] of this.lives) if (live.relay?.deviceId === deviceId) ids.add(id);
    await Promise.all(
      [...ids].map(async (id) => {
        await this.cancel(id);
        const live = this.lives.get(id);
        if (live?.relay) {
          this.lives.delete(id);
          await live.session.close().catch(() => {});
        }
      }),
    );
  }

  private relayEpoch(deviceId: string): number {
    return this.relayEpochs.get(deviceId) ?? 0;
  }

  /** Refused before anything is written: a command in any disguise, or an agent the gateway cannot restrict. */
  private checkRelayPrompt(conv: StoredConversation, text: string, input: PromptInput) {
    if (isSlashCommand(text)) throw new RelayRefusedError("commands cannot go through the relay", 400);
    if (input.agent || input.model || input.effort || input.attachments?.length || input.folder) throw new RelayRefusedError("the relay sends text only", 400);
    const config = this.configFor(conv);
    if (config && (conv.agent ?? config.agent) !== "claude") {
      throw new RelayRefusedError(`${config.name} ne passe pas par l'accès de relais : à faire depuis l'iPhone déverrouillé`, 409);
    }
  }

  /**
   * With a `rule`, the card's tool is decided for good on its bot, and this call is answered once accordingly
   * (`optionId` aside): the agent's own « always » would only last its session.
   */
  answerPermission(requestId: string, optionId: string, rule?: ToolRule): boolean {
    const p = this.permissions.get(requestId);
    if (!p) return false;
    // A relay session was offered « once » answers only: an « always » from the app would leave no yes to count.
    if (p.relay && !p.options.some((o) => o.id === optionId)) return false;
    let chosen = optionId;
    if (rule) {
      if (p.relay || !p.remember?.rules.includes(rule)) return false;
      const answer = rule === "allow" ? allowOption(p.options) : rejectOption(p.options);
      if (!answer) return false;
      this.bots.setToolRule(p.remember.botId, p.remember.key, rule);
      chosen = answer;
    }
    this.permissions.delete(requestId);
    p.resolve(chosen);
    this.permissionSettled(p.conversationId, requestId);
    return true;
  }

  async closeConversation(conversationId: string) {
    this.stopIdleCompaction(conversationId);
    await this.cancel(conversationId);
    const live = this.lives.get(conversationId);
    this.lives.delete(conversationId);
    await live?.session.close().catch(() => {});
  }

  async closeBot(botId: string) {
    await Promise.all(this.store.conversations(botId).map((c) => this.closeConversation(c.id)));
  }

  /**
   * Notes what a stop is about to cut: turns running or waiting, and sessions whose background work (subagents,
   * shells) outlives their turn. Called for every profile before any of them stops: an agent that stops first ends its
   * turn as cancelled, and a turn no longer running would not be noted.
   */
  noteInterrupted() {
    this.cut ??= this.busy();
  }

  private busy(): Map<string, RelayOrigin | undefined> {
    const relayOf = (id: string) => this.relayTurns.get(id) ?? this.relayPending.get(id)?.origin ?? this.lives.get(id)?.relay;
    const background = [...this.lives].filter(([, live]) => live.session.awaitsBackground).map(([id]) => id);
    const ids = [...new Set([...this.active.keys(), ...this.queues.keys(), ...background])].filter((id) => !this.idleCompactions.has(id));
    return new Map(ids.map((id) => [id, relayOf(id)]));
  }

  /**
   * Turns still running or waiting are noted before their agents stop, so `resumeInterrupted` starts them again once
   * the gateway is back: a deploy or a crash-restart must not cut a long task.
   */
  async shutdown() {
    this.noteInterrupted();
    clearInterval(this.sweeper);
    // Turns cut below end after this point and would plan a compaction on a closed store.
    this.stopping = true;
    for (const timer of this.idleCompactTimers.values()) clearTimeout(timer);
    this.idleCompactTimers.clear();
    const cut = new Map(this.cut);
    for (const [id, origin] of this.busy()) if (!cut.has(id)) cut.set(id, origin);
    const relayCut = [...cut].flatMap(([conversationId, origin]) => (origin ? [{ conversationId, origin }] : []));
    const interrupted = [...cut].filter(([, origin]) => !origin).map(([id]) => id);
    if (interrupted.length) this.store.setMeta(INTERRUPTED_KEY, JSON.stringify(interrupted));
    if (relayCut.length) this.store.setMeta(INTERRUPTED_RELAY_KEY, JSON.stringify(relayCut));
    const settled = Promise.allSettled([...this.queues.values()]);
    await Promise.all([...this.lives.keys()].map((id) => this.closeConversation(id)));
    await Promise.race([settled, Bun.sleep(SHUTDOWN_SETTLE_MS)]);
    await this.mcp.closeAll();
  }

  /**
   * Starts again the turns the last shutdown cut; returns their conversations. A relay turn is not started again: it
   * would run as the app's, with the bot's own policy and tools. It waits for the unlocked iPhone instead.
   */
  resumeInterrupted(): string[] {
    this.closeInterruptedRelay();
    const raw = this.store.getMeta(INTERRUPTED_KEY);
    if (!raw) return [];
    this.store.setMeta(INTERRUPTED_KEY, "[]");
    let ids: unknown;
    try {
      ids = JSON.parse(raw);
    } catch {
      return [];
    }
    if (!Array.isArray(ids)) return [];
    const resumed = ids.filter((id): id is string => typeof id === "string" && !!this.store.conversation(id));
    for (const id of resumed) {
      this.recordNotice(id, { kind: "resumed", text: RESUMED_TEXT });
      void this.prompt({ conversationId: id, text: this.languageHint(this.configFor(this.store.conversation(id)!)) + RESUME_PROMPT }, { silent: true }).catch((e) => console.warn(`[runner] resume ${id}: ${(e as Error)?.message ?? e}`));
    }
    return resumed;
  }

  private closeInterruptedRelay() {
    const raw = this.store.getMeta(INTERRUPTED_RELAY_KEY);
    if (!raw) return;
    this.store.setMeta(INTERRUPTED_RELAY_KEY, "[]");
    let cut: unknown;
    try {
      cut = JSON.parse(raw);
    } catch {
      return;
    }
    if (!Array.isArray(cut)) return;
    for (const c of cut as { conversationId?: unknown; origin?: Partial<RelayOrigin> }[]) {
      const origin = c?.origin;
      if (typeof c?.conversationId !== "string" || typeof origin?.deviceId !== "string" || typeof origin.conversationId !== "string") continue;
      if (!this.store.conversation(c.conversationId)) continue;
      this.recordNotice(c.conversationId, { kind: "resumed", text: RELAY_INTERRUPTED_TEXT });
      this.relayRefused.add(origin.conversationId);
      this.onRelayRefused?.({ deviceId: origin.deviceId, conversationId: origin.conversationId }, "redémarrage", c.conversationId);
    }
  }

  private emit(e: ServerEvent) {
    if (e.type === "message.end" && this.scheduled.has(e.conversationId)) e = { ...e, scheduled: true };
    this.track(e);
    this.hub.broadcast(e);
  }

  /** Every turn event goes through here, so the snapshot always matches what a connected client received. */
  private track(e: ServerEvent) {
    if (e.type === "message.start") {
      this.turnStates.set(e.conversationId, {
        conversationId: e.conversationId,
        botId: e.botId ?? this.store.conversation(e.conversationId)?.botId ?? "",
        messageId: e.messageId,
        startedAt: Date.parse(e.at),
        phase: e.phase ?? "thinking",
        text: "",
        thoughts: "",
        steps: [],
        subagents: [],
      });
      return;
    }
    if (!("conversationId" in e) || !e.conversationId) return;
    const s = this.turnStates.get(e.conversationId);
    if (!s || ("messageId" in e && e.messageId !== s.messageId)) return;
    const running = () => s.steps.some((step) => step.status === "running");
    switch (e.type) {
      case "message.delta":
        s.text += e.text;
        if (!s.permission && !running()) s.phase = "answering";
        break;
      case "thought.delta":
        s.thoughts += e.text;
        if (s.phase === "queued") s.phase = "thinking";
        break;
      case "tool.start":
        if (!s.steps.some((step) => step.toolCallId === e.toolCallId)) s.steps.push({ toolCallId: e.toolCallId, title: e.title, ...(e.kind ? { kind: e.kind } : {}), status: "running" });
        if (!s.permission) s.phase = "working";
        break;
      case "tool.detail": {
        const step = s.steps.find((x) => x.toolCallId === e.toolCallId);
        if (step) step.detail = e.detail;
        break;
      }
      case "tool.end": {
        const step = s.steps.find((x) => x.toolCallId === e.toolCallId);
        if (step) Object.assign(step, { status: e.status, durationMs: e.durationMs });
        if (!s.permission && !running()) s.phase = "thinking";
        break;
      }
      case "permission.request":
        s.permission = { requestId: e.requestId, title: e.title, options: e.options, ...(e.tool ? { tool: e.tool, rules: e.rules } : {}) };
        s.phase = "waiting_permission";
        break;
      case "turn.phase":
        s.phase = e.phase;
        break;
      case "subagent": {
        const i = s.subagents.findIndex((x) => x.id === e.subagent.id);
        if (i >= 0) s.subagents[i] = e.subagent;
        else s.subagents.push(e.subagent);
        break;
      }
      case "message.end":
        this.turnStates.delete(e.conversationId);
        break;
    }
  }

  /** Emits message.start before anything slow (tool discovery, session spawn) so clients react at once. */
  private begin(conv: StoredConversation, phase: TurnPhase = "queued"): TurnStart {
    const startedAt = Date.now();
    const t: TurnStart = { messageId: newId(), startedAt, at: new Date(startedAt).toISOString() };
    this.emit({ type: "message.start", conversationId: conv.id, botId: conv.botId, messageId: t.messageId, role: "assistant", at: t.at, phase });
    return t;
  }

  private setPhase(conversationId: string, messageId: string, phase: TurnPhase) {
    const s = this.turnStates.get(conversationId);
    if (!s || s.messageId !== messageId || s.phase === phase) return;
    this.emit({ type: "turn.phase", conversationId, messageId, phase });
  }

  private permissionSettled(conversationId: string, requestId: string) {
    const s = this.turnStates.get(conversationId);
    if (!s || s.permission?.requestId !== requestId) return;
    s.permission = undefined;
    this.setPhase(conversationId, s.messageId, s.steps.some((step) => step.status === "running") ? "working" : "thinking");
  }

  /**
   * Persists the agent, model and effort picked in the chat. A model chosen for another agent does not carry over:
   * switching agent without a model takes that agent's default. A change after the first message leaves a
   * `switched` notice in the transcript, just before the message that triggered it.
   */
  private async applyBrainChoice(conv: StoredConversation, input: PromptInput, first: boolean) {
    const config = this.configFor(conv);
    const agentChanged = !!input.agent && input.agent !== (conv.agent ?? config?.agent);
    if (!agentChanged && !input.model && !input.effort) return;
    const before = config && !first ? await this.brain(conv, config) : undefined;
    this.store.updateConversation(conv.id, {
      agent: input.agent,
      model: input.model || (agentChanged ? null : undefined),
      effort: input.effort || (agentChanged ? null : undefined),
    });
    const updated = this.store.conversation(conv.id);
    if (!before || !updated || !config) return;
    const after = await this.brain(updated, config);
    if (after.agent === before.agent && after.model === before.model) return;
    this.recordNotice(conv.id, { kind: "switched", text: await this.switchText(after), agent: after.agent, ...(after.model ? { model: after.model } : {}) });
  }

  private async brain(conv: StoredConversation, config: BotConfig): Promise<Brain> {
    const agent = conv.agent ?? config.agent;
    if (conv.model) return { agent, model: conv.model };
    if (agent === config.agent) return { agent, model: config.model };
    const models = (await this.runtimes.get(agent)?.models().catch(() => [])) ?? [];
    return { agent, model: (models.find((m) => m.isDefault) ?? models[0])?.id ?? "" };
  }

  private async switchText(b: Brain): Promise<string> {
    const runtime = this.runtimes.get(b.agent);
    const models = (await runtime?.models().catch(() => [])) ?? [];
    const model = models.find((m) => m.id === b.model)?.name ?? b.model;
    return `Passage à ${[runtime?.name ?? b.agent, model].filter(Boolean).join(" · ")}`;
  }

  /** Resolves a slash command against the conversation's bot config, then runs the matching turn. */
  private async turn(conversationId: string, text: string, attachments: Attachment[], voice: boolean, note = "", userMessageId?: string) {
    const conv = this.store.conversation(conversationId);
    if (!conv) return;
    const start = this.begin(conv);
    try {
      await this.dispatchTurn(conv, start, text, attachments, voice, note, userMessageId);
    } catch (e) {
      if (this.turnStates.get(conv.id)?.messageId !== start.messageId) throw e;
      const message = (e as Error)?.message ?? String(e);
      this.emit({ type: "error", conversationId: conv.id, message });
      this.finish(conv, undefined, { ...start, text: "", steps: [], stopReason: "error" });
      this.outcomes.set(conv.id, { text: "", stopReason: "error", error: message });
    }
  }

  private async dispatchTurn(
    conv: StoredConversation,
    start: TurnStart,
    text: string,
    attachments: Attachment[],
    voice: boolean,
    note: string,
    userMessageId?: string,
  ) {
    const conversationId = conv.id;
    if (this.relayTurns.has(conversationId)) {
      // Taken word for word: no command, no compaction, no machine tool hint.
      return this.run(conversationId, RELAY_HINT + text, attachments, undefined, start, userMessageId);
    }
    const compact = COMPACT_RE.exec(text);
    if (compact) return void (await this.compact(conv, compact[1]?.trim() ?? "", start));
    const config = this.configFor(conv);
    const prefix = (voice ? VOICE_PREFIX : "") + (this.goals.has(conversationId) ? GOAL_PREFIX : "") + (this.scheduled.has(conversationId) ? this.languageHint(config) : "");
    const parsed = parseCommand(text, config);
    const action = parsed?.command.action;
    let pending: TurnStart | undefined = start;
    if (this.autoCompact && (!action || action.type === "prompt") && shouldAutoCompact(conv.context)) {
      // The compaction notice takes the message already announced; the answer gets its own.
      await this.compact(conv, "", start);
      pending = undefined;
    }
    if (!parsed || !action) {
      return this.run(conversationId, prefix + (await this.toolHintFor(text, config)) + text + note, attachments, undefined, pending, userMessageId);
    }
    switch (action.type) {
      case "prompt": {
        const expanded = expandTemplate(action.template, parsed.args);
        const hint = await this.toolHintFor(expanded, config);
        return this.run(conversationId, prefix + hint + expanded + note, attachments, { model: action.model, effort: action.effort }, pending, userMessageId);
      }
      case "tool":
        return this.runTool(conv, action, parsed.command.name, parsed.args, pending);
      default:
        return this.reply(conv, "Cette commande est gérée par l'app Nuo : choisis-la dans le menu / pour l'utiliser.", pending);
    }
  }

  /** The user's preferred language in English ("French"); undefined until an app has said it. */
  private userLanguage(): string | undefined {
    return languageName(this.store.userLanguages()[0]);
  }

  private languageHint(config: BotConfig | undefined): string {
    const language = config?.language ?? this.userLanguage();
    return language ? unattendedLanguageHint(language) : "";
  }

  /** The hint goes to the agent only; the persisted user message keeps the typed text. */
  private async toolHintFor(text: string, config: BotConfig | undefined): Promise<string> {
    if (!this.machine || !config || config.noTools || !text.includes("#")) return "";
    try {
      return toolHint(taggedTools(text, await this.machine.list()), config.permissionPolicy);
    } catch (e) {
      console.warn(`[runner] machine tools unavailable: ${(e as Error)?.message ?? e}`);
      return "";
    }
  }

  /** The bot's configuration; a relay session's own limits are set on the session (`ensureSession`), never here. */
  private configFor(conv: StoredConversation): BotConfig | undefined {
    const bot = this.store.bot(conv.botId);
    return conv.useDraft ? (bot?.draft ?? bot?.published?.config) : bot?.published?.config;
  }

  private async runTool(conv: StoredConversation, action: Extract<BotCommandAction, { type: "tool" }>, name: string, args: string, start?: TurnStart) {
    const conversationId = conv.id;
    const config = this.configFor(conv);
    const { messageId, startedAt, at } = start ?? this.begin(conv, "working");
    const step: ToolStep = { toolCallId: newId(), title: action.tool, status: "running" };
    this.emit({ type: "tool.start", conversationId, messageId, toolCallId: step.toolCallId, title: step.title });

    const controller = new AbortController();
    const turn: ActiveTurn = { cancelled: false, abort: () => controller.abort() };
    this.active.set(conversationId, turn);
    let text = "";
    let stopReason: Message["stopReason"] = "end_turn";
    try {
      if (!config) throw new Error("ce bot n'a pas de configuration publiée");
      const toolArgs = toolArguments(action.params, action.fixedArgs, args);
      let result: { content: ToolContent[]; isError?: boolean };
      if (action.server === BUILTIN_TOOL_SERVER) {
        if (!this.nuo) throw new Error("la passerelle n'a pas encore d'adresse locale");
        const tools = new NuoTools({ url: this.nuo.url, token: this.nuo.token, botId: conv.botId, conversationId, overview: config.overview }, Date.now, controller.signal);
        result = await tools.call(action.tool, toolArgs).then(
          (t) => ({ content: [{ type: "text", text: t }] }),
          (e) => ({ content: [{ type: "text", text: (e as Error)?.message ?? String(e) }], isError: true }),
        );
      } else {
        const spec = this.catalog.specs([action.server], this.mcpEnv(config), config.workdir)[0];
        if (!spec) throw new Error(`serveur d'outils « ${action.server} » introuvable`);
        result = await this.mcp.call(spec, action.tool, toolArgs, controller.signal);
      }
      text = await this.renderToolContent(result.content);
      if (!result.isError) text = cardsFromToolText(text);
      if (result.isError) {
        stopReason = "error";
        text = `La commande /${name} a échoué : ${text.trim() || "erreur inconnue"}`;
      }
    } catch (e) {
      if (turn.cancelled) {
        stopReason = "cancelled";
        text = "";
      } else {
        stopReason = "error";
        text = `Impossible d'exécuter /${name} : ${(e as Error)?.message ?? String(e)}`;
      }
    } finally {
      this.active.delete(conversationId);
    }

    step.status = stopReason === "end_turn" ? "completed" : "failed";
    step.durationMs = Date.now() - startedAt;
    this.emit({ type: "tool.end", conversationId, messageId, toolCallId: step.toolCallId, status: step.status, durationMs: step.durationMs });
    if (text) this.emit({ type: "message.delta", conversationId, messageId, text });
    this.finish(conv, config, { messageId, at, startedAt, text, steps: [step], stopReason });
  }

  /** Text parts are concatenated; images are stored as media and shown as ::image cards. */
  private async renderToolContent(content: ToolContent[]): Promise<string> {
    const parts: string[] = [];
    for (const c of content) {
      if (c.type === "text" && c.text) parts.push(c.text);
      else if (c.type === "image" && c.data && c.mimeType) {
        try {
          const id = await this.media.saveBase64(c.mimeType, c.data);
          parts.push(`::image ${JSON.stringify({ url: `/api/media/${id}` })}`);
        } catch (e) {
          parts.push(`(image non affichable : ${(e as Error).message})`);
        }
      }
    }
    return parts.join("\n");
  }

  /** A short assistant message that needs no agent nor tool. */
  private async reply(conv: StoredConversation, text: string, start?: TurnStart) {
    const { messageId, startedAt, at } = start ?? this.begin(conv, "answering");
    this.emit({ type: "message.delta", conversationId: conv.id, messageId, text });
    this.finish(conv, undefined, { messageId, at, startedAt, text, steps: [], stopReason: "end_turn" });
  }

  private finish(
    conv: StoredConversation,
    config: BotConfig | undefined,
    t: { messageId: string; at: string; startedAt: number; text: string; steps: ToolStep[]; stopReason: NonNullable<Message["stopReason"]> },
  ) {
    const durationMs = Date.now() - t.startedAt;
    if (this.store.conversation(conv.id)) {
      this.store.addMessage({
        id: t.messageId,
        conversationId: conv.id,
        role: "assistant",
        text: t.text,
        steps: t.steps,
        durationMs,
        stopReason: t.stopReason,
        createdAt: t.at,
      });
    }
    this.emit({ type: "message.end", conversationId: conv.id, messageId: t.messageId, durationMs, steps: t.steps.length, stopReason: t.stopReason });
    this.outcomes.set(conv.id, { messageId: t.messageId, text: t.text, stopReason: t.stopReason });
    if (t.stopReason !== "cancelled" && config) this.pushIfAway(conv, config, t.text, { messageId: t.messageId });
  }

  private mcpEnv(config: BotConfig): Record<string, string> {
    const env: Record<string, string> = { NUO_MEDIA_DIR: this.media.dir };
    if (config.workdir) env.NUO_WORKDIR = config.workdir;
    return env;
  }

  /** With `work`, the turn is the one the agent started by itself: nothing is sent, its events are taken. */
  private async run(
    conversationId: string,
    text: string,
    attachments: Attachment[],
    override?: ModelOverride,
    start?: TurnStart,
    userMessageId?: string,
    work?: UnpromptedWork,
  ) {
    const conv = this.store.conversation(conversationId);
    if (!conv) return;
    const bot = this.store.bot(conv.botId);
    const config = this.configFor(conv);
    const { messageId, startedAt, at } = start ?? this.begin(conv);
    const agent = config ? (conv.agent ?? config.agent) : undefined;
    let sessionId: string | undefined;
    let relaySession = false;
    let sent = text;
    let out = "";
    let thoughts = "";
    const steps: ToolStep[] = [];
    const stepStarts = new Map<string, number>();
    const detailPushed = new Set<string>();
    let usage: UsageReport | undefined;
    let compacted: Omit<CompactedNotice, "kind" | "text"> | undefined;
    let model: string | undefined;

    const subagents = new Map<string, SubagentInfo>();
    const subagentTimers = new Map<string, ReturnType<typeof setTimeout>>();
    const publishSubagent = (sa: SubagentInfo, soon = false) => {
      if (soon) {
        if (!subagentTimers.has(sa.id)) subagentTimers.set(sa.id, setTimeout(() => publishSubagent(sa), SUBAGENT_TEXT_THROTTLE_MS));
        return;
      }
      clearTimeout(subagentTimers.get(sa.id));
      subagentTimers.delete(sa.id);
      this.emit({ type: "subagent", conversationId, messageId, subagent: { ...sa, steps: sa.steps.map((x) => ({ ...x })) } });
    };
    const subagent = (id: string): SubagentInfo => {
      let sa = subagents.get(id);
      if (!sa) {
        sa = { id, title: "Sous-agent", state: "running", startedAt: now(), steps: [] };
        subagents.set(id, sa);
      }
      return sa;
    };

    let toolSinceText = false;
    const handle = (e: RunEvent) => {
      switch (e.type) {
        case "subagent": {
          const sa = subagent(e.id);
          if (e.title) sa.title = e.title;
          if (e.description && !sa.description) sa.description = truncate(e.description.trim(), SUBAGENT_DESCRIPTION_MAX);
          if (e.result) sa.text = tail(e.result, SUBAGENT_TEXT_MAX);
          if (e.state) {
            sa.state = e.state;
            if (e.state === "running" || e.state === "waiting") delete sa.endedAt;
            else sa.endedAt ??= now();
          }
          publishSubagent(sa);
          break;
        }
        case "subagent.tool": {
          const sa = subagent(e.id);
          let step = sa.steps.find((x) => x.toolCallId === e.toolCallId);
          if (!step) {
            if (sa.steps.length >= SUBAGENT_STEPS_MAX) sa.steps.shift();
            step = { toolCallId: e.toolCallId, title: e.title ?? "outil", status: "running" };
            sa.steps.push(step);
            stepStarts.set(`${e.id}:${e.toolCallId}`, Date.now());
          } else if (e.title) step.title = e.title;
          if (e.status !== "running" && step.status === "running") {
            step.status = e.status;
            step.durationMs = Date.now() - (stepStarts.get(`${e.id}:${e.toolCallId}`) ?? Date.now());
          }
          publishSubagent(sa);
          break;
        }
        case "subagent.text": {
          const sa = subagent(e.id);
          sa.text = tail((sa.text ?? "") + e.text, SUBAGENT_TEXT_MAX);
          publishSubagent(sa, true);
          break;
        }
        case "text": {
          // Text written before and after a tool call would otherwise run together in one paragraph.
          const text = toolSinceText && out && !out.endsWith("\n") ? "\n\n" + e.text : e.text;
          toolSinceText = false;
          out += text;
          this.emit({ type: "message.delta", conversationId, messageId, text });
          break;
        }
        case "thought":
          thoughts += e.text;
          this.emit({ type: "thought.delta", conversationId, messageId, text: e.text });
          break;
        case "tool.start":
          if (stepStarts.has(e.toolCallId)) break;
          stepStarts.set(e.toolCallId, Date.now());
          steps.push({ toolCallId: e.toolCallId, title: e.title, kind: e.kind, status: "running" });
          toolSinceText = true;
          this.emit({ type: "tool.start", conversationId, messageId, toolCallId: e.toolCallId, title: e.title, kind: e.kind });
          this.updateLiveActivities(conversationId, { phase: "working", steps: steps.length, currentTool: e.title, startedAt });
          break;
        case "tool.detail": {
          const step = steps.find((s) => s.toolCallId === e.toolCallId);
          if (!step) break;
          step.detail = e.detail;
          this.emit({ type: "tool.detail", conversationId, messageId, toolCallId: e.toolCallId, detail: e.detail });
          // It lands right after tool.start, inside the push throttle: once per tool, the lock screen still gets it.
          if (step.status === "running" && steps.at(-1) === step && !detailPushed.has(step.toolCallId)) {
            detailPushed.add(step.toolCallId);
            this.updateLiveActivities(conversationId, { phase: "working", steps: steps.length, currentTool: e.detail, startedAt }, true);
          }
          break;
        }
        case "tool.end": {
          const step = steps.find((s) => s.toolCallId === e.toolCallId);
          if (!step || step.status !== "running") break;
          step.status = e.status;
          step.durationMs = Date.now() - stepStarts.get(e.toolCallId)!;
          this.emit({ type: "tool.end", conversationId, messageId, toolCallId: e.toolCallId, status: e.status, durationMs: step.durationMs });
          break;
        }
        case "usage":
          usage = { usedTokens: e.usedTokens, maxTokens: e.maxTokens };
          break;
        case "compacted":
          compacted = { beforeTokens: e.beforeTokens, afterTokens: e.afterTokens };
          break;
      }
    };
    // Secret values never leave the gateway in what the bot writes, whatever it was asked.
    const mask = this.opts.mask;
    const textMask = mask?.stream();
    const thoughtMask = mask?.stream();
    const onEvent = (e: RunEvent) => {
      if (!mask) return handle(e);
      switch (e.type) {
        case "text": {
          const text = textMask!.push(e.text);
          return text ? handle({ ...e, text }) : undefined;
        }
        case "thought": {
          const text = thoughtMask!.push(e.text);
          return text ? handle({ ...e, text }) : undefined;
        }
        case "tool.start": {
          // The text written before the tool is still held back: released after it, the paragraph break would land mid-word.
          const held = textMask!.flush();
          if (held) handle({ type: "text", text: held });
          return handle({ ...e, title: mask.mask(e.title) });
        }
        case "subagent":
          return handle({
            ...e,
            ...(e.title ? { title: mask.mask(e.title) } : {}),
            ...(e.description ? { description: mask.mask(e.description) } : {}),
            ...(e.result ? { result: mask.mask(e.result) } : {}),
          });
        case "tool.detail":
          return handle({ ...e, detail: mask.mask(e.detail) });
        case "subagent.tool":
          return handle(e.title ? { ...e, title: mask.mask(e.title) } : e);
        case "subagent.text":
          return handle({ ...e, text: mask.mask(e.text) });
        default:
          return handle(e);
      }
    };
    const flushMasks = () => {
      const thought = thoughtMask?.flush();
      if (thought) handle({ type: "thought", text: thought });
      const text = textMask?.flush();
      if (text) handle({ type: "text", text });
    };

    let stopReason: Message["stopReason"] = "end_turn";
    let error: string | undefined;
    try {
      if (!bot || !config) throw new Error(conv.useDraft ? "this bot has no configuration" : "this bot has no published version");
      const turn: ActiveTurn = { cancelled: false };
      this.active.set(conversationId, turn);
      const live = work ? this.lives.get(conversationId) : await this.ensureSession(conv, bot.id, config, override);
      if (!live) throw new Error("the agent session is gone");
      if (turn.cancelled) throw new Error("cancelled");
      turn.session = live.session;
      model = live.model;
      live.lastUsed = Date.now();
      relaySession = !!live.relay;
      // A relay session gets no transcript of the conversation's other turns: they may be the app's, with full access.
      if (!work && !relaySession) sent = this.handoffFor(conversationId, agent!, live.session.agentSessionId, conv.agentId, userMessageId) + text;
      this.setPhase(conversationId, messageId, "thinking");
      const ask = (q: PermissionAsk) => this.askPermission(conversationId, q);
      const result = work ? await work.run(onEvent, ask) : await live.session.prompt(sent, attachments, onEvent, ask);
      live.lastUsed = Date.now();
      // Agents without a session protocol (agy) only learn their conversation id from the first prompt.
      const agentSessionId = live.session.agentSessionId;
      if (!relaySession && agentSessionId && agentSessionId !== this.store.conversation(conversationId)?.agentSessionId) {
        this.store.updateConversation(conversationId, { agentSessionId });
      }
      sessionId = agentSessionId;
      usage ??= result.usage;
      stopReason = this.active.get(conversationId)?.cancelled && result.stopReason !== "end_turn" ? "cancelled" : result.stopReason;
      error = result.error;
    } catch (e) {
      const cancelled = !!this.active.get(conversationId)?.cancelled;
      stopReason = cancelled ? "cancelled" : "error";
      error = (e as Error)?.message ?? String(e);
      const live = cancelled ? undefined : this.lives.get(conversationId);
      if (live) {
        this.lives.delete(conversationId);
        await live.session.close().catch(() => {});
      }
    } finally {
      this.active.delete(conversationId);
      this.rejectPermissions(conversationId);
    }
    if (stopReason === "end_turn" && !this.lives.get(conversationId)?.session.awaitsBackground) this.cut?.delete(conversationId);
    flushMasks();

    for (const s of steps) if (s.status === "running") s.status = "failed";
    for (const sa of subagents.values()) {
      if (sa.state === "running" || sa.state === "waiting") {
        sa.state = stopReason === "end_turn" ? "completed" : stopReason === "cancelled" ? "cancelled" : "failed";
        sa.endedAt = now();
      }
      for (const step of sa.steps) if (step.status === "running") step.status = sa.state === "completed" ? "completed" : "failed";
      publishSubagent(sa);
    }
    if (bot && out.includes("::artifact")) {
      const ws = this.bots.workspace(bot.id);
      const bases = [ws.botDir, ...(config?.workdir ? [config.workdir] : [])];
      out = await publishArtifacts(out, {
        bases,
        roots: [...bases, this.bots.attachmentsRoot(bot.id)],
        save: (mime, bytes, name) => this.media.saveBytes(mime, bytes, name),
      }).catch(() => out);
    }
    const durationMs = Date.now() - startedAt;
    const answeredBy = agent && model !== undefined ? { agent, ...(model ? { model } : {}) } : {};
    if (stopReason === "error") this.emit({ type: "error", conversationId, message: error || "the agent failed" });
    if (this.store.conversation(conversationId)) {
      this.store.addMessage({
        id: messageId,
        conversationId,
        role: "assistant",
        text: out,
        thoughts: thoughts || undefined,
        steps,
        ...(subagents.size ? { subagents: [...subagents.values()] } : {}),
        durationMs,
        stopReason,
        ...answeredBy,
        createdAt: at,
      });
      // A failed turn is handed over again next time: the agent may not have seen it.
      if (agent && sessionId && stopReason !== "error") this.store.setNativeSession(conversationId, relaySession ? relayNativeKey(agent) : agent, { sessionId, syncedTo: messageId });
    }
    if (config && (usage || stopReason === "end_turn")) {
      if (compacted) {
        // The agent compacted by itself during the turn (e.g. Claude Code's auto-compact).
        this.recordNotice(conversationId, { kind: "compacted", text: COMPACTED_TEXT, ...compacted });
      }
      this.recordContext(conversationId, config, model, usage, estimateTokens([sent, out, thoughts]), compacted ? 1 : 0);
    }
    this.emit({ type: "message.end", conversationId, messageId, durationMs, steps: steps.length, stopReason, ...answeredBy });
    this.outcomes.set(conversationId, { messageId, text: out, stopReason, ...(stopReason === "error" ? { error: error || "the agent failed" } : {}) });
    const body = stopReason === "error" ? `Erreur : ${error ?? ""}` : out;
    const handled = this.endLiveActivities(conversationId, messageId, config, stopReason, body, startedAt, steps.length);
    if (stopReason !== "cancelled" && config) this.pushIfAway(conv, config, body, { messageId, skip: handled });
    this.scheduleIdleCompaction(conversationId);
  }

  /**
   * Stores and broadcasts the context usage. Without a report from the agent, the previous value grows by
   * this turn's estimate (or the whole history since the last compaction is estimated).
   */
  private recordContext(
    conversationId: string,
    config: BotConfig,
    model: string | undefined,
    usage: UsageReport | undefined,
    turnEstimate: number,
    newCompactions = 0,
  ): ContextUsage | undefined {
    const conv = this.store.conversation(conversationId);
    if (!conv) return undefined;
    const prev = conv.context;
    const usedTokens =
      usage?.usedTokens ?? (prev ? prev.usedTokens + turnEstimate : estimateConversationTokens(config.instructions, messagesSinceCompaction(this.store.messages(conversationId))));
    const maxTokens = usage?.maxTokens ?? contextWindow(conv.agent ?? config.agent, model ?? conv.model ?? config.model, this.opts.codexHome) ?? prev?.maxTokens;
    const context: ContextUsage = {
      usedTokens,
      ...(maxTokens ? { maxTokens } : {}),
      compactions: (prev?.compactions ?? 0) + newCompactions,
      updatedAt: now(),
    };
    this.store.setContext(conversationId, context);
    this.emit({ type: "context", conversationId, context });
    return context;
  }

  private recordNotice(conversationId: string, notice: Notice, messageId: string = newId(), at = now(), durationMs?: number) {
    if (!this.store.conversation(conversationId)) return;
    this.store.addMessage({
      id: messageId,
      conversationId,
      role: "assistant",
      text: noticeLine(notice),
      durationMs,
      stopReason: "end_turn",
      createdAt: at,
    });
    this.emit({ type: "notice", conversationId, ...notice });
  }

  /**
   * Built-in /compact (and /compress): the agent's own command when it advertises one, otherwise a summary
   * asked in the current session that seeds a fresh one. Returns whether the context was compacted.
   */
  private async compact(conv: StoredConversation, args: string, start?: TurnStart): Promise<boolean> {
    const conversationId = conv.id;
    const bot = this.store.bot(conv.botId);
    const config = this.configFor(conv);
    const { messageId, startedAt, at } = start ?? this.begin(conv);

    if (!conv.agentSessionId && !this.lives.has(conversationId)) {
      const text = "Rien à compacter : la conversation n'a pas encore de contexte.";
      this.emit({ type: "message.delta", conversationId, messageId, text });
      this.finish(conv, undefined, { messageId, at, startedAt, text, steps: [], stopReason: "end_turn" });
      return false;
    }

    const turn: ActiveTurn = { cancelled: false };
    this.active.set(conversationId, turn);
    let result: CompactResult | undefined;
    let error: string | undefined;
    try {
      if (!bot || !config) throw new Error(conv.useDraft ? "ce bot n'a pas de configuration" : "ce bot n'a pas de version publiée");
      const live = await this.ensureSession(conv, bot.id, config);
      if (turn.cancelled) throw new Error("cancelled");
      turn.session = live.session;
      this.setPhase(conversationId, messageId, "thinking");
      result = await this.compactSession(conv, bot.id, config, live, args, turn);
    } catch (e) {
      error = turn.cancelled ? undefined : ((e as Error)?.message ?? String(e));
      const live = this.lives.get(conversationId);
      if (live && !turn.cancelled) {
        this.lives.delete(conversationId);
        await live.session.close().catch(() => {});
      }
    } finally {
      this.active.delete(conversationId);
      this.rejectPermissions(conversationId);
    }

    const durationMs = Date.now() - startedAt;
    if (!result || !config) {
      const stopReason = turn.cancelled ? "cancelled" : "error";
      const text = stopReason === "error" ? `La compaction a échoué : ${error ?? "erreur inconnue"}` : "";
      if (stopReason === "error") this.emit({ type: "error", conversationId, message: text });
      if (text) this.emit({ type: "message.delta", conversationId, messageId, text });
      this.finish(conv, undefined, { messageId, at, startedAt, text, steps: [], stopReason });
      return false;
    }

    this.recordCompaction(conv, config, result, messageId, at, durationMs);
    this.emit({ type: "message.end", conversationId, messageId, durationMs, steps: 0, stopReason: "end_turn" });
    this.outcomes.set(conversationId, { text: COMPACTED_TEXT, stopReason: "end_turn" });
    return true;
  }

  private async compactSession(conv: StoredConversation, botId: string, config: BotConfig, live: Live, args: string, turn: ActiveTurn): Promise<CompactResult> {
    const native = NATIVE_COMPACT.find((c) => live.session.commands?.includes(c));
    const result: CompactResult = native ? await this.nativeCompact(live, native, args) : await this.summaryCompact(conv, botId, config, live, turn);
    result.model = this.lives.get(conv.id)?.model ?? live.model;
    return result;
  }

  private recordCompaction(conv: StoredConversation, config: BotConfig, result: CompactResult, messageId: string, at: string, durationMs: number) {
    const before = result.before ?? conv.context?.usedTokens;
    const notice: CompactedNotice = {
      kind: "compacted",
      text: COMPACTED_TEXT,
      ...(before !== undefined ? { beforeTokens: before } : {}),
      ...(result.after !== undefined ? { afterTokens: result.after } : {}),
    };
    this.recordNotice(conv.id, notice, messageId, at, durationMs);
    const compacted = this.lives.get(conv.id);
    const compactedAgent = conv.agent ?? config.agent;
    if (compacted?.session.agentSessionId) {
      this.store.setNativeSession(conv.id, compacted.relay ? relayNativeKey(compactedAgent) : compactedAgent, { sessionId: compacted.session.agentSessionId, syncedTo: messageId });
    }
    const usage: UsageReport = { usedTokens: result.after ?? estimateTokens([config.instructions]), maxTokens: result.maxTokens };
    this.recordContext(conv.id, config, result.model, usage, 0, 1);
  }

  private scheduleIdleCompaction(conversationId: string) {
    this.stopIdleCompaction(conversationId);
    const o = this.opts.idleCompact ?? IDLE_COMPACT;
    if (this.stopping || !this.autoCompact || (this.store.conversation(conversationId)?.context?.usedTokens ?? 0) <= o.minTokens) return;
    const timer = setTimeout(() => this.compactIdle(conversationId), o.afterMs);
    timer.unref?.();
    this.idleCompactTimers.set(conversationId, timer);
  }

  /** A new message drops the planned compaction, or stops the running one so the answer does not wait for it. */
  private stopIdleCompaction(conversationId: string) {
    clearTimeout(this.idleCompactTimers.get(conversationId));
    this.idleCompactTimers.delete(conversationId);
    if (this.idleCompactions.delete(conversationId)) void this.cancel(conversationId);
  }

  /**
   * The compaction of `compact`, without a turn: no message.start/end, push or Live Activity, nothing said when it
   * fails. It holds the conversation's queue, so a message sent meanwhile waits for it to stop.
   */
  private compactIdle(conversationId: string) {
    this.idleCompactTimers.delete(conversationId);
    const conv = this.store.conversation(conversationId);
    const live = this.lives.get(conversationId);
    const bot = conv ? this.store.bot(conv.botId) : undefined;
    const config = conv ? this.configFor(conv) : undefined;
    if (!conv || !live || !bot || !config || this.active.has(conversationId) || this.queues.has(conversationId) || live.session.awaitsBackground) return;
    // A summary compaction replaces the session: one cut short by a new message would leave it with no history.
    if (!NATIVE_COMPACT.some((c) => live.session.commands?.includes(c))) return;
    const turn: ActiveTurn = { cancelled: false, session: live.session };
    this.active.set(conversationId, turn);
    this.idleCompactions.set(conversationId, turn);
    const at = now();
    const startedAt = Date.now();
    const next = this.compactSession(conv, bot.id, config, live, "", turn)
      .then((result) => {
        if (!turn.cancelled) this.recordCompaction(conv, config, result, newId(), at, Date.now() - startedAt);
      })
      .catch(async (e) => {
        if (turn.cancelled) return;
        console.warn(`[runner] ${conversationId}: background compaction failed: ${(e as Error)?.message ?? e}`);
        const current = this.lives.get(conversationId);
        if (!current) return;
        this.lives.delete(conversationId);
        await current.session.close().catch(() => {});
      })
      .finally(() => {
        if (this.active.get(conversationId) === turn) this.active.delete(conversationId);
        if (this.idleCompactions.get(conversationId) === turn) this.idleCompactions.delete(conversationId);
        this.rejectPermissions(conversationId);
      });
    this.queues.set(conversationId, next);
    next.finally(() => {
      if (this.queues.get(conversationId) === next) this.queues.delete(conversationId);
    });
  }

  private async nativeCompact(live: Live, command: string, args: string) {
    let usage: UsageReport | undefined;
    let reported: { beforeTokens?: number; afterTokens?: number } | undefined;
    const result = await live.session.prompt(
      `/${command}${args ? ` ${args}` : ""}`,
      [],
      (e) => {
        if (e.type === "usage") usage = e;
        else if (e.type === "compacted") reported = e;
      },
      async (ask) => rejectOption(ask.options),
    );
    live.lastUsed = Date.now();
    if (result.stopReason !== "end_turn") throw new Error(result.error ?? "compaction interrompue");
    // Grok reports nothing after /compact: the next turn's usage corrects the estimate.
    return { before: reported?.beforeTokens, after: reported?.afterTokens ?? usage?.usedTokens, maxTokens: usage?.maxTokens };
  }

  private async summaryCompact(conv: StoredConversation, botId: string, config: BotConfig, live: Live, turn: ActiveTurn) {
    let summary = "";
    const asked = await live.session.prompt(
      SUMMARY_PROMPT,
      [],
      (e) => {
        if (e.type === "text") summary += e.text;
      },
      async (ask) => rejectOption(ask.options),
    );
    if (asked.stopReason !== "end_turn") throw new Error(asked.error ?? "résumé interrompu");
    summary = summary.trim();
    if (!summary) throw new Error("l'agent n'a pas produit de résumé");
    if (turn.cancelled) throw new Error("cancelled");

    this.lives.delete(conv.id);
    await live.session.close().catch(() => {});
    this.store.clearAgentSession(conv.id, conv.agent ?? config.agent);
    const fresh = await this.ensureSession(this.store.conversation(conv.id) ?? conv, botId, config);
    turn.session = fresh.session;
    let usage: UsageReport | undefined;
    const seeded = await fresh.session.prompt(
      SEED_PREFIX + summary,
      [],
      (e) => {
        if (e.type === "usage") usage = e;
      },
      async (ask) => rejectOption(ask.options),
    );
    fresh.lastUsed = Date.now();
    if (seeded.stopReason !== "end_turn") throw new Error(seeded.error ?? "nouvelle session interrompue");
    usage ??= seeded.usage;
    return { after: usage?.usedTokens ?? estimateTokens([config.instructions, SEED_PREFIX, summary]), maxTokens: usage?.maxTokens };
  }

  private updateLiveActivities(conversationId: string, state: LiveActivityState, force = false) {
    const list = this.liveActivities.get(conversationId);
    if (!list) return;
    const t = Date.now();
    for (const a of list) {
      // While its socket is up, the app drives the activity itself.
      if ((!force && t - a.lastPushAt < LIVE_ACTIVITY_THROTTLE_MS) || this.hub.connected(a.deviceId)) continue;
      a.lastPushAt = t;
      void this.pusher.sendLiveActivity(a, { event: "update", contentState: activityContentState(state) });
    }
  }

  /**
   * Ends the Live Activities of the turn with an alert, so the lock screen and the Dynamic Island say the
   * answer arrived. Returns the devices that get it, which then need no regular push.
   */
  private endLiveActivities(
    conversationId: string,
    messageId: string,
    config: BotConfig | undefined,
    stopReason: Message["stopReason"],
    text: string,
    startedAt: number,
    steps: number,
  ): Set<string> {
    const list = this.liveActivities.get(conversationId);
    this.liveActivities.delete(conversationId);
    const handled = new Set<string>();
    if (!list?.length) return handled;
    const phase = stopReason === "end_turn" ? "done" : stopReason === "cancelled" ? "cancelled" : "failed";
    const answer = preview(text, 160) || undefined;
    const contentState = activityContentState({ phase, steps, answer, startedAt, endedAt: Date.now() });
    const alert =
      stopReason === "cancelled" || !config || this.scheduled.has(conversationId) || this.hub.anyActive()
        ? undefined
        : { title: `${config.emoji} ${config.name}`.trim(), body: preview(text, 120) || "Nouvelle réponse" };
    const dismissalDate = Math.floor(Date.now() / 1000) + LIVE_ACTIVITY_DISMISS_S;
    for (const a of list) {
      handled.add(a.deviceId);
      if (this.hub.connected(a.deviceId)) continue;
      void this.pusher.sendLiveActivity(a, { event: "end", contentState, alert, dismissalDate }).then((ok) => {
        if (ok || !alert) return;
        const conv = this.store.conversation(conversationId);
        if (conv && config) this.pushIfAway(conv, config, text, { messageId, only: a.deviceId });
      });
    }
    return handled;
  }

  private pushIfAway(conv: StoredConversation, config: BotConfig, text: string, o: { messageId?: string; skip?: Set<string>; only?: string } = {}) {
    if (this.scheduled.has(conv.id) || this.hub.anyActive()) return;
    const body = preview(text, 120) || "Nouvelle réponse";
    for (const d of this.store.devices()) {
      if (o.only ? d.id !== o.only : o.skip?.has(d.id)) continue;
      if (!d.apnsToken || this.hub.connected(d.id)) continue;
      void this.pusher.send(d, {
        title: `${config.emoji} ${config.name}`.trim(),
        body,
        botId: conv.botId,
        conversationId: conv.id,
        messageId: o.messageId,
        destination: { kind: "conversation", id: conv.id, botId: conv.botId },
      });
    }
  }

  /** The built-in server bots use to manage their scheduled tasks; it calls back the gateway with the local token, read from its file. */
  private nuoSpec(conv: StoredConversation, config: BotConfig, relay = false): McpServerSpec[] {
    if (!this.nuo || !this.nuoEnvFile) return [];
    const env: Record<string, string> = {
      NUO_ENV_FILE: this.nuoEnvFile,
      NUO_BOT_ID: conv.botId,
      NUO_CONVERSATION_ID: conv.id,
      ...(config.overview ? { NUO_OVERVIEW: "1" } : {}),
      ...(relay ? { NUO_RELAY: "1" } : {}),
    };
    for (const k of ["HOME", "LANG", "TZ"]) if (process.env[k]) env[k] = process.env[k]!;
    const custom = this.opts.nuoMcp;
    if (custom?.home) env.HOME = custom.home;
    return [{ name: "nuo", command: custom?.command ?? process.execPath, args: custom?.args ?? ["run", NUO_MCP_SERVER], env }];
  }

  private browserSpec(config: BotConfig): McpServerSpec[] {
    const spec = this.opts.browserMcp;
    return spec && !config.toolServers.includes(spec.name) ? [spec] : [];
  }

  /** A command's model override applies to this turn only: the next turn's call switches the model back. */
  private async ensureSession(conv: StoredConversation, botId: string, config: BotConfig, override?: ModelOverride): Promise<Live> {
    const agent = conv.agent ?? config.agent;
    const relay = this.relayTurns.get(conv.id);
    // Only Claude's tools can be narrowed to the whitelist: another agent never runs a relay turn.
    if (relay && agent !== "claude") throw new Error(`${config.name} ne passe pas par l'accès de relais : à faire depuis l'iPhone déverrouillé`);
    const model = override?.model || (await this.brain(conv, config)).model;
    const effort = override?.effort || conv.effort || (agent === config.agent ? config.effort : undefined);
    const key = JSON.stringify([agent, config.instructions, config.toolServers, config.workdir, config.permissionPolicy, !!config.noTools, !!relay]);
    const existing = this.lives.get(conv.id);
    if (existing && existing.key === key) {
      if (existing.model !== model || existing.effort !== effort) {
        await existing.session.setModel(model, effort);
        existing.model = model;
        existing.effort = effort;
      }
      return existing;
    }
    if (existing) {
      this.lives.delete(conv.id);
      await existing.session.close().catch(() => {});
    }
    await this.evictFor(conv.id);

    const runtime = this.runtimes.get(agent);
    if (!runtime) throw new Error(`agent ${agent} is not available`);
    if (config.noTools && !runtime.toolless) throw new Error(`ce bot n'a aucun outil : ${runtime.name} ne peut pas lui répondre, seul Claude le peut`);
    const ws = this.bots.workspace(botId);
    // A relay session works in its own folder, with instructions that leave out the memory and the database schema;
    // the bot's shared CLAUDE.md is neither read nor rewritten for it.
    const userLanguage = this.userLanguage();
    if (!relay) await prepareWorkspace(ws, config, this.bots.readMemory(botId).content, userLanguage);
    const extraEnv = this.mcpEnv(config);
    // A relay session gets the `nuo` server alone (its add tools), and asks for each of them, whatever the policy.
    const servers = config.noTools
      ? []
      : relay
        ? this.nuoSpec(conv, config, true)
        : [...this.catalog.specs(config.toolServers, extraEnv, config.workdir).filter((sp) => sp.name !== "nuo"), ...this.nuoSpec(conv, config), ...this.browserSpec(config)];
    const opts: SessionOptions = {
      workdir: relay ? this.bots.relayDir(botId) : ws.botDir,
      model,
      effort,
      mcpServers: servers.map((sp) => this.agentEnv.seal(sp)),
      permissionPolicy: relay ? "ask" : config.permissionPolicy,
      ...(relay
        ? { relay: true, instructions: relayInstructions(config, userLanguage), onRelayRefusal: (tool: string) => this.relayRefusedTool(conv.id, tool) }
        : { toolRule: (tool: RelayToolCall) => this.toolRule(conv.id, tool) }),
      ...(config.noTools ? { noTools: true } : {}),
      ...(config.language || userLanguage ? { language: config.language ?? userLanguage } : {}),
      // Conversations from before per-agent sessions only have the last agent's session.
      resumeId: relay ? conv.agentSessions?.[relayNativeKey(agent)]?.sessionId : (conv.agentSessions?.[agent]?.sessionId ?? (conv.agentId === agent ? conv.agentSessionId : undefined)),
      ...(ws.shared ? { attachmentsDir: join(this.bots.attachmentsRoot(botId), ".nuo", "attachments") } : {}),
    };
    let session: AgentSession;
    try {
      session = await runtime.start(opts);
    } catch (e) {
      if (!opts.resumeId) throw e;
      console.warn(`[runner] resume failed for ${conv.id}, starting fresh: ${(e as Error)?.message ?? e}`);
      session = await runtime.start({ ...opts, resumeId: undefined });
    }
    const native = relay ? relayNativeKey(agent) : agent;
    if (!relay) this.store.updateConversation(conv.id, { agentId: agent, agentSessionId: session.agentSessionId });
    if (session.agentSessionId && conv.agentSessions?.[native]?.sessionId !== session.agentSessionId) {
      this.store.setNativeSession(conv.id, native, { sessionId: session.agentSessionId });
    }
    const live: Live = { session, key, model, effort, lastUsed: Date.now(), ...(relay ? { relay } : {}) };
    session.onUnprompted = (work) => this.unprompted(conv.id, live, work);
    this.lives.set(conv.id, live);
    return live;
  }

  /**
   * Native sessions do not move between agents: when another agent answered turns this agent's session has not
   * seen, they are prepended to the prompt as a bounded transcript. A resumed session gets only those turns; a
   * fresh one (first use of this agent, or its resume failed) gets the whole history up to `beforeMessageId`.
   * `previousAgent` stands for the answers persisted before messages recorded their agent.
   */
  private handoffFor(conversationId: string, agent: AgentId, sessionId: string, previousAgent: string | undefined, beforeMessageId?: string): string {
    const conv = this.store.conversation(conversationId);
    if (!conv) return "";
    const messages = this.store.messages(conversationId);
    const end = beforeMessageId ? messages.findIndex((m) => m.id === beforeMessageId) : -1;
    const history = end >= 0 ? messages.slice(0, end) : messages;
    const native = conv.agentSessions?.[agent];
    const syncedTo = native && native.sessionId === sessionId ? native.syncedTo : undefined;
    const from = syncedTo ? history.findIndex((m) => m.id === syncedTo) + 1 : 0;
    const unseen = history.slice(from);
    const fallback = previousAgent ?? agent;
    // Relay turns are Claude's too, but in a session of their own this one never saw (the request the unlock replays).
    const relayTurns = !!conv.agentSessions?.[relayNativeKey(agent)];
    if (!relayTurns && !unseen.some((m) => m.role === "assistant" && !isNotice(m) && (m.agent ?? fallback) !== agent)) return "";
    return handoffTranscript(unseen, from > 0);
  }

  private async evictFor(conversationId: string) {
    while (this.lives.size >= this.opts.maxSessions) {
      const idle = [...this.lives.entries()]
        .filter(([id, live]) => id !== conversationId && !this.active.has(id) && !this.queues.has(id) && !live.session.awaitsBackground)
        .sort((a, b) => a[1].lastUsed - b[1].lastUsed)[0];
      const victim =
        idle ?? [...this.lives.entries()].filter(([id]) => !this.active.has(id)).sort((a, b) => a[1].lastUsed - b[1].lastUsed)[0];
      if (!victim) return;
      this.lives.delete(victim[0]);
      await victim[1].session.close().catch(() => {});
    }
  }

  private closeIdle() {
    const cutoff = Date.now() - this.opts.idleMs;
    for (const [id, live] of this.lives) {
      if (live.lastUsed < cutoff && !this.active.has(id) && !live.session.awaitsBackground) {
        this.lives.delete(id);
        void live.session.close().catch(() => {});
      }
    }
  }

  /**
   * During a goal turn, what the user confirms before a `nuo` tool acts on other people or loses data
   * (src/runner/goal.ts); true at once outside a goal turn or for any other call. A push reaches the user away.
   */
  async confirmGoalAction(conversationId: string, name: string, input: Record<string, unknown>, draft?: () => Promise<string | undefined>): Promise<boolean> {
    if (!this.goals.has(conversationId) || this.relaySession(conversationId)) return true;
    const title = goalConfirmation(name, input, name === "gmail_send" ? await draft?.().catch(() => undefined) : undefined);
    if (!title) return true;
    const options: PermissionOption[] = [
      { id: "allow", name: "Autoriser", kind: "allow_once" },
      { id: "reject", name: "Refuser", kind: "reject_once" },
    ];
    const conv = this.store.conversation(conversationId);
    const config = conv ? this.configFor(conv) : undefined;
    if (conv && config) this.pushIfAway(conv, config, `Confirmation demandée : ${title}`);
    return (await this.waitForAnswer(conversationId, title, options, GOAL_CONFIRMATION_TIMEOUT_MS)) === "allow";
  }

  /**
   * The rule the user kept for this call's tool on the conversation's bot; none in a relay session, which keeps its
   * whitelist, nor for a tool the agent did not name.
   */
  private toolRule(conversationId: string, tool: RelayToolCall | undefined): ToolRule | undefined {
    if (!tool || this.relaySession(conversationId)) return undefined;
    const conv = this.store.conversation(conversationId);
    return ruleFor(conv ? this.configFor(conv)?.toolRules : undefined, tool);
  }

  private askPermission(conversationId: string, ask: PermissionAsk): Promise<string> {
    const relay = this.relaySession(conversationId);
    // The sessions decide by the rules before asking; checked here too for a runtime that asks without them.
    const rule = this.toolRule(conversationId, ask.tool);
    if (rule === "block") return Promise.resolve(rejectOption(ask.options));
    const allowed = rule === "allow" ? allowOption(ask.options) : undefined;
    if (allowed) return Promise.resolve(allowed);
    if (!relay && this.goals.has(conversationId)) {
      // What needs the user is confirmed where it runs (confirmGoalAction), whatever the agent asks here.
      const yes = ask.options.find((o) => o.kind === "allow_once") ?? ask.options.find((o) => o.kind === "allow_always");
      if (yes) return Promise.resolve(yes.id);
    }
    if (relay) {
      // Off the whitelist: refused at once, nobody is asked; the request waits for the unlocked iPhone.
      if (relayRefusal(ask.tool ?? { name: "" }, this.relayTurnFacts(conversationId))) {
        this.relayRefusedTool(conversationId, ask.tool?.name ?? ask.title);
        return Promise.resolve(rejectOption(ask.options));
      }
    }
    const tool: RelayToolCall | undefined = relay ? ask.tool : undefined;
    // In a relay session the yes is given for what the call adds, said in words, and counts once: no « always ».
    const title = tool ? relayConfirmationTitle(tool) : ask.title;
    const options = relay ? ask.options.filter((o) => o.kind === "allow_once" || o.kind === "reject_once") : ask.options;
    if (relay && relay.conversationId !== conversationId) this.pushDelegatedConfirmation(conversationId, relay, title);
    const key = !relay && ask.tool ? toolRuleKey(ask.tool) : undefined;
    const botId = this.store.conversation(conversationId)?.botId;
    return this.waitForAnswer(conversationId, title, options, this.opts.permissionTimeoutMs, {
      relay: !!relay,
      tool: tool?.name,
      ...(key && botId && ask.tool ? { remember: { botId, key, rules: offeredRules(ask.tool) } } : {}),
      // The gateway lets that tool's call through once (`takeRelayApproval`).
      onAllowOnce: tool ? () => this.relayFacts.get(conversationId)?.approvals.push(tool.name) : undefined,
    });
  }

  /** Shows a permission card and resolves with the chosen option; a reject when nobody answers in time. */
  private waitForAnswer(
    conversationId: string,
    title: string,
    options: PermissionOption[],
    timeoutMs: number,
    o: { relay?: boolean; tool?: string; remember?: PendingPermission["remember"]; onAllowOnce?: () => void } = {},
  ): Promise<string> {
    const requestId = newId();
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        if (!this.permissions.delete(requestId)) return;
        resolve(rejectOption(options));
        this.permissionSettled(conversationId, requestId);
      }, timeoutMs);
      this.permissions.set(requestId, {
        conversationId,
        title,
        options,
        relay: !!o.relay,
        ...(o.tool ? { tool: o.tool } : {}),
        ...(o.remember ? { remember: o.remember } : {}),
        resolve: (id) => {
          clearTimeout(timer);
          if (options.find((x) => x.id === id)?.kind === "allow_once") o.onAllowOnce?.();
          resolve(id);
        },
      });
      const remember = o.remember ? { tool: o.remember.key, rules: o.remember.rules } : {};
      this.emit({ type: "permission.request", conversationId, requestId, title, options, ...remember });
    });
  }

  /**
   * A bot another one asked during a relay turn waits for a confirmation the relay cannot give (it answers only in its
   * own conversation): the iPhone, and the watch through it, are told who waits.
   */
  private pushDelegatedConfirmation(conversationId: string, relay: RelayOrigin, what: string) {
    const conv = this.store.conversation(conversationId);
    const config = conv ? this.configFor(conv) : undefined;
    const device = this.store.devices().find((d) => d.id === relay.deviceId);
    if (!conv || !config || !device) return;
    void this.pusher.send(device, {
      title: `${config.emoji} ${config.name} attend ta confirmation`.trim(),
      body: preview(what, 120) || "Une action attend ton accord dans Nuo.",
      botId: conv.botId,
      conversationId: conv.id,
      destination: { kind: "conversation", id: conv.id, botId: conv.botId },
    });
  }

  private rejectPermissions(conversationId: string) {
    for (const [id, p] of this.permissions) {
      if (p.conversationId !== conversationId) continue;
      this.permissions.delete(id);
      p.resolve(rejectOption(p.options));
      this.permissionSettled(conversationId, id);
    }
  }
}

function currentTool(s: TurnState): string | undefined {
  return s.steps.findLast((step) => step.status === "running")?.title;
}

function messagesSinceCompaction(messages: Message[]): Message[] {
  for (let i = messages.length - 1; i >= 0; i--) {
    if (messages[i]!.role === "assistant" && messages[i]!.text.startsWith(NOTICE_PREFIX)) return messages.slice(i + 1);
  }
  return messages;
}

function rejectOption(options: PermissionOption[]): string {
  return (options.find((o) => o.kind === "reject_once") ?? options.find((o) => o.kind === "reject_always"))?.id ?? "reject";
}

function allowOption(options: PermissionOption[]): string | undefined {
  return (options.find((o) => o.kind === "allow_once") ?? options.find((o) => o.kind === "allow_always"))?.id;
}

function truncate(text: string, max: number): string {
  const t = text.replace(/\s+/g, " ").trim();
  return t.length > max ? `${head(t, max - 1).trimEnd()}…` : t;
}
