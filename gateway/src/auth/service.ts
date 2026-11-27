import { createHash, randomBytes, randomInt, timingSafeEqual } from "node:crypto";
import type { Store } from "../store/store";
import { newId, now as isoNow } from "../store/store";
import { normalizePublicKey, open, seal, sha256, verifyP256 } from "./keys";
import { EXTENSION_SCOPES, type ExtensionScope, type Scope } from "./policy";
import { base32Encode, generateTotpSecret, otpauthUri, verifyTotp } from "./totp";

export const PAIR_CODE_TTL_MS = 10 * 60 * 1000;
export const ACCESS_TTL_MS = 15 * 60 * 1000;
export const EXTENSION_TTL_MS = 30 * 24 * 3600 * 1000;
const EXTENSION_ROTATE_MS = 7 * 24 * 3600 * 1000;
export const STEP_UP_WINDOW_MS = 60 * 1000;
/** A relay token lives as long as an access token: the iPhone signs for a new one with its relay key. */
export const RELAY_TTL_MS = 15 * 60 * 1000;
/** Prompts a device may pass on through its relay per hour. */
export const RELAY_PROMPTS_PER_HOUR = 30;
/** Conversations a device's relay may open per hour. */
export const RELAY_CONVERSATIONS_PER_HOUR = 20;
/** Step-up reasons a step-up must be taken for, by name: one taken for anything else does not do. */
export const BOUND_STEP_UP_REASONS: ReadonlySet<string> = new Set(["relay"]);
const NONCE_TTL_MS = 2 * 60 * 1000;
const MAX_NONCES = 500;
export const FAIL_WINDOW_MS = 15 * 60 * 1000;
export const MAX_FAILS_PER_IP = 5;
export const MAX_FAILS_TOTAL = 20;
const RECOVERY_CODES = 10;

export type AuthEventType =
  | "pair"
  | "refresh"
  | "step_up"
  | "revoke"
  | "legacy_token"
  | "local_token_rejected"
  | "machine_token_rejected"
  | "totp_setup"
  | "totp_reset"
  | "google_connect"
  | "google_disconnect"
  | "google_error"
  | "secret_reveal"
  | "secret_create"
  | "secret_update"
  | "secret_delete"
  | "action_key"
  | "bot_policy"
  | "relay_key"
  | "relay_token"
  | "relay_prompt"
  | "relay_conversation"
  | "relay_permission"
  | "relay_transcription"
  | "relay_refused";

export interface AuthDevice {
  id: string;
  name: string;
  platform?: string;
  createdAt: string;
  lastSeenAt?: string;
  /** Paired before device keys: must pair again. */
  legacy: boolean;
}

export interface AuthContext {
  /** Profile the device belongs to; every route then works on that profile's data only. */
  profileId: string;
  deviceId: string;
  deviceName: string;
  scope: Scope;
  stepUpAt?: number;
  expiresAt: number;
}

export interface TokenGrant {
  deviceId: string;
  accessToken: string;
  expiresAt: string;
  /** Thumbprint of the device key the tokens are bound to. */
  cnf: string;
  network?: NetworkInfo;
  /** Present when new extension tokens were minted; extensions keep the previous ones until they expire. */
  extensionTokens?: Partial<Record<ExtensionScope, { token: string; expiresAt: string }>>;
  stepUpUntil?: string;
}

/** `unknown`: the credential is not one of this profile's (the caller tries the other profiles). */
export type Failure = { status: number; error: string; reauth?: boolean; retryAt?: string; unknown?: boolean };
type Result<T> = T | Failure;
export const isFailure = (r: unknown): r is Failure => !!r && typeof r === "object" && "status" in r && "error" in r;

export const signedMessage = (purpose: "refresh" | "step-up" | "relay", deviceId: string, nonce: string) => `nuo-auth:v1:${purpose}:${deviceId}:${nonce}`;

/**
 * What the device's action key signs for one sensitive call: the exact method, path (with its query) and body,
 * so a signature cannot be replayed on another secret, another value or another route.
 */
