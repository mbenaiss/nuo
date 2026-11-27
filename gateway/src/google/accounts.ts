import type { Database } from "bun:sqlite";
import { hkdfSync } from "node:crypto";
import { open, seal } from "../auth/keys";
import type { AuthEventType } from "../auth/service";
import { HttpError } from "../bots/service";
import { GoogleAuthError, SERVICE_SCOPES, servicesOf, type GoogleOAuth, type GoogleService } from "./oauth";

export interface GoogleAccountInfo {
  email: string;
  services: GoogleService[];
  status: "ok" | "error";
  lastError?: string;
  connectedAt: string;
  updatedAt: string;
  lastUsedAt?: string;
}

export const SERVICE_LABELS: Record<GoogleService, string> = { gmail: "Gmail", drive: "Drive", calendar: "Agenda" };

export type GoogleAudit = (type: AuthEventType, ok: boolean, info: { deviceId?: string; deviceName?: string; detail?: string }) => void;

export interface GoogleAccountsOptions {
  db: Database;
  oauth: GoogleOAuth;
  /** NUO_AUTH_KEY; without it no token can be stored. */
  authKey?: Buffer;
  profileId: string;
  audit?: GoogleAudit;
  /** Another profile holds a token for this email too: revoking would end its grant as well. */
  sharedElsewhere?: (email: string) => boolean;
}

type Row = { email: string; sub: string | null; scopes: string; token_enc: string; status: string; last_error: string | null; connected_at: string; updated_at: string; last_used_at: string | null };

const EARLY_REFRESH_MS = 60_000;

/** One profile's Google accounts: refresh tokens sealed in its nuo.db, which only the gateway user can read. */
export class GoogleAccounts {
  private key?: Buffer;
  private cache = new Map<string, { token: string; expiresAt: number }>();
  private refreshing = new Map<string, Promise<string>>();
  private readonly now: () => number;

  constructor(private o: GoogleAccountsOptions) {
    // A key of its own: a leaked Google row cannot be opened with the TOTP sealing key and vice versa.
    if (o.authKey) this.key = Buffer.from(hkdfSync("sha256", o.authKey, Buffer.alloc(0), "nuo:google-refresh-token:v1", 32));
    this.now = o.oauth.now;
  }

  get oauth(): GoogleOAuth {
    return this.o.oauth;
  }

  get profileId(): string {
    return this.o.profileId;
  }

  audit(type: AuthEventType, ok: boolean, info: { deviceId?: string; deviceName?: string; detail?: string }) {
    this.o.audit?.(type, ok, info);
  }

  get canStore(): boolean {
    return !!this.key;
  }

  private get db() {
    return this.o.db;
  }

  private iso(t = this.now()) {
    return new Date(t).toISOString();
  }

  private row(email: string): Row | undefined {
    return (this.db.query("SELECT * FROM google_accounts WHERE email = ?").get(email.toLowerCase()) as Row | null) ?? undefined;
  }

  has(email: string): boolean {
    return !!this.row(email);
  }

  list(): GoogleAccountInfo[] {
    return (this.db.query("SELECT * FROM google_accounts ORDER BY connected_at").all() as Row[]).map((r) => ({
      email: r.email,
      services: servicesOf(r.scopes.split(" ")),
      status: r.status === "error" ? "error" : "ok",
      ...(r.last_error ? { lastError: r.last_error } : {}),
      connectedAt: r.connected_at,
      updatedAt: r.updated_at,
      ...(r.last_used_at ? { lastUsedAt: r.last_used_at } : {}),
    }));
  }

  private sealToken(email: string, refreshToken: string): string {
    return seal(this.key!, Buffer.from(JSON.stringify({ email, refreshToken })));
  }

  private openToken(r: Row): string {
    if (!this.key) throw new HttpError(503, "NUO_AUTH_KEY is missing: Google tokens cannot be read");
    const v = JSON.parse(open(this.key, r.token_enc).toString("utf8"));
    // The email is sealed with the token: a row copied under another address does not open.
    if (v?.email !== r.email || typeof v.refreshToken !== "string") throw new HttpError(500, `sealed Google token of ${r.email} does not match its row`);
    return v.refreshToken;
  }

  /** After a consent: a new account, or more scopes and a new refresh token for a known one. */
  save(a: { email: string; sub?: string; scopes: string[]; refreshToken?: string; accessToken?: string; expiresAt?: number }): GoogleAccountInfo {
    if (!this.key) throw new HttpError(503, "NUO_AUTH_KEY is missing: Google tokens cannot be stored");
    const email = a.email.toLowerCase();
    const existing = this.row(email);
    const refreshToken = a.refreshToken ?? (existing ? this.openToken(existing) : undefined);
    if (!refreshToken) throw new GoogleAuthError("Google returned no refresh token: remove Nuo from https://myaccount.google.com/permissions and connect again");
    const scopes = [...new Set(a.scopes)].join(" ");
    const t = this.iso();
    this.db
      .query(
        `INSERT INTO google_accounts (email, sub, scopes, token_enc, status, last_error, connected_at, updated_at) VALUES (?, ?, ?, ?, 'ok', NULL, ?, ?)
         ON CONFLICT(email) DO UPDATE SET sub = coalesce(excluded.sub, sub), scopes = excluded.scopes, token_enc = excluded.token_enc, status = 'ok', last_error = NULL, updated_at = excluded.updated_at`,
      )
      .run(email, a.sub ?? null, scopes, this.sealToken(email, refreshToken), t, t);
    if (a.accessToken && a.expiresAt) this.cache.set(email, { token: a.accessToken, expiresAt: a.expiresAt });
    else this.cache.delete(email);
    return this.list().find((x) => x.email === email)!;
  }

