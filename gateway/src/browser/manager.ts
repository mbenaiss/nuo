import { randomBytes } from "node:crypto";
import { HttpError } from "../bots/service";

export const BROWSER_UNIT = "nuo-browser.service";
export const DEFAULT_CDP_PORT = 9222;
export const DEFAULT_IDLE_MS = 20 * 60 * 1000;
const START_TIMEOUT_MS = 30_000;
const SWEEP_MS = 60_000;
/** A pending login request older than this is dropped (the agent gave up long before). */
const LOGIN_TTL_MS = 6 * 3600 * 1000;

export type Systemctl = (verb: "start" | "stop", unit: string) => Promise<void>;

/** What runs the browser process: the owner's systemd unit, or a profile's launcher (src/browser/profile.ts). */
export interface BrowserBackend {
  start(): Promise<void>;
  stop(): Promise<void>;
}

export interface BrowserOptions {
  /** DevTools port of the browser, bound to 127.0.0.1 by scripts/nuo-chrome.sh. */
  cdpPort?: number;
  unit?: string;
  /** The browser is stopped after this long without a viewer, an agent lease or a page change; 0 keeps it running. */
  idleMs?: number;
  /** `systemctl --user <verb> <unit>`; tests replace it. */
  systemctl?: Systemctl;
  /** Replaces the systemd unit. */
  backend?: BrowserBackend;
  startTimeoutMs?: number;
}

export function browserOptionsFromEnv(env: Record<string, string | undefined> = process.env): BrowserOptions {
  const minutes = env.NUO_BROWSER_IDLE_MIN === undefined ? undefined : Number(env.NUO_BROWSER_IDLE_MIN);
  return {
    cdpPort: Number(env.NUO_BROWSER_CDP_PORT) || undefined,
    idleMs: minutes !== undefined && Number.isFinite(minutes) && minutes >= 0 ? minutes * 60_000 : undefined,
  };
}

const userSystemctl: Systemctl = async (verb, unit) => {
  const p = Bun.spawn(["systemctl", "--user", verb, unit], { stdout: "ignore", stderr: "pipe" });
  const [code, err] = await Promise.all([p.exited, new Response(p.stderr).text()]);
  if (code !== 0) throw new Error(`systemctl --user ${verb} ${unit} failed: ${err.trim().split("\n").pop() ?? code}`);
};

export interface LoginRequest {
  id: string;
  site: string;
  url?: string;
  botId?: string;
  createdAt: string;
  status: "pending" | "done";
  doneAt?: string;
}

export interface BrowserStatus {
  running: boolean;
  endpoint: string;
  viewers: number;
  idleStopAt?: string;
  logins: LoginRequest[];
}

export type LoginNotifier = (r: LoginRequest) => void;

/**
 * Owns one profile's shared browser lifecycle (started on demand and stopped when idle) and the "login needed"
 * requests its agents raise for the user.
 */
export class BrowserManager {
  readonly endpoint: string;
  private readonly idleMs: number;
  private readonly backend: BrowserBackend;
  private readonly startTimeoutMs: number;
  private starting?: Promise<void>;
  private lastActivity = Date.now();
  private pageSignature = "";
  private viewers = 0;
  private logins = new Map<string, LoginRequest & { at: number }>();
  private sweeper?: ReturnType<typeof setInterval>;
  private loginListeners = new Set<() => void>();

  constructor(
    o: BrowserOptions = {},
    private notify: LoginNotifier = () => {},
  ) {
    this.endpoint = `http://127.0.0.1:${o.cdpPort ?? DEFAULT_CDP_PORT}`;
    this.idleMs = o.idleMs ?? DEFAULT_IDLE_MS;
    const unit = o.unit ?? BROWSER_UNIT;
    const systemctl = o.systemctl ?? userSystemctl;
    this.backend = o.backend ?? { start: () => systemctl("start", unit), stop: () => systemctl("stop", unit) };
    this.startTimeoutMs = o.startTimeoutMs ?? START_TIMEOUT_MS;
  }

  start() {
    this.sweeper ??= setInterval(() => void this.sweep().catch(() => {}), SWEEP_MS);
    this.sweeper.unref?.();
  }

  close() {
    clearInterval(this.sweeper);
    this.sweeper = undefined;
  }

  touch() {
    this.lastActivity = Date.now();
  }

  /** The `/json/version` document of the running browser, or undefined when it does not answer. */
  async version(): Promise<{ webSocketDebuggerUrl: string; Browser?: string } | undefined> {
    try {
      const res = await fetch(`${this.endpoint}/json/version`, { signal: AbortSignal.timeout(1500) });
      if (!res.ok) return undefined;
      const v = (await res.json()) as { webSocketDebuggerUrl?: string; Browser?: string };
      return v.webSocketDebuggerUrl ? (v as { webSocketDebuggerUrl: string }) : undefined;
    } catch {
      return undefined;
    }
  }

  /** Starts the browser when it does not answer, then waits for its DevTools endpoint. */
  async ensure(): Promise<string> {
    this.touch();
    const running = await this.version();
    if (running) return running.webSocketDebuggerUrl;
    this.starting ??= this.boot().finally(() => (this.starting = undefined));
    await this.starting;
    const v = await this.version();
    if (!v) throw new HttpError(503, "the browser did not start");
    return v.webSocketDebuggerUrl;
  }