export const actionMessage = (deviceId: string, nonce: string, method: string, pathAndQuery: string, body: string) =>
  `nuo-action:v1:${deviceId}:${nonce}:${method.toUpperCase()}:${pathAndQuery}:${createHash("sha256").update(body).digest("hex")}`;

export function createPairCode(store: Store): string {
  const code = randomInt(0, 1_000_000).toString().padStart(6, "0");
  store.addPairCode(sha256(code), Date.now() + PAIR_CODE_TTL_MS);
  return code;
}

const RECOVERY_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789";
function recoveryCode(): string {
  let s = "";
  for (let i = 0; i < 10; i++) s += RECOVERY_ALPHABET[randomInt(0, RECOVERY_ALPHABET.length)];
  return `${s.slice(0, 5)}-${s.slice(5)}`;
}
const normalizeRecovery = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, "");
const looksLikeRecovery = (s: string) => /^[a-z0-9]{5}-?[a-z0-9]{5}$/i.test(s.trim()) && !/^\d+$/.test(s.trim());

export function bearer(req: Request): string | undefined {
  return req.headers.get("authorization")?.match(/^Bearer\s+(\S+)$/i)?.[1];
}

/** RFC 7638-style key thumbprint: SHA-256 of the SPKI DER, base64url. */
export const thumbprint = (spkiB64: string) => createHash("sha256").update(Buffer.from(spkiB64, "base64")).digest("base64url");

/** How the app reaches the gateway from outside: returned at pairing and by GET /api/auth/network. */
export interface NetworkInfo {
  publicURL?: string;
  cfAccess?: { clientId: string; clientSecret: string };
}

export function networkInfoFromEnv(env: Record<string, string | undefined> = process.env): NetworkInfo {
  const id = env.NUO_CF_ACCESS_CLIENT_ID;
  const secret = env.NUO_CF_ACCESS_CLIENT_SECRET;
  return { publicURL: env.NUO_PUBLIC_URL || undefined, cfAccess: id && secret ? { clientId: id, clientSecret: secret } : undefined };
}

export interface AuthOptions {
  network?: NetworkInfo;
  /** Push to the user's devices on a new pairing or repeated failures. */
  alert?: (title: string, body: string, exceptDeviceId?: string) => void;
  localToken?: string;
  /** Profile of this service's database. */
  profileId?: string;
  /** Challenge nonces, shared by the profiles: a challenge is fetched before the device says who it is. */
  nonces?: Map<string, number>;
  /** Key that seals the TOTP secret; without it pairing is refused (2FA cannot be checked). */
  authKey?: Buffer;
  now?: () => number;
  /** A device's relay access ended (key revoked or replaced, device revoked): its relay turns stop. */
  relayRevoked?: (deviceId: string) => void;
}

type Row = Record<string, any>;

export class AuthService {
  private nonces: Map<string, number>;
  private touched = new Map<string, number>();
  private legacyLogged = new Map<string, number>();
  private logged = 0;
  private readonly now: () => number;

  constructor(
    private store: Store,
    private opts: AuthOptions = {},
  ) {
    this.now = opts.now ?? Date.now;
    this.nonces = opts.nonces ?? new Map();
  }

  get profileId(): string {
    return this.opts.profileId ?? "owner";
  }

  private get db() {
    return this.store.db;
  }

  // Audit log

  event(type: AuthEventType, ok: boolean, info: { ip?: string; deviceId?: string; deviceName?: string; detail?: string } = {}) {
    this.db
      .query("INSERT INTO auth_events (at, type, ok, ip, device_id, device_name, detail) VALUES (?, ?, ?, ?, ?, ?, ?)")
      .run(this.now(), type, ok ? 1 : 0, info.ip ?? null, info.deviceId ?? null, info.deviceName ?? null, info.detail ?? null);
  }

  events(limit = 50): { at: string; type: string; ok: boolean; ip?: string; deviceId?: string; deviceName?: string; detail?: string }[] {
    return (this.db.query("SELECT * FROM auth_events ORDER BY id DESC LIMIT ?").all(limit) as Row[]).map((r) => ({
      at: new Date(r.at).toISOString(),
      type: r.type,
      ok: !!r.ok,
      ip: r.ip ?? undefined,
      deviceId: r.device_id ?? undefined,
      deviceName: r.device_name ?? undefined,
      detail: r.detail ?? undefined,
    }));
  }

