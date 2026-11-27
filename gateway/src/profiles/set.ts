import { timingSafeEqual } from "node:crypto";
import { existsSync, realpathSync } from "node:fs";
import { normalizePublicKey, sha256 } from "../auth/keys";
import type { GateAuth } from "../auth/routes";
import { bearer, FAIL_WINDOW_MS, isFailure, MAX_FAILS_PER_IP, MAX_FAILS_TOTAL, type AuthContext, type Failure, type TokenGrant } from "../auth/service";
import { join } from "node:path";
import { profileLayout, treeLayout, type GlobalLayout, type Layout } from "../paths";
import type { NuoEndpoint } from "../runner/runner";
import { OWNER, profileKey, type Profile, Registry } from "./registry";
import { ProfileStack, type StackOptions } from "./stack";

/** Failed pairings for one typed profile name (existing or not) within FAIL_WINDOW_MS lock that name. */
export const MAX_FAILS_PER_PROFILE = 10;
/** Every pairing answer takes at least this long, so an unknown profile and a wrong code cannot be told apart by timing. */
export const PAIR_MIN_MS = 400;
export const PAIR_FAILED = "invalid profile, pairing code or 2FA code";
const SYNC_MS = 5_000;

export interface ProfileSetOptions {
  global: GlobalLayout;
  /** NUO_DATA_DIR / NUO_CONFIG_DIR: the owner's data and config only. */
  ownerOver?: { data?: string; config?: string };
  /** Everything a stack needs but its profile, layout and host. */
  stack: (profile: Profile, layout: Layout) => Omit<StackOptions, "profile" | "nonces">;
  authNow?: () => number;
  /** Minimum duration of a pairing answer (tests lower it). */
  pairMinMs?: number;
  /** NUO_MACHINE_TOKEN: a standing credential for another host, owner profile, conversations only. */
  machineToken?: string;
}

/** The profiles a gateway serves, kept in step with the registry the CLI edits (creation, disabling, deletion). */
export class ProfileSet implements GateAuth {
  readonly registry: Registry;
  private stacks = new Map<string, ProfileStack>();
  private endpoint?: NuoEndpoint;
  private timer?: ReturnType<typeof setInterval>;
  private readonly nonces = new Map<string, number>();
  private readonly now: () => number;
  private syncing?: Promise<void>;

  constructor(private o: ProfileSetOptions) {
    this.registry = new Registry(o.global.registry);
    this.registry.ensureOwner();
    this.now = o.authNow ?? Date.now;
    for (const p of this.registry.list()) if (!p.disabledAt) this.open(p);
  }

  get owner(): ProfileStack {
    return this.stacks.get(OWNER)!;
  }

  all(): ProfileStack[] {
    return [...this.stacks.values()];
  }

  stack(id: string): ProfileStack | undefined {
    return this.stacks.get(id);
  }

  layout(id: string) {
    const layout = profileLayout(this.o.global, id, id === OWNER ? this.o.ownerOver : {});
    // Agent paths must not go through the owner's home, which profile users cannot traverse: once
    // scripts/profile-os-setup.sh moved the tree to /srv/nuo/<slug>, its real path is used everywhere.
    if (id !== OWNER && existsSync(layout.home)) return treeLayout(realpathSync(layout.home), layout.nuo, join(realpathSync(layout.home), "config"));
    return layout;
  }

  private open(p: Profile): ProfileStack {
    const layout = this.layout(p.id);
    const stack = new ProfileStack(layout, { ...this.o.stack(p, layout), profile: p, nonces: this.nonces });
    this.stacks.set(p.id, stack);
    if (this.endpoint) stack.start(this.endpoint);
    return stack;
  }

  start(endpoint: NuoEndpoint) {
    this.endpoint = endpoint;
    for (const s of this.stacks.values()) s.start(endpoint);
    this.timer = setInterval(() => void this.sync(), SYNC_MS);
    this.timer.unref?.();
  }

  /** Opens new or re-enabled profiles, closes disabled or deleted ones (their sockets close, their tokens stop working). */
  sync(): Promise<void> {
    this.syncing ??= (async () => {
      const wanted = new Map(this.registry.list().filter((p) => !p.disabledAt).map((p) => [p.id, p]));
      for (const [id, s] of this.stacks) {
        const p = wanted.get(id);
        if (p) {
          s.profile = p;
          continue;
        }
        this.stacks.delete(id);
        await s.stop().catch((e) => console.error(`[profiles] closing ${id}:`, e));
        console.log(`[profiles] ${id} closed`);
      }
      for (const [id, p] of wanted) {
        if (this.stacks.has(id)) continue;
        try {
          this.open(p);
          console.log(`[profiles] ${id} opened`);
        } catch (e) {
          console.error(`[profiles] cannot open ${id}:`, e);
        }
      }
    })().finally(() => (this.syncing = undefined));
    return this.syncing;
  }

  async stop() {
    clearInterval(this.timer);
    for (const s of this.stacks.values()) s.noteInterrupted();
    for (const s of this.stacks.values()) await s.stop().catch((e) => console.error(e));
    this.stacks.clear();
    this.registry.close();
  }

  // GateAuth

  profile(id: string) {
    return this.stacks.get(id);
  }

  event: GateAuth["event"] = (type, ok, info) => this.owner.auth.event(type, ok, info);

  challenge() {
    return this.owner.auth.challenge();
  }

  private byDevice(deviceId: string): ProfileStack | undefined {
    if (!deviceId) return undefined;
    for (const s of this.stacks.values()) if (s.auth.hasDevice(deviceId)) return s;
    return undefined;
  }

