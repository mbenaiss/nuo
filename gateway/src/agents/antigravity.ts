import { head } from "../text";
import type { ChildProcess } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";
import type { Attachment, ModelInfo, PermissionPolicy } from "../protocol";
import { killTree, runQuick, trackProcess, type Status } from "./acp";
import { contextWindow } from "./context";
import { LOCAL_HOST, type AgentHost } from "./host";
import type { AgentRuntime, AgentSession, PermissionAsk, PromptResult, RunEvent, SessionOptions, UsageReport } from "./types";

const BIN = "agy";
const EFFORT_SUFFIX = /-(low|medium|high|xhigh|max)$/;
const EFFORT_ORDER = ["low", "medium", "high", "xhigh", "max"];
const STDERR_LIMIT = 16 * 1024;
const PROBE_OK_TTL_MS = 10 * 60_000;
const PROBE_FAIL_TTL_MS = 60_000;

export interface AgyTimeouts {
  /** A prompt with no output from agy for this long is cancelled and reported as an error. */
  promptIdleMs: number;
  killGraceMs: number;
  /** Upper bound handed to agy itself (`--print-timeout`), which otherwise gives up after a few minutes. */
  printTimeout: string;
}

const DEFAULT_TIMEOUTS: AgyTimeouts = { promptIdleMs: 15 * 60_000, killGraceMs: 3_000, printTimeout: "60m" };