  // TOTP enrolment (CLI)

  totpConfigured(): boolean {
    return !!this.db.query("SELECT 1 FROM auth_totp WHERE id = 1").get();
  }

  /** Replaces any previous secret and recovery codes. The caller prints the result once. */
  enrollTotp(account: string, reset = false): { uri: string; secret: string; recoveryCodes: string[] } {
    const key = this.requireKey();
    const secret = generateTotpSecret();
    const codes = Array.from({ length: RECOVERY_CODES }, recoveryCode);
    this.db.transaction(() => {
      this.db.query("DELETE FROM auth_totp").run();
      this.db.query("DELETE FROM auth_recovery_codes").run();
      this.db.query("INSERT INTO auth_totp (id, secret_enc, last_step, created_at) VALUES (1, ?, 0, ?)").run(seal(key, secret), isoNow());
      for (const c of codes) this.db.query("INSERT INTO auth_recovery_codes (code_hash) VALUES (?)").run(sha256(normalizeRecovery(c)));
    })();
    this.event(reset ? "totp_reset" : "totp_setup", true, { detail: "cli" });
    return { uri: otpauthUri(secret, account), secret: base32Encode(secret), recoveryCodes: codes };
  }

  recoveryCodesLeft(): number {
    return (this.db.query("SELECT count(*) AS n FROM auth_recovery_codes WHERE used_at IS NULL").get() as Row).n;
  }

  private requireKey(): Buffer {
    if (!this.opts.authKey) throw new Error("NUO_AUTH_KEY is not available");
    return this.opts.authKey;
  }

  /** TOTP code (each step accepted once) or an unused recovery code. Consumes what it accepts. */
  private checkSecondFactor(code: string): "totp" | "recovery" | undefined {
    const row = this.db.query("SELECT secret_enc, last_step FROM auth_totp WHERE id = 1").get() as Row | null;
    if (!row) return undefined;
    const trimmed = code.replace(/\s/g, "");
    if (looksLikeRecovery(trimmed)) {
      const used = this.db.query("UPDATE auth_recovery_codes SET used_at = ? WHERE code_hash = ? AND used_at IS NULL").run(isoNow(), sha256(normalizeRecovery(trimmed)));
      return used.changes > 0 ? "recovery" : undefined;
    }
    const secret = open(this.requireKey(), row.secret_enc);
    const step = verifyTotp(secret, trimmed, this.now(), row.last_step);
    if (step === undefined) return undefined;
    // Conditional update: two concurrent requests with the same code cannot both win.
    const won = this.db.query("UPDATE auth_totp SET last_step = ? WHERE id = 1 AND last_step < ?").run(step, step);
    return won.changes > 0 ? "totp" : undefined;
  }

  /** Exposed for tests and the CLI check command. */
  verifySecondFactor(code: string) {
    return this.checkSecondFactor(code);
  }

  // Pairing

  /**
   * Checks the pairing code and the second factor of this profile and enrols the device. Lockouts, failure
   * alerts and the generic answer are handled for all profiles by ProfileSet.pair.
   */
  pairDevice(b: { code?: unknown; totp?: unknown; platform?: unknown }, name: string, publicKey: string, ip: string): { grant: TokenGrant; recovery: boolean } | { detail: string } {
    if (!this.totpConfigured() || !this.opts.authKey) return { detail: "2fa not set up" };
    const code = String(b.code ?? "");
    const codeHash = sha256(code);
    const codeOk = /^\d{6}$/.test(code) && !!this.db.query("SELECT 1 FROM pair_codes WHERE code_hash = ? AND expires_at >= ?").get(codeHash, Date.now());
    if (!codeOk) return { detail: "pair code" };
    const factor = typeof b.totp === "string" ? this.checkSecondFactor(b.totp) : undefined;
    if (!factor) return { detail: "second factor" };
    if (!this.store.consumePairCode(codeHash)) return { detail: "pair code race" };
    const platform = typeof b.platform === "string" ? b.platform.slice(0, 20) : undefined;
    const id = newId();
    this.db.query("INSERT INTO devices (id, name, platform, public_key, created_at, last_seen_at) VALUES (?, ?, ?, ?, ?, ?)").run(id, name, platform ?? null, publicKey, isoNow(), isoNow());
    this.event("pair", true, { ip, deviceId: id, deviceName: name, detail: factor === "recovery" ? `recovery code (${this.recoveryCodesLeft()} left)` : platform });
    this.opts.alert?.("Nuo · nouvel appareil", `« ${name} » vient d'être appairé depuis ${ip}${factor === "recovery" ? " avec un code de secours" : ""}.`, id);
    return { grant: { ...this.grant(id, { forceExtensions: true }), network: this.opts.network ?? {} }, recovery: factor === "recovery" };
  }

