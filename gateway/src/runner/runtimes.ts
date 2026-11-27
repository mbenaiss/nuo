import type { AgentRuntime } from "../agents/types";
import type { AgentInfo } from "../protocol";

export interface Runtimes {
  get(id: string): AgentRuntime | undefined;
  all(): AgentRuntime[];
}

export function runtimesFrom(list: AgentRuntime[]): Runtimes {
  return { get: (id) => list.find((r) => r.id === id), all: () => list };
}

const INFO_TTL_MS = 60_000;
const DESCRIBE_TIMEOUT_MS = 5_000;

/** Agent status probes spawn CLIs, so results are cached briefly. */
export class AgentDirectory {
  private cache?: { at: number; info: Promise<AgentInfo[]> };

  constructor(
    readonly runtimes: Runtimes,
    private readonly describeTimeoutMs = DESCRIBE_TIMEOUT_MS,
  ) {}

  info(): Promise<AgentInfo[]> {
    if (!this.cache || Date.now() - this.cache.at > INFO_TTL_MS) {
      const info = Promise.all(this.runtimes.all().map((rt) => describe(rt, this.describeTimeoutMs)));
      this.cache = { at: Date.now(), info };
      info.catch(() => (this.cache = undefined));
    }
    return this.cache.info;
  }

  async defaultModel(id: string): Promise<string> {
    const rt = this.runtimes.get(id);
    if (!rt) return "";
    const models = await rt.models().catch(() => []);
    return (models.find((m) => m.isDefault) ?? models[0])?.id ?? "";
  }
}

/** One hung CLI must not hold back the others: past the timeout the agent is listed as not responding. */
async function describe(rt: AgentRuntime, timeoutMs: number): Promise<AgentInfo> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<null>((resolve) => (timer = setTimeout(() => resolve(null), timeoutMs)));
  const probe = Promise.all([
    rt.status().catch((e) => ({ available: false, authenticated: false, note: String(e?.message ?? e) })),
    rt.models().catch(() => []),
  ]);
  const done = await Promise.race([probe, timeout]).finally(() => clearTimeout(timer));
  if (!done) return { id: rt.id, name: rt.name, available: false, authenticated: false, note: "not responding", models: [] };
  const [status, models] = done;
  return { id: rt.id, name: rt.name, ...status, models };
}
