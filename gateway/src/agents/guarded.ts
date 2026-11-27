import type { ModelInfo } from "../protocol";
import type { AgentHost } from "./host";
import type { AgentRuntime, AgentSession, SessionOptions } from "./types";

/** Refuses to start (or even probe) an agent while its host is not ready: a profile's Linux user must exist first. */
export class GuardedRuntime implements AgentRuntime {
  constructor(
    private readonly inner: AgentRuntime,
    private readonly host: AgentHost,
  ) {}

  get id() {
    return this.inner.id;
  }

  get name() {
    return this.inner.name;
  }

  get toolless() {
    return this.inner.toolless;
  }

  async status() {
    const r = await this.host.ready();
    if (!r.ok) return { available: false, authenticated: false, note: r.reason };
    return this.inner.status();
  }

  async models(): Promise<ModelInfo[]> {
    return (await this.host.ready()).ok ? this.inner.models() : [];
  }

  async start(opts: SessionOptions): Promise<AgentSession> {
    const r = await this.host.ready();
    if (!r.ok) throw new Error(r.reason ?? "this profile cannot run agents yet");
    return this.inner.start(opts);
  }
}
