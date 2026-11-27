import { accessSync, constants, existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { delimiter, isAbsolute, join } from "node:path";
import type { MachineTool } from "../protocol";

export const MACHINE_TOOL_ID_RE = /^[a-z0-9_-]+$/;
export const VERSION_TIMEOUT_MS = 3000;
export const DISCOVERY_TTL_MS = 60 * 60 * 1000;

export interface CatalogEntry {
  id: string;
  name: string;
  kind: "cli";
  description: string;
  usage?: string;
  binary?: string;
  versionArgs?: string[]; // [] = no version probe; default ["--version"]
  needsShell: boolean;
}

export interface MachineToolSource {
  list(): Promise<MachineTool[]>;
}

export interface DiscoveryOptions {
  catalogPath: string;
  path?: string;
  home?: string;
  versionTimeoutMs?: number;
  ttlMs?: number;
}

const KIND_ORDER: Record<MachineTool["kind"], number> = { cli: 0, mcp: 1, skill: 2 };

export function sortMachineTools(tools: MachineTool[]): MachineTool[] {
  return [...tools].sort(
    (a, b) => Number(b.available) - Number(a.available) || KIND_ORDER[a.kind] - KIND_ORDER[b.kind] || a.name.localeCompare(b.name, "fr"),
  );
}

export const slugId = (s: string) =>
  s
    .toLowerCase()
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/[^a-z0-9_-]+/g, "-")
    .replace(/^-+|-+$/g, "");

export function extractVersion(output: string): string | undefined {
  const line = output.split(/\r?\n/).find((l) => l.trim());
  return line ? /\d+(?:\.\d+)+[^\s,;()]*/.exec(line)?.[0] : undefined;
}

export class MachineToolDiscovery implements MachineToolSource {
  private cache?: { at: number; tools: Promise<MachineTool[]> };
  private readonly path: string;
  private readonly home: string;

  constructor(private opts: DiscoveryOptions) {
    this.path = opts.path ?? process.env.PATH ?? "";
    this.home = opts.home ?? homedir();
  }

  list(): Promise<MachineTool[]> {
    const ttl = this.opts.ttlMs ?? DISCOVERY_TTL_MS;
    if (!this.cache || Date.now() - this.cache.at > ttl) {
      const tools = this.discover();
      this.cache = { at: Date.now(), tools };
      tools.catch(() => {
        if (this.cache?.tools === tools) this.cache = undefined;
      });
    }
    return this.cache.tools;
  }

  private async discover(): Promise<MachineTool[]> {
    const clis = await Promise.all(this.catalog().map((e) => this.probe(e)));
    const taken = new Set(clis.map((t) => t.id));
    const unique = (id: string, suffix: string) => {
      let out = taken.has(id) ? `${id}-${suffix}` : id;
      for (let i = 2; taken.has(out); i++) out = `${id}-${suffix}${i}`;
      taken.add(out);
      return out;
    };
    const mcps = this.mcpServers().map((name) => ({ ...mcpTool(name), id: unique(slugId(name) || "mcp", "mcp") }));
    const skills = this.skills().map((s) => ({ ...s, id: unique(s.id, "skill") }));
    return sortMachineTools([...clis, ...mcps, ...skills]);
  }

  private catalog(): CatalogEntry[] {
    if (!existsSync(this.opts.catalogPath)) return [];
    const data = JSON.parse(readFileSync(this.opts.catalogPath, "utf8"));
    if (!Array.isArray(data)) throw new Error(`${this.opts.catalogPath}: expected an array of tools`);
    return data.filter((e: CatalogEntry) => {
      const ok = typeof e?.id === "string" && MACHINE_TOOL_ID_RE.test(e.id) && typeof e.name === "string";
      if (!ok) console.warn(`[machine] skipping invalid catalog entry ${JSON.stringify(e?.id)}`);
      return ok;
    });
  }

  private async probe(e: CatalogEntry): Promise<MachineTool> {
    const tool: MachineTool = {
      id: e.id,
      name: e.name,
      kind: "cli",
      description: e.description ?? "",
      ...(e.usage ? { usage: e.usage } : {}),
      needsShell: e.needsShell !== false,
      available: false,
    };
    const bin = this.resolve(e.binary || e.id);
    if (!bin) return tool;
    tool.available = true;
    const args = e.versionArgs ?? ["--version"];
    if (args.length) {
      const version = await this.version(bin, args);
      if (version) tool.version = version;
    }
    return tool;
  }

