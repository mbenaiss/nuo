import { head, tail } from "../text";
import * as acp from "@agentclientprotocol/sdk";
import type { ChildProcess } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable, Writable } from "node:stream";
import type { AgentId, Attachment, ModelInfo, PermissionOption, PermissionPolicy } from "../protocol";
import { LOCAL_HOST, type AgentHost } from "./host";
import { compactionFromRawOutput, usageFromPromptResponse, usageFromUpdate } from "./context";
import { neutralizeMentions } from "./mentions";
import { relayRefusal, toolFromAcp } from "../relay/whitelist";
import type {
  AgentRuntime,
  AgentSession,
  McpServerSpec,
  PermissionAsk,
  PromptResult,
  RunEvent,
  SessionOptions,
  SubagentState,
  UnpromptedWork,
  UsageReport,
} from "./types";

export interface SpawnSpec {
  command: string;
  args: string[];
  env?: Record<string, string>;
}

export interface Timeouts {
  initializeMs: number;
  sessionMs: number;
  /** A prompt with no update from the agent for this long is cancelled and reported as an error. */
  promptIdleMs: number;
  /** Work the agent started on its own ends after this long without an update, when it sends no end of its own. */
  unpromptedIdleMs: number;
  cancelGraceMs: number;
  killGraceMs: number;
}

export const DEFAULT_TIMEOUTS: Timeouts = {
  initializeMs: 30_000,
  sessionMs: 90_000,
  promptIdleMs: 15 * 60_000,
  unpromptedIdleMs: 60_000,
  cancelGraceMs: 10_000,
  killGraceMs: 3_000,
};

const READ_ONLY_KINDS = new Set(["read", "search", "fetch", "think"]);
const STDERR_LIMIT = 16 * 1024;
const MODELS_TTL_MS = 10 * 60_000;
/** How long a session stays open for a background command the agent has not come back to yet. */
const BACKGROUND_KEEPALIVE_MS = 2 * 60 * 60_000;
/** Updates that mean the agent works again; usage or command lists alone do not open a turn. */
const TOOL_DETAIL_MAX = 200;
const UNPROMPTED_STARTS = new Set(["agent_message_chunk", "agent_thought_chunk", "tool_call"]);
export { augmentedPath, childEnv, extraPathDirs, findBinary } from "./host";

/** Runs a short command and returns its output; never throws. */
export async function runQuick(
  command: string,
  args: string[],
  timeoutMs = 10_000,
  host: AgentHost = LOCAL_HOST,
): Promise<{ code: number | null; stdout: string; stderr: string }> {
  return new Promise((resolve) => {
    let stdout = "";
    let stderr = "";
    let child: ChildProcess;
    try {
      child = host.spawn(command, args, { cwd: host.kind === "local" ? undefined : host.home, stdio: ["ignore", "pipe", "pipe"] });
    } catch (e) {
      resolve({ code: null, stdout: "", stderr: String(e) });
      return;
    }
    const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
    child.stdout?.on("data", (d) => (stdout += d));
    child.stderr?.on("data", (d) => (stderr += d));
    child.on("error", (e) => {
      clearTimeout(timer);
      resolve({ code: null, stdout, stderr: stderr + String(e) });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr });
    });
  });
}

class RingBuffer {
  private buf = "";
  constructor(private readonly limit: number) {}
  push(s: string) {
    this.buf += s;
    if (this.buf.length > this.limit) this.buf = tail(this.buf, this.limit);
  }
  tail(chars = 2000): string {
    return tail(this.buf, chars).trim();
  }
}

const liveProcesses = new Set<ChildProcess>();
let exitHookInstalled = false;
export function trackProcess(child: ChildProcess) {
  liveProcesses.add(child);
  child.once("exit", () => liveProcesses.delete(child));
  if (!exitHookInstalled) {
    exitHookInstalled = true;
    process.once("exit", () => {
      for (const c of liveProcesses) killGroup(c, "SIGKILL");
    });
  }
}

function killGroup(child: ChildProcess, signal: NodeJS.Signals) {
  if (child.pid === undefined) return;
  try {
    process.kill(-child.pid, signal);
  } catch {
    try {
      child.kill(signal);
    } catch {
      // already gone
    }
  }
}

export async function killTree(child: ChildProcess, graceMs: number): Promise<void> {
  if (child.pid === undefined) return;
  if (child.exitCode === null && child.signalCode === null) {
    const exited = new Promise<void>((r) => child.once("exit", () => r()));
    killGroup(child, "SIGTERM");
    await Promise.race([exited, new Promise((r) => setTimeout(r, graceMs))]);
  }
  // Also reaps grandchildren (MCP servers, shells) left in the group after the leader exited.
  killGroup(child, "SIGKILL");
}

function withTimeout<T>(p: Promise<T>, ms: number, what: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout>;
  const t = new Promise<never>((_, rej) => {
    timer = setTimeout(() => rej(new Error(`${what} timed out after ${Math.round(ms / 1000)}s`)), ms);
  });
  return Promise.race([p, t]).finally(() => clearTimeout(timer));
}

function errorMessage(e: unknown): string {
  if (e instanceof acp.RequestError) {
    const data = e.data && typeof e.data === "object" ? JSON.stringify(e.data) : e.data ? String(e.data) : "";
    return data && !e.message.includes(data) ? `${e.message} (${data})` : e.message;
  }
  return e instanceof Error ? e.message : String(e);
}

// ---------- model helpers ----------

type SelectOption = { value: string; name: string; description?: string | null };

export function flattenSelectOptions(options: acp.SessionConfigSelectOptions | undefined): SelectOption[] {
  const out: SelectOption[] = [];
  for (const o of options ?? []) {
    if ("group" in o) out.push(...o.options);
    else out.push(o);
  }
  return out;
}

function slug(s: string): string {
  return s
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
}

function normModel(s: string): string {
  return slug(s)
    .replace(/^(claude|anthropic)-/, "")
    .replace(/-\d{8}$/, "")
    .replace(/-latest$/, "");
}

/** Resolves a requested id (exact value, display name or a canonical variant) to one of the option values. */
export function resolveOption(requested: string, options: SelectOption[]): string | undefined {
  const exact = options.find((o) => o.value === requested);
  if (exact) return exact.value;
  const want = normModel(requested);
  const byValue = options.find((o) => normModel(o.value) === want);
  if (byValue) return byValue.value;
  const byName = options.find((o) => normModel(o.name) === want);
  if (byName) return byName.value;
  return options.find((o) => o.value.toLowerCase() === requested.toLowerCase())?.value;
}