  private async boot() {
    await this.backend.start().catch((e) => {
      console.warn(`[browser] ${(e as Error).message}`);
      throw new HttpError(503, "the browser service could not be started");
    });
    const deadline = Date.now() + this.startTimeoutMs;
    while (Date.now() < deadline) {
      if (await this.version()) {
        console.log("[browser] started");
        return;
      }
      await Bun.sleep(250);
    }
    // A browser that never answers would otherwise stay up: the idle sweep only sees browsers that answer.
    await this.stop();
    throw new HttpError(503, "the browser did not start in time");
  }

  async stop() {
    await this.backend.stop().catch((e) => console.warn(`[browser] ${(e as Error).message}`));
  }

  viewerOpened() {
    this.viewers++;
    this.touch();
  }

  viewerClosed() {
    this.viewers = Math.max(0, this.viewers - 1);
    this.touch();
  }

  async status(): Promise<BrowserStatus> {
    const running = !!(await this.version());
    const idle = running && this.viewers === 0 && this.idleMs > 0 ? new Date(this.lastActivity + this.idleMs).toISOString() : undefined;
    return { running, endpoint: this.endpoint, viewers: this.viewers, ...(idle ? { idleStopAt: idle } : {}), logins: this.pendingLogins() };
  }

  /** Agents navigating count as activity, so a long scrape is not cut off mid-way. */
  async sweep(now = Date.now()) {
    for (const [id, r] of this.logins) if (now - r.at > LOGIN_TTL_MS) this.logins.delete(id);
    if (this.idleMs <= 0 || !(await this.version())) return;
    const signature = await this.pages()
      .then((p) => p.map((t) => t.url).join("\n"))
      .catch(() => this.pageSignature);
    if (signature !== this.pageSignature) {
      this.pageSignature = signature;
      this.lastActivity = now;
    }
    if (this.viewers > 0 || now - this.lastActivity < this.idleMs) return;
    console.log("[browser] idle, stopping");
    await this.stop();
  }

  private async pages(): Promise<{ url: string }[]> {
    const res = await fetch(`${this.endpoint}/json/list`, { signal: AbortSignal.timeout(1500) });
    return ((await res.json()) as { type: string; url: string }[]).filter((t) => t.type === "page");
  }

  // Login requests

  requestLogin(b: { site?: unknown; url?: unknown; botId?: unknown }): LoginRequest {
    const site = typeof b.site === "string" ? b.site.trim().slice(0, 60) : "";
    if (!site) throw new HttpError(400, "site is required");
    let url: string | undefined;
    if (b.url !== undefined && b.url !== null && b.url !== "") {
      url = safeUrl(String(b.url));
      if (!url) throw new HttpError(400, "url must be an http(s) URL");
    }
    const botId = typeof b.botId === "string" && b.botId ? b.botId.slice(0, 64) : undefined;
    const at = Date.now();
    const r: LoginRequest & { at: number } = { id: randomBytes(8).toString("hex"), site, ...(url ? { url } : {}), ...(botId ? { botId } : {}), createdAt: new Date(at).toISOString(), status: "pending", at };
    this.logins.set(r.id, r);
    this.touch();
    this.notify(publicLogin(r));
    this.changed();
    return publicLogin(r);
  }

  login(id: string): LoginRequest {
    const r = this.logins.get(id);
    if (!r) throw new HttpError(404, "login request not found");
    return publicLogin(r);
  }

  pendingLogins(): LoginRequest[] {
    return [...this.logins.values()].filter((r) => r.status === "pending").map(publicLogin);
  }

  /** Done in the app: every pending request is answered at once (the user logged in where needed). */
  completeLogins(): number {
    let n = 0;
    const doneAt = new Date().toISOString();
    for (const r of this.logins.values()) {
      if (r.status !== "pending") continue;
      r.status = "done";
      r.doneAt = doneAt;
      n++;
    }
    this.changed();
    return n;
  }

  /** Open viewers show the pending requests; they refresh when one is raised or answered. */
  onLoginsChanged(listener: () => void): () => void {
    this.loginListeners.add(listener);
    return () => this.loginListeners.delete(listener);
  }

  private changed() {
    for (const l of this.loginListeners) l();
  }
}

const publicLogin = ({ at, ...r }: LoginRequest & { at: number }): LoginRequest => ({ ...r });

/** Only web pages: no file://, chrome:// or javascript: from the app or an agent's login request. */
export function safeUrl(raw: string): string | undefined {
  try {
    const u = new URL(raw.trim());
    return u.protocol === "http:" || u.protocol === "https:" ? u.toString() : undefined;
  } catch {
    return undefined;
  }
}

/** What the address bar sends: a URL, a bare host (`linkedin.com`) or words to search. */
export function addressToUrl(input: string): string | undefined {
  const text = input.trim();
  if (!text) return undefined;
  if (text === "about:blank") return text;
  if (/^[a-z][a-z0-9+.-]*:/i.test(text) && !/^[^\s/]+\.[^\s/]+:\d+/.test(text)) return safeUrl(text);
  if (!/\s/.test(text) && /^[^\s/]+\.[a-z]{2,}(?::\d+)?(\/.*)?$/i.test(text)) return safeUrl(`https://${text}`);
  return `https://duckduckgo.com/?q=${encodeURIComponent(text)}`;
}
