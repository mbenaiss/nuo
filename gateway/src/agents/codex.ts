import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { ModelInfo, PermissionPolicy } from "../protocol";
import { AcpRuntime, runQuick, type SpawnSpec, type Status } from "./acp";

const ADAPTER = "codex-acp";

export class CodexRuntime extends AcpRuntime {
  readonly id = "codex" as const;
  readonly name = "Codex";

  private codexHome(): string {
    return this.host.env("CODEX_HOME") ?? join(this.host.home, ".codex");
  }

  protected async spawnSpec(): Promise<SpawnSpec> {
    const bin = this.host.which(ADAPTER);
    if (!bin) throw new Error(`${ADAPTER} is not installed (npm i -g @agentclientprotocol/codex-acp)`);
    const env: Record<string, string> = { NO_BROWSER: "1" };
    // The user's own codex matches their login and config; the adapter's bundled copy may lag behind.
    const codex = this.host.which("codex");
    if (codex && !this.host.env("CODEX_PATH")) env.CODEX_PATH = codex;
    return { command: bin, args: [], env };
  }

  protected modeFor(policy: PermissionPolicy, modes: { value: string }[]): string | undefined {
    // Codex's "read-only" mode still asks before edits and network access, which is what `ask` needs too.
    if (policy === "auto") return undefined;
    return modes.find((m) => m.value === "read-only")?.value;
  }

  async status(): Promise<Status> {
    if (!this.host.which(ADAPTER)) {
      return { available: false, authenticated: false, note: "npm i -g @agentclientprotocol/codex-acp" };
    }
    const codex = this.host.which("codex");
    if (codex) {
      const r = await runQuick(codex, ["login", "status"], 10_000, this.host);
      const out = `${r.stdout}\n${r.stderr}`;
      if (r.code === 0 && /logged in/i.test(out)) return { available: true, authenticated: true, note: out.trim().split("\n")[0] };
      if (r.code !== null && /not logged in/i.test(out)) return { available: true, authenticated: false, note: "run `codex login`" };
    }
    const ok = existsSync(join(this.codexHome(), "auth.json")) || !!this.host.env("CODEX_API_KEY") || !!this.host.env("OPENAI_API_KEY");
    return { available: true, authenticated: ok, ...(ok ? {} : { note: "run `codex login`" }) };
  }

  protected async fallbackModels(): Promise<ModelInfo[]> {
    let defaultModel: string | undefined;
    try {
      const toml = readFileSync(join(this.codexHome(), "config.toml"), "utf8");
      defaultModel = /^\s*model\s*=\s*"([^"]+)"/m.exec(toml)?.[1];
    } catch {
      // no config
    }
    try {
      const cache = JSON.parse(readFileSync(join(this.codexHome(), "models_cache.json"), "utf8")) as {
        models?: {
          slug: string;
          display_name?: string;
          visibility?: string;
          supported_reasoning_levels?: (string | { effort?: string })[];
        }[];
      };
      const list = (cache.models ?? []).filter((m) => m.visibility !== "hide");
      if (list.length) {
        return list.map((m) => {
          const efforts = (m.supported_reasoning_levels ?? [])
            .map((l) => (typeof l === "string" ? l : l.effort))
            .filter((e): e is string => !!e);
          return {
            id: m.slug,
            name: m.display_name ?? m.slug,
            ...(m.slug === (defaultModel ?? list[0]!.slug) ? { isDefault: true } : {}),
            ...(efforts.length ? { efforts } : {}),
          };
        });
      }
    } catch {
      // no cache yet
    }
    const id = defaultModel ?? "gpt-5.6-sol";
    return [{ id, name: id, isDefault: true, efforts: ["low", "medium", "high", "xhigh"] }];
  }
}