function configSelect(
  options: acp.SessionConfigOption[] | undefined,
  category: string,
): (acp.SessionConfigOption & { type: "select" }) | undefined {
  return options?.find((o): o is acp.SessionConfigOption & { type: "select" } => o.category === category && o.type === "select");
}

interface LegacyModels {
  currentModelId: string;
  availableModels: { modelId: string; name: string; description?: string | null }[];
}

export interface DiscoveredModels {
  configOptions?: acp.SessionConfigOption[];
  legacy?: LegacyModels;
}

// ---------- session ----------

interface ActivePrompt {
  onEvent: (e: RunEvent) => void;
  askPermission: (ask: PermissionAsk) => Promise<string>;
  openTools: Set<string>;
  seenTools: Set<string>;
  details: Map<string, string>;
  abort: AbortController;
  lastActivity: number;
  usageSeen: boolean;
}

export interface AcpSessionHooks {
  spawnSpec(model?: string, effort?: string): Promise<SpawnSpec>;
  sessionMeta?(opts: SessionOptions): Record<string, unknown> | undefined;
  /** Mode id to switch to for a permission policy, if the agent has a matching mode. */
  modeFor?(policy: PermissionPolicy, modes: SelectOption[]): string | undefined;
  /** Auth method to call `authenticate` with before creating a session, when the agent needs it. */
  authMethod?(methods: acp.AuthMethod[]): Promise<string | undefined>;
  /** Whether `setModel` may restart the process with new CLI flags when ACP offers no way to switch. */
  restartForModel?: boolean;
  timeouts?: Partial<Timeouts>;
  /** Who runs the agent process; the gateway user when absent. */
  host?: AgentHost;
}

export class AcpSession implements AgentSession {
  private child!: ChildProcess;
  private conn!: acp.ClientConnection;
  private stderr = new RingBuffer(STDERR_LIMIT);
  private exitInfo: string | null = null;
  private exited: Promise<string> = new Promise(() => {});
  private sessionId = "";
  private caps: acp.AgentCapabilities = {};
  private authMethods: acp.AuthMethod[] = [];
  private configOptions: acp.SessionConfigOption[] = [];
  private legacyModels: LegacyModels | undefined;
  private modes: acp.SessionModeState | null | undefined;
  private active: ActivePrompt | null = null;
  private closed = false;
  private readonly timeouts: Timeouts;
  private currentModel?: string;
  private currentEffort?: string;
  private availableCommands: string[] = [];
  private usage?: UsageReport;
  /** The agent takes `_session/steering` (Claude, Codex): a message joins the running turn instead of waiting. */
  private steering = false;
  /** Child sessions of subagents; their updates are the subagent's work, not the answer. */
  private children = new Set<string>();
  /** Descriptions of Grok's `spawn_subagent` calls, matched in order with the children it announces. */
  private spawnTitles: string[] = [];
  /** Claude: the tool call that launched each subagent, whose result is the subagent's answer. */
  private subagentCalls = new Map<string, string>();
  /** Claude: subagents that handed their report back (`SubagentHandback`); their tool result only points at it. */
  private handedBack = new Set<string>();
  /** The work Claude does by itself after a background command finished, while no prompt runs. */
  private unprompted: { a: ActivePrompt; end: (r: PromptResult) => void } | null = null;
  /** Background commands not followed up yet, and when the last one started. */
  private background = { count: 0, since: 0 };
  onUnprompted?: (work: UnpromptedWork) => void;
  onModelsDiscovered?: (d: DiscoveredModels) => void;

  constructor(
    private readonly opts: SessionOptions,
    private readonly hooks: AcpSessionHooks,
  ) {
    this.timeouts = { ...DEFAULT_TIMEOUTS, ...hooks.timeouts };
  }

  get agentSessionId(): string {
    return this.sessionId;
  }

  get agentCapabilities(): acp.AgentCapabilities {
    return this.caps;
  }

  get awaitsBackground(): boolean {
    return this.background.count > 0 && Date.now() - this.background.since < BACKGROUND_KEEPALIVE_MS;
  }

  get sessionConfigOptions(): acp.SessionConfigOption[] {
    return this.configOptions;
  }

  /** Current model/effort as the agent reports them, for diagnostics. */
  get currentSelection(): { model?: string; effort?: string } {
    const model = configSelect(this.configOptions, "model")?.currentValue ?? this.legacyModels?.currentModelId ?? this.currentModel;
    const effort = configSelect(this.configOptions, "thought_level")?.currentValue ?? this.currentEffort;
    return { ...(model ? { model } : {}), ...(effort ? { effort } : {}) };
  }

  get commands(): readonly string[] {
    return this.availableCommands;
  }

  /** Last context usage the agent reported, including outside a prompt. */
  get lastUsage(): UsageReport | undefined {
    return this.usage;
  }

  get stderrTail(): string {
    return this.stderr.tail();
  }

  get pid(): number | undefined {
    return this.child?.pid;
  }

  async open(): Promise<void> {
    await this.spawnAndConnect(this.opts.model, this.opts.effort);
    await this.createOrResume(this.opts.resumeId);
    this.onModelsDiscovered?.({ configOptions: this.configOptions, legacy: this.legacyModels });
    if (this.opts.model) await this.applyModel(this.opts.model, this.opts.effort, false);
    await this.applyPolicyMode();
  }