  private resolve(binary: string): string | undefined {
    const b = binary.startsWith("~/") ? join(this.home, binary.slice(2)) : binary;
    if (isAbsolute(b)) return isExecutable(b) ? b : undefined;
    for (const dir of this.path.split(delimiter)) {
      if (!dir) continue;
      const candidate = join(dir, b);
      if (isExecutable(candidate)) return candidate;
    }
    return undefined;
  }

  private async version(bin: string, args: string[]): Promise<string | undefined> {
    const timeoutMs = this.opts.versionTimeoutMs ?? VERSION_TIMEOUT_MS;
    let proc: ReturnType<typeof Bun.spawn> | undefined;
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      proc = Bun.spawn([bin, ...args], {
        stdin: "ignore",
        stdout: "pipe",
        stderr: "pipe",
        env: { ...process.env, PATH: this.path, HOME: this.home, NO_COLOR: "1" },
      });
      const p = proc;
      // Killing the child is not enough: a grandchild can keep the pipes open, so the read itself is raced.
      const read = Promise.all([new Response(p.stdout as ReadableStream).text(), new Response(p.stderr as ReadableStream).text()]);
      const timeout = new Promise<undefined>((resolve) => {
        timer = setTimeout(() => {
          p.kill("SIGKILL");
          resolve(undefined);
        }, timeoutMs);
      });
      const out = await Promise.race([read, timeout]);
      if (!out) return undefined;
      return extractVersion(out[0].trim() ? out[0] : out[1]);
    } catch {
      return undefined;
    } finally {
      clearTimeout(timer);
    }
  }

  private mcpServers(): string[] {
    const file = join(this.home, ".claude.json");
    try {
      const data = JSON.parse(readFileSync(file, "utf8"));
      const servers = data?.mcpServers;
      return servers && typeof servers === "object" ? Object.keys(servers) : [];
    } catch {
      return [];
    }
  }

  private skills(): MachineTool[] {
    const dir = join(this.home, ".claude", "skills");
    let entries: string[];
    try {
      entries = readdirSync(dir);
    } catch {
      return [];
    }
    const out: MachineTool[] = [];
    for (const entry of entries.sort()) {
      const file = join(dir, entry, "SKILL.md");
      if (!existsSync(file)) continue;
      try {
        out.push(skillTool(entry, file, readFileSync(file, "utf8")));
      } catch (e) {
        console.warn(`[machine] skill ${entry}: ${(e as Error).message}`);
      }
    }
    return out;
  }
}

function isExecutable(p: string): boolean {
  try {
    if (!statSync(p).isFile()) return false;
    accessSync(p, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function mcpTool(name: string): MachineTool {
  return {
    id: slugId(name),
    name,
    kind: "mcp",
    description: `Serveur MCP « ${name} » configuré pour Claude sur la machine.`,
    usage: `Utilise les outils MCP du serveur « ${name} » (préfixe mcp__${name}__), disponibles dans les sessions Claude.`,
    needsShell: false,
    available: true,
  };
}

/** Minimal YAML frontmatter reader: flat `key: value` pairs plus `|`/`>` blocks, which is all SKILL.md files use. */
export function parseFrontmatter(text: string): Record<string, string> {
  const m = /^---\r?\n([\s\S]*?)\r?\n---/.exec(text);
  if (!m) return {};
  const out: Record<string, string> = {};
  const lines = m[1]!.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const kv = /^([A-Za-z0-9_-]+):\s*(.*)$/.exec(lines[i]!);
    if (!kv) continue;
    let value = kv[2]!.trim();
    if (/^[|>][+-]?$/.test(value)) {
      const block: string[] = [];
      while (i + 1 < lines.length && (/^\s+\S/.test(lines[i + 1]!) || !lines[i + 1]!.trim())) block.push(lines[++i]!.trim());
      value = block.filter(Boolean).join(" ");
    } else if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    out[kv[1]!] = value;
  }
  return out;
}

function oneLine(text: string, max = 200): string {
  const t = text.replace(/\s+/g, " ").trim();
  return t.length > max ? `${t.slice(0, max - 1).trimEnd()}…` : t;
}

export function skillTool(dirName: string, file: string, text: string): MachineTool {
  const fm = parseFrontmatter(text);
  const name = fm.name?.trim() || dirName;
  const description = oneLine(fm.description || `Skill ${name}`);
  const allowed = fm["allowed-tools"];
  return {
    id: slugId(name) || slugId(dirName) || "skill",
    name,
    kind: "skill",
    description,
    usage: `Skill Claude « ${name} » : suis les instructions de ${file} (outil Skill dans Claude Code). ${description}`,
    // A skill that declares its tools and none of them is Bash can run without a shell.
    needsShell: allowed === undefined || /\bBash\b/.test(allowed),
    available: true,
  };
}
