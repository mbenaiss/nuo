import type { PushDestination } from "./push/apns";

export type AgentId = "claude" | "codex" | "grok" | "gemini";

export interface ModelInfo {
  id: string;
  name: string;
  isDefault?: boolean;
  efforts?: string[];
}

export interface AgentInfo {
  id: AgentId;
  name: string;
  available: boolean;
  authenticated: boolean;
  models: ModelInfo[];
  note?: string;
}

export interface ToolServer {
  id: string;
  name: string;
  description: string;
  tools: string[];
}

/** Something installed on the gateway machine that a bot can use: a CLI, an MCP server or a skill. */
export interface MachineTool {
  id: string; // tag used after "#", [a-z0-9_-]+
  name: string;
  kind: "cli" | "mcp" | "skill";
  description: string; // French, one line
  version?: string;
  usage?: string; // short hint given to the agent when the tool is tagged
  needsShell: boolean; // only bots with permissionPolicy "auto" can run it
  available: boolean;
}

export type PermissionPolicy = "ask" | "auto" | "readonly";

/**
 * A slash command of a bot. The app lists them when the user types "/".
 * - tool: the gateway calls the MCP tool directly, without the agent (instant, free).
 * - prompt: the gateway sends `template` to the agent instead of the typed text.
 * - open / app: handled by the app only (open a URL, or a native action).
 */
export type BotCommandAction =
  | { type: "tool"; server: string; tool: string; params?: string[]; fixedArgs?: Record<string, unknown> }
  | { type: "prompt"; template: string; model?: string; effort?: string }
  | { type: "open"; url: string }
  | { type: "app"; action: "new_conversation" | "barcode" | "voice" };

export interface BotCommand {
  name: string; // without the slash, [a-z0-9_]+
  description: string;
  args?: string; // usage hint, e.g. "<vol> [jj/mm]"
  action: BotCommandAction;
}

export interface BotConfig {
  name: string;
  emoji: string;
  color: string; // hex, e.g. "#E0EEFF"
  description: string;
  agent: AgentId;
  model: string;
  effort?: string;
  instructions: string;
  toolServers: string[]; // ToolServer ids
  workdir?: string; // absolute path on dev; defaults to the bot's own folder
  permissionPolicy: PermissionPolicy;
  voice?: { voiceId?: string };
  commands?: BotCommand[];
  /** Once published, the gateway keeps a daily 9:00 (Paris) "Propositions du jour" task for the bot (`createdBy: "gateway"`). */
  proactive?: boolean;
  /** The bot sees every bot and conversation of the profile: it can list them, search and read them, and ask another bot. */
  overview?: boolean;
  /**
   * No tool at all, whatever `permissionPolicy` says: no MCP server (not even nuo), no built-in tool, no file read,
   * no file attached by an `@path` mention. For a bot that reads other people's words (the meeting notes).
   */
  noTools?: boolean;
  /** The language the bot writes everything in, as a person would name it ("English"); French when absent. */
  language?: string;
  /**
   * What the user decided for good about a tool, from a permission card or the bot's settings, keyed by
   * `server/name` for an MCP tool (`nuo/gmail_search`) or the bare name of a built-in one (`Bash`). Changed in
   * place (`DELETE /api/bots/:id/tool-rules/:key`, the `rule` of a permission answer), never by a saved draft.
   */
  toolRules?: Record<string, ToolRule>;
}

/** `allow`: no card for that tool while the bot asks (`ask`); `block`: refused whatever the policy. */
export type ToolRule = "allow" | "block";

export interface BotVersion {
  version: number;
  config: BotConfig;
  note?: string;
  publishedAt: string;
}

export interface Bot {
  id: string;
  slug: string; // readable folder name on the gateway machine, fixed at creation (a rename keeps it)
  published?: BotVersion;
  draft?: BotConfig;
  createdAt: string;
  updatedAt: string;
  lastMessageAt?: string;
  lastMessagePreview?: string;
  /** GET /api/bots(/:id) only: conversations of this bot with a running turn, and the most recent of them. */
  activeTurns?: number;
  activeConversationId?: string;
}

