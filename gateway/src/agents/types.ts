import type { AgentId, Attachment, ModelInfo, PermissionOption, PermissionPolicy, ToolRule } from "../protocol";
import type { RelayToolCall } from "../relay/whitelist";

export type RunEvent =
  | { type: "text"; text: string }
  | { type: "thought"; text: string }
  | { type: "tool.start"; toolCallId: string; title: string; kind?: string }
  /** What a started tool is doing, in words, when the agent says it (the description of a shell command). */
  | { type: "tool.detail"; toolCallId: string; detail: string }
  | { type: "tool.end"; toolCallId: string; status: "completed" | "failed" }
  /** Tokens currently in the agent's context, as the agent reports them. */
  | ({ type: "usage" } & UsageReport)
  /** The agent compacted its context (natively, on request or by itself). */
  | { type: "compacted"; beforeTokens?: number; afterTokens?: number }
  /** A subagent started or changed state; title and description only when known; `result` is its whole answer. */
  | { type: "subagent"; id: string; title?: string; description?: string; state?: SubagentState; result?: string }
  | { type: "subagent.tool"; id: string; toolCallId: string; title?: string; status: "running" | "completed" | "failed" }
  | { type: "subagent.text"; id: string; text: string };

export type SubagentState = "running" | "waiting" | "completed" | "failed" | "cancelled";

export interface UsageReport {
  usedTokens: number;
  maxTokens?: number;
}

export interface PermissionAsk {
  title: string;
  options: PermissionOption[];
  /** The tool asked for, when the agent says: a relay session's whitelist is checked against it. */
  tool?: RelayToolCall;
}

export interface SessionOptions {
  workdir: string; // contains the generated CLAUDE.md / AGENTS.md / GEMINI.md instructions
  model: string;
  effort?: string;
  mcpServers: McpServerSpec[];
  permissionPolicy: PermissionPolicy;
  resumeId?: string; // agent session id from a previous process, when the agent supports load/resume
  /** Where the gateway writes files for the agent; outside the workdir for profiles whose agent can write there. */
  attachmentsDir?: string;
  /** No tool at all (BotConfig.noTools), and no file attached by an `@path` mention: only runtimes with `toolless`. */
  noTools?: boolean;
  /** BotConfig.language; French when absent. */
  language?: string;
  /**
   * Started for a turn the relay passed on: no built-in tool but the loader of the `nuo` server's schemas, and
   * every permission request checked against the whitelist (src/relay/whitelist.ts) before anyone is asked.
   */
  relay?: boolean;
  /** A relay session's instructions (without the bot's memory or the database schema), given in the system prompt. */
  instructions?: string;
  /** A relay session's tool the agent asked for and the whitelist refused before anyone was asked. */
  onRelayRefusal?: (tool: string) => void;
  /**
   * The rule the user kept for a tool (BotConfig.toolRules), read at each request so a new one applies at once:
   * `block` refuses whatever the policy, `allow` spares the question under `ask` only. Never given to a relay session.
   */
  toolRule?: (tool: RelayToolCall) => ToolRule | undefined;
}

export interface McpServerSpec {
  name: string;
  command: string;
  args: string[];
  env: Record<string, string>;
}

export function lightpandaMcp(bin: string): McpServerSpec {
  return { name: "lightpanda", command: bin, args: ["mcp"], env: {} };
}

export interface PromptResult {
  stopReason: "end_turn" | "cancelled" | "error";
  error?: string;
  /** Usage taken from the prompt response, for agents that send no usage updates. */
  usage?: UsageReport;
}

/** A turn nobody prompted. Its events wait until `run` takes them, which resolves when that work ends. */
export interface UnpromptedWork {
  run(onEvent: (e: RunEvent) => void, askPermission: (ask: PermissionAsk) => Promise<string>): Promise<PromptResult>;
}

export interface AgentSession {
  readonly agentSessionId: string;
  /** Slash command names the agent advertises (ACP `available_commands_update`), without the slash. */
  readonly commands?: readonly string[];
  prompt(
    text: string,
    attachments: Attachment[],
    onEvent: (e: RunEvent) => void,
    askPermission: (ask: PermissionAsk) => Promise<string>, // returns the chosen option id
  ): Promise<PromptResult>;
  cancel(): Promise<void>;
  /**
   * Hands a message to the running turn without stopping it; false when the agent cannot (no running turn, or no
   * steering support), and the caller then queues it.
   */
  steer?(text: string, attachments: Attachment[]): Promise<boolean>;
  /**
   * Called when the agent works again on its own after its turn ended: Claude's follow-up once a background command
   * finishes. Unset, that work is dropped.
   */
  onUnprompted?: (work: UnpromptedWork) => void;
  /** Background work the agent will come back to by itself: the session must stay open meanwhile. */
  readonly awaitsBackground?: boolean;
  setModel(model: string, effort?: string): Promise<void>;
  close(): Promise<void>;
}

export interface AgentRuntime {
  readonly id: AgentId;
  readonly name: string;
  status(): Promise<{ available: boolean; authenticated: boolean; note?: string }>;
  models(): Promise<ModelInfo[]>;
  start(opts: SessionOptions): Promise<AgentSession>;
  /** Can run a session without any tool (`SessionOptions.noTools`): the others have built-in tools no option removes. */
  readonly toolless?: boolean;
}
