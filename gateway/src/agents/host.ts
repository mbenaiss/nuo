import { spawn, type ChildProcess, type StdioOptions } from "node:child_process";
import { readFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

// Variables of the gateway itself that agent processes (which run arbitrary tools) must not see.
const PRIVATE_ENV_PREFIXES = ["NUO_", "APNS_"];

export function extraPathDirs(): string[] {
  const home = homedir();
  return [
    join(home, ".local/bin"),
    join(home, ".bun/bin"),
    join(home, ".npm-global/bin"),
    "/home/linuxbrew/.linuxbrew/bin",
    "/opt/homebrew/bin",
    "/usr/local/bin",
  ];
}

export function augmentedPath(base = process.env.PATH ?? ""): string {
  const parts = base.split(":").filter(Boolean);
  for (const dir of extraPathDirs()) if (!parts.includes(dir)) parts.push(dir);
  return parts.join(":");
}

export function findBinary(name: string): string | null {
  return Bun.which(name, { PATH: augmentedPath() });
}

export function childEnv(extra: Record<string, string> = {}): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env)) {
    if (v === undefined || PRIVATE_ENV_PREFIXES.some((p) => k.startsWith(p))) continue;
    env[k] = v;
  }
  env.PATH = augmentedPath(env.PATH);
  return { ...env, ...extra };
}

export interface HostSpawnOptions {
  cwd?: string;
  env?: Record<string, string>;
  stdio: StdioOptions;
  detached?: boolean;
}

export interface Readiness {
  ok: boolean;
  reason?: string;
}

/**
 * Where and as whom a profile's agent processes run. The owner's run as the gateway user with its own
 * logins; another profile's run as its Linux user `nuo-<slug>` through the launcher, with its own HOME.
 */
export interface AgentHost {
  readonly kind: "local" | "profile";
  /** HOME of the agent processes: the CLIs keep their logins there (~/.claude, ~/.codex, ~/.gemini, ~/.grok). */
  readonly home: string;
  /** A variable the agent processes see (API keys). */
  env(name: string): string | undefined;
  which(name: string): string | null;
  spawn(command: string, args: string[], o: HostSpawnOptions): ChildProcess;
  /** Throwaway working folder (model probes). */
  scratch(): string;
  /** Agent processes may only start when this is ok. */
  ready(): Promise<Readiness>;
}

export const LOCAL_HOST: AgentHost = {
  kind: "local",
  get home() {
    return homedir();
  },
  env: (name) => process.env[name],
  which: findBinary,
  spawn: (command, args, o) => spawn(command, args, { cwd: o.cwd, env: childEnv(o.env), stdio: o.stdio, detached: o.detached }),
  scratch: () => tmpdir(),
  ready: async () => ({ ok: true }),
};

export const LAUNCHER = "/usr/local/lib/nuo/nuo-agent";
/** Copies of bun and the nuo MCP server that profile users can run (the gateway's live in its private home). */
export const PROFILE_RUNTIME_DIR = "/srv/nuo/runtime";
/** Variables the launcher accepts from the gateway; everything else comes from the profile's own env file. */
export const LAUNCHER_VARS = ["LANG", "LC_ALL", "TZ", "TERM", "NO_BROWSER", "CODEX_PATH"] as const;

export function profilePath(home: string): string {
  return [join(home, ".local/bin"), "/home/linuxbrew/.linuxbrew/bin", "/usr/local/bin", "/usr/bin", "/bin", join(PROFILE_RUNTIME_DIR, "bin")].join(":");
}

