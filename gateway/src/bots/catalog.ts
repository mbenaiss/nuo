import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import type { McpServerSpec } from "../agents/types";
import type { ToolServer } from "../protocol";

export interface ToolServerDef extends ToolServer {
  command: string;
  args: string[];
  cwd?: string;
  envFile?: string;
  env?: Record<string, string>;
}

export const expandHome = (p: string) => (p === "~" ? homedir() : p.startsWith("~/") ? homedir() + p.slice(1) : p);

function baseEnv(): Record<string, string> {
  const env: Record<string, string> = {};
  for (const k of ["HOME", "USER", "LOGNAME", "LANG", "TZ"]) {
    const v = process.env[k];
    if (v) env[k] = v;
  }
  return env;
}

export function parseDotenv(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const m = line.match(/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_.]*)\s*=\s*(.*)$/);
    if (!m) continue;
    let value = m[2]!;
    const q = value[0];
    if ((q === '"' || q === "'") && value.lastIndexOf(q) > 0) {
      value = value.slice(1, value.lastIndexOf(q));
      if (q === '"') value = value.replace(/\\n/g, "\n").replace(/\\"/g, '"');
    } else {
      value = value.replace(/\s+#.*$/, "");
    }
    out[m[1]!] = value;
  }
  return out;
}

export class ToolCatalog {
  private defs: ToolServerDef[] = [];

  constructor(private path: string) {
    this.reload();
  }

  reload() {
    if (!existsSync(this.path)) {
      this.defs = [];
      return;
    }
    const data = JSON.parse(readFileSync(this.path, "utf8"));
    if (!Array.isArray(data)) throw new Error(`${this.path}: expected an array of tool servers`);
    this.defs = data.map((d: ToolServerDef) => ({ ...d, tools: d.tools ?? [], args: d.args ?? [], description: d.description ?? "" }));
  }

  list(): ToolServer[] {
    return this.defs.map(({ id, name, description, tools }) => ({ id, name, description, tools }));
  }

  has(id: string) {
    return this.defs.some((d) => d.id === id);
  }

  /**
   * McpServerSpec has no cwd, so a server that needs one is wrapped in `sh -c 'cd … && exec …'`.
   * Servers without their own cwd run in `defaultCwd` (the bot's workdir).
   */
  specs(ids: string[], extraEnv: Record<string, string>, defaultCwd?: string): McpServerSpec[] {
    return ids.flatMap((id) => {
      const d = this.defs.find((x) => x.id === id);
      if (!d) return [];
      // Agents start MCP servers with only the env they are given; tools still expect a normal user env.
      const env: Record<string, string> = { ...baseEnv(), ...extraEnv };
      if (d.envFile) {
        const file = expandHome(d.envFile);
        if (existsSync(file)) Object.assign(env, parseDotenv(readFileSync(file, "utf8")));
        else console.warn(`[tools] ${d.id}: envFile not found`);
      }
      Object.assign(env, d.env ?? {});
      const command = expandHome(d.command);
      const args = d.args.map(expandHome);
      const cwd = d.cwd ? expandHome(d.cwd) : defaultCwd;
      if (!cwd) return [{ name: d.id, command, args, env }];
      return [{ name: d.id, command: "/bin/sh", args: ["-c", 'cd "$1" || exit 1; shift; exec "$@"', "nuo-mcp", cwd, command, ...args], env }];
    });
  }
}
