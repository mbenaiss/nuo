import { createPrivateKey, sign, type KeyObject } from "node:crypto";
import { readFileSync } from "node:fs";
import http2 from "node:http2";
import type { Device } from "../store/store";

/** Screen the app opens on tap; the app's `NotificationDestination` reads it back. */
export type PushDestination =
  | { kind: "conversation"; id: string; botId: string }
  | { kind: "bot"; id: string }
  /** `runId`: the run (task_runs) the alert is about, when there is one. */
  | { kind: "task"; id: string; botId: string; runId?: string }
  | { kind: "reminder"; id: string }
  | { kind: "booking"; id: string }
  | { kind: "browser" }
  | { kind: "settings" }
  | { kind: "link"; url: string }
  | { kind: "home" };

export interface PushPayload {
  title: string;
  body: string;
  destination: PushDestination;
  botId?: string;
  conversationId?: string;
  taskId?: string;
  runId?: string;
  /** Same id as the app's local notification for this answer, so iOS shows it once. */
  messageId?: string;
  reminderId?: string;
  bookingId?: string;
  /** `nuo://` link read by app versions that predate `destination`. */
  url?: string;
  /** Notification category of the app; defaults to nuo.answer with a conversation, nuo.alert (no reply) without. */
  category?: string;
}

/** Remote update of a Live Activity; `contentState` must decode as the app's `ContentState`. */
export interface LiveActivityPush {
  event: "update" | "end";
  contentState: Record<string, unknown>;
  alert?: { title: string; body: string };
  dismissalDate?: number; // unix seconds
}

export interface LiveActivityTarget {
  pushToken: string;
  environment: "development" | "production";
}

export interface Pusher {
  send(device: Device, payload: PushPayload): Promise<void>;
  sendLiveActivity(target: LiveActivityTarget, payload: LiveActivityPush): Promise<boolean>;
  /** Silent push that wakes the app in the background with `data` (no alert); false when APNs refused it. */
  sendBackground(device: Device, data: Record<string, unknown>): Promise<boolean>;
  close(): void;
}

export interface ApnsConfig {
  keyPath: string;
  keyId: string;
  teamId: string;
  topic: string;
}

const HOSTS = { production: "https://api.push.apple.com", development: "https://api.sandbox.push.apple.com" } as const;
const JWT_TTL_MS = 50 * 60 * 1000;

export function apnsConfigFromEnv(env = process.env): ApnsConfig | undefined {
  const { APNS_KEY_PATH, APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC } = env;
  if (!APNS_KEY_PATH || !APNS_KEY_ID || !APNS_TEAM_ID || !APNS_TOPIC) return undefined;
  return { keyPath: APNS_KEY_PATH, keyId: APNS_KEY_ID, teamId: APNS_TEAM_ID, topic: APNS_TOPIC };
}

export function createPusher(config: ApnsConfig | undefined, onInvalidToken: (deviceId: string) => void): Pusher {
  if (!config) {
    let logged = false;
    return {
      async send() {
        if (!logged) console.log("[push] APNs not configured (APNS_KEY_PATH, APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC); push disabled");
        logged = true;
      },
      async sendLiveActivity() {
        return false;
      },
      async sendBackground() {
        return false;
      },
      close() {},
    };
  }
  return new ApnsPusher(config, onInvalidToken);
}

class ApnsPusher implements Pusher {
  private key: KeyObject;
  private jwt?: { token: string; at: number };
  private sessions = new Map<string, http2.ClientHttp2Session>();

  constructor(
    private config: ApnsConfig,
    private onInvalidToken: (deviceId: string) => void,
  ) {
    this.key = createPrivateKey(readFileSync(config.keyPath));
  }

  private token(): string {
    if (this.jwt && Date.now() - this.jwt.at < JWT_TTL_MS) return this.jwt.token;
    const b64 = (o: object) => Buffer.from(JSON.stringify(o)).toString("base64url");
    const input = `${b64({ alg: "ES256", kid: this.config.keyId })}.${b64({ iss: this.config.teamId, iat: Math.floor(Date.now() / 1000) })}`;
    const sig = sign("sha256", Buffer.from(input), { key: this.key, dsaEncoding: "ieee-p1363" }).toString("base64url");
    this.jwt = { token: `${input}.${sig}`, at: Date.now() };
    return this.jwt.token;
  }

