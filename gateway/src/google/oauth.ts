import { createHash, randomBytes } from "node:crypto";
import { HttpError } from "../bots/service";
import { isEmail } from "../calendar/validate";

export const GOOGLE_SERVICES = ["gmail", "drive", "calendar"] as const;
export type GoogleService = (typeof GOOGLE_SERVICES)[number];

export const SERVICE_SCOPES: Record<GoogleService, string> = {
  gmail: "https://www.googleapis.com/auth/gmail.modify",
  drive: "https://www.googleapis.com/auth/drive",
  calendar: "https://www.googleapis.com/auth/calendar",
};
const IDENTITY_SCOPES = ["openid", "email"];

/** Served on every host, the public booking one included: Google redirects the user's browser there, outside Cloudflare Access. */
export const CALLBACK_PATH = "/oauth/google/callback";
/** ASWebAuthenticationSession waits for this scheme (the app's own) to close the sheet. */
export const APP_RETURN_URL = "nuo://google/connected";
export const STATE_TTL_MS = 10 * 60 * 1000;
const MAX_PENDING = 100;

export interface GoogleEndpoints {
  auth: string;
  token: string;
  revoke: string;
  gmail: string;
  drive: string;
  calendar: string;
}

export const GOOGLE_ENDPOINTS: GoogleEndpoints = {
  auth: "https://accounts.google.com/o/oauth2/v2/auth",
  token: "https://oauth2.googleapis.com/token",
  revoke: "https://oauth2.googleapis.com/revoke",
  gmail: "https://gmail.googleapis.com/gmail/v1",
  drive: "https://www.googleapis.com/drive/v3",
  calendar: "https://www.googleapis.com/calendar/v3",
};

export interface GoogleOAuthOptions {
  clientId?: string;
  clientSecret?: string;
  /** Must be listed as an authorized redirect URI of the Google « Web application » client. */
  redirectUri?: string;
  endpoints?: Partial<GoogleEndpoints>;
  fetch?: typeof fetch;
  now?: () => number;
}

export function googleOAuthOptionsFromEnv(env: Record<string, string | undefined> = process.env): GoogleOAuthOptions {
  const booking = (env.NUO_BOOKING_BASE_URL || "").replace(/\/+$/, "");
  return {
    clientId: env.GOOGLE_OAUTH_CLIENT_ID || undefined,
    clientSecret: env.GOOGLE_OAUTH_CLIENT_SECRET || undefined,
    redirectUri: env.GOOGLE_OAUTH_REDIRECT_URI || (booking ? `${booking}${CALLBACK_PATH}` : undefined),
  };
}

export interface PendingConnect {
  profileId: string;
  deviceId: string;
  deviceName: string;
  services: GoogleService[];
  verifier: string;
  expiresAt: number;
}

export interface TokenSet {
  accessToken: string;
  expiresAt: number;
  refreshToken?: string;
  scopes: string[];
  idToken?: string;
}

export class GoogleAuthError extends Error {
  constructor(
    message: string,
    /** The refresh token is dead (revoked, expired or the password changed): only a new consent fixes it. */
    readonly invalidGrant = false,
  ) {
    super(message);
  }
}

const b64url = (b: Buffer) => b.toString("base64url");

export function servicesOf(scopes: string[]): GoogleService[] {
  return GOOGLE_SERVICES.filter((s) => scopes.includes(SERVICE_SCOPES[s]));
}

export function parseServices(v: unknown): GoogleService[] {
  const list = Array.isArray(v) ? v : [];
  const out = GOOGLE_SERVICES.filter((s) => list.includes(s));
  if (!out.length || out.length !== new Set(list).size) throw new HttpError(400, `services must be a non-empty subset of ${GOOGLE_SERVICES.join(", ")}`);
  return out;
}

/** The id_token comes straight from Google's token endpoint over TLS, so its claims are read without checking the signature (OIDC Core 3.1.3.7). */
export function idTokenClaims(idToken: string | undefined): { email?: string; sub?: string; emailVerified?: boolean } {
  const part = idToken?.split(".")[1];
  if (!part) return {};
  try {
    const c = JSON.parse(Buffer.from(part, "base64url").toString("utf8"));
    return { email: typeof c.email === "string" ? c.email.toLowerCase() : undefined, sub: typeof c.sub === "string" ? c.sub : undefined, emailVerified: c.email_verified === true };
  } catch {
    return {};
  }
}

/** The gateway-wide Google OAuth client: authorization URLs, pending consents (in memory, single use) and token calls. */
export class GoogleOAuth {
  readonly endpoints: GoogleEndpoints;
  private pending = new Map<string, PendingConnect>();
  readonly now: () => number;
  private readonly http: typeof fetch;