  /** Revokes at Google (unless another profile still uses the same grant) and forgets the account. */
  async remove(email: string, by: { deviceId?: string; deviceName?: string } = {}): Promise<{ revoked: boolean }> {
    const r = this.row(email);
    if (!r) throw new HttpError(404, "Google account not found");
    let revoked = false;
    if (!this.o.sharedElsewhere?.(r.email)) {
      const token = (() => {
        try {
          return this.openToken(r);
        } catch {
          return undefined;
        }
      })();
      revoked = token ? await this.o.oauth.revoke(token) : false;
    }
    this.db.query("DELETE FROM google_accounts WHERE email = ?").run(r.email);
    this.cache.delete(r.email);
    this.audit("google_disconnect", true, { ...by, detail: `${r.email}${revoked ? "" : " (not revoked at Google)"}` });
    return { revoked };
  }

  /** The account a tool works on: the one named, else the only one that granted the service. */
  resolve(service: GoogleService, email?: string): string {
    const all = this.list();
    const label = SERVICE_LABELS[service];
    if (!all.length) throw new HttpError(404, "Aucun compte Google n'est connecté à ce profil : l'utilisateur peut en ajouter un dans l'app Nuo, Réglages › Comptes Google.");
    if (email) {
      const a = all.find((x) => x.email === email.trim().toLowerCase());
      if (!a) throw new HttpError(404, `Le compte ${email} n'est pas connecté. Comptes connectés : ${all.map((x) => x.email).join(", ")}.`);
      if (!a.services.includes(service)) throw new HttpError(403, `Le compte ${a.email} n'a pas autorisé ${label} : l'utilisateur doit le reconnecter avec ${label} dans Réglages › Comptes Google.`);
      return a.email;
    }
    const withService = all.filter((x) => x.services.includes(service));
    if (withService.length === 1) return withService[0]!.email;
    if (!withService.length) throw new HttpError(403, `Aucun compte connecté n'a autorisé ${label} : l'utilisateur peut l'ajouter dans Réglages › Comptes Google.`);
    throw new HttpError(400, `Plusieurs comptes ont ${label} : précise account parmi ${withService.map((x) => x.email).join(", ")}.`);
  }

  async accessToken(email: string, service: GoogleService): Promise<string> {
    const r = this.row(email);
    if (!r) throw new HttpError(404, `Le compte ${email} n'est pas connecté.`);
    if (!r.scopes.split(" ").includes(SERVICE_SCOPES[service])) throw new HttpError(403, `Le compte ${email} n'a pas autorisé ${SERVICE_LABELS[service]}.`);
    const cached = this.cache.get(r.email);
    if (cached && cached.expiresAt - EARLY_REFRESH_MS > this.now()) return cached.token;
    let p = this.refreshing.get(r.email);
    if (!p) {
      p = this.refreshNow(r).finally(() => this.refreshing.delete(r.email));
      this.refreshing.set(r.email, p);
    }
    return p;
  }

  /** A 401 from an API: the cached token is dropped and the next call refreshes. */
  invalidate(email: string) {
    this.cache.delete(email.toLowerCase());
  }

  private async refreshNow(r: Row): Promise<string> {
    try {
      const t = await this.o.oauth.refresh(this.openToken(r));
      this.cache.set(r.email, { token: t.accessToken, expiresAt: t.expiresAt });
      if (t.refreshToken) {
        this.db.query("UPDATE google_accounts SET token_enc = ? WHERE email = ?").run(this.sealToken(r.email, t.refreshToken), r.email);
      }
      this.db.query("UPDATE google_accounts SET status = 'ok', last_error = NULL, last_used_at = ? WHERE email = ?").run(this.iso(), r.email);
      return t.accessToken;
    } catch (e) {
      if (e instanceof GoogleAuthError && e.invalidGrant) {
        const msg = "Accès révoqué ou expiré : reconnecte ce compte.";
        if (r.status !== "error") this.audit("google_error", false, { detail: `${r.email}: invalid_grant` });
        this.db.query("UPDATE google_accounts SET status = 'error', last_error = ?, updated_at = ? WHERE email = ?").run(msg, this.iso(), r.email);
        throw new HttpError(409, `Le compte ${r.email} doit être reconnecté par l'utilisateur (Réglages › Comptes Google) : ${msg}`);
      }
      throw new HttpError(502, (e as Error)?.message ?? String(e));
    }
  }
}
