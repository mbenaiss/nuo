import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AgentRuntime, AgentSession, PermissionAsk, RunEvent, SessionOptions } from "../src/agents/types";
import { createApp, type AppOptions } from "../src/api/app";
import { createPairCode, signedMessage } from "../src/auth/service";
import { base32Decode, totp } from "../src/auth/totp";
import type { MachineToolSource } from "../src/machine/discovery";
import type { AgentId, Attachment, ModelInfo, ServerEvent } from "../src/protocol";
import type { Pusher, PushPayload } from "../src/push/apns";
import type { RunnerOptions } from "../src/runner/runner";
import { runtimesFrom } from "../src/runner/runtimes";
import type { SchedulerOptions } from "../src/scheduler/scheduler";
import type { DataOptions } from "../src/data/service";
import { OWNER_ONLY_MARKER, SCHEMA_DIR } from "../src/data/db";
import type { CalendarOptions } from "../src/calendar/service";
import type { BrowserOptions } from "../src/browser/manager";
import type { Device } from "../src/store/store";
import type { NetworkConfig } from "../src/auth/network";
import type { NetworkInfo } from "../src/auth/service";
import type { GoogleOAuthOptions } from "../src/google/oauth";
import type { BridgeOptions } from "../src/device/bridge";
import type { SecretsOptions } from "../src/secrets/store";

export class FakeRuntime implements AgentRuntime {
  starts: SessionOptions[] = [];
  closed: string[] = [];
  prompts: { text: string; attachments: Attachment[] }[] = [];
  modelChanges: string[] = [];
  /** Slash commands the fake agent advertises (e.g. ["compact"] for native compaction). */
  commands: string[] = [];
  /** Context usage reported after each normal prompt; undefined = the agent reports nothing. */
  reportedUsage?: number;
  /** Delay before a session is ready, like a slow ACP spawn. */
  startDelayMs = 0;
  /** /compact runs until cancelled, like a native compaction of a big context. */
  holdCompact = false;
  /** The next normal prompt throws, like an agent process that dies mid-turn. */
  failNextPrompt = false;
  /** Takes « Envoyer maintenant » into the running turn, like Claude and Codex; false = like Grok and Antigravity. */
  steerable = false;
  steered: string[] = [];
  /** Sessions in start order, to make one work again by itself. */
  sessions: AgentSession[] = [];
  private n = 0;

  constructor(
    readonly id: AgentId = "claude",
    readonly name = "Fake Claude",
    public modelList: ModelInfo[] = [{ id: "fake-model", name: "Fake", isDefault: true }],
    private sessionPrefix = "s",
  ) {}

