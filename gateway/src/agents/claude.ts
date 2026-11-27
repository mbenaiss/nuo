import { existsSync, readdirSync, renameSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ModelInfo } from "../protocol";
import { AcpRuntime, runQuick, type SpawnSpec, type Status } from "./acp";
import { ClaudeAuthSession, DEFAULT_RETRY_DELAYS_MS } from "./claude-auth";
import type { AgentSession, SessionOptions } from "./types";
import { RELAY_BUILTIN_TOOLS } from "../relay/whitelist";

const ADAPTER = "claude-agent-acp";
const EFFORTS = ["low", "medium", "high"];
/**
 * The built-in tools bots use; Claude Code's others (Workflow, Cron*, Task*, worktrees, LSP…) were never called
 * and cost ~14k tokens of context per session. A list of what to keep, so a new built-in stays out until chosen.
 * ToolSearch loads the MCP tools (nuo, lightpanda…) on first use instead of ~22k tokens of schemas up front.
 */
export const BOT_BUILTIN_TOOLS = ["Bash", "Read", "Edit", "Write", "WebFetch", "WebSearch", "Agent", "SendMessage", "Monitor", "TaskStop", "Skill", "ToolSearch"];

/**
 * Set per session, above the agent process's environment, so profiles get them whatever their launcher passes.
 * The claude.ai connectors of the logged-in account (Notion, Claude Docs…) are not bot tools.
 */
export const BOT_CLAUDE_ENV = { ENABLE_TOOL_SEARCH: "true", ENABLE_CLAUDEAI_MCP_SERVERS: "false" };
/** Claude Code's own system prompt is in English: without a language, the short updates between two tool calls drift to it. */
export const DEFAULT_BOT_LANGUAGE = "French";

/** Claude Code keeps sessions per cwd, in projects/<cwd with every non-alphanumeric char as "-">. */
export function claudeProjectDir(cwd: string, configDir = process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude")): string {
  return join(configDir, "projects", cwd.replace(/[^a-zA-Z0-9]/g, "-"));
}

/** Moves a folder's session history along with it so its conversations can still be resumed. */
export function moveClaudeProject(fromCwd: string, toCwd: string, configDir?: string) {
  const from = claudeProjectDir(fromCwd, configDir);
  const to = claudeProjectDir(toCwd, configDir);
  if (from === to || !existsSync(from)) return;
  if (!existsSync(to)) return renameSync(from, to);
  for (const f of readdirSync(from)) if (!existsSync(join(to, f))) renameSync(join(from, f), join(to, f));
}

export class ClaudeRuntime extends AcpRuntime {
  readonly id = "claude" as const;
  readonly name = "Claude Code";
  readonly toolless = true;

  protected async spawnSpec(): Promise<SpawnSpec> {
    const bin = this.host.which(ADAPTER);
    if (!bin) throw new Error(`${ADAPTER} is not installed (npm i -g @agentclientprotocol/claude-agent-acp)`);
    return { command: bin, args: [] };
  }

  /**
   * Only the MCP servers the gateway passes (nuo, the bot's own, lightpanda): the gateway user's own Claude
   * config is not the bots'. Prompt suggestions cost a request per turn for a predicted follow-up the app never shows.
   * A relay session's instructions come in the system prompt: its folder holds no CLAUDE.md (src/runner/runner.ts).
   */
  protected sessionMeta(opts: SessionOptions): Record<string, unknown> {
    const tools = opts.noTools ? [] : opts.relay ? RELAY_BUILTIN_TOOLS : BOT_BUILTIN_TOOLS;
    return {
      claudeCode: { options: { tools, env: BOT_CLAUDE_ENV, settings: { language: opts.language ?? DEFAULT_BOT_LANGUAGE }, promptSuggestions: false, extraArgs: { "strict-mcp-config": null } } },
      ...(opts.relay && opts.instructions ? { systemPrompt: { append: opts.instructions } } : {}),
    };
  }

  async start(opts: SessionOptions): Promise<AgentSession> {
    const profileHome = this.host.kind === "profile" ? this.host.home : undefined;
    return new ClaudeAuthSession(await super.start(opts), { retryDelaysMs: DEFAULT_RETRY_DELAYS_MS, profileHome });
  }

  async status(): Promise<Status> {
    if (!this.host.which(ADAPTER)) {
      return { available: false, authenticated: false, note: "npm i -g @agentclientprotocol/claude-agent-acp" };
    }
    const cli = this.host.which("claude");
    if (cli) {
      const r = await runQuick(cli, ["auth", "status"], 10_000, this.host);
      try {
        const s = JSON.parse(r.stdout) as { loggedIn?: boolean; authMethod?: string; subscriptionType?: string };
        if (s.loggedIn) {
          return { available: true, authenticated: true, note: [s.authMethod, s.subscriptionType].filter(Boolean).join(" ") || undefined };
        }
        return { available: true, authenticated: !!this.host.env("ANTHROPIC_API_KEY"), note: "run `claude` then /login" };
      } catch {
        // older CLI without JSON output: fall through to the credentials file
      }
    }
    const creds = existsSync(join(this.host.env("CLAUDE_CONFIG_DIR") ?? join(this.host.home, ".claude"), ".credentials.json"));
    const ok = creds || !!this.host.env("ANTHROPIC_API_KEY") || !!this.host.env("CLAUDE_CODE_OAUTH_TOKEN");
    return { available: true, authenticated: ok, ...(ok ? {} : { note: "run `claude` then /login" }) };
  }

  /** Exposes aliases like `opus` ("Opus 5.5") under stable ids such as `claude-opus-5-5`. */
  protected canonicalModelId(option: { value: string; name: string }): string {
    const m = /^(opus|sonnet|haiku|fable)\s+([\d.]+)$/i.exec(option.name.trim());
    if (m) return `claude-${m[1]!.toLowerCase()}-${m[2]!.replace(/\./g, "-")}`;
    return option.value.replace(/-\d{8}$/, "");
  }

  protected async fallbackModels(): Promise<ModelInfo[]> {
    return [
      { id: "claude-opus-5-5", name: "Opus 5.5", isDefault: true, efforts: EFFORTS },
      { id: "claude-sonnet-5", name: "Sonnet 5", efforts: EFFORTS },
      { id: "claude-haiku-4-5", name: "Haiku 4.5" },
      { id: "claude-opus-4-8", name: "Opus 4.8", efforts: EFFORTS },
    ];
  }
}