  canPair(): boolean {
    return !!this.opts.authKey;
  }

  hasDevice(id: string): boolean {
    return !!this.db.query("SELECT 1 FROM devices WHERE id = ?").get(id);
  }

  /** Pushes to every device of the profile (no device is spared: the one acting may be stolen). */
  alert(title: string, body: string) {
    this.opts.alert?.(title, body);
  }

  // Action key: a Face ID–bound key that signs each sensitive action

  hasActionKey(deviceId: string): boolean {
    return !!(this.db.query("SELECT action_key FROM devices WHERE id = ?").get(deviceId) as Row | null)?.action_key;
  }

  /** Registered with a fresh step-up, from home only (the caller checks both); replaces the previous key. */
  setActionKey(ctx: AuthContext, publicKey: unknown, ip: string): Result<{ ok: true }> {
    let key: string;
    try {
      key = normalizePublicKey(String(publicKey ?? ""));
    } catch {
      return { status: 400, error: "publicKey must be a P-256 public key (base64 SPKI or X9.63)" };
    }
    const device = this.db.query("SELECT public_key FROM devices WHERE id = ?").get(ctx.deviceId) as Row | null;
    if (!device) return { status: 401, error: "unknown or revoked device: pair again", reauth: true };
    if (device.public_key === key) return { status: 400, error: "the action key must differ from the device key" };
    const replaced = this.hasActionKey(ctx.deviceId);
    this.db.query("UPDATE devices SET action_key = ? WHERE id = ?").run(key, ctx.deviceId);
    this.event("action_key", true, { ip, deviceId: ctx.deviceId, deviceName: ctx.deviceName, detail: replaced ? "replaced" : "registered" });
    this.alert("Nouvelle clé Face ID", `${ctx.deviceName} a ${replaced ? "remplacé" : "enregistré"} sa clé de confirmation des secrets.`);
    return { ok: true };
  }

  /** One-time proof that the device owner confirmed this exact call with Face ID (see `actionMessage`). */
  verifyAction(ctx: AuthContext, nonce: unknown, signature: unknown, method: string, pathAndQuery: string, body: string): Failure | undefined {
    const device = this.db.query("SELECT action_key FROM devices WHERE id = ?").get(ctx.deviceId) as Row | null;
    if (!device?.action_key) return { status: 403, error: "this device has no action key yet" };
    if (!this.takeNonce(nonce)) return { status: 403, error: "unknown or expired nonce" };
    if (typeof signature !== "string" || !verifyP256(device.action_key, actionMessage(ctx.deviceId, nonce as string, method, pathAndQuery, body), signature)) {
      return { status: 403, error: "invalid action signature" };
    }
    return undefined;
  }

  // Relay key: a third key of the device, readable by the iPhone after its first unlock, that only obtains relay tokens

  /** `thumbprint` lets the iPhone tell whether the key it holds is the one the gateway knows. */
  relayKeyInfo(deviceId: string): { registered: boolean; createdAt?: string; thumbprint?: string } {
    const row = this.db.query("SELECT relay_key, relay_key_at FROM devices WHERE id = ?").get(deviceId) as Row | null;
    return row?.relay_key ? { registered: true, createdAt: row.relay_key_at ?? undefined, thumbprint: thumbprint(row.relay_key) } : { registered: false };
  }