  /** Like the real runtimes: only Claude runs a session without any tool. */
  get toolless() {
    return this.id === "claude";
  }
  async status() {
    return { available: true, authenticated: true };
  }
  async models() {
    return this.modelList;
  }
  async start(opts: SessionOptions): Promise<AgentSession> {
    if (opts.noTools && !this.toolless) throw new Error(`${this.name} cannot run without tools`);
    if (this.startDelayMs) await Bun.sleep(this.startDelayMs);
    this.starts.push(opts);
    const rt = this;
    const id = opts.resumeId ?? `${this.sessionPrefix}${++this.n}`;
    let cancel: (() => void) | undefined;
    const session: AgentSession = {
      agentSessionId: id,
      get commands() {
        return rt.commands;
      },
      async prompt(text: string, attachments: Attachment[], on: (e: RunEvent) => void, ask: (a: PermissionAsk) => Promise<string>) {
        rt.prompts.push({ text, attachments });
        if (/^\/(compact|compress)\b/.test(text)) {
          if (rt.holdCompact) {
            await new Promise<void>((r) => (cancel = r));
            return { stopReason: "cancelled" };
          }
          on({ type: "compacted", beforeTokens: 90000, afterTokens: 5000 });
          on({ type: "usage", usedTokens: 5000, maxTokens: 200000 });
          return { stopReason: "end_turn" };
        }
        if (text.startsWith("[Nuo] La conversation va être compactée")) {
          on({ type: "text", text: "Résumé : l'utilisateur part à Rome le 20/10." });
          return { stopReason: "end_turn" };
        }
        if (text.startsWith("[Nuo] Cette conversation a été compactée")) {
          on({ type: "text", text: "OK" });
          return { stopReason: "end_turn", usage: { usedTokens: 1200 } };
        }
        if (rt.reportedUsage !== undefined) on({ type: "usage", usedTokens: rt.reportedUsage, maxTokens: 200000 });
        if (text.startsWith("repeat: ")) {
          // Says back what it was given, in two chunks split mid-word, like a streamed answer.
          const said = text.slice("repeat: ".length);
          const cut = Math.floor(said.length / 2);
          on({ type: "text", text: said.slice(0, cut) });
          on({ type: "text", text: said.slice(cut) });
          return { stopReason: "end_turn" };
        }
        if (text.startsWith("narrate: ")) {
          // Text, a tool call, more text: how an agent reports its progress.
          const [before, after] = text.slice("narrate: ".length).split(" | ");
          on({ type: "text", text: before! });
          on({ type: "tool.start", toolCallId: "t1", title: "Read gateway/src/scan/service.ts", kind: "read" });
          on({ type: "tool.end", toolCallId: "t1", status: "completed" });
          on({ type: "text", text: after! });
          return { stopReason: "end_turn" };
        }
        const calls = [...text.matchAll(/call:([a-z0-9_-]+)\/([A-Za-z0-9_]+)(\{[^}]*\})?/g)];
        if (calls.length) {
          // Each tool the agent wants asks first, like Claude Code in its default mode; `hold` keeps the turn open after.
          for (const [, server, name, input] of calls) {
            const chosen = await ask({
              title: `mcp__${server}__${name}`,
              tool: { server: server!, name: name!, ...(input ? { input: JSON.parse(input) } : {}) },
              options: [
                { id: "allow_once", name: "Autoriser", kind: "allow_once" },
                { id: "allow_always", name: "Toujours autoriser", kind: "allow_always" },
                { id: "reject_once", name: "Refuser", kind: "reject_once" },
              ],
            });
            on({ type: "text", text: `${name}:${chosen} ` });
          }
          if (text.includes("hold")) {
            await new Promise<void>((r) => (cancel = r));
            return { stopReason: "cancelled" };
          }
          return { stopReason: "end_turn" };
        }
        if (text.includes("boom")) throw new Error("agent crashed");
        if (rt.failNextPrompt) {
          rt.failNextPrompt = false;
          throw new Error("agent crashed");
        }
        if (text.includes("deploy")) {
          on({ type: "tool.start", toolCallId: "t1", title: "Terminal", kind: "execute" });
          on({ type: "tool.detail", toolCallId: "t1", detail: "Wait for the deploy workflow on main" });
          on({ type: "tool.end", toolCallId: "t1", status: "completed" });
          on({ type: "text", text: "Déployé" });
          return { stopReason: "end_turn" };
        }
        if (text.includes("tool")) {
          on({ type: "tool.start", toolCallId: "t1", title: "flight_status", kind: "fetch" });
          await Bun.sleep(20);
          on({ type: "tool.end", toolCallId: "t1", status: "completed" });
          on({ type: "text", text: "done" });
          return { stopReason: "end_turn" };
        }
        if (text.includes("delegate")) {
          on({ type: "tool.start", toolCallId: "spawn", title: "Task", kind: "think" });
          on({ type: "subagent", id: "sub-1", title: "Explore", description: "Compter les fichiers de /etc/systemd", state: "running" });
          on({ type: "subagent.tool", id: "sub-1", toolCallId: "b1", title: "find /etc/systemd -type f | wc -l", status: "running" });
          on({ type: "subagent.tool", id: "sub-1", toolCallId: "b1", status: "completed" });
          on({ type: "subagent.text", id: "sub-1", text: "12 fichiers" });
          on({ type: "subagent", id: "sub-1", state: "completed" });
          on({ type: "tool.end", toolCallId: "spawn", status: "completed" });
          if (text.includes("unfinished")) on({ type: "subagent", id: "sub-2", title: "Plan", state: "running" });
          on({ type: "text", text: "Il y a 12 fichiers." });
          return { stopReason: "end_turn" };
        }
        if (text.includes("perm")) {
          const chosen = await ask({
            title: "Run rm?",
            options: [
              { id: "allow_once", name: "Autoriser", kind: "allow_once" },
              { id: "reject_once", name: "Refuser", kind: "reject_once" },
            ],
          });
          on({ type: "text", text: `chosen:${chosen}` });
          return { stopReason: "end_turn" };
        }
        if (text.includes("hang")) {
          on({ type: "thought", text: "plan" });
          on({ type: "tool.start", toolCallId: "t1", title: "gog calendar", kind: "execute" });
          await Bun.sleep(5);
          on({ type: "tool.end", toolCallId: "t1", status: "completed" });
          on({ type: "text", text: "Voici" });
          on({ type: "tool.start", toolCallId: "t2", title: "gog mail", kind: "execute" });
          await new Promise<void>((r) => (cancel = r));
          return { stopReason: "cancelled" };
        }
        if (text.includes("slow")) {
          on({ type: "text", text: "partial" });
          await new Promise<void>((r) => (cancel = r));
          return { stopReason: "cancelled" };
        }
        on({ type: "thought", text: "thinking" });
        on({ type: "text", text: "Hello " });
        on({ type: "text", text: "world" });
        return { stopReason: "end_turn" };
      },
      async cancel() {
        cancel?.();
      },
      async steer(text: string) {
        if (!rt.steerable || !cancel) return false;
        rt.steered.push(text);
        return true;
      },
      async setModel(model: string) {
        rt.modelChanges.push(model);
      },
      async close() {
        rt.closed.push(id);
      },
    };
    this.sessions.push(session);
    return session;
  }

  /** The last session comes back by itself, like Claude once a background command finished. */
  comeBack(text: string) {
    const session = this.sessions.at(-1);
    session?.onUnprompted?.({
      run: async (on) => {
        on({ type: "tool.start", toolCallId: "bg-read", title: "Read build output", kind: "read" });
        on({ type: "tool.end", toolCallId: "bg-read", status: "completed" });
        on({ type: "text", text });
        return { stopReason: "end_turn" };
      },
    });
  }
}

