import { readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { DEFAULT_UI_LANGUAGE, t, type UiLanguage } from "../i18n/language";

export const DEFAULT_COMMAND_TIMEOUT_SEC = 600;
export const MAX_COMMAND_TIMEOUT_SEC = 24 * 60 * 60;
const OUTPUT_TAIL_BYTES = 4096;
const KILL_GRACE_MS = 5000;
// A background child that inherited the pipes can keep them open long after bash exits.
const DRAIN_AFTER_EXIT_MS = 1000;

export interface CommandSpec {
  command: string;
  cwd?: string;
  envFile?: string;
  env?: Record<string, string>;
  timeoutSec?: number;
}

export interface CommandResult {
  ok: boolean;
  exitCode?: number;
  output: string;
  durationMs: number;
  error?: string;
}

export function expandHome(path: string, home = homedir()): string {
  if (path === "~") return home;
  return path.startsWith("~/") ? join(home, path.slice(2)) : path;
}

export function stripAnsi(s: string): string {
  return s.replace(/\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]/g, "").replace(/\r(?!\n)/g, "\n");
}

/** Same rules as systemd's EnvironmentFile: KEY=VALUE lines, # or ; comments, optional quotes and `export`. */
export function parseEnvFile(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#") || line.startsWith(";")) continue;
    const m = line.match(/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
    if (!m) continue;
    let value = m[2]!;
    const q = value[0];
    if ((q === '"' || q === "'") && value.length >= 2 && value.endsWith(q)) {
      value = value.slice(1, -1);
      if (q === '"') value = value.replace(/\\(["\\$`n])/g, (_, c) => (c === "n" ? "\n" : c));
    }
    out[m[1]!] = value;
  }
  return out;
}

/** systemd user units start from a near-empty environment; so do commands, so the gateway's secrets never leak into them. */
export function commandPath(home = homedir()): string {
  return [join(home, ".local/bin"), join(home, ".bun/bin"), "/home/linuxbrew/.linuxbrew/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].join(":");
}

function baseEnv(home: string): Record<string, string> {
  const env: Record<string, string> = { HOME: home, PATH: commandPath(home), SHELL: "/bin/bash" };
  for (const k of ["USER", "LOGNAME", "LANG", "LC_ALL", "TZ", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"]) {
    const v = process.env[k];
    if (v) env[k] = v;
  }
  return env;
}

class Tail {
  private chunks: Uint8Array[] = [];
  private size = 0;
  push(b: Uint8Array) {
    this.chunks.push(b);
    this.size += b.byteLength;
    while (this.chunks.length > 1 && this.size - this.chunks[0]!.byteLength >= OUTPUT_TAIL_BYTES * 2) this.size -= this.chunks.shift()!.byteLength;
  }
  text(): string {
    const all = Buffer.concat(this.chunks);
    const s = stripAnsi(all.subarray(Math.max(0, all.byteLength - OUTPUT_TAIL_BYTES * 2)).toString("utf8"));
    const bytes = Buffer.from(s, "utf8");
    if (bytes.byteLength <= OUTPUT_TAIL_BYTES) return s.trimEnd();
    return bytes.subarray(bytes.byteLength - OUTPUT_TAIL_BYTES).toString("utf8").replace(/^\uFFFD+/, "").trimEnd();
  }
}

async function pump(stream: ReadableStream<Uint8Array>, tail: Tail, stop: Promise<void>) {
  const reader = stream.getReader();
  const stopped = stop.then(() => ({ done: true as const, value: undefined }));
  try {
    for (;;) {
      const r = await Promise.race([reader.read(), stopped]);
      if (r.done) break;
      tail.push(r.value);
    }
  } finally {
    reader.cancel().catch(() => {});
  }
}

/** Starts `/bin/bash -c <command>`; profiles other than the owner start it as their Linux user. */
export type CommandSpawner = (command: string, o: { cwd: string; env: Record<string, string> }) => Bun.Subprocess<"ignore" | "pipe", "pipe", "pipe">;

const localSpawner: CommandSpawner = (command, o) =>
  Bun.spawn(["/bin/bash", "-c", command], { cwd: o.cwd, env: o.env, stdin: "ignore", stdout: "pipe", stderr: "pipe", detached: true });

/** Variables travel on stdin: they may be secrets (env files), which must never appear on a command line. */
export function launcherSpawner(user: string, launcher: string, sudo = "/usr/bin/sudo"): CommandSpawner {
  return (command, o) => {
    const proc = Bun.spawn([sudo, "-n", "-u", user, launcher, "--env-stdin", "--", "/bin/bash", "-c", command], {
      cwd: o.cwd,
      env: { PATH: "/usr/bin:/bin" },
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
      detached: true,
    });
    const lines = Object.entries(o.env)
      .filter(([k, v]) => /^[A-Za-z_][A-Za-z0-9_]*$/.test(k) && !/[\n\0]/.test(v))
      .map(([k, v]) => `${k}=${v}\n`)
      .join("");
    proc.stdin.write(`${lines}\n`);
    void proc.stdin.end();
    return proc;
  };
}

export interface RunningCommand {
  done: Promise<CommandResult>;
  kill(): void;
}

export function runCommand(spec: CommandSpec, home = homedir(), spawner: CommandSpawner = localSpawner, lang: UiLanguage = DEFAULT_UI_LANGUAGE): RunningCommand {
  const started = Date.now();
  const fail = (error: string): RunningCommand => ({ done: Promise.resolve({ ok: false, output: "", durationMs: 0, error }), kill() {} });

  const cwd = expandHome(spec.cwd || "~", home);
  try {
    if (!statSync(cwd).isDirectory()) return fail(t("schedule.folderNotFound", { folder: spec.cwd ?? cwd }, lang));
  } catch {
    return fail(t("schedule.folderNotFound", { folder: spec.cwd ?? cwd }, lang));
  }
  const env = baseEnv(home);
  if (spec.envFile) {
    try {
      Object.assign(env, parseEnvFile(readFileSync(expandHome(spec.envFile, home), "utf8")));
    } catch {
      return fail(t("schedule.envFileUnreadable", { file: spec.envFile }, lang));
    }
  }
  Object.assign(env, spec.env ?? {});

  const proc = spawner(spec.command, { cwd, env });
  const killGroup = (sig: NodeJS.Signals) => {
    try {
      process.kill(-proc.pid, sig);
    } catch {
      try {
        proc.kill(sig);
      } catch {}
    }
  };
  let timedOut = false;
  let killed = false;
  let killTimer: ReturnType<typeof setTimeout> | undefined;
  const terminate = () => {
    killGroup("SIGTERM");
    killTimer ??= setTimeout(() => killGroup("SIGKILL"), KILL_GRACE_MS);
  };
  const timeoutSec = spec.timeoutSec ?? DEFAULT_COMMAND_TIMEOUT_SEC;
  const timer = setTimeout(() => {
    timedOut = true;
    terminate();
  }, timeoutSec * 1000);

  const tail = new Tail();
  const exited = proc.exited;
  const drainStop = exited.then(() => Bun.sleep(DRAIN_AFTER_EXIT_MS));
  const pumps = Promise.all([pump(proc.stdout, tail, drainStop), pump(proc.stderr, tail, drainStop)]);

  const done = (async (): Promise<CommandResult> => {
    const code = await exited;
    await pumps;
    clearTimeout(timer);
    if (killTimer) clearTimeout(killTimer);
    const output = tail.text();
    const durationMs = Date.now() - started;
    if (timedOut) return { ok: false, output, durationMs, error: t("schedule.timedOut", { seconds: timeoutSec }, lang) };
    if (killed) return { ok: false, output, durationMs, error: t("schedule.stoppedByGateway", {}, lang) };
    const exitCode = proc.signalCode ? undefined : code;
    if (exitCode === 0) return { ok: true, exitCode, output, durationMs };
    return { ok: false, exitCode, output, durationMs, error: exitCode === undefined ? t("schedule.killedBySignal", { signal: String(proc.signalCode) }, lang) : t("schedule.exitCode", { code: exitCode }, lang) };
  })();

  return {
    done,
    kill() {
      killed = true;
      terminate();
    },
  };
}