  /** Registered from the app with a fresh step-up, from home only (the caller checks both); replaces the previous key. */
  setRelayKey(ctx: AuthContext, publicKey: unknown, ip: string): Result<{ ok: true }> {
    if (ctx.scope !== "app") return { status: 403, error: "only the app registers a relay key" };
    if (this.profileId !== "owner") return { status: 403, error: "the relay access is for the owner's profile only" };
    let key: string;
    try {
      key = normalizePublicKey(String(publicKey ?? ""));
    } catch {
      return { status: 400, error: "publicKey must be a P-256 public key (base64 SPKI or X9.63)" };
    }
    const device = this.db.query("SELECT public_key, action_key, relay_key FROM devices WHERE id = ?").get(ctx.deviceId) as Row | null;
    if (!device) return { status: 401, error: "unknown or revoked device: pair again", reauth: true };
    if (device.public_key === key || device.action_key === key) return { status: 400, error: "the relay key must differ from the device's other keys" };
    const replaced = !!device.relay_key;
    this.db.transaction(() => {
      this.db.query("UPDATE devices SET relay_key = ?, relay_key_at = ? WHERE id = ?").run(key, isoNow(), ctx.deviceId);
      // Tokens of a previous relay key go with it.
      this.db.query("DELETE FROM auth_tokens WHERE device_id = ? AND scope = 'relay'").run(ctx.deviceId);
    })();
    this.event("relay_key", true, { ip, deviceId: ctx.deviceId, deviceName: ctx.deviceName, detail: replaced ? "replaced" : "registered" });
    if (replaced) this.opts.relayRevoked?.(ctx.deviceId);
    this.alert("Accès de relais", `${ctx.deviceName} a ${replaced ? "recréé" : "activé"} son accès de relais pour la montre.`);
    return { ok: true };
  }

  /** The key and every relay token of the device go; true when there was one. */
  revokeRelayKey(ctx: AuthContext, ip: string): boolean {
    if (ctx.scope !== "app") return false;
    const had = !!this.relayKeyInfo(ctx.deviceId).registered;
    this.db.transaction(() => {
      this.db.query("UPDATE devices SET relay_key = NULL, relay_key_at = NULL WHERE id = ?").run(ctx.deviceId);
      this.db.query("DELETE FROM auth_tokens WHERE device_id = ? AND scope = 'relay'").run(ctx.deviceId);
    })();
    if (had) this.event("relay_key", true, { ip, deviceId: ctx.deviceId, deviceName: ctx.deviceName, detail: "revoked" });
    this.opts.relayRevoked?.(ctx.deviceId);
    return had;
  }

  /** A relay token for the device whose relay key signed this nonce; nothing else is minted. */
  relayToken(b: { deviceId?: unknown; nonce?: unknown; signature?: unknown }, ip: string): Result<{ token: string; expiresAt: string }> {
    const deviceId = typeof b.deviceId === "string" ? b.deviceId : "";
    const device = this.db.query("SELECT name, public_key, relay_key FROM devices WHERE id = ?").get(deviceId) as Row | null;
    const refuse = (f: Failure) => {
      this.event("relay_token", false, { ip, deviceId: deviceId || undefined, deviceName: device?.name, detail: f.error });
      return f;
    };
    if (!device || !device.public_key) return refuse({ status: 401, error: "unknown or revoked device: pair again", reauth: true });
    if (!device.relay_key || this.profileId !== "owner") return refuse({ status: 401, error: "no relay key for this device", reauth: false });
    if (!this.takeNonce(b.nonce)) return refuse({ status: 401, error: "unknown or expired nonce", reauth: false });
    if (typeof b.signature !== "string" || !verifyP256(device.relay_key, signedMessage("relay", deviceId, b.nonce as string), b.signature)) {
      return refuse({ status: 401, error: "invalid signature", reauth: false });
    }
    this.db.query("DELETE FROM auth_tokens WHERE expires_at < ?").run(this.now());
    const minted = this.mint(deviceId, thumbprint(device.public_key), "relay", RELAY_TTL_MS);
    this.event("relay_token", true, { ip, deviceId, deviceName: device.name });
    return minted;
  }