export class FakePusher implements Pusher {
  sent: { device: Device; payload: PushPayload }[] = [];
  async send(device: Device, payload: PushPayload) {
    this.sent.push({ device, payload });
  }
  live: { target: LiveActivityTarget; payload: LiveActivityPush }[] = [];
  async sendLiveActivity(target: LiveActivityTarget, payload: LiveActivityPush) {
    this.live.push({ target, payload });
    return true;
  }
  background: { device: Device; data: Record<string, unknown> }[] = [];
  async sendBackground(device: Device, data: Record<string, unknown>) {
    this.background.push({ device, data });
    return true;
  }
  close() {}
}

export interface TestApp {
  base: string;
  /** Access token minted by a fresh step-up, so sensitive routes work during the test. */
  token: string;
  device: TestDevice;
  /** Enrols TOTP (the helper already did) and returns the base32 secret. */
  totpSecret: string;
  runtime: FakeRuntime;
  pusher: FakePusher;
  app: ReturnType<typeof createApp>;
  home: string;
  /** The owner's profile tree (bots, instructions, memory, docs…). */
  profileHome: string;
  dataDir: string;
  configDir: string;
  api: (method: string, path: string, body?: unknown, token?: string) => Promise<{ status: number; data: any }>;
  close: () => Promise<void>;
}

// A checkout with the owner's private migrations laid over it already has these tables, with the same columns.
const ownerSchemaPresent = readdirSync(SCHEMA_DIR).some((f) => f.endsWith(".sql") && readFileSync(join(SCHEMA_DIR, f), "utf8").startsWith(OWNER_ONLY_MARKER));

/** The shipped migrations plus example owner collections (invoices, clients) that the data tests work on. */
export const TEST_SCHEMA_DIRS: readonly string[] = ownerSchemaPresent ? [SCHEMA_DIR] : [SCHEMA_DIR, join(import.meta.dir, "fixtures", "schema")];