  private async spawnAndConnect(model?: string, effort?: string) {
    const spec = await this.hooks.spawnSpec(model, effort);
    this.currentModel = model;
    this.currentEffort = effort;
    this.exitInfo = null;
    this.stderr = new RingBuffer(STDERR_LIMIT);
    let child: ChildProcess;
    try {
      child = (this.hooks.host ?? LOCAL_HOST).spawn(spec.command, spec.args, {
        cwd: this.opts.workdir,
        env: spec.env,
        stdio: ["pipe", "pipe", "pipe"],
        detached: true,
      });
    } catch (e) {
      throw new Error(`cannot start ${spec.command}: ${errorMessage(e)}`);
    }
    this.child = child;
    trackProcess(child);
    child.stderr!.on("data", (d: Buffer) => this.stderr.push(d.toString()));
    child.stdin!.on("error", () => {}); // EPIPE when the agent dies; surfaced through the exit handler
    await new Promise<void>((resolve, reject) => {
      child.once("spawn", () => resolve());
      child.once("error", (e) => reject(new Error(`cannot start ${spec.command}: ${e.message}`)));
    });
    this.exited = new Promise((resolve) => {
      child.once("exit", (code, signal) => {
        // Give the stderr pipe a moment to flush the reason of the crash.
        setTimeout(() => {
          const info = `agent process exited (${signal ?? `code ${code}`})`;
          if (this.child === child) this.exitInfo = info;
          resolve(info);
        }, 50);
      });
    });

    const stream = acp.ndJsonStream(
      Writable.toWeb(child.stdin!) as WritableStream<Uint8Array>,
      Readable.toWeb(child.stdout!) as unknown as ReadableStream<Uint8Array>,
    );
    // Lenient parsers: agents send fields newer than this SDK's schema and we must not drop their updates.
    this.conn = acp
      .client({ name: "nuo-gateway" })
      .onNotification("session/update", (p: unknown) => p as acp.SessionNotification, (ctx) => this.handleUpdate(ctx.params))
      .onNotification("_x.ai/session_notification", (p: unknown) => p as XaiNotification, (ctx) => this.handleXai(ctx.params))
      .onRequest(
        "session/request_permission",
        (p: unknown) => p as acp.RequestPermissionRequest,
        (ctx) => this.handlePermission(ctx.params),
      )
      .connect(stream);

    const init = await this.guard(
      this.conn.agent.request("initialize", {
        protocolVersion: acp.PROTOCOL_VERSION,
        // Claude streams its subagents as child sessions only to clients that ask for them.
        clientCapabilities: { subagents: {} },
        clientInfo: { name: "nuo-gateway", version: "0.1.0" },
      }),
      this.timeouts.initializeMs,
      "initialize",
    );
    this.caps = init.agentCapabilities ?? {};
    this.steering = (init as { _meta?: { steering?: { supported?: unknown } } | null })._meta?.steering?.supported === true;
    this.authMethods = init.authMethods ?? [];
    const method = await this.hooks.authMethod?.(this.authMethods);
    if (method) {
      await this.guard(this.conn.agent.request("authenticate", { methodId: method }), this.timeouts.initializeMs, "authenticate");
    }
  }

  private mcpServers(): acp.McpServer[] {
    if (this.opts.noTools) return [];
    return this.opts.mcpServers.map((s: McpServerSpec) => ({
      name: s.name,
      command: s.command,
      args: s.args,
      env: Object.entries(s.env).map(([name, value]) => ({ name, value })),
    }));
  }

  private async createOrResume(resumeId?: string) {
    const meta = this.hooks.sessionMeta?.(this.opts);
    const base: acp.NewSessionRequest = { cwd: this.opts.workdir, mcpServers: this.mcpServers(), ...(meta ? { _meta: meta } : {}) };
    if (resumeId) {
      try {
        if (this.caps.sessionCapabilities?.resume) {
          const r = await this.guard(
            this.conn.agent.request("session/resume", { ...base, sessionId: resumeId }),
            this.timeouts.sessionMs,
            "session/resume",
          );
          this.sessionId = resumeId;
          this.absorbSessionState(r);
          return;
        }
        if (this.caps.loadSession) {
          // History is replayed as session/update notifications; they are ignored since no prompt is active.
          const r = await this.guard(
            this.conn.agent.request("session/load", { ...base, sessionId: resumeId }),
            this.timeouts.sessionMs,
            "session/load",
          );
          this.sessionId = resumeId;
          this.absorbSessionState(r ?? {});
          return;
        }
      } catch (e) {
        if (this.exitInfo) throw e;
        this.stderr.push(`\n[nuo] resume of ${resumeId} failed: ${errorMessage(e)}; starting a new session\n`);
      }
    }
    const r = await this.guard(this.conn.agent.request("session/new", base), this.timeouts.sessionMs, "session/new");
    this.sessionId = r.sessionId;
    this.absorbSessionState(r);
  }

  private absorbSessionState(r: { configOptions?: acp.SessionConfigOption[] | null; modes?: acp.SessionModeState | null }) {
    const raw = r as { models?: LegacyModels | null };
    if (r.configOptions) this.configOptions = r.configOptions;
    if (r.modes !== undefined) this.modes = r.modes;
    if (raw.models?.availableModels) this.legacyModels = raw.models;
  }

  private async guard<T>(p: Promise<T>, ms: number, what: string): Promise<T> {
    const exited = this.exited.then((info) => {
      throw new Error(this.withStderr(info));
    });
    try {
      return await withTimeout(Promise.race([p, exited]), ms, what);
    } catch (e) {
      const msg = errorMessage(e);
      throw new Error(msg.includes("stderr:") ? msg : `${what}: ${this.withStderr(msg)}`);
    }
  }

  private withStderr(msg: string): string {
    const tail = this.stderr.tail(1500);
    return tail ? `${msg}\nstderr: ${tail}` : msg;
  }

  // ---------- model / mode ----------

  private async setConfig(configId: string, value: string) {
    const r = await this.guard(
      this.conn.agent.request("session/set_config_option", { sessionId: this.sessionId, configId, value }),
      this.timeouts.sessionMs,
      "session/set_config_option",
    );
    if (r?.configOptions) this.configOptions = r.configOptions;
  }

  /** Returns true when the agent applied the model through ACP. */
  private async applyModel(model: string, effort: string | undefined, allowRestart: boolean): Promise<boolean> {
    const modelOpt = configSelect(this.configOptions, "model");
    let applied = false;
    if (modelOpt) {
      const value = resolveOption(model, flattenSelectOptions(modelOpt.options));
      if (value) {
        if (value !== modelOpt.currentValue) await this.setConfig(modelOpt.id, value);
        applied = true;
      }
    } else if (this.legacyModels) {
      const ids = this.legacyModels.availableModels.map((m) => ({ value: m.modelId, name: m.name }));
      const withEffort = effort ? resolveOption(`${model}[${effort}]`, ids) : undefined;
      const value = withEffort ?? resolveOption(model, ids);
      if (value) {
        if (value !== this.legacyModels.currentModelId) {
          await this.guard(
            this.conn.agent.request("session/set_model", { sessionId: this.sessionId, modelId: value }),
            this.timeouts.sessionMs,
            "session/set_model",
          );
          this.legacyModels.currentModelId = value;
        }
        applied = true;
        if (withEffort) effort = undefined;
      }
    }
    if (effort) {
      const effortOpt = configSelect(this.configOptions, "thought_level");
      if (effortOpt) {
        const value = resolveOption(effort, flattenSelectOptions(effortOpt.options));
        if (value && value !== effortOpt.currentValue) await this.setConfig(effortOpt.id, value);
      }
    }
    if (!applied && allowRestart && this.hooks.restartForModel && model !== this.currentModel) {
      await this.restart(model, effort);
      return true;
    }
    if (applied) {
      this.currentModel = model;
      this.currentEffort = effort ?? this.currentEffort;
    }
    return applied;
  }

