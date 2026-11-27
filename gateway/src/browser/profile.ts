import type { ChildProcess } from "node:child_process";
import { chmodSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { PROFILE_RUNTIME_DIR, type AgentHost } from "../agents/host";
import type { BrowserBackend } from "./manager";

/**
 * A profile's DevTools port is this plus the uid of `nuo-<slug>`: unique by construction, and scripts/nuo-firewall
 * computes the same port to open it to that user only.
 */
export const PROFILE_CDP_PORT_BASE = 29000;
/** Copy of scripts/nuo-chrome.sh that profile users can run (src/profiles/runtime.ts). */
export const PROFILE_BROWSER_SCRIPT = join(PROFILE_RUNTIME_DIR, "bin", "nuo-chrome");
/** Under the agents' HOME: the browser profile (cookies) is the profile user's alone (0700). */
export const PROFILE_BROWSER_DIR = ".browser";
/** Next to the agents' HOME, in the part of the tree the profile's user can read but not write. */
export const AGENT_GATEWAY_ENV = "gateway.env";
const STOP_GRACE_MS = 15_000;

export function profileCdpPort(uid: number): number | undefined {
  const port = PROFILE_CDP_PORT_BASE + uid;
  return Number.isInteger(uid) && uid > 0 && port <= 65535 ? port : undefined;
}

export function userUid(user: string): number | undefined {
  const r = Bun.spawnSync(["id", "-u", user], { stdout: "pipe", stderr: "ignore" });
  const uid = Number(r.stdout.toString().trim());
  return r.exitCode === 0 && Number.isInteger(uid) ? uid : undefined;
}

/** The browser of a profile: Xvfb and Chrome run as its Linux user through the launcher, profile under its HOME. */
export function launcherBrowser(host: AgentHost, o: { port: number; dir: string; script?: string }): BrowserBackend {
  let child: ChildProcess | undefined;
  const alive = (c: ChildProcess | undefined): c is ChildProcess => !!c && c.exitCode === null && c.signalCode === null;
  return {
    async start() {
      if (alive(child)) return;
      const r = await host.ready();
      if (!r.ok) throw new Error(r.reason ?? "the profile's Linux user is not ready");
      const c = host.spawn(o.script ?? PROFILE_BROWSER_SCRIPT, ["--port", String(o.port), "--dir", o.dir], { stdio: ["ignore", "ignore", "pipe"] });
      child = c;
      // Chrome logs a lot on stderr: it must be drained or Chrome blocks; the tail explains an early exit.
      let tail = "";
      c.stderr?.on("data", (d) => (tail = (tail + d).slice(-2000)));
      c.on("error", (e) => console.warn(`[browser] ${host.home}: ${e.message}`));
      c.on("exit", (code) => {
        if (child === c) child = undefined;
        if (code) console.warn(`[browser] ${host.home}: exited with ${code}: ${tail.trim().split("\n").pop() ?? ""}`);
      });
    },
    async stop() {
      const c = child;
      if (!alive(c)) return;
      const exited = new Promise<void>((resolve) => c.once("exit", () => resolve()));
      // sudo relays the signal to the launcher, which passes it to the whole browser process group.
      c.kill("SIGTERM");
      const timer = setTimeout(() => c.kill("SIGKILL"), STOP_GRACE_MS);
      await exited;
      clearTimeout(timer);
    },
  };
}

/**
 * How the profile's `nuo-browser` CLI reaches the gateway: its local token changes at each start and is otherwise
 * only known to the nuo MCP server of its agents, which run as the same user.
 */
export function writeAgentGatewayEnv(tree: string, endpoint: { url: string; token: string }) {
  const path = join(tree, AGENT_GATEWAY_ENV);
  const tmp = `${path}.tmp-${process.pid}`;
  writeFileSync(tmp, `NUO_URL=${endpoint.url}\nNUO_LOCAL_TOKEN=${endpoint.token}\n`, { mode: 0o644 });
  chmodSync(tmp, 0o644);
  renameSync(tmp, path);
}