  constructor(private o: GoogleOAuthOptions = {}) {
    this.endpoints = { ...GOOGLE_ENDPOINTS, ...o.endpoints };
    this.now = o.now ?? Date.now;
    this.http = o.fetch ?? fetch;
  }

  get configured(): boolean {
    return !!(this.o.clientId && this.o.clientSecret && this.o.redirectUri);
  }

  get redirectUri(): string | undefined {
    return this.o.redirectUri;
  }

  begin(p: Omit<PendingConnect, "verifier" | "expiresAt">, loginHint?: string): { url: string; expiresAt: string } {
    if (!this.configured) throw new HttpError(503, "Google is not configured on the gateway (GOOGLE_OAUTH_CLIENT_ID, GOOGLE_OAUTH_CLIENT_SECRET, GOOGLE_OAUTH_REDIRECT_URI)");
    this.prune();
    if (this.pending.size >= MAX_PENDING) throw new HttpError(429, "too many Google connections in progress, try again in a few minutes");
    const state = b64url(randomBytes(32));
    const verifier = b64url(randomBytes(48));
    const expiresAt = this.now() + STATE_TTL_MS;
    this.pending.set(state, { ...p, verifier, expiresAt });
    const q = new URLSearchParams({
      client_id: this.o.clientId!,
      redirect_uri: this.o.redirectUri!,
      response_type: "code",
      scope: [...IDENTITY_SCOPES, ...p.services.map((s) => SERVICE_SCOPES[s])].join(" "),
      access_type: "offline",
      // consent: Google only returns a refresh token on a fresh consent; select_account: the user picks among his accounts.
      prompt: "consent select_account",
      include_granted_scopes: "true",
      state,
      code_challenge: b64url(createHash("sha256").update(verifier).digest()),
      code_challenge_method: "S256",
    });
    if (loginHint && isEmail(loginHint)) q.set("login_hint", loginHint);
    return { url: `${this.endpoints.auth}?${q}`, expiresAt: new Date(expiresAt).toISOString() };
  }

  /** Single use: a state is gone once read, valid or not. */
  take(state: string | null): PendingConnect | undefined {
    if (!state) return undefined;
    const p = this.pending.get(state);
    this.pending.delete(state);
    return p && p.expiresAt > this.now() ? p : undefined;
  }

  private prune() {
    const t = this.now();
    for (const [k, p] of this.pending) if (p.expiresAt <= t) this.pending.delete(k);
  }

  private async tokenCall(params: Record<string, string>): Promise<TokenSet> {
    let res: Response;
    try {
      res = await this.http(this.endpoints.token, {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
        body: new URLSearchParams({ client_id: this.o.clientId ?? "", client_secret: this.o.clientSecret ?? "", ...params }),
        signal: AbortSignal.timeout(20_000),
      });
    } catch (e) {
      throw new GoogleAuthError(`Google token endpoint unreachable: ${(e as Error)?.message ?? e}`);
    }
    const data = (await res.json().catch(() => ({}))) as Record<string, any>;
    if (!res.ok || typeof data.access_token !== "string") {
      const code = typeof data.error === "string" ? data.error : `HTTP ${res.status}`;
      throw new GoogleAuthError(`Google refused the token request: ${code}${data.error_description ? ` (${String(data.error_description).slice(0, 200)})` : ""}`, code === "invalid_grant");
    }
    return {
      accessToken: data.access_token,
      expiresAt: this.now() + Math.max(60, Number(data.expires_in) || 3600) * 1000,
      refreshToken: typeof data.refresh_token === "string" ? data.refresh_token : undefined,
      scopes: typeof data.scope === "string" ? data.scope.split(/\s+/).filter(Boolean) : [],
      idToken: typeof data.id_token === "string" ? data.id_token : undefined,
    };
  }

  exchange(code: string, verifier: string): Promise<TokenSet> {
    return this.tokenCall({ grant_type: "authorization_code", code, code_verifier: verifier, redirect_uri: this.o.redirectUri ?? "" });
  }

  refresh(refreshToken: string): Promise<TokenSet> {
    return this.tokenCall({ grant_type: "refresh_token", refresh_token: refreshToken });
  }

  /** Revoking a refresh token ends the whole grant of that Google account to this client. */
  async revoke(token: string): Promise<boolean> {
    try {
      const res = await this.http(this.endpoints.revoke, {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ token }),
        signal: AbortSignal.timeout(20_000),
      });
      // 400 invalid_token: already revoked on Google's side, which is the goal.
      return res.ok || res.status === 400;
    } catch {
      return false;
    }
  }

  fetch(url: string, init: RequestInit): Promise<Response> {
    return this.http(url, init);
  }
}