  private async applyPolicyMode() {
    if (!this.hooks.modeFor) return;
    const modeOpt = configSelect(this.configOptions, "mode");
    const modes: SelectOption[] = modeOpt
      ? flattenSelectOptions(modeOpt.options)
      : (this.modes?.availableModes ?? []).map((m) => ({ value: m.id, name: m.name, description: m.description }));
    const target = this.hooks.modeFor(this.opts.permissionPolicy, modes);
    if (!target) return;
    if (modeOpt) {
      if (modeOpt.currentValue !== target) await this.setConfig(modeOpt.id, target);
    } else if (this.modes && this.modes.currentModeId !== target) {
      await this.guard(
        this.conn.agent.request("session/set_mode", { sessionId: this.sessionId, modeId: target }),
        this.timeouts.sessionMs,
        "session/set_mode",
      );
      this.modes.currentModeId = target;
    }
  }

  private async restart(model: string, effort?: string) {
    const previous = this.sessionId;
    await this.teardown();
    this.closed = false;
    await this.spawnAndConnect(model, effort);
    await this.createOrResume(previous);
    await this.applyPolicyMode();
  }

  async setModel(model: string, effort?: string): Promise<void> {
    if (this.closed) throw new Error("session closed");
    await this.applyModel(model, effort, true);
  }

  // ---------- events ----------