/** The bot's persistent memory (memory/<slug>/MEMORY.md), shared by all its conversations. */
export interface BotMemory {
  content: string;
  updatedAt?: string;
}

/** How full the agent's context window is for a conversation. */
export interface ContextUsage {
  usedTokens: number;
  maxTokens?: number; // context window of the current model, when known
  compactions: number; // how many times the conversation was compacted
  updatedAt: string;
}

/** When a scheduled task runs: a cron expression (5 fields, in `timezone`) or a single date. */
export type TaskSchedule =
  | { kind: "cron"; expr: string; timezone: string } // e.g. "0 7 * * 1-5", "Europe/Paris"
  | { kind: "once"; at: string }; // ISO date

export type CommandNotify = "failure" | "always" | "never";

/**
 * What a run does.
 * - prompt: sends `prompt` to the bot (the original kind; a task without `action` is a prompt task).
 * - command: runs `/bin/bash -c <command>` on the gateway machine, without any agent. Only the paired app
 *   may create or change these; `notifyOn` replaces `notify`.
 */
export type TaskAction =
  | { type: "prompt" }
  | {
      type: "command";
      command: string;
      cwd?: string; // absolute or "~/…"; defaults to the gateway user's home
      envFile?: string; // KEY=VALUE lines added to the environment (values are never logged)
      env?: Record<string, string>;
      timeoutSec?: number; // default 600
      notifyOn: CommandNotify; // default "failure": one push per outage, then one when it recovers
    };

/** A prompt the gateway sends to a bot, or a command it runs, on a schedule; the outcome is pushed to the user. */
export interface ScheduledTask {
  id: string;
  botId: string; // command tasks: the bot they are grouped under in the app and in push threads
  title: string; // short French label, e.g. "Séance du jour"
  action: TaskAction;
  prompt: string; // sent to the bot as a user message (slash commands and #tags allowed); "" for command tasks
  schedule: TaskSchedule;
  enabled: boolean;
  conversation: "dedicated" | "new"; // reuse one conversation per task, or a new one per run
  conversationId?: string; // the dedicated conversation, once created
  notify: boolean; // push the answer; for command tasks, notifyOn != "never"
  createdBy: "user" | "bot" | "gateway"; // gateway: the daily proposals of a proactive bot, one per bot
  nextRunAt?: string;
  lastRunAt?: string;
  lastStatus?: "ok" | "error" | "running";
  createdAt: string;
  updatedAt: string;
}

export interface TaskRun {
  id: string;
  taskId: string;
  conversationId: string; // "" for command runs
  startedAt: string;
  endedAt?: string;
  status: "ok" | "error" | "running";
  preview?: string; // start of the answer; last output line for command runs
  error?: string;
  exitCode?: number; // command runs
  output?: string; // command runs: last ~4 KB of stdout+stderr, ANSI stripped
  durationMs?: number; // command runs
}

export interface Conversation {
  id: string;
  botId: string;
  title: string;
  useDraft: boolean;
  /** Agent picked in the chat for this conversation; the bot's `agent` when absent. `model` belongs to it. */
  agent?: AgentId;
  model?: string;
  effort?: string;
  context?: ContextUsage;
  /** GET /api/conversations(/:id) only: the turn running right now, if any. */
  activeTurn?: ActiveTurn;
  createdAt: string;
  updatedAt: string;
}

/** GET /api/conversations/search: a conversation found by its title or by what was said in it. */
export interface ConversationSearchHit {
  conversation: Conversation;
  /** The message that matched best, cut around the words found; absent when only the title matched. */
  messageId?: string;
  role?: Message["role"];
  snippet?: string;
}

/**
 * Where a running turn is:
 * - queued: accepted, the agent has not received the prompt yet (session spawning, compaction ahead…)
 * - thinking: the agent has the prompt and is reasoning (no tool running, no answer text yet)
 * - working: a tool call is running
 * - answering: the answer text is streaming
 * - waiting_permission: the agent waits for the user to answer a permission request
 */
export type TurnPhase = "queued" | "thinking" | "working" | "answering" | "waiting_permission";