  refresh(b: Record<string, unknown>, ip: string): TokenGrant | Failure {
    const deviceId = typeof b.deviceId === "string" ? b.deviceId : "";
    // An unknown device gets the owner's answer (and audit line): the same as before profiles existed.
    return (this.byDevice(deviceId) ?? this.owner).auth.refresh(b, ip);
  }

  relayToken(b: Record<string, unknown>, ip: string): { token: string; expiresAt: string } | Failure {
    const deviceId = typeof b.deviceId === "string" ? b.deviceId : "";
    return (this.byDevice(deviceId) ?? this.owner).auth.relayToken(b, ip);
  }

  authenticate(req: Request, ip: string): AuthContext | Failure {
    let last: Failure | undefined;
    for (const s of this.stacks.values()) {
      const r = s.auth.authenticate(req, ip);
      if (!isFailure(r) || !r.unknown) return r;
      last = r;
    }
    return last ?? { status: 401, error: "unauthorized" };
  }

  /** The owner's profile when the request carries the machine token; the gate decides which zones may use it. */
  machineProfile(req: Request): string | undefined {
    const token = bearer(req);
    if (!token || !this.o.machineToken) return undefined;
    const matches = timingSafeEqual(Buffer.from(sha256(token)), Buffer.from(sha256(this.o.machineToken)));
    return matches ? OWNER : undefined;
  }

  localProfile(req: Request): string | undefined {
    const token = bearer(req);
    if (!token) return undefined;
    const hash = Buffer.from(sha256(token));
    for (const s of this.stacks.values()) if (timingSafeEqual(hash, Buffer.from(sha256(s.localToken)))) return s.id;
    return undefined;
  }

  logRequest(r: { ip: string; method: string; path: string; status: number; deviceId?: string; profileId?: string }) {
    const s = (r.profileId && this.stacks.get(r.profileId)) || this.owner;
    s.auth.logRequest(r);
  }

  // Pairing

  private lockout(ip: string, key: string): Failure | undefined {
    const fails = this.registry.pairFailures(this.now() - FAIL_WINDOW_MS);
    const mine = fails.filter((f) => f.ip === ip);
    const named = fails.filter((f) => f.key === key);
    const blocking =
      fails.length >= MAX_FAILS_TOTAL
        ? fails[fails.length - MAX_FAILS_TOTAL]
        : mine.length >= MAX_FAILS_PER_IP
          ? mine[mine.length - MAX_FAILS_PER_IP]
          : named.length >= MAX_FAILS_PER_PROFILE
            ? named[named.length - MAX_FAILS_PER_PROFILE]
            : undefined;
    if (!blocking) return undefined;
    return { status: 429, error: "too many failed attempts: pairing is locked for a while", retryAt: new Date(blocking.at + FAIL_WINDOW_MS).toISOString() };
  }

  async pair(b: Record<string, unknown>, ip: string): Promise<(TokenGrant & { profile: { id: string; name: string } }) | Failure> {
    const started = Date.now();
    const r = this.pairNow(b, ip);
    const wait = (this.o.pairMinMs ?? PAIR_MIN_MS) - (Date.now() - started);
    if (wait > 0) await Bun.sleep(wait);
    return r;
  }

  private pairNow(b: Record<string, unknown>, ip: string): (TokenGrant & { profile: { id: string; name: string } }) | Failure {
    const name = (typeof b.deviceName === "string" ? b.deviceName.trim().slice(0, 80) : "") || "iPhone";
    if (typeof b.publicKey !== "string" || typeof b.totp !== "string" || typeof b.profile !== "string") {
      return { status: 400, error: "this version of the app is too old: update Nuo to pair (profile, device key and 2FA code are required)" };
    }
    const key = profileKey(b.profile);
    const locked = this.lockout(ip, key);
    if (locked) {
      this.owner.auth.event("pair", false, { ip, deviceName: name, detail: "locked" });
      return locked;
    }
    let publicKey: string;
    try {
      publicKey = normalizePublicKey(b.publicKey);
    } catch {
      return { status: 400, error: "publicKey must be a P-256 public key (base64 SPKI or X9.63)" };
    }
    if (!this.owner.auth.canPair()) return { status: 503, error: "2FA cannot be checked on the gateway (NUO_AUTH_KEY is missing)" };
    const p = this.registry.find(b.profile);
    const stack = p && !p.disabledAt ? this.stacks.get(p.id) : undefined;
    const r = stack ? stack.auth.pairDevice(b, name, publicKey, ip) : { detail: "unknown profile" };
    if ("grant" in r) return { ...r.grant, profile: { id: stack!.id, name: stack!.profile.name } };

    this.registry.recordPairFailure({ at: this.now(), ip, key });
    // The person behind the profile sees failures on their account; the owner sees every one (with the name typed).
    stack?.auth.event("pair", false, { ip, deviceName: name, detail: r.detail });
    if (stack !== this.owner) this.owner.auth.event("pair", false, { ip, deviceName: name, detail: `${r.detail} (profile "${key.slice(0, 40)}")` });
    const recent = this.registry.pairFailures(this.now() - FAIL_WINDOW_MS).length;
    if (recent === 3 || recent === MAX_FAILS_PER_IP || recent === MAX_FAILS_TOTAL) {
      const body = `${recent} tentatives d'appairage échouées en 15 min (dernière depuis ${ip}).`;
      this.owner.alert("Nuo · échecs d'appairage", body);
      if (stack && stack !== this.owner) stack.alert("Nuo · échecs d'appairage", body);
    }
    return { status: 401, error: PAIR_FAILED };
  }
}