  private handleUpdate(n: acp.SessionNotification) {
    const u = n.update as acp.SessionUpdate;
    // Agents announce their commands while session/new or session/load is still pending (one session per process).
    if (u.sessionUpdate === "available_commands_update" && (!this.sessionId || n.sessionId === this.sessionId)) {
      this.availableCommands = (u.availableCommands ?? []).map((c) => c.name.replace(/^\//, ""));
      return;
    }
    if (n.sessionId !== this.sessionId) {
      if (this.children.has(n.sessionId)) this.childUpdate(n.sessionId, u);
      return;
    }
    if ((u.sessionUpdate as string) === "subagent_update") {
      this.subagentUpdate(u as unknown as RfdSubagentUpdate);
      return;
    }
    if (u.sessionUpdate === "config_option_update") {
      this.configOptions = (u as { configOptions: acp.SessionConfigOption[] }).configOptions;
      return;
    }
    if (u.sessionUpdate === "current_mode_update" && this.modes) {
      this.modes.currentModeId = (u as { currentModeId: string }).currentModeId;
      return;
    }
    let a = this.active;
    if (u.sessionUpdate === "usage_update") {
      const usage = usageFromUpdate(u);
      if (usage) this.usage = usage;
      if (a && usage) {
        a.usageSeen = true;
        a.onEvent({ type: "usage", ...usage });
      }
      // Claude closes the work it started by itself with the usage of its result, which names that origin.
      if (a && a === this.unprompted?.a && (u as { _meta?: Record<string, unknown> | null })._meta?.["_claude/origin"]) {
        this.endUnprompted({ stopReason: "end_turn" });
      }
      return;
    }
    if (u.sessionUpdate === "tool_call" && (u.rawInput as { run_in_background?: unknown } | undefined)?.run_in_background === true) {
      this.background = { count: this.background.count + 1, since: Date.now() };
    }
    if (!a && UNPROMPTED_STARTS.has(u.sessionUpdate) && this.onUnprompted && !this.closed) a = this.beginUnprompted();
    if (!a) return;
    a.lastActivity = Date.now();
    if ((u.sessionUpdate === "tool_call" || u.sessionUpdate === "tool_call_update") && u.rawOutput) {
      const compacted = compactionFromRawOutput(u.rawOutput);
      if (compacted) a.onEvent({ type: "compacted", ...compacted });
    }
    if (u.sessionUpdate === "tool_call" || u.sessionUpdate === "tool_call_update") {
      this.toolSubagent(a, u, u.sessionUpdate === "tool_call");
      const child = this.subagentCalls.get(u.toolCallId);
      const result = child && u.status === "completed" && !this.handedBack.has(child) ? (handbackReport(u) ?? toolResultText(u)) : undefined;
      if (child && result) a.onEvent({ type: "subagent", id: child, result });
    }
    switch (u.sessionUpdate) {
      case "agent_message_chunk":
        if (u.content.type === "text" && u.content.text) a.onEvent({ type: "text", text: u.content.text });
        break;
      case "agent_thought_chunk":
        if (u.content.type === "text" && u.content.text) a.onEvent({ type: "thought", text: u.content.text });
        break;
      case "tool_call":
        this.toolStart(a, u.toolCallId, u.title, u.kind);
        this.toolDetail(a, u.toolCallId, u.rawInput);
        if (u.status === "completed" || u.status === "failed") this.toolEnd(a, u.toolCallId, u.status);
        break;
      case "tool_call_update":
        if (!a.seenTools.has(u.toolCallId) && (u.title || u.status === "completed" || u.status === "failed")) {
          this.toolStart(a, u.toolCallId, u.title ?? "tool", u.kind ?? undefined);
        }
        this.toolDetail(a, u.toolCallId, u.rawInput);
        if (u.status === "completed" || u.status === "failed") this.toolEnd(a, u.toolCallId, u.status);
        break;
    }
  }

  /**
   * Opens a turn for work nobody prompted. Its events are held until the runner takes the work; it ends with the
   * agent's own end of it, a stretch without updates, a prompt, a cancel or the process exiting.
   */
  private beginUnprompted(): ActivePrompt {
    const held: RunEvent[] = [];
    let attach!: (ask: (q: PermissionAsk) => Promise<string>) => void;
    const asker = new Promise<(q: PermissionAsk) => Promise<string>>((r) => (attach = r));
    const a: ActivePrompt = {
      onEvent: (e) => held.push(e),
      askPermission: (q) => asker.then((ask) => ask(q)),
      openTools: new Set(),
      seenTools: new Set(),
      details: new Map(),
      abort: new AbortController(),
      lastActivity: Date.now(),
      usageSeen: false,
    };
    let resolve!: (r: PromptResult) => void;
    const ended = new Promise<PromptResult>((r) => (resolve = r));
    const timer = setInterval(() => {
      if (a.openTools.size === 0 && Date.now() - a.lastActivity > this.timeouts.unpromptedIdleMs) this.endUnprompted({ stopReason: "end_turn" });
    }, Math.min(5_000, this.timeouts.unpromptedIdleMs));
    this.unprompted = {
      a,
      end: (r) => {
        clearInterval(timer);
        for (const id of [...a.openTools]) this.toolEnd(a, id, r.stopReason === "end_turn" ? "completed" : "failed");
        resolve(r);
      },
    };
    this.active = a;
    void this.exited.then((info) => {
      if (this.unprompted?.a === a) this.endUnprompted({ stopReason: "error", error: this.withStderr(info) });
    });
    const work: UnpromptedWork = {
      run: (onEvent, askPermission) => {
        a.onEvent = (e) => {
          try {
            onEvent(e);
          } catch {
            // a consumer failure must not break the turn
          }
        };
        for (const e of held.splice(0)) a.onEvent(e);
        attach(askPermission);
        return ended;
      },
    };
    try {
      this.onUnprompted!(work);
    } catch (e) {
      console.warn(`[acp] unprompted work not taken: ${errorMessage(e)}`);
    }
    return a;
  }

  private endUnprompted(r: PromptResult) {
    const u = this.unprompted;
    if (!u) return;
    this.unprompted = null;
    if (this.active === u.a) this.active = null;
    if (r.stopReason === "end_turn" && this.background.count > 0) this.background.count--;
    u.end(r);
  }

  // ---------- subagents ----------

  /** Claude: the subagents RFD (`subagent_update` on the parent, the child's work in its own session). */
  private subagentUpdate(u: RfdSubagentUpdate) {
    this.children.add(u.sessionId);
    const a = this.active;
    if (!a) return;
    a.lastActivity = Date.now();
    const state = u.state ? rfdState(u.state) : undefined;
    a.onEvent({ type: "subagent", id: u.sessionId, ...(u.description ? { description: u.description } : {}), ...(u.title ? { title: u.title } : {}), ...(state ? { state } : {}) });
  }

  /**
   * Subagents that only show as tool calls: Codex's "Start subagent x" / "Complete subagent x" (same
   * `agentThreadId`), and the description of Grok's `spawn_subagent`, kept for the child it announces next.
   */
  private toolSubagent(a: ActivePrompt, u: { title?: string | null; rawInput?: unknown }, isNew: boolean) {
    const input = (u.rawInput ?? {}) as { agentThreadId?: unknown; description?: unknown };
    const title = u.title ?? "";
    if (isNew && title === "spawn_subagent" && typeof input.description === "string") this.spawnTitles.push(input.description);
    if (typeof input.agentThreadId !== "string") return;
    const start = /^Start subagent (.+)$/.exec(title);
    const end = /^Complete subagent (.+)$/.exec(title);
    if (start) a.onEvent({ type: "subagent", id: input.agentThreadId, title: start[1]!.replace(/_/g, " "), state: "running" });
    else if (end) a.onEvent({ type: "subagent", id: input.agentThreadId, state: "completed" });
  }

  /** Grok announces its subagents with its own notifications; their work arrives in the child session. */
  private handleXai(p: XaiNotification) {
    const u = p.update;
    const a = this.active;
    if (!u || p.sessionId !== this.sessionId || typeof u.child_session_id !== "string") return;
    const id = u.child_session_id;
    if (u.sessionUpdate === "subagent_spawned") {
      this.children.add(id);
      const title = this.spawnTitles.shift() ?? (typeof u.subagent_type === "string" ? u.subagent_type : undefined);
      a?.onEvent({ type: "subagent", id, ...(title ? { title } : {}), state: "running" });
    } else if (u.sessionUpdate === "subagent_finished") {
      const state = u.status === "completed" ? "completed" : u.status === "cancelled" ? "cancelled" : "failed";
      a?.onEvent({ type: "subagent", id, state });
    }
    if (a) a.lastActivity = Date.now();
  }

  private childUpdate(id: string, u: acp.SessionUpdate) {
    // Claude sends the subagent its mission as a message whose id is the tool call that launched it.
    if ((u.sessionUpdate as string) === "session_message") {
      const m = u as unknown as { messageId?: unknown; content?: unknown };
      if (typeof m.messageId === "string") this.subagentCalls.set(m.messageId, id);
      const text = blocksText(m.content);
      if (text) this.active?.onEvent({ type: "subagent", id, description: text });
    }
    const a = this.active;
    if (!a) return;
    a.lastActivity = Date.now();
    // Claude's subagent ends by handing its report to its caller: that call is its answer, not a step.
    if ((u.sessionUpdate === "tool_call" || u.sessionUpdate === "tool_call_update") && claudeToolName(u) === "SubagentHandback") {
      const report = (u.rawInput as { message?: unknown } | undefined)?.message;
      if (typeof report === "string" && report.trim()) {
        this.handedBack.add(id);
        a.onEvent({ type: "subagent", id, result: report.trim() });
      }
      return;
    }
    switch (u.sessionUpdate) {
      case "agent_message_chunk":
        if (u.content.type === "text" && u.content.text) a.onEvent({ type: "subagent.text", id, text: u.content.text });
        break;
      case "user_message_chunk":
        if (u.content.type === "text" && u.content.text) a.onEvent({ type: "subagent", id, description: u.content.text });
        break;
      case "tool_call":
      case "tool_call_update": {
        const status = u.status === "completed" || u.status === "failed" ? u.status : "running";
        a.onEvent({ type: "subagent.tool", id, toolCallId: u.toolCallId, ...(u.title ? { title: u.title } : {}), status });
        break;
      }
    }
  }

  private toolStart(a: ActivePrompt, id: string, title: string, kind?: string | null) {
    if (a.seenTools.has(id)) return;
    a.seenTools.add(id);
    a.openTools.add(id);
    a.onEvent({ type: "tool.start", toolCallId: id, title: title || "tool", ...(kind ? { kind } : {}) });
  }

  /** A shell command's own description ("Wait for the deploy workflow"): its title alone is only "Terminal". */
  private toolDetail(a: ActivePrompt, id: string, rawInput: unknown) {
    const description = (rawInput as { description?: unknown } | null | undefined)?.description;
    if (!a.seenTools.has(id) || typeof description !== "string") return;
    const detail = head(description.trim(), TOOL_DETAIL_MAX);
    if (!detail || a.details.get(id) === detail) return;
    a.details.set(id, detail);
    a.onEvent({ type: "tool.detail", toolCallId: id, detail });
  }

  private toolEnd(a: ActivePrompt, id: string, status: "completed" | "failed") {
    if (!a.openTools.delete(id)) return;
    a.onEvent({ type: "tool.end", toolCallId: id, status });
  }

  // ---------- permissions ----------

  private isOwnMcpTool(toolCall: unknown): boolean {
    const names = this.opts.mcpServers.map((s) => s.name);
    if (!names.length || !toolCall) return false;
    const text = JSON.stringify(toolCall);
    return names.some((n) => text.includes(`mcp__${n}__`));
  }

  private async handlePermission(req: acp.RequestPermissionRequest): Promise<acp.RequestPermissionResponse> {
    const cancelled: acp.RequestPermissionResponse = { outcome: { outcome: "cancelled" } };
    const a = this.active;
    if (a) a.lastActivity = Date.now();
    const options = req.options ?? [];
    const pick = (...kinds: string[]) => {
      for (const k of kinds) {
        const o = options.find((x) => x.kind === k);
        if (o) return o;
      }
      return undefined;
    };
    const select = (o: acp.PermissionOption | undefined): acp.RequestPermissionResponse =>
      o ? { outcome: { outcome: "selected", optionId: o.optionId } } : cancelled;
    const kind = req.toolCall?.kind ?? undefined;

    if (!a || a.abort.signal.aborted || this.opts.noTools) return select(pick("reject_once", "reject_always"));
    const tool = toolFromAcp(req.toolCall);
    // A relay session: what is off the whitelist is refused here, before anyone is asked. Moving an event depends on
    // what the turn created, which the runner knows: it decides that one (and checks every other call again).
    if (this.opts.relay && tool?.name !== "apple_event_update" && relayRefusal(tool ?? { name: "" }, { createdEvents: new Set() })) {
      this.opts.onRelayRefusal?.(tool?.name ?? req.toolCall?.title ?? "");
      return select(pick("reject_once", "reject_always"));
    }
    const rule = tool && !this.opts.relay ? this.opts.toolRule?.(tool) : undefined;
    if (rule === "block") return select(pick("reject_once", "reject_always"));
    if (rule === "allow" && this.opts.permissionPolicy === "ask") {
      const allowed = pick("allow_once", "allow_always");
      if (allowed) return select(allowed);
    }
    switch (this.opts.relay ? "ask" : this.opts.permissionPolicy) {
      case "auto":
        return select(pick("allow_once", "allow_always") ?? options[0]);
      case "readonly":
        // The bot's own MCP tools may write to their data (log_meal, save_flight); the machine itself stays off-limits.
        if ((kind && READ_ONLY_KINDS.has(kind)) || this.isOwnMcpTool(req.toolCall)) {
          return select(pick("allow_once", "allow_always"));
        }
        return select(pick("reject_once", "reject_always"));
      case "ask": {
        const ask: PermissionAsk = {
          ...(tool ? { tool } : {}),
          title: req.toolCall?.title || (kind ? `Allow ${kind}?` : "Allow this action?"),
          options: options.map(
            (o): PermissionOption => ({ id: o.optionId, name: o.name, kind: o.kind as PermissionOption["kind"] }),
          ),
        };
        const aborted = new Promise<null>((r) => {
          if (a.abort.signal.aborted) r(null);
          else a.abort.signal.addEventListener("abort", () => r(null), { once: true });
        });
        try {
          const chosen = await Promise.race([a.askPermission(ask), aborted]);
          a.lastActivity = Date.now();
          if (chosen === null) return cancelled;
          return select(options.find((o) => o.optionId === chosen));
        } catch {
          return cancelled;
        }
      }
    }
  }

  // ---------- prompt ----------

  private promptBlocks(text: string, attachments: Attachment[]): acp.ContentBlock[] {
    const blocks: acp.ContentBlock[] = [];
    const images = attachments.filter((x) => x.kind === "image" && x.dataBase64);
    const notes: string[] = [];
    if (images.length && !this.caps.promptCapabilities?.image) {
      // Agents without image prompts can still open a file from the workdir with their own tools.
      const dir = this.opts.attachmentsDir ?? join(this.opts.workdir, ".nuo", "attachments");
      mkdirSync(dir, { recursive: true });
      for (const img of images) {
        const ext = (img.mime.split("/")[1] ?? "bin").replace("jpeg", "jpg");
        const path = join(dir, `${crypto.randomUUID()}.${ext}`);
        writeFileSync(path, Buffer.from(img.dataBase64!, "base64"));
        notes.push(path);
      }
    }
    const body = notes.length ? `${text}\n\n[Attached image(s) saved at: ${notes.join(", ")}]` : text;
    blocks.push({ type: "text", text: this.opts.noTools ? neutralizeMentions(body) : body });
    if (this.caps.promptCapabilities?.image) {
      for (const img of images) blocks.push({ type: "image", mimeType: img.mime, data: img.dataBase64! });
    }
    return blocks;
  }

  async prompt(
    text: string,
    attachments: Attachment[],
    onEvent: (e: RunEvent) => void,
    askPermission: (ask: PermissionAsk) => Promise<string>,
  ): Promise<PromptResult> {
    if (this.closed) return { stopReason: "error", error: "session closed" };
    // A prompt takes over the work Claude started by itself: that turn ends here, the answer goes on in this one.
    if (this.unprompted) this.endUnprompted({ stopReason: "end_turn" });
    if (this.active) return { stopReason: "error", error: "a prompt is already running in this session" };
    if (this.exitInfo) return { stopReason: "error", error: this.withStderr(this.exitInfo) };

    const a: ActivePrompt = {
      onEvent: (e) => {
        try {
          onEvent(e);
        } catch {
          // a consumer failure must not break the turn
        }
      },
      askPermission,
      openTools: new Set(),
      seenTools: new Set(),
      details: new Map(),
      abort: new AbortController(),
      lastActivity: Date.now(),
      usageSeen: false,
    };
    this.active = a;
    let idleTimer: ReturnType<typeof setInterval> | undefined;
    const finish = (r: PromptResult): PromptResult => {
      const status = r.stopReason === "end_turn" ? "completed" : "failed";
      for (const id of [...a.openTools]) this.toolEnd(a, id, status);
      this.active = null;
      if (idleTimer) clearInterval(idleTimer);
      return r;
    };

    let blocks: acp.ContentBlock[];
    try {
      blocks = this.promptBlocks(text, attachments);
    } catch (e) {
      return finish({ stopReason: "error", error: `cannot prepare attachments: ${errorMessage(e)}` });
    }

    const exited = this.exited.then((info) => ({ kind: "exit" as const, info }));
    const idle = new Promise<{ kind: "idle" }>((r) => {
      idleTimer = setInterval(() => {
        if (Date.now() - a.lastActivity > this.timeouts.promptIdleMs) r({ kind: "idle" });
      }, Math.min(5_000, this.timeouts.promptIdleMs));
    });
    const request = this.conn.agent
      .request("session/prompt", { sessionId: this.sessionId, prompt: blocks })
      .then((r) => ({ kind: "done" as const, r }))
      .catch((e: unknown) => ({ kind: "fail" as const, e }));

    let outcome = await Promise.race([request, exited, idle]);
    let idleError: string | undefined;
    if (outcome.kind === "idle") {
      idleError = `no activity from the agent for ${Math.round(this.timeouts.promptIdleMs / 1000)}s`;
      await this.cancel();
      outcome = await Promise.race([request, exited]);
    }
    if (idleError) return finish({ stopReason: "error", error: idleError });
    if (outcome.kind === "done") {
      if (a.abort.signal.aborted || outcome.r.stopReason === "cancelled") return finish({ stopReason: "cancelled" });
      if (outcome.r.stopReason === "refusal") return finish({ stopReason: "error", error: "the agent refused to answer" });
      const usage = a.usageSeen ? undefined : usageFromPromptResponse(outcome.r);
      if (usage) this.usage = usage;
      return finish({ stopReason: "end_turn", ...(usage ? { usage } : {}) });
    }
    if (a.abort.signal.aborted) return finish({ stopReason: "cancelled" });
    if (outcome.kind === "fail") {
      // When the process died, the connection error is less useful than the exit status.
      const died = await Promise.race([exited, new Promise<null>((r) => setTimeout(() => r(null), 300))]);
      if (died) return finish({ stopReason: "error", error: this.withStderr(died.info) });
      return finish({ stopReason: "error", error: this.withStderr(errorMessage(outcome.e)) });
    }
    return finish({ stopReason: "error", error: this.withStderr((outcome as { info: string }).info) });
  }

  async steer(text: string, attachments: Attachment[]): Promise<boolean> {
    const a = this.active;
    if (!this.steering || !a || a.abort.signal.aborted || this.exitInfo) return false;
    try {
      await this.guard(this.conn.agent.request("_session/steering", { sessionId: this.sessionId, prompt: this.promptBlocks(text, attachments) }), this.timeouts.sessionMs, "_session/steering");
      a.lastActivity = Date.now();
      return true;
    } catch (e) {
      console.warn(`[acp] steering refused, the turn will be restarted: ${errorMessage(e)}`);
      return false;
    }
  }

  async cancel(): Promise<void> {
    const a = this.active;
    if (!a || a.abort.signal.aborted) return;
    a.abort.abort();
    if (this.exitInfo) return;
    try {
      await this.conn.agent.notify("session/cancel", { sessionId: this.sessionId });
    } catch {
      // connection already gone
    }
    // No prompt request answers work the agent started by itself: it ends here.
    if (this.unprompted?.a === a) return this.endUnprompted({ stopReason: "cancelled" });
    // An agent that ignores session/cancel is killed so the turn still ends.
    const child = this.child;
    setTimeout(() => {
      if (this.active === a && !this.exitInfo) void killTree(child, this.timeouts.killGraceMs);
    }, this.timeouts.cancelGraceMs);
  }

  private async teardown() {
    if (!this.child) return;
    if (!this.exitInfo && this.sessionId && this.caps.sessionCapabilities?.close) {
      try {
        await withTimeout(this.conn.agent.request("session/close", { sessionId: this.sessionId }), 2_000, "session/close");
      } catch {
        // best effort
      }
    }
    try {
      this.conn?.close();
    } catch {
      // ignore
    }
    await killTree(this.child, this.timeouts.killGraceMs);
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    if (this.active) {
      this.active.abort.abort();
    }
    this.endUnprompted({ stopReason: "cancelled" });
    await this.teardown();
  }
}

// ---------- subagent wire types ----------

interface RfdSubagentUpdate {
  sessionId: string;
  title?: string | null;
  description?: string | null;
  state?: { state?: string; stopReason?: string } | null;
}

interface XaiNotification {
  sessionId?: string;
  update?: { sessionUpdate?: string; child_session_id?: unknown; subagent_type?: unknown; status?: unknown };
}

function blocksText(content: unknown): string {
  if (!Array.isArray(content)) return "";
  return content
    .map((b) => {
      const block = (b as { type?: string; content?: unknown })?.type === "content" ? (b as { content?: unknown }).content : b;
      return (block as { type?: string; text?: unknown })?.type === "text" && typeof (block as { text?: unknown }).text === "string" ? (block as { text: string }).text : "";
    })
    .filter(Boolean)
    .join("\n\n")
    .trim();
}

function claudeMeta(u: unknown): { toolName?: unknown; toolResponse?: { handbackReport?: { text?: unknown } } } | undefined {
  return (u as { _meta?: { claudeCode?: ReturnType<typeof claudeMeta> } | null })._meta?.claudeCode ?? undefined;
}

function claudeToolName(u: unknown): unknown {
  return claudeMeta(u)?.toolName;
}

/** Claude: the report a subagent handed back, copied into the result of the call that launched it. */
function handbackReport(u: unknown): string | undefined {
  const text = claudeMeta(u)?.toolResponse?.handbackReport?.text;
  return typeof text === "string" && text.trim() ? text.trim() : undefined;
}

/** The text a finished tool call returned: its content blocks, or a text raw output. */
function toolResultText(u: { content?: unknown; rawOutput?: unknown }): string {
  const fromContent = blocksText(u.content);
  if (fromContent) return fromContent;
  if (typeof u.rawOutput === "string") return u.rawOutput.trim();
  return blocksText((u.rawOutput as { content?: unknown } | undefined)?.content);
}

export function rfdState(s: { state?: string; stopReason?: string }): SubagentState | undefined {
  switch (s.state) {
    case "running":
      return "running";
    case "requires_action":
      return "waiting";
    case "idle":
      return s.stopReason === "cancelled" ? "cancelled" : s.stopReason && s.stopReason !== "end_turn" ? "failed" : "completed";
    case "failed":
    case "error":
      return "failed";
    case "cancelled":
      return "cancelled";
    default:
      return undefined;
  }
}

// ---------- runtime ----------

export interface Status {
  available: boolean;
  authenticated: boolean;
  note?: string;
}

export abstract class AcpRuntime implements AgentRuntime {
  abstract readonly id: AgentId;
  abstract readonly name: string;
  readonly toolless: boolean = false;
  protected timeouts: Partial<Timeouts> = {};
  protected restartForModel = false;
  private modelsCache: { at: number; models: ModelInfo[] } | null = null;
  private modelsProbe: Promise<ModelInfo[]> | null = null;

  constructor(protected readonly host: AgentHost = LOCAL_HOST) {}

  /** Command line for the ACP agent process. Throws when the binary is missing. */
  protected abstract spawnSpec(model?: string, effort?: string): Promise<SpawnSpec>;
  abstract status(): Promise<Status>;
  /** Models used when the agent cannot be asked (not installed, not logged in, probe failed). */
  protected abstract fallbackModels(): Promise<ModelInfo[]>;

  protected sessionMeta(_opts: SessionOptions): Record<string, unknown> | undefined {
    return undefined;
  }

  protected modeFor(_policy: PermissionPolicy, _modes: SelectOption[]): string | undefined {
    return undefined;
  }

  protected async authMethod(_methods: acp.AuthMethod[]): Promise<string | undefined> {
    return undefined;
  }

  /** Id exposed to clients for a model option; `resolveOption` maps it back to the agent value. */
  protected canonicalModelId(option: SelectOption): string {
    return option.value;
  }

  protected hooks(): AcpSessionHooks {
    return {
      spawnSpec: (m, e) => this.spawnSpec(m, e),
      sessionMeta: (o) => this.sessionMeta(o),
      modeFor: (p, m) => this.modeFor(p, m),
      authMethod: (m) => this.authMethod(m),
      restartForModel: this.restartForModel,
      timeouts: this.timeouts,
      host: this.host,
    };
  }

  async start(opts: SessionOptions): Promise<AgentSession> {
    if (opts.noTools && !this.toolless) throw new Error(`${this.name} cannot run without tools`);
    const session = new AcpSession(opts, this.hooks());
    session.onModelsDiscovered = (d) => {
      const models = this.modelsFrom(d);
      if (models.length) this.modelsCache = { at: Date.now(), models };
    };
    try {
      await session.open();
    } catch (e) {
      await session.close().catch(() => {});
      throw e;
    }
    return session;
  }

  modelsFrom(d: DiscoveredModels): ModelInfo[] {
    const modelOpt = configSelect(d.configOptions, "model");
    const effortOpt = configSelect(d.configOptions, "thought_level");
    const efforts = effortOpt
      ? flattenSelectOptions(effortOpt.options)
          .map((o) => o.value)
          .filter((v) => v !== "default")
      : undefined;
    const out: ModelInfo[] = [];
    const seen = new Set<string>();
    if (modelOpt) {
      const options = flattenSelectOptions(modelOpt.options);
      let current = options.find((o) => o.value === modelOpt.currentValue);
      if (current && current.value === "default" && current.description) {
        current = options.find((o) => o !== current && o.name === current!.description) ?? current;
      }
      for (const o of options) {
        if (o.value === "default") continue;
        const id = this.canonicalModelId(o);
        if (seen.has(id)) continue;
        seen.add(id);
        out.push({ id, name: o.name, ...(o === current ? { isDefault: true } : {}), ...(efforts?.length ? { efforts } : {}) });
      }
      return out;
    }
    if (d.legacy) {
      const byBase = new Map<string, ModelInfo>();
      for (const m of d.legacy.availableModels) {
        const match = /^(.*)\[([^\]]+)\]$/.exec(m.modelId);
        const base = match ? match[1]! : m.modelId;
        let info = byBase.get(base);
        if (!info) {
          info = { id: base, name: match ? m.name.replace(/\s*\([^)]*\)$/, "") : m.name };
          byBase.set(base, info);
        }
        if (match) info.efforts = [...(info.efforts ?? []), match[2]!];
        if (m.modelId === d.legacy.currentModelId) info.isDefault = true;
      }
      return [...byBase.values()];
    }
    return out;
  }

