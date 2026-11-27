import type { AgentId } from "../protocol";
import { AntigravityRuntime } from "./antigravity";
import { ClaudeRuntime } from "./claude";
import { CodexRuntime } from "./codex";
import { GrokRuntime } from "./grok";
import type { AgentRuntime } from "./types";
import type { AgentHost } from "./host";
import { GuardedRuntime } from "./guarded";
import { runtimesFrom, type Runtimes } from "../runner/runtimes";

const runtimes: Record<AgentId, AgentRuntime> = {
  claude: new ClaudeRuntime(),
  codex: new CodexRuntime(),
  grok: new GrokRuntime(),
  gemini: new AntigravityRuntime(),
};

export function getRuntime(id: AgentId): AgentRuntime {
  return runtimes[id];
}

export function allRuntimes(): AgentRuntime[] {
  return Object.values(runtimes);
}

/** A profile's own agents: same CLIs, run as its Linux user with its own logins, refused until that user is set up. */
export function runtimesFor(host: AgentHost): Runtimes {
  return runtimesFrom([new ClaudeRuntime(host), new CodexRuntime(host), new GrokRuntime(host), new AntigravityRuntime(host)].map((r) => new GuardedRuntime(r, host)));
}