export const FALLBACK_MODELS: ModelInfo[] = [
  { id: "gemini-3.1-pro", name: "Gemini 3.1 Pro", isDefault: true, efforts: ["low", "high"] },
  { id: "gemini-4-argon", name: "Gemini 4 Argon", efforts: ["low", "medium", "high"] },
  { id: "gemini-3.8-flash", name: "Gemini 3.8 Flash", efforts: ["low", "medium", "high"] },
  { id: "claude-opus-5-5", name: "Claude Opus 5.5", efforts: ["low", "medium", "high", "max"] },
  { id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", efforts: ["low", "medium", "high", "max"] },
  { id: "gpt-oss-120b", name: "GPT-OSS 120B" },
];

export interface AgyArgsOptions {
  prompt: string;
  model?: string;
  effort?: string;
  policy: PermissionPolicy;
  conversationId?: string;
  printTimeout?: string;
}

/**
 * Print mode cannot ask the user: a tool that needs approval is soft-denied (the turn goes on without it).
 * So `auto` skips approvals, while `ask` and `readonly` keep agy's defaults, where file writes and commands
 * are denied. Plan mode is not used for `readonly`: it rewrites every prompt into a planning request.
 */
export function agyArgs(o: AgyArgsOptions): string[] {
  const args = ["--print", o.prompt, "--output-format", "stream-json"];
  if (o.printTimeout) args.push("--print-timeout", o.printTimeout);
  if (o.conversationId) args.push("--conversation", o.conversationId);
  if (o.model) args.push("--model", o.model);
  // A model slug that already carries its effort conflicts with --effort.
  if (o.effort && !(o.model && EFFORT_SUFFIX.test(o.model))) args.push("--effort", o.effort);
  if (o.policy === "auto") args.push("--dangerously-skip-permissions");
  return args;
}

type Json = Record<string, unknown>;

const obj = (v: unknown): Json | undefined => (v && typeof v === "object" && !Array.isArray(v) ? (v as Json) : undefined);
const str = (v: unknown): string | undefined => (typeof v === "string" && v ? v : undefined);
const num = (v: unknown): number | undefined => (typeof v === "number" && Number.isFinite(v) && v >= 0 ? v : undefined);

export function toolKind(name: string): string | undefined {
  if (["run_command", "send_command_input", "notebook_execution"].includes(name)) return "execute";
  if (["write_to_file", "replace_file_content", "multi_replace_file_content", "sed_file", "notebook_edit"].includes(name)) return "edit";
  if (["view_file", "list_dir", "read_resource", "list_resources", "list_permissions"].includes(name)) return "read";
  if (["grep_search", "find_by_name", "code_search"].includes(name)) return "search";
  if (["read_url_content", "search_web"].includes(name)) return "fetch";
  if (["invoke_subagent", "define_subagent", "manage_subagents", "manage_task", "browser_subagent"].includes(name)) return "think";
  return name ? "other" : undefined;
}

/** agy runs these as subagents: only their start and end are visible in its stream. */
const SUBAGENT_TOOLS = new Set(["invoke_subagent", "browser_subagent"]);

export function subagentTitle(name: string, params: Json | undefined): string {
  const detail = params ? ["TaskName", "Task", "Name", "Description", "Prompt", "Goal"].map((k) => str(params[k])).find(Boolean) : undefined;
  if (detail) return detail.length > 80 ? `${head(detail, 77)}…` : detail;
  return name === "browser_subagent" ? "Navigateur" : "Sous-agent";
}

const TITLE_KEYS = ["CommandLine", "AbsolutePath", "TargetFile", "File", "DirectoryPath", "SearchPath", "Query", "Pattern", "Url"];

function toolTitle(name: string, params: Json | undefined): string {
  if (name === "call_mcp_tool" && params) {
    const tool = str(params.tool_name) ?? str(params.tool) ?? str(params.ToolName);
    const server = str(params.server_name) ?? str(params.server) ?? str(params.ServerName);
    if (tool) return server ? `${server}: ${tool}` : tool;
  }
  const detail = params ? TITLE_KEYS.map((k) => str(params[k])).find(Boolean) : undefined;
  if (!detail) return name || "tool";
  const short = detail.length > 80 ? `${head(detail, 77)}…` : detail;
  return name ? `${name}: ${short}` : short;
}

export interface AgyResult {
  status?: string;
  response?: string;
  error?: string;
}

/**
 * Maps agy's `--output-format stream-json` NDJSON (one `init`, `step_update`s, one `result`) to run events.
 * Unknown events and fields are ignored: the format is young and only partly documented.
 */
export class AgyStream {
  conversationId?: string;
  result?: AgyResult;
  usage?: UsageReport;
  textSeen = false;
  private readonly openTools = new Map<string, true>();
  private readonly seenTools = new Set<string>();
  private readonly subagents = new Set<string>();
  private loose = 0;

  constructor(
    private readonly prefix: string,
    private readonly emit: (e: RunEvent) => void,
    private readonly maxTokens?: number,
  ) {}

  line(raw: string) {
    const s = raw.trim();
    if (!s.startsWith("{")) return;
    let ev: Json | undefined;
    try {
      ev = obj(JSON.parse(s));
    } catch {
      return;
    }
    if (!ev) return;
    this.noteConversation(ev.conversation_id);
    switch (ev.event ?? ev.type) {
      case "step_update":
        this.step(obj(ev.step_update) ?? ev);
        break;
      case "result": {
        const r = obj(ev.result) ?? ev;
        this.noteConversation(r.conversation_id);
        this.result = { status: str(r.status), response: typeof r.response === "string" ? r.response : undefined, error: str(r.error) };
        break;
      }
    }
  }

  /** Ends the tools still open when the process is gone. */
  finish(ok: boolean) {
    for (const id of [...this.openTools.keys()]) this.toolEnd(id, ok ? "completed" : "failed");
  }

  private noteConversation(v: unknown) {
    const id = str(v);
    if (id) this.conversationId = id;
  }

  private step(s: Json) {
    this.noteConversation(s.conversation_id);
    const type = str(s.step_type) ?? "";
    const state = str(s.state);
    const thought = str(s.thinking_delta) ?? str(s.thought_delta);
    if (thought) this.emit({ type: "thought", text: thought });
    const delta = str(s.text_delta);
    if (type === "agent_response") {
      if (delta) {
        this.textSeen = true;
        this.emit({ type: "text", text: delta });
      }
      const u = obj(s.usage);
      const input = num(u?.input_tokens);
      if (state === "DONE" && input !== undefined) {
        // input_tokens already includes cache reads (total = input + output); the reply joins the context.
        this.usage = { usedTokens: input + (num(u?.output_tokens) ?? 0), ...(this.maxTokens ? { maxTokens: this.maxTokens } : {}) };
        this.emit({ type: "usage", ...this.usage });
      }
      return;
    }
    if (type === "tool") {
      this.tool(s, state);
      return;
    }
    if (delta && /think|thought|reason|plan/i.test(type)) this.emit({ type: "thought", text: delta });
  }

  private tool(s: Json, state: string | undefined) {
    const index = num(s.step_index);
    const info = obj(s.tool_info);
    const name = str(s.tool_name) ?? str(info?.name) ?? "";
    const id = `${this.prefix}-${index ?? `x${++this.loose}`}`;
    const done = state === "DONE" || state === "ERROR" || index === undefined;
    if (!this.seenTools.has(id)) {
      this.seenTools.add(id);
      this.openTools.set(id, true);
      const kind = toolKind(name);
      this.emit({ type: "tool.start", toolCallId: id, title: toolTitle(name, obj(info?.parameters)), ...(kind ? { kind } : {}) });
      if (SUBAGENT_TOOLS.has(name)) {
        this.subagents.add(id);
        this.emit({ type: "subagent", id, title: subagentTitle(name, obj(info?.parameters)), state: "running" });
      }
    }
    if (done) this.toolEnd(id, state === "ERROR" || info?.error ? "failed" : "completed");
  }

  private toolEnd(id: string, status: "completed" | "failed") {
    if (!this.openTools.delete(id)) return;
    this.emit({ type: "tool.end", toolCallId: id, status });
    if (this.subagents.delete(id)) this.emit({ type: "subagent", id, state: status });
  }
}

/** `agy models`: tab-separated `slug<TAB>name` lines, with one line per effort for models that have them; JSON also accepted. */
export function parseAgyModels(out: string): ModelInfo[] {
  const rows: { id: string; name: string }[] = [];
  const text = out.trim();
  if (text.startsWith("[") || text.startsWith("{")) {
    try {
      const parsed = JSON.parse(text) as unknown;
      const list = Array.isArray(parsed) ? parsed : ((obj(parsed)?.models as unknown[]) ?? []);
      for (const m of list) {
        const o = obj(m);
        const id = str(o?.id) ?? str(o?.slug) ?? str(o?.model) ?? str(o?.model_id);
        if (id) rows.push({ id, name: str(o?.name) ?? str(o?.display_name) ?? str(o?.displayName) ?? id });
      }
    } catch {
      // not JSON after all
    }
  } else {
    for (const raw of text.split("\n")) {
      const line = raw.trim();
      if (!line || /^(fetching|available|error)/i.test(line)) continue;
      const [id, name] = line.split("\t").map((x) => x.trim());
      if (id && /^[\w.\-]+$/.test(id)) rows.push({ id, name: name || id });
    }
  }
  const byBase = new Map<string, ModelInfo>();
  for (const r of rows) {
    const m = EFFORT_SUFFIX.exec(r.id);
    const base = m ? r.id.slice(0, -m[0].length) : r.id;
    let info = byBase.get(base);
    if (!info) {
      const name = r.name.replace(/\s*\((low|medium|high|xhigh|max)\)\s*$/i, "").trim() || base;
      info = { id: base, name };
      byBase.set(base, info);
    }
    if (m) info.efforts = [...new Set([...(info.efforts ?? []), m[1]!])].sort((a, b) => EFFORT_ORDER.indexOf(a) - EFFORT_ORDER.indexOf(b));
  }
  const models = [...byBase.values()];
  if (models[0]) models[0].isDefault = true;
  return models;
}

function saveImages(opts: SessionOptions, attachments: Attachment[]): string[] {
  const images = attachments.filter((x) => x.kind === "image" && x.dataBase64);
  if (!images.length) return [];
  const dir = opts.attachmentsDir ?? join(opts.workdir, ".nuo", "attachments");
  mkdirSync(dir, { recursive: true });
  return images.map((img) => {
    const ext = (img.mime.split("/")[1] ?? "bin").replace("jpeg", "jpg");
    const path = join(dir, `${crypto.randomUUID()}.${ext}`);
    writeFileSync(path, Buffer.from(img.dataBase64!, "base64"));
    return path;
  });
}

/** One `agy --print` process per prompt; the conversation carries over with `--conversation`. */
export class AntigravitySession implements AgentSession {
  private conversationId: string;
  private model?: string;
  private effort?: string;
  private child: ChildProcess | null = null;
  private cancelled = false;
  private closed = false;
  private turns = 0;

  constructor(
    private readonly opts: SessionOptions,
    private readonly bin: string,
    private readonly host: AgentHost,
    private readonly timeouts: AgyTimeouts,
  ) {
    this.conversationId = opts.resumeId ?? "";
    this.model = opts.model || undefined;
    this.effort = opts.effort;
  }

  get agentSessionId(): string {
    return this.conversationId;
  }

  async prompt(
    text: string,
    attachments: Attachment[],
    onEvent: (e: RunEvent) => void,
    _askPermission: (ask: PermissionAsk) => Promise<string>,
  ): Promise<PromptResult> {
    if (this.closed) return { stopReason: "error", error: "session closed" };
    if (this.child) return { stopReason: "error", error: "a prompt is already running in this session" };
    let body = text;
    try {
      const saved = saveImages(this.opts, attachments);
      if (saved.length) body = `${text}\n\n[Attached image(s) saved at: ${saved.join(", ")}]`;
    } catch (e) {
      return { stopReason: "error", error: `cannot prepare attachments: ${e instanceof Error ? e.message : String(e)}` };
    }
    const emit = (e: RunEvent) => {
      try {
        onEvent(e);
      } catch {
        // a consumer failure must not break the turn
      }
    };
    const stream = new AgyStream(`t${++this.turns}`, emit, contextWindow("gemini", this.model));
    const args = agyArgs({
      prompt: body,
      model: this.model,
      effort: this.effort,
      policy: this.opts.permissionPolicy,
      conversationId: this.conversationId || undefined,
      printTimeout: this.timeouts.printTimeout,
    });

    let child: ChildProcess;
    try {
      child = this.host.spawn(this.bin, args, { cwd: this.opts.workdir, stdio: ["ignore", "pipe", "pipe"], detached: true });
    } catch (e) {
      return { stopReason: "error", error: `cannot start ${this.bin}: ${e instanceof Error ? e.message : String(e)}` };
    }
    this.child = child;
    this.cancelled = false;
    trackProcess(child);

    let stderr = "";
    let lastActivity = Date.now();
    let idle = false;
    child.stderr?.on("data", (d: Buffer) => {
      stderr = (stderr + d.toString()).slice(-STDERR_LIMIT);
    });
    const lines = createInterface({ input: child.stdout!, crlfDelay: Infinity });
    lines.on("line", (l) => {
      lastActivity = Date.now();
      stream.line(l);
    });
    const idleTimer = setInterval(() => {
      if (Date.now() - lastActivity > this.timeouts.promptIdleMs && !idle) {
        idle = true;
        void killTree(child, this.timeouts.killGraceMs);
      }
    }, Math.min(5_000, this.timeouts.promptIdleMs));

    const exit = await new Promise<{ code: number | null; signal: NodeJS.Signals | null; error?: string }>((resolve) => {
      child.once("error", (e) => resolve({ code: null, signal: null, error: e.message }));
      child.once("close", (code, signal) => resolve({ code, signal }));
    });
    clearInterval(idleTimer);
    lines.close();
    // Also reaps tool processes agy may have left in its group.
    void killTree(child, 0);
    this.child = null;
    if (stream.conversationId) this.conversationId = stream.conversationId;

    const tail = stderr.trim().slice(-1500);
    const withStderr = (msg: string) => (tail ? `${msg}\nstderr: ${tail}` : msg);
    const r = stream.result;
    const finish = (res: PromptResult): PromptResult => {
      stream.finish(res.stopReason === "end_turn");
      return res;
    };

    if (this.cancelled) return finish({ stopReason: "cancelled" });
    if (idle) return finish({ stopReason: "error", error: `no activity from the agent for ${Math.round(this.timeouts.promptIdleMs / 1000)}s` });
    if (exit.error) return finish({ stopReason: "error", error: `cannot start ${this.bin}: ${exit.error}` });
    if (r?.status === "CANCELED" || r?.status === "INTERRUPTED") return finish({ stopReason: "cancelled" });
    if (!stream.textSeen && r?.response?.trim()) {
      stream.textSeen = true;
      emit({ type: "text", text: r.response });
    }
    const usage = stream.usage ? { usage: stream.usage } : {};
    // A trailing error after a delivered reply (quota hit while closing, stream teardown) does not void the reply.
    if (r && (r.status === "SUCCESS" || stream.textSeen)) return finish({ stopReason: "end_turn", ...usage });
    if (r) return finish({ stopReason: "error", error: withStderr(r.error ?? `agy finished with status ${r.status ?? "unknown"}`) });
    if (exit.code === 0 && stream.textSeen) return finish({ stopReason: "end_turn", ...usage });
    return finish({ stopReason: "error", error: withStderr(`agent process exited (${exit.signal ?? `code ${exit.code}`})`) });
  }

  async cancel(): Promise<void> {
    const child = this.child;
    if (!child || this.cancelled) return;
    this.cancelled = true;
    await killTree(child, this.timeouts.killGraceMs);
  }

  async setModel(model: string, effort?: string): Promise<void> {
    if (this.closed) throw new Error("session closed");
    this.model = model || undefined;
    this.effort = effort;
  }

  async close(): Promise<void> {
    if (this.closed) return;
    await this.cancel();
    this.closed = true;
  }
}

export class AntigravityRuntime implements AgentRuntime {
  // Antigravity replaced the Gemini CLI: it keeps the "gemini" id so bots and the app see the same agent.
  readonly id = "gemini" as const;
  readonly name = "Gemini";
  private probe: { at: number; ttl: number; p: Promise<ModelInfo[] | null> } | null = null;

  constructor(
    private readonly host: AgentHost = LOCAL_HOST,
    private readonly timeouts: Partial<AgyTimeouts> = {},
  ) {}

  /** API-key mode needs both the key and `"modelProvider": "gemini"` in the CLI settings. */
  private apiKeyMode(): boolean {
    if (!this.host.env("GEMINI_API_KEY")) return false;
    try {
      const s = JSON.parse(readFileSync(join(this.host.home, ".gemini", "antigravity-cli", "settings.json"), "utf8")) as { modelProvider?: string };
      return s.modelProvider === "gemini";
    } catch {
      return false;
    }
  }

  /**
   * Google sign-in lives in the OS keyring, which cannot be checked from here: `agy models` succeeds only
   * when the CLI is signed in, so it doubles as the login check.
   */
  private listModels(bin: string): Promise<ModelInfo[] | null> {
    if (this.probe && Date.now() - this.probe.at < this.probe.ttl) return this.probe.p;
    const p = runQuick(bin, ["models"], 30_000, this.host).then((r) => {
      const models = r.code === 0 ? parseAgyModels(r.stdout) : [];
      if (this.probe?.p === p) this.probe.ttl = models.length ? PROBE_OK_TTL_MS : PROBE_FAIL_TTL_MS;
      return models.length ? models : null;
    });
    this.probe = { at: Date.now(), ttl: PROBE_OK_TTL_MS, p };
    return p;
  }

  async status(): Promise<Status> {
    const bin = this.host.which(BIN);
    if (!bin) return { available: false, authenticated: false, note: "install the Antigravity CLI (agy)" };
    if (await this.listModels(bin)) return { available: true, authenticated: true };
    if (this.apiKeyMode()) return { available: true, authenticated: true, note: "GEMINI_API_KEY" };
    return { available: true, authenticated: false, note: "run `agy` once and sign in with Google, or set GEMINI_API_KEY with modelProvider gemini" };
  }

  async models(): Promise<ModelInfo[]> {
    const bin = this.host.which(BIN);
    return (bin && (await this.listModels(bin))) || FALLBACK_MODELS;
  }

  async start(opts: SessionOptions): Promise<AgentSession> {
    if (opts.noTools) throw new Error(`${this.name} cannot run without tools`);
    const bin = this.host.which(BIN);
    if (!bin) throw new Error("agy is not installed (Antigravity CLI)");
    return new AntigravitySession(opts, bin, this.host, { ...DEFAULT_TIMEOUTS, ...this.timeouts });
  }
}