  async models(): Promise<ModelInfo[]> {
    if (this.modelsCache && Date.now() - this.modelsCache.at < MODELS_TTL_MS) return this.modelsCache.models;
    this.modelsProbe ??= this.probeModels().finally(() => {
      this.modelsProbe = null;
    });
    return this.modelsProbe;
  }

  private async probeModels(): Promise<ModelInfo[]> {
    const st = await this.status().catch(() => null);
    if (st?.available && st.authenticated) {
      const dir = this.host.kind === "local" ? join(tmpdir(), `nuo-probe-${this.id}`) : this.host.scratch();
      if (this.host.kind === "local") mkdirSync(dir, { recursive: true });
      let session: AcpSession | null = null;
      try {
        session = new AcpSession(
          { workdir: dir, model: "", mcpServers: [], permissionPolicy: "readonly" },
          { ...this.hooks(), modeFor: undefined },
        );
        let discovered: DiscoveredModels = {};
        session.onModelsDiscovered = (d) => (discovered = d);
        await session.open();
        const models = this.modelsFrom(discovered);
        if (models.length) {
          this.modelsCache = { at: Date.now(), models };
          return models;
        }
      } catch {
        // fall back below
      } finally {
        await session?.close().catch(() => {});
      }
    }
    const fallback = await this.fallbackModels();
    // Short cache for the fallback so a later login is picked up quickly.
    this.modelsCache = { at: Date.now() - MODELS_TTL_MS + 60_000, models: fallback };
    return fallback;
  }
}
