import { chmodSync, mkdirSync, mkdtempSync, renameSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { McpServerSpec } from "../agents/types";

/** What an MCP server's command line may show: where things are, never how to get in. */
const PUBLIC_ENV = new Set(["HOME", "USER", "LOGNAME", "LANG", "TZ", "PATH", "NUO_MEDIA_DIR", "NUO_WORKDIR", "NUO_BOT_ID", "NUO_CONVERSATION_ID", "NUO_OVERVIEW", "NUO_RELAY", "NUO_ENV_FILE"]);
const SH_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;
export const NUO_ENV_NAME = "nuo.env";

/**
 * Files that carry the agents' MCP secrets (local token, API keys). Claude's adapter hands its MCP servers to the
 * `claude` process as `--mcp-config '{…env…}'`, and on dev /proc has no hidepid: anything in a spec's env would be
 * read by every local user with `ps`. `shared`: the profile's own Linux user reads them through the tree's group,
 * which other users cannot traverse; otherwise they stay the gateway user's alone.
 */
export class AgentEnv {
  private dir?: string;

  constructor(private o?: { dir: string; shared?: boolean }) {}

  private get mode() {
    return this.o?.shared ? 0o644 : 0o600;
  }

  private folder(): string {
    if (this.dir) return this.dir;
    const dir = this.o?.dir ?? mkdtempSync(join(tmpdir(), "nuo-agent-env-"));
    const mode = this.o?.shared ? 0o755 : 0o700;
    mkdirSync(dir, { recursive: true, mode });
    chmodSync(dir, mode);
    return (this.dir = dir);
  }

  private write(name: string, text: string): string {
    const path = join(this.folder(), name);
    const tmp = `${path}.tmp-${process.pid}`;
    writeFileSync(tmp, text, { mode: this.mode });
    chmodSync(tmp, this.mode);
    renameSync(tmp, path);
    return path;
  }

  /** For the `nuo` MCP server (NUO_ENV_FILE), in the format src/mcp/nuo-server.ts parses. */
  writeNuo(endpoint: { url: string; token: string }): string {
    return this.write(NUO_ENV_NAME, `NUO_URL=${endpoint.url}\nNUO_LOCAL_TOKEN=${endpoint.token}\n`);
  }

  /**
   * Moves the secret part of a spec's env to a file the server's shell sources before exec'ing it. Names a shell
   * cannot export (`A.B`) stay inline: no catalog server is known to use one.
   */
  seal(spec: McpServerSpec): McpServerSpec {
    const secret = Object.entries(spec.env).filter(([k]) => !PUBLIC_ENV.has(k) && SH_NAME.test(k));
    if (!secret.length) return spec;
    const env = Object.fromEntries(Object.entries(spec.env).filter(([k]) => PUBLIC_ENV.has(k) || !SH_NAME.test(k)));
    const file = this.write(`mcp-${spec.name.replace(/[^A-Za-z0-9_.-]/g, "_")}.env`, secret.map(([k, v]) => `export ${k}=${shQuote(v)}\n`).join(""));
    return { name: spec.name, command: "/bin/sh", args: ["-c", '. "$1" || exit 1; shift; exec "$@"', "nuo-mcp-env", file, spec.command, ...spec.args], env };
  }
}

function shQuote(v: string): string {
  return `'${v.replace(/'/g, `'\\''`)}'`;
}
