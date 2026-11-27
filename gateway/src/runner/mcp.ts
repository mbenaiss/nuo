import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import type { McpServerSpec } from "../agents/types";

export interface ToolContent {
  type: string;
  text?: string;
  data?: string;
  mimeType?: string;
}

export interface ToolCallResult {
  content: ToolContent[];
  isError?: boolean;
}

interface Entry {
  key: string;
  client: Promise<Client>;
  schemas?: Map<string, Record<string, { type?: string | string[] }>>;
  lastUsed: number;
  busy: number;
}

export const MCP_IDLE_MS = 5 * 60 * 1000;
const CALL_TIMEOUT_MS = 3 * 60 * 1000;

/** One stdio MCP client per server spec, reused across slash commands and closed when idle. */
export class McpPool {
  private entries = new Map<string, Entry>();
  private sweeper: ReturnType<typeof setInterval>;

  constructor(private idleMs = MCP_IDLE_MS) {
    this.sweeper = setInterval(() => this.closeIdle(), Math.min(30_000, idleMs));
    this.sweeper.unref?.();
  }

  get size() {
    return this.entries.size;
  }

  async call(spec: McpServerSpec, tool: string, args: Record<string, unknown>, signal?: AbortSignal): Promise<ToolCallResult> {
    const entry = this.entry(spec);
    entry.busy++;
    entry.lastUsed = Date.now();
    try {
      const client = await entry.client;
      const schema = await this.schema(entry, client, tool);
      const result = await client.callTool({ name: tool, arguments: coerce(args, schema) }, undefined, { timeout: CALL_TIMEOUT_MS, signal });
      return { content: (result.content ?? []) as ToolContent[], isError: result.isError === true };
    } catch (e) {
      // A dead or wedged server must not poison later calls.
      if (!signal?.aborted) this.drop(entry);
      throw e;
    } finally {
      entry.busy--;
      entry.lastUsed = Date.now();
    }
  }

  async closeAll() {
    clearInterval(this.sweeper);
    await Promise.all([...this.entries.values()].map((e) => this.drop(e)));
  }

  private entry(spec: McpServerSpec): Entry {
    const key = JSON.stringify([spec.name, spec.command, spec.args, spec.env]);
    const existing = this.entries.get(key);
    if (existing) return existing;
    const entry: Entry = { key, client: this.connect(spec), lastUsed: Date.now(), busy: 0 };
    entry.client.catch(() => this.entries.get(key) === entry && this.entries.delete(key));
    this.entries.set(key, entry);
    return entry;
  }

  private async connect(spec: McpServerSpec): Promise<Client> {
    const transport = new StdioClientTransport({ command: spec.command, args: spec.args, env: spec.env, stderr: "ignore" });
    const client = new Client({ name: "nuo-gateway", version: "1.0.0" });
    await client.connect(transport, { timeout: 30_000 });
    return client;
  }

  private async schema(entry: Entry, client: Client, tool: string) {
    if (!entry.schemas) {
      entry.schemas = new Map();
      const { tools } = await client.listTools(undefined, { timeout: 30_000 });
      for (const t of tools) entry.schemas.set(t.name, (t.inputSchema?.properties ?? {}) as Record<string, { type?: string | string[] }>);
    }
    return entry.schemas.get(tool) ?? {};
  }

  private async drop(entry: Entry) {
    if (this.entries.get(entry.key) === entry) this.entries.delete(entry.key);
    const client = await entry.client.catch(() => undefined);
    await client?.close().catch(() => {});
  }

  private closeIdle() {
    const cutoff = Date.now() - this.idleMs;
    for (const e of this.entries.values()) if (e.busy === 0 && e.lastUsed < cutoff) void this.drop(e);
  }
}

/** Typed words arrive as strings; numeric or boolean parameters are converted when the schema says so. */
function coerce(args: Record<string, unknown>, props: Record<string, { type?: string | string[] }>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(args)) {
    const types = [props[k]?.type ?? []].flat();
    if (typeof v === "string" && (types.includes("number") || types.includes("integer")) && v.trim() !== "" && Number.isFinite(Number(v))) out[k] = Number(v);
    else if (typeof v === "string" && types.includes("boolean") && /^(true|false)$/i.test(v)) out[k] = v.toLowerCase() === "true";
    else if (typeof v === "string" && types.includes("array") && !types.includes("string")) out[k] = v.split(/[\s,]+/).filter(Boolean);
    else out[k] = v;
  }
  return out;
}