export async function startTestApp(
  opts: {
    seed?: unknown[];
    tools?: unknown[];
    maxSessions?: number;
    localToken?: string;
    machineToken?: string;
    machine?: MachineToolSource;
    autoCompact?: boolean;
    idleCompact?: RunnerOptions["idleCompact"];
    scheduler?: SchedulerOptions;
    data?: DataOptions;
    authNow?: () => number;
    network?: NetworkConfig;
    networkInfo?: NetworkInfo;
    calendar?: CalendarOptions;
    browser?: BrowserOptions;
    profileExecution?: AppOptions["profileExecution"];
    pairMinMs?: number;
    google?: GoogleOAuthOptions;
    device?: BridgeOptions;
    secrets?: SecretsOptions;
    cfAccess?: AppOptions["cfAccess"];
    scan?: AppOptions["scan"];
    transcription?: AppOptions["transcription"];
    muscu?: AppOptions["muscu"];
    wake?: AppOptions["wake"];
    /** Runs before the app starts, on the empty NUO_HOME (old layouts, registry rows). */
    prepare?: (home: string) => void;
    /** Agents besides the default fake Claude (`runtime`). */
    extraRuntimes?: FakeRuntime[];
    /** Stands for the host's lightpanda; tests never pick up the machine's own. */
    browserMcp?: RunnerOptions["browserMcp"];
  } = {},
): Promise<TestApp> {
  const home = mkdtempSync(join(tmpdir(), "nuo-test-"));
  const configDir = join(home, "config");
  const profileHome = join(home, "profiles", "owner");
  const dataDir = join(profileHome, "data");
  require("node:fs").mkdirSync(configDir);
  opts.prepare?.(home);
  writeFileSync(
    join(configDir, "tools.json"),
    JSON.stringify(
      opts.tools ?? [{ id: "travel", name: "Voyages", description: "Vols", tools: ["flight_status"], command: "node", args: ["server.js"], cwd: "/opt/travel", env: { A: "1" } }],
    ),
  );
  if (opts.seed) writeFileSync(join(configDir, "bots.seed.json"), JSON.stringify(opts.seed));
  const runtime = new FakeRuntime();
  const pusher = new FakePusher();
  const app = createApp({
    layout: { home },
    pairMinMs: opts.pairMinMs ?? 0,
    profileExecution: opts.profileExecution,
    port: 0,
    hostname: "127.0.0.1",
    runtimes: runtimesFrom([runtime, ...(opts.extraRuntimes ?? [])]),
    pusher,
    localToken: opts.localToken,
    machineToken: opts.machineToken,
    machine: opts.machine ?? { list: async () => [] },
    runner: { maxSessions: opts.maxSessions ?? 3, permissionTimeoutMs: 2000, autoCompact: opts.autoCompact ?? true, idleCompact: opts.idleCompact, browserMcp: opts.browserMcp },
    scheduler: opts.scheduler,
    data: { schemaDirs: TEST_SCHEMA_DIRS, ...opts.data },
    claudeConfigDir: join(home, "claude"),
    authKey: TEST_AUTH_KEY,
    authNow: opts.authNow,
    network: opts.network,
    cfAccess: opts.cfAccess,
    networkInfo: opts.networkInfo,
    calendar: opts.calendar ?? { gogRunner: null },
    // Port 1 never answers: no test reaches a real browser or systemd unless it brings a fake one.
    browser: opts.browser ?? { cdpPort: 1, systemctl: async () => {} },
    google: opts.google,
    device: opts.device,
    secrets: opts.secrets,
    scan: opts.scan,
    transcription: opts.transcription,
    muscu: opts.muscu,
    wake: opts.wake,
  });
  const base = `http://127.0.0.1:${app.server.port}`;
  const api = async (method: string, path: string, body?: unknown, token?: string) => {
    const res = await fetch(base + path, {
      method,
      headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    return { status: res.status, data: text ? JSON.parse(text) : undefined };
  };
  const totpSecret = app.auth.enrollTotp("test").secret;
  const device = await pairDevice({ base, api, store: app.store, totpSecret, now: opts.authNow?.() ?? Date.now() });
  const token = await stepUp(api, device);
  return {
    base,
    token,
    device,
    totpSecret,
    runtime,
    pusher,
    app,
    home,
    profileHome,
    dataDir,
    configDir,
    api: (m, p, b, t) => api(m, p, b, t ?? token),
    close: async () => {
      await app.stop();
      rmSync(home, { recursive: true, force: true });
    },
  };
}

export const botConfig = (over: Record<string, unknown> = {}) => ({
  name: "Voyages",
  emoji: "✈️",
  color: "#E0EEFF",
  description: "Travel",
  agent: "claude",
  model: "fake-model",
  instructions: "Tu es l'assistant voyages.",
  toolServers: ["travel"],
  permissionPolicy: "ask",
  ...over,
});

/** Turn-state events; kept out of `Socket.events` so the per-turn event sequences stay readable. */
const TURN_STATE_EVENTS = new Set(["turns.snapshot", "turn.phase"]);

export class Socket {
  events: ServerEvent[] = [];
  turnEvents: ServerEvent[] = [];
  private taken = new WeakSet<ServerEvent>();
  private waiters: { pred: (e: ServerEvent) => boolean; resolve: (e: ServerEvent) => void }[] = [];
  constructor(readonly ws: WebSocket) {
    ws.onmessage = (m) => {
      const e = JSON.parse(String(m.data)) as ServerEvent;
      (TURN_STATE_EVENTS.has(e.type) ? this.turnEvents : this.events).push(e);
      this.waiters = this.waiters.filter((w) => (w.pred(e) ? (w.resolve(e), false) : true));
    };
  }
  static open(t: TestApp, token = t.token): Promise<Socket> {
    const ws = new WebSocket(t.base.replace("http", "ws") + "/api/ws", { headers: { authorization: `Bearer ${token}` } } as any);
    return new Promise((resolve, reject) => {
      ws.onopen = () => resolve(new Socket(ws));
      ws.onerror = (e) => reject(e);
    });
  }
  send(e: unknown) {
    this.ws.send(JSON.stringify(e));
  }
  next<T extends ServerEvent["type"]>(type: T, timeoutMs = 3000): Promise<Extract<ServerEvent, { type: T }>> {
    const seen = [...this.events, ...this.turnEvents].find((e) => e.type === type && !this.taken.has(e));
    if (seen) {
      this.taken.add(seen);
      return Promise.resolve(seen as any);
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`timeout waiting for ${type}`)), timeoutMs);
      this.waiters.push({
        pred: (e) => e.type === type && !this.taken.has(e),
        resolve: (e) => {
          clearTimeout(timer);
          this.taken.add(e);
          resolve(e as any);
        },
      });
    });
  }
  close() {
    this.ws.close();
  }
}