  /** Counts a prompt passed on by the relay, or refuses it past the hourly limit; both are written to the audit log. */
  relayPrompt(ctx: AuthContext, detail: string, ip?: string): boolean {
    return this.relayCounted("relay_prompt", RELAY_PROMPTS_PER_HOUR, ctx, detail, ip);
  }

  /** The same for a conversation the relay opens. */
  relayConversation(ctx: AuthContext, detail: string, ip?: string): boolean {
    return this.relayCounted("relay_conversation", RELAY_CONVERSATIONS_PER_HOUR, ctx, detail, ip);
  }

  private relayCounted(type: "relay_prompt" | "relay_conversation", max: number, ctx: AuthContext, detail: string, ip?: string): boolean {
    const since = this.now() - 3600_000;
    const sent = (this.db.query("SELECT count(*) AS n FROM auth_events WHERE type = ? AND ok = 1 AND device_id = ? AND at > ?").get(type, ctx.deviceId, since) as Row).n as number;
    const allowed = sent < max;
    this.event(type, allowed, { ip, deviceId: ctx.deviceId, deviceName: ctx.deviceName, detail: allowed ? detail : `limit: ${detail}` });
    return allowed;
  }

  // Challenge / refresh / step-up

  challenge(): { nonce: string; expiresAt: string } {
    const t = this.now();
    for (const [n, exp] of this.nonces) if (exp < t) this.nonces.delete(n);
    while (this.nonces.size >= MAX_NONCES) this.nonces.delete(this.nonces.keys().next().value!);
    const nonce = randomBytes(32).toString("base64url");
    this.nonces.set(nonce, t + NONCE_TTL_MS);
    return { nonce, expiresAt: new Date(t + NONCE_TTL_MS).toISOString() };
  }

  private takeNonce(nonce: unknown): boolean {
    if (typeof nonce !== "string") return false;
    const exp = this.nonces.get(nonce);
    this.nonces.delete(nonce);
    return exp !== undefined && exp >= this.now();
  }

  private verifyDeviceSignature(purpose: "refresh" | "step-up", deviceId: string, b: { nonce?: unknown; signature?: unknown }): Row | Failure {
    const device = this.db.query("SELECT * FROM devices WHERE id = ?").get(deviceId) as Row | null;
    if (!device) return { status: 401, error: "unknown or revoked device: pair again", reauth: true };
    if (!device.public_key) return { status: 401, error: "this device was paired before device keys: pair again", reauth: true };
    if (!this.takeNonce(b.nonce)) return { status: 401, error: "unknown or expired nonce", reauth: false };
    if (typeof b.signature !== "string" || !verifyP256(device.public_key, signedMessage(purpose, deviceId, b.nonce as string), b.signature)) {
      return { status: 401, error: "invalid signature", reauth: false };
    }
    return device;
  }

  refresh(b: { deviceId?: unknown; nonce?: unknown; signature?: unknown }, ip: string): Result<TokenGrant> {
    const deviceId = typeof b.deviceId === "string" ? b.deviceId : "";
    const device = this.verifyDeviceSignature("refresh", deviceId, b);
    if (isFailure(device)) {
      this.event("refresh", false, { ip, deviceId: deviceId || undefined, detail: device.error });
      return device;
    }
    this.store.touchDevice(deviceId);
    this.event("refresh", true, { ip, deviceId, deviceName: device.name });
    return this.grant(deviceId);
  }

  /** `reason`: the action this Face ID is for, when that action takes only a step-up given for it (`BOUND_STEP_UP_REASONS`). */
  stepUp(ctx: AuthContext, b: { nonce?: unknown; signature?: unknown; reason?: unknown }, ip: string): Result<TokenGrant> {
    if (ctx.scope !== "app") return { status: 403, error: "extension tokens cannot step up" };
    if (b.reason !== undefined && (typeof b.reason !== "string" || !BOUND_STEP_UP_REASONS.has(b.reason))) return { status: 400, error: "unknown step-up reason" };
    const device = this.verifyDeviceSignature("step-up", ctx.deviceId, b);
    if (isFailure(device)) {
      this.event("step_up", false, { ip, deviceId: ctx.deviceId, deviceName: ctx.deviceName, detail: device.error });
      return device;
    }
    const reason = typeof b.reason === "string" ? b.reason : undefined;
    this.event("step_up", true, { ip, deviceId: ctx.deviceId, deviceName: ctx.deviceName, ...(reason ? { detail: reason } : {}) });
    return this.grant(ctx.deviceId, { stepUp: true, includeExtensions: false, stepUpReason: reason });
  }