  private session(host: string): http2.ClientHttp2Session {
    const existing = this.sessions.get(host);
    if (existing && !existing.closed && !existing.destroyed) return existing;
    const s = http2.connect(host);
    s.on("error", (e) => console.warn(`[push] connection error: ${e.message}`));
    s.on("close", () => this.sessions.delete(host));
    s.unref();
    this.sessions.set(host, s);
    return s;
  }

  send(device: Device, p: PushPayload): Promise<void> {
    if (!device.apnsToken) return Promise.resolve();
    const body = apnsBody(p);
    return this.post(device.apnsEnv ?? "production", device.apnsToken, "alert", this.config.topic, "10", body, device.name, p.messageId).then((r) => {
      if (r.invalid) this.onInvalidToken(device.id);
    });
  }

  async sendBackground(device: Device, data: Record<string, unknown>): Promise<boolean> {
    if (!device.apnsToken) return false;
    // APNs drops a background push sent with priority 10 or with an alert.
    const r = await this.post(device.apnsEnv ?? "production", device.apnsToken, "background", this.config.topic, "5", { aps: { "content-available": 1 }, ...data }, device.name);
    if (r.invalid) this.onInvalidToken(device.id);
    return r.ok;
  }

  async sendLiveActivity(t: LiveActivityTarget, p: LiveActivityPush): Promise<boolean> {
    const aps: Record<string, unknown> = {
      timestamp: Math.floor(Date.now() / 1000),
      event: p.event,
      "content-state": p.contentState,
    };
    if (p.alert) aps.alert = { ...p.alert, sound: "default" };
    if (p.dismissalDate !== undefined) aps["dismissal-date"] = p.dismissalDate;
    const priority = p.event === "end" || p.alert ? "10" : "5";
    const r = await this.post(t.environment, t.pushToken, "liveactivity", `${this.config.topic}.push-type.liveactivity`, priority, { aps }, "live activity");
    return r.ok;
  }

  private post(
    env: "development" | "production",
    token: string,
    pushType: string,
    topic: string,
    priority: string,
    body: object,
    label: string,
    collapseId?: string,
  ): Promise<{ ok: boolean; invalid: boolean }> {
    return new Promise((resolve) => {
      const req = this.session(HOSTS[env]).request({
        ":method": "POST",
        ":path": `/3/device/${token}`,
        authorization: `bearer ${this.token()}`,
        "apns-topic": topic,
        "apns-push-type": pushType,
        "apns-priority": priority,
        "content-type": "application/json",
        ...(collapseId ? { "apns-collapse-id": collapseId.slice(0, 64) } : {}),
      });
      let status = 0;
      let data = "";
      req.setEncoding("utf8");
      req.on("response", (h) => (status = Number(h[":status"])));
      req.on("data", (c) => (data += c));
      req.on("end", () => {
        if (status === 200) return resolve({ ok: true, invalid: false });
        const reason = safeReason(data);
        console.warn(`[push] ${label}: HTTP ${status} ${reason}`);
        resolve({ ok: false, invalid: status === 410 || reason === "BadDeviceToken" || reason === "Unregistered" });
      });
      req.on("error", (e) => {
        console.warn(`[push] ${label}: ${e.message}`);
        resolve({ ok: false, invalid: false });
      });
      req.end(JSON.stringify(body));
    });
  }

  close() {
    for (const s of this.sessions.values()) s.close();
  }
}

/** Only a notification about a conversation can be answered inline: the app's reply needs that conversation. */
function defaultCategory(p: PushPayload): string {
  return p.conversationId ? "nuo.answer" : "nuo.alert";
}

/** The flat ids stay next to `destination`: inline replies need them, and older app versions route on them. */
export function apnsBody(p: PushPayload): Record<string, unknown> {
  return {
    aps: { alert: { title: p.title, body: p.body }, sound: "default", category: p.category ?? defaultCategory(p), ...(p.botId ? { "thread-id": p.botId } : {}) },
    destination: p.destination,
    ...(p.botId ? { botId: p.botId } : {}),
    ...(p.conversationId ? { conversationId: p.conversationId } : {}),
    ...(p.taskId ? { taskId: p.taskId } : {}),
    ...(p.runId ? { runId: p.runId } : {}),
    ...(p.reminderId ? { reminderId: p.reminderId } : {}),
    ...(p.bookingId ? { bookingId: p.bookingId } : {}),
    ...(p.url ? { url: p.url } : {}),
  };
}

function safeReason(data: string): string {
  try {
    return JSON.parse(data).reason ?? "";
  } catch {
    return "";
  }
}