export interface ActiveTurn {
  messageId: string; // id of the assistant message being written
  startedAt: string;
  phase: TurnPhase;
  currentTool?: string; // title of the last running tool call
  steps: number;
  partialText?: string; // conversation lists: the last 200 characters; GET /api/conversations/:id: the whole text so far
}

/** Everything needed to rebuild the message of a running turn as if every event had been received. */
export interface TurnSnapshot {
  conversationId: string;
  botId: string;
  messageId: string;
  startedAt: string;
  phase: TurnPhase;
  currentTool?: string;
  text: string;
  thoughts?: string;
  steps: ToolStep[];
  subagents?: SubagentInfo[];
  permission?: PermissionRequest;
}

/** A permission card. `tool` and `rules`: the card's rule key and the rules it may remember for it, when it can. */
export interface PermissionRequest {
  requestId: string;
  title: string;
  options: PermissionOption[];
  tool?: string;
  rules?: ToolRule[];
}

export interface ToolStep {
  toolCallId: string;
  title: string;
  kind?: string;
  /** What the step does, in words (a shell command's description), when the agent says it. */
  detail?: string;
  status: "running" | "completed" | "failed";
  durationMs?: number;
}

/**
 * A subagent the agent delegated to during a turn (Claude, Codex, Grok and Antigravity all have their own kind).
 * `steps` and `text` are only known for agents that stream the subagent's work (Claude, Grok).
 */
export interface SubagentInfo {
  id: string;
  title: string;
  description?: string;
  state: "running" | "waiting" | "completed" | "failed" | "cancelled";
  startedAt: string;
  endedAt?: string;
  steps: ToolStep[];
  /** The subagent's own answer so far, the last few thousand characters. */
  text?: string;
}

export interface PromptFolder {
  name: string;
  path: string;
}

export interface Attachment {
  kind: "image" | "file"; // images go to the agent as images, other files are saved in the bot's workspace
  mime: string;
  name?: string; // original file name, for files
  size?: number; // bytes
  dataBase64?: string; // client → server only
  url?: string; // server → client (/api/media/:id)
}

export interface Message {
  id: string;
  conversationId: string;
  role: "user" | "assistant";
  text: string;
  thoughts?: string;
  attachments?: Attachment[];
  steps?: ToolStep[];
  subagents?: SubagentInfo[];
  durationMs?: number;
  stopReason?: "end_turn" | "cancelled" | "error";
  /** Assistant messages written by an agent: the agent and model that answered. */
  agent?: AgentId;
  model?: string;
  /** User messages a scheduled task sent: the apps show a marker with its title instead of the prompt. */
  task?: MessageTask;
  /** User messages a webhook or a mail wrote: the apps show this card instead of the prompt written for the agent. */
  wake?: MessageWake;
  createdAt: string;
}

/** How fast the bots answered (GET /api/metrics/latency); a percentile is absent when no answer had that part. */
export interface LatencyStats {
  responses: number;
  firstTextMedianMs?: number; // message.start → first visible word
  firstTextP90Ms?: number;
  firstEventMedianMs?: number; // message.start → first sign of the agent (thought, tool, text…)
  durationMedianMs?: number; // whole answer, completed answers only
  toolMedianMs?: number; // time spent in tools per answer
  avgSteps: number;
}

export interface LatencyDay extends LatencyStats {
  day: string; // YYYY-MM-DD, the gateway's local day
}

export interface BotLatency extends LatencyStats {
  botId: string;
  name: string;
  emoji: string;
  color?: string;
  daily: LatencyDay[]; // days with at least one answer, oldest first
}

export interface LatencyReport {
  days: number;
  since: string;
  scheduled: boolean; // scheduled tasks counted too
  bots: BotLatency[]; // most answers first
}

export interface MessageTask {
  id: string;
  title: string;
}

/**
 * What woke the bot, as the apps show it: clipped copies of what came in, never the prompt itself. `verified`: the
 * owner's own mail, checked by the gateway.
 */