/** Same syntax as the env files the launcher reads: KEY=VALUE lines, # comments, optional quotes. */
export function readEnvFile(path: string): Record<string, string> {
  const out: Record<string, string> = {};
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch {
    return out;
  }
  for (const raw of text.split(/\r?\n/)) {
    const m = raw.trim().match(/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (!m) continue;
    let v = m[2]!.trim();
    if (v.length >= 2 && (v[0] === '"' || v[0] === "'") && v.endsWith(v[0]!)) v = v.slice(1, -1);
    out[m[1]!] = v;
  }
  return out;
}

export interface ProfileHostOptions {
  slug: string;
  /** Real path of the profile's agent HOME (`/srv/nuo/<slug>/home`), owned by `nuo-<slug>`. */
  home: string;
  user?: string;
  launcher?: string;
  sudo?: string;
  /** Replaces `sudo … --check` (tests). */
  check?: () => Promise<Readiness>;
  /** Replaces the process spawn (tests). */
  spawner?: (command: string, args: string[], o: HostSpawnOptions) => ChildProcess;
}

const READY_TTL_MS = 60_000;
const NOT_READY_TTL_MS = 10_000;

export function agentsEnvFile(home: string): string {
  return join(home, ".config", "nuo", "agents.env");
}

/** The sudo command line that runs `command` as the profile's user; env values are never secrets (see LAUNCHER_VARS). */
export function launcherArgs(user: string, launcher: string, command: string, args: string[], env: Record<string, string> = {}): string[] {
  const allowed = new Set<string>(LAUNCHER_VARS);
  const vars = Object.entries(env)
    .filter(([k, v]) => allowed.has(k) && !/[\n\0]/.test(v))
    .map(([k, v]) => `${k}=${v}`);
  return ["-n", "-u", user, launcher, ...vars, "--", command, ...args];
}

export function profileHost(o: ProfileHostOptions): AgentHost {
  const user = o.user ?? `nuo-${o.slug}`;
  const launcher = o.launcher ?? LAUNCHER;
  const sudo = o.sudo ?? "/usr/bin/sudo";
  const passthrough = (extra: Record<string, string> = {}) => {
    const base: Record<string, string> = {};
    for (const k of ["LANG", "LC_ALL", "TZ"]) if (process.env[k]) base[k] = process.env[k]!;
    return { ...base, ...extra };
  };
  const doSpawn =
    o.spawner ??
    ((command: string, args: string[], so: HostSpawnOptions) =>
      // sudo resets the environment; the launcher builds the agent's from scratch.
      spawn(sudo, launcherArgs(user, launcher, command, args, passthrough(so.env)), { cwd: so.cwd ?? o.home, env: { PATH: "/usr/bin:/bin" }, stdio: so.stdio, detached: so.detached }));
  let cache: { at: number; r: Readiness } | undefined;
  const runCheck =
    o.check ??
    (() =>
      new Promise<Readiness>((resolve) => {
        let out = "";
        let child: ChildProcess;
        try {
          child = spawn(sudo, ["-n", "-u", user, launcher, "--check"], { cwd: "/", env: { PATH: "/usr/bin:/bin" }, stdio: ["ignore", "pipe", "pipe"] });
        } catch (e) {
          resolve({ ok: false, reason: String(e) });
          return;
        }
        const timer = setTimeout(() => child.kill("SIGKILL"), 10_000);
        child.stdout?.on("data", (d) => (out += d));
        child.stderr?.on("data", (d) => (out += d));
        child.on("error", (e) => {
          clearTimeout(timer);
          resolve({ ok: false, reason: e.message });
        });
        child.on("close", (code) => {
          clearTimeout(timer);
          const last = out.trim().split("\n").pop() ?? "";
          resolve(code === 0 && last === "ok" ? { ok: true } : { ok: false, reason: last || `exit ${code}` });
        });
      }));
  return {
    kind: "profile",
    home: o.home,
    env: (name) => readEnvFile(agentsEnvFile(o.home))[name],
    which: (name) => Bun.which(name, { PATH: profilePath(o.home) }),
    spawn: (command, args, so) => doSpawn(command, args, so),
    scratch: () => o.home,
    async ready() {
      if (cache && Date.now() - cache.at < (cache.r.ok ? READY_TTL_MS : NOT_READY_TTL_MS)) return cache.r;
      const r = await runCheck();
      cache = { at: Date.now(), r: r.ok ? r : { ok: false, reason: `the Linux user ${user} is not set up on this machine (run scripts/profile-os-setup.sh ${o.slug} with sudo): ${r.reason ?? "check failed"}` } };
      return cache.r;
    },
  };
}
