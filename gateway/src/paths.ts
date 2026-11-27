import { copyFileSync, existsSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/** Where one profile keeps its things; see docs/layout.md. */
export interface Layout {
  /** Root of the profile tree (`~/nuo/profiles/<slug>`). */
  home: string;
  /** NUO_HOME: the app code (`app/`) and the gateway-wide config live there. */
  nuo: string;
  config: string;
  data: string;
  bots: string;
  instructions: string;
  memory: string;
  /** Collections, reminders and their history (docs/data.md); separate from nuo.db. */
  dataDb: string;
  /** Attachments of data rows, referenced by relative paths. */
  dataFiles: string;
  docs: string;
  dashboards: string;
  browser: string;
  /** HOME of the profile's agent processes (CLI logins); unused by the owner, whose agents run as the gateway user. */
  agentHome: string;
}

/** The gateway-wide folders. */
export interface GlobalLayout {
  home: string;
  config: string;
  profiles: string;
  /** Profile list and pairing failures (src/profiles/registry.ts). */
  registry: string;
  archive: string;
}

export const CONFIG_FILES = ["tools.json", "machine-tools.json", "bots.seed.json"] as const;
/** Folders of a profile tree; the owner's were at the root of NUO_HOME before profiles. */
export const PROFILE_DIRS = ["data", "docs", "dashboards", "bots", "instructions", "memory", "browser"] as const;

export function globalLayout(home: string, config?: string): GlobalLayout {
  return { home, config: config || join(home, "config"), profiles: join(home, "profiles"), registry: join(home, "profiles", "registry.db"), archive: join(home, "archive") };
}

export function profileLayout(g: GlobalLayout, slug: string, over: { data?: string; config?: string } = {}): Layout {
  const root = join(g.profiles, slug);
  return treeLayout(root, g.home, over.config || (slug === "owner" ? g.config : join(root, "config")), over.data);
}

export function treeLayout(root: string, nuo: string, config: string, data?: string): Layout {
  const d = data || join(root, "data");
  return {
    home: root,
    nuo,
    config,
    data: d,
    bots: join(root, "bots"),
    instructions: join(root, "instructions"),
    memory: join(root, "memory"),
    dataDb: join(d, "data.db"),
    dataFiles: join(d, "files"),
    docs: join(root, "docs"),
    dashboards: join(root, "dashboards"),
    browser: join(root, "browser"),
    agentHome: join(root, "home"),
  };
}

/** The tree of NUO_HOME before profiles; kept for installs not migrated yet. */
export function layoutFrom(home: string, over: { data?: string; config?: string } = {}): Layout {
  return treeLayout(home, home, over.config || join(home, "config"), over.data);
}

export function defaultGlobal(env: Record<string, string | undefined> = process.env): GlobalLayout {
  return globalLayout(env.NUO_HOME || join(homedir(), "nuo"), env.NUO_CONFIG_DIR);
}

/**
 * The owner's layout, for the CLI and scripts: under profiles/owner once the gateway migrated the install,
 * else the old tree (a CLI never moves files itself).
 */
export function defaultLayout(env: Record<string, string | undefined> = process.env): Layout {
  const g = defaultGlobal(env);
  const over = { data: env.NUO_DATA_DIR, config: env.NUO_CONFIG_DIR };
  return existsSync(join(g.profiles, "owner")) ? profileLayout(g, "owner", over) : layoutFrom(g.home, over);
}

/** The repo's config/ is only a default: the live copy in the config folder is never overwritten by a deploy. */
export function seedConfig(configDir: string, defaultsDir: string): string[] {
  mkdirSync(configDir, { recursive: true });
  const copied: string[] = [];
  for (const f of CONFIG_FILES) {
    const src = join(defaultsDir, f);
    const dst = join(configDir, f);
    if (existsSync(dst) || !existsSync(src)) continue;
    copyFileSync(src, dst);
    copied.push(f);
  }
  return copied;
}

export const REPO_CONFIG_DIR = new URL("../config", import.meta.url).pathname;