export type MessageWake =
  | { kind: "mail"; from: string; fromName?: string; to: string; subject: string; text: string; verified: boolean; attachments?: string[] }
  | { kind: "hook"; name: string; event?: string; contentType?: string; body: string };

export type ClientEvent =
  /**
   * `steer`: « Envoyer maintenant » while a turn runs. Claude and Codex take the message into the running turn; the
   * other agents stop the turn and start a new one with it. Without a running turn it is a normal prompt.
   */
  | {
      type: "prompt";
      conversationId: string;
      text: string;
      attachments?: Attachment[];
      agent?: AgentId;
      model?: string;
      effort?: string;
      voice?: boolean;
      /** « Objectif »: the bot works without asking at each step; what it sends, invites or deletes is confirmed. */
      goal?: boolean;
      steer?: boolean;
      /** The folder of the user's Mac this conversation works in, reached through the `mac_*` device tools. */
      folder?: PromptFolder;
    }
  | { type: "cancel"; conversationId: string }
  /** `rule`: also remembered for the card's tool (one the card offered); the agent is then answered once accordingly. */
  | { type: "permission"; requestId: string; optionId: string; rule?: ToolRule }
  | { type: "turns.sync" }
  /** The app is in the foreground (or not): while one device is, the others get no push for chat replies. */
  | { type: "presence"; active: boolean }
  | { type: "ping" };

export interface PermissionOption {
  id: string;
  name: string;
  kind: "allow_once" | "allow_always" | "reject_once" | "reject_always";
}

/** A push alert the gateway sent, kept so the app can show it after the notification is gone. */
export interface Alert {
  id: string;
  title: string;
  body: string;
  botId?: string;
  destination: PushDestination;
  createdAt: string;
  readAt?: string;
}

export type ServerEvent =
  /** A user message the gateway wrote itself (a webhook or a mail woke the bot), as stored. */
  | { type: "message.user"; conversationId: string; botId: string; message: Message }
  | { type: "message.start"; conversationId: string; botId?: string; messageId: string; role: "assistant"; at: string; phase?: TurnPhase }
  | { type: "turn.phase"; conversationId: string; messageId: string; phase: TurnPhase }
  | { type: "turns.snapshot"; turns: TurnSnapshot[] }
  | { type: "message.delta"; conversationId: string; messageId: string; text: string }
  | { type: "thought.delta"; conversationId: string; messageId: string; text: string }
  | { type: "tool.start"; conversationId: string; messageId: string; toolCallId: string; title: string; kind?: string }
  | { type: "tool.detail"; conversationId: string; messageId: string; toolCallId: string; detail: string }
  | { type: "tool.end"; conversationId: string; messageId: string; toolCallId: string; status: "completed" | "failed"; durationMs: number }
  /** The whole subagent each time it changes (started, new step, more text, finished). */
  | { type: "subagent"; conversationId: string; messageId: string; subagent: SubagentInfo }
  | {
      type: "message.end";
      conversationId: string;
      messageId: string;
      durationMs: number;
      steps: number;
      stopReason: "end_turn" | "cancelled" | "error";
      agent?: AgentId;
      model?: string;
      /** A scheduled task ran the turn: the gateway notifies for it (or not) itself, apps don't announce it again. */
      scheduled?: true;
    }
  | ({ type: "permission.request"; conversationId: string } & PermissionRequest)
  | { type: "error"; conversationId?: string; message: string }
  | { type: "context"; conversationId: string; context: ContextUsage }
  | {
      type: "notice";
      conversationId: string;
      kind: "compacted" | "switched" | "resumed";
      text: string;
      beforeTokens?: number;
      afterTokens?: number;
      agent?: AgentId;
      model?: string;
    }
  /** `conversationId`: the conversation that now holds the alert as a message. */
  | { type: "notification"; title: string; body: string; botId?: string; conversationId?: string }
  /** A push alert was just kept in the alert history (GET /api/alerts). */
  | { type: "alert"; alert: Alert }
  /** A bot needs the device (calendar, position, maps…): the app answers with POST /api/device/requests/:id/result. */
  | { type: "device.request"; requestId: string; tool: string; args: Record<string, unknown> }
  | { type: "pong" };