export const TEST_AUTH_KEY = Buffer.alloc(32, 7);

export interface TestDevice {
  id: string;
  name: string;
  keys: CryptoKeyPair;
  accessToken: string;
  extensionTokens: Record<string, { token: string; expiresAt: string }>;
  sign: (message: string) => Promise<string>;
}

type Api = (method: string, path: string, body?: unknown, token?: string) => Promise<{ status: number; data: any }>;

export async function newDeviceKey() {
  const keys = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, false, ["sign", "verify"])) as CryptoKeyPair;
  const spki = Buffer.from(await crypto.subtle.exportKey("spki", keys.publicKey)).toString("base64");
  const sign = async (message: string) => Buffer.from(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, keys.privateKey, new TextEncoder().encode(message))).toString("base64");
  return { keys, spki, sign };
}

/** Pairs a new device with a fresh pairing code, the TOTP code of the next unused step and a WebCrypto key. */
export async function pairDevice(o: { base: string; api: Api; store: import("../src/store/store").Store; totpSecret: string; now: number; name?: string; step?: number; profile?: string }): Promise<TestDevice> {
  const { keys, spki, sign } = await newDeviceKey();
  const code = createPairCode(o.store);
  const last = (o.store.db.query("SELECT last_step FROM auth_totp").get() as { last_step: number }).last_step;
  const at = Math.max(o.now, (last + 1) * 30_000);
  // A code one step ahead is still inside the accepted window.
  const second = totp(base32Decode(o.totpSecret), at > o.now + 30_000 ? o.now + 30_000 : at);
  const r = await o.api("POST", "/api/pair", { profile: o.profile ?? "owner", code, totp: second, deviceName: o.name ?? "Test iPhone", platform: "iOS", publicKey: spki }, "");
  if (r.status !== 200) throw new Error(`pairing failed: ${r.status} ${JSON.stringify(r.data)}`);
  return { id: r.data.deviceId, name: o.name ?? "Test iPhone", keys, accessToken: r.data.accessToken, extensionTokens: r.data.extensionTokens, sign };
}

/** `reason`: a step-up taken for that one action (the relay key), refused for any other. */
export async function stepUp(api: Api, device: TestDevice, reason?: string): Promise<string> {
  const { data: c } = await api("GET", "/api/auth/challenge", undefined, "");
  const signature = await device.sign(signedMessage("step-up", device.id, c.nonce));
  const r = await api("POST", "/api/auth/step-up", { nonce: c.nonce, signature, ...(reason ? { reason } : {}) }, device.accessToken);
  if (r.status !== 200) throw new Error(`step-up failed: ${r.status} ${JSON.stringify(r.data)}`);
  return r.data.accessToken;
}

export async function refresh(api: Api, device: TestDevice): Promise<{ status: number; data: any }> {
  const { data: c } = await api("GET", "/api/auth/challenge", undefined, "");
  const signature = await device.sign(signedMessage("refresh", device.id, c.nonce));
  return api("POST", "/api/auth/refresh", { deviceId: device.id, nonce: c.nonce, signature }, "");
}
