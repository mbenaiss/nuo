import { readFileSync } from "node:fs";
import { join } from "node:path";
import type { ModelInfo } from "../protocol";
import { AcpRuntime, runQuick, type SpawnSpec, type Status } from "./acp";
import type { AgentHost } from "./host";
import type { SessionOptions } from "./types";

const EFFORTS = ["low", "medium", "high", "xhigh"];

function hasCachedToken(host: AgentHost): boolean {
  try {
    const auth = JSON.parse(readFileSync(join(host.home, ".grok", "auth.json"), "utf8")) as unknown;
    return !!auth && typeof auth === "object" && Object.keys(auth).length > 0;
  } catch {
    return false;
  }
}

function workdirRules(workdir: string): string | undefined {
  for (const name of ["AGENTS.md", "CLAUDE.md"]) {
    try {
      const text = readFileSync(join(workdir, name), "utf8").trim();
      if (text) return text;
    } catch {
      // try the next name
    }
  }
  return undefined;
}

export function parseGrokModels(out: string): ModelInfo[] {
  const models: ModelInfo[] = [];
  for (const line of out.split("\n")) {
    const m = /^\s*([*-])\s+([\w.\-]+)(\s+\(default\))?\s*$/.exec(line);
    if (m) models.push({ id: m[2]!, name: m[2]!, ...(m[1] === "*" || m[3] ? { isDefault: true } : {}), efforts: EFFORTS });
  }
  return models;
}

export class GrokRuntime extends AcpRuntime {
  readonly id = "grok" as const;
  readonly name = "Grok";
  protected restartForModel = true;

  protected async spawnSpec(model?: string, effort?: string): Promise<SpawnSpec> {
    const bin = this.host.which("grok");
    if (!bin) throw new Error("grok is not installed");
    const args = ["agent", "--no-leader"];
    if (model) args.push("--model", model);
    if (effort) args.push("--reasoning-effort", effort);
    args.push("stdio");
    return { command: bin, args };
  }

  protected sessionMeta(opts: SessionOptions): Record<string, unknown> | undefined {
    const meta: Record<string, unknown> = {};
    if (opts.permissionPolicy === "auto") meta.yoloMode = true;
    // Grok ignores AGENTS.md in folders the user never trusted interactively, which bot workdirs are.
    const rules = workdirRules(opts.workdir);
    if (rules) meta.rules = rules;
    return Object.keys(meta).length ? meta : undefined;
  }

  async status(): Promise<Status> {
    const bin = this.host.which("grok");
    if (!bin) return { available: false, authenticated: false, note: "grok CLI not installed" };
    const r = await runQuick(bin, ["models"], 15_000, this.host);
    const out = `${r.stdout}\n${r.stderr}`;
    if (/not (authenticated|logged in)|please (log|sign) in|grok login/i.test(out)) {
      return { available: true, authenticated: false, note: "run `grok login`" };
    }
    if (/logged in/i.test(out)) return { available: true, authenticated: true };
    const ok = hasCachedToken(this.host);
    return { available: true, authenticated: ok, ...(ok ? {} : { note: "run `grok login`" }) };
  }

  protected async fallbackModels(): Promise<ModelInfo[]> {
    const bin = this.host.which("grok");
    if (bin) {
      const parsed = parseGrokModels((await runQuick(bin, ["models"], 15_000, this.host)).stdout);
      if (parsed.length) return parsed;
    }
    return [
      { id: "grok-4.7", name: "Grok 4.7", isDefault: true, efforts: EFFORTS },
      { id: "grok-4.7-build-fast", name: "Grok 4.7 Fast", efforts: EFFORTS },
      { id: "grok-4.6", name: "Grok 4.6", efforts: EFFORTS },
    ];
  }
}