  private mint(deviceId: string, cnf: string, scope: Scope, ttl: number, stepUpAt?: number, stepUpReason?: string): { token: string; expiresAt: string } {
    const t = this.now();
    const token = randomBytes(32).toString("base64url");
    this.db
      .query("INSERT INTO auth_tokens (token_hash, device_id, scope, step_up_at, step_up_reason, cnf, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
      .run(sha256(token), deviceId, scope, stepUpAt ?? null, stepUpReason ?? null, cnf, t, t + ttl);
    return { token, expiresAt: new Date(t + ttl).toISOString() };
  }

  private grant(deviceId: string, o: { stepUp?: boolean; stepUpReason?: string; forceExtensions?: boolean; includeExtensions?: boolean } = {}): TokenGrant {
    const t = this.now();
    this.db.query("DELETE FROM auth_tokens WHERE expires_at < ?").run(t);
    const key = (this.db.query("SELECT public_key FROM devices WHERE id = ?").get(deviceId) as Row).public_key as string;
    const cnf = thumbprint(key);
    const access = this.mint(deviceId, cnf, "app", ACCESS_TTL_MS, o.stepUp ? t : undefined, o.stepUp ? o.stepUpReason : undefined);
    const grant: TokenGrant = { deviceId, accessToken: access.token, expiresAt: access.expiresAt, cnf };
    if (o.stepUp) grant.stepUpUntil = new Date(t + STEP_UP_WINDOW_MS).toISOString();
    if (o.includeExtensions !== false) {
      const ext: TokenGrant["extensionTokens"] = {};
      for (const scope of EXTENSION_SCOPES) {
        const newest = this.db.query("SELECT max(created_at) AS at FROM auth_tokens WHERE device_id = ? AND scope = ?").get(deviceId, scope) as Row;
        if (o.forceExtensions || !newest.at || t - newest.at > EXTENSION_ROTATE_MS) ext[scope] = this.mint(deviceId, cnf, scope, EXTENSION_TTL_MS);
      }
      if (Object.keys(ext).length) grant.extensionTokens = ext;
    }
    return grant;
  }

  // Request authentication

  authenticate(req: Request, ip: string): AuthContext | Failure {
    const token = bearer(req);
    if (!token) return { status: 401, error: "unauthorized" };
    const hash = sha256(token);
    const row = this.db
      .query("SELECT t.device_id, t.scope, t.step_up_at, t.expires_at, t.cnf, d.name, d.public_key FROM auth_tokens t JOIN devices d ON d.id = t.device_id WHERE t.token_hash = ?")
      .get(hash) as Row | null;
    // A token minted for another key of this device id (re-keyed or tampered row) is not honoured.
    if (row && (!row.public_key || !timingSafeEqual(Buffer.from(thumbprint(row.public_key)), Buffer.from(row.cnf)))) {
      return { status: 401, error: "token is not bound to this device key", reauth: true };
    }
    if (row && row.expires_at >= this.now()) {
      this.touch(row.device_id);
      return { profileId: this.profileId, deviceId: row.device_id, deviceName: row.name, scope: row.scope as Scope, stepUpAt: row.step_up_at ?? undefined, expiresAt: row.expires_at };
    }
    if (row) return { status: 401, error: "access token expired", reauth: false };
    const legacy = this.store.deviceByTokenHash(hash);
    if (legacy) {
      const last = this.legacyLogged.get(legacy.id) ?? 0;
      if (this.now() - last > 3600_000) {
        this.legacyLogged.set(legacy.id, this.now());
        this.event("legacy_token", false, { ip, deviceId: legacy.id, deviceName: legacy.name });
      }
      return { status: 401, error: "security upgrade: this device must pair again with a 2FA code", reauth: true };
    }
    return { status: 401, error: "invalid or expired access token", reauth: false, unknown: true };
  }

  /**
   * Clears the step-up of the request's token; false when another request already used it, or, with `reason`, when
   * that step-up was not taken for it.
   */
  consumeStepUp(req: Request, reason?: string): boolean {
    const token = bearer(req);
    if (!token) return false;
    return (
      this.db
        .query("UPDATE auth_tokens SET step_up_at = NULL, step_up_reason = NULL WHERE token_hash = ?1 AND step_up_at IS NOT NULL AND (?2 IS NULL OR step_up_reason = ?2)")
        .run(sha256(token), reason ?? null).changes > 0
    );
  }

  stepUpFresh(ctx: AuthContext): boolean {
    return ctx.scope === "app" && ctx.stepUpAt !== undefined && this.now() - ctx.stepUpAt <= STEP_UP_WINDOW_MS;
  }

  private touch(deviceId: string) {
    const last = this.touched.get(deviceId) ?? 0;
    if (this.now() - last < 60_000) return;
    this.touched.set(deviceId, this.now());
    this.store.touchDevice(deviceId);
  }

  // Devices

  devices(): AuthDevice[] {
    return (this.db.query("SELECT * FROM devices ORDER BY created_at").all() as Row[]).map((r) => ({
      id: r.id,
      name: r.name,
      platform: r.platform ?? undefined,
      createdAt: r.created_at,
      lastSeenAt: r.last_seen_at ?? undefined,
      legacy: !r.public_key,
    }));
  }

  /** Deleting the row cascades to its tokens: the next request with any of them is refused. */
  revoke(id: string, by: { ctx?: AuthContext; ip?: string; via?: string }): boolean {
    const device = this.db.query("SELECT name FROM devices WHERE id = ?").get(id) as Row | null;
    if (!device) return false;
    this.db.query("DELETE FROM devices WHERE id = ?").run(id);
    this.touched.delete(id);
    this.opts.relayRevoked?.(id);
    this.event("revoke", true, { ip: by.ip, deviceId: id, deviceName: device.name, detail: by.via ?? (by.ctx ? `by ${by.ctx.deviceName}` : undefined) });
    return true;
  }

  networkInfo(): NetworkInfo {
    return this.opts.network ?? {};
  }

  /** Summary of requests that came through the tunnel; kept 30 days. */
  logRequest(r: { ip: string; method: string; path: string; status: number; deviceId?: string }) {
    const t = this.now();
    this.db.query("INSERT INTO auth_requests (at, ip, method, route, status, device_id) VALUES (?, ?, ?, ?, ?, ?)").run(t, r.ip, r.method, r.path.slice(0, 200), r.status, r.deviceId ?? null);
    if (++this.logged % 500 === 1) this.db.query("DELETE FROM auth_requests WHERE at < ?").run(t - 30 * 24 * 3600 * 1000);
  }

  /** Data of the app's « Activité de sécurité » screen. */
  activity(limit = 100) {
    const since = this.now() - 7 * 24 * 3600 * 1000;
    const names = new Map((this.db.query("SELECT id, name FROM devices").all() as Row[]).map((r) => [r.id, r.name]));
    const internet = (this.db.query("SELECT ip, device_id, count(*) AS n, sum(status >= 400) AS errors, max(at) AS last FROM auth_requests WHERE at > ? GROUP BY ip, device_id ORDER BY last DESC LIMIT 50").all(since) as Row[]).map((r) => ({
      ip: r.ip,
      deviceId: r.device_id ?? undefined,
      deviceName: r.device_id ? names.get(r.device_id) : undefined,
      requests: r.n,
      errors: r.errors ?? 0,
      lastAt: new Date(r.last).toISOString(),
    }));
    return { events: this.events(limit), internet, recoveryCodesLeft: this.recoveryCodesLeft(), totp: this.totpConfigured() };
  }

  // Local token

  isLocalToken(req: Request): boolean {
    const token = bearer(req);
    if (!token || !this.opts.localToken) return false;
    return timingSafeEqual(Buffer.from(sha256(token)), Buffer.from(sha256(this.opts.localToken)));
  }
}
