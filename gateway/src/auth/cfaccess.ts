/**
 * Checks the `Cf-Access-Jwt-Assertion` Cloudflare Access adds to each request it lets through: without it, any
 * process that reaches the gateway port from a tunnel or proxy host would count as "passed Access".
 */
export interface CfAccessConfig {
  /** `<team>.cloudflareaccess.com`: the token's issuer and where its signing keys are published. */
  teamDomain: string;
  /** The Access application's audience tag. */
  aud: string;
}

export function cfAccessFromEnv(env: Record<string, string | undefined> = process.env): CfAccessConfig | undefined {
  const teamDomain = env.NUO_CF_ACCESS_TEAM?.trim().replace(/^https?:\/\//, "").replace(/\/+$/, "");
  const aud = env.NUO_CF_ACCESS_AUD?.trim();
  return teamDomain && aud ? { teamDomain, aud } : undefined;
}

const KEYS_TTL_MS = 60 * 60 * 1000;
/** An unknown key id refetches the keys at most this often, so forged tokens cannot hammer Cloudflare. */
const REFETCH_MIN_MS = 60 * 1000;
const CLOCK_SKEW_S = 60;

type Jwk = JsonWebKey & { kid?: string };

const b64url = (s: string) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(s.length / 4) * 4, "=")), (c) => c.charCodeAt(0));
const decodeJson = (s: string): Record<string, unknown> | undefined => {
  try {
    const v = JSON.parse(new TextDecoder().decode(b64url(s)));
    return v && typeof v === "object" ? (v as Record<string, unknown>) : undefined;
  } catch {
    return undefined;
  }
};

export class CfAccessVerifier {
  private keys = new Map<string, CryptoKey>();
  private fetchedAt = -Infinity;

  constructor(
    private readonly cfg: CfAccessConfig,
    private readonly fetchKeys: (url: string) => Promise<{ keys?: Jwk[] }> = async (url) => (await fetch(url, { signal: AbortSignal.timeout(5000) })).json() as Promise<{ keys?: Jwk[] }>,
    private readonly now: () => number = Date.now,
  ) {}

  private async key(kid: string): Promise<CryptoKey | undefined> {
    const stale = this.now() - this.fetchedAt > KEYS_TTL_MS;
    if (stale || (!this.keys.has(kid) && this.now() - this.fetchedAt > REFETCH_MIN_MS)) {
      try {
        const { keys = [] } = await this.fetchKeys(`https://${this.cfg.teamDomain}/cdn-cgi/access/certs`);
        const next = new Map<string, CryptoKey>();
        for (const k of keys) {
          if (!k.kid || k.kty !== "RSA") continue;
          next.set(k.kid, await crypto.subtle.importKey("jwk", { kty: k.kty, n: k.n, e: k.e, alg: "RS256", ext: true }, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]));
        }
        if (next.size) {
          this.keys = next;
          this.fetchedAt = this.now();
        }
      } catch (e) {
        console.warn(`[cf-access] cannot fetch the signing keys: ${(e as Error)?.message ?? e}`);
      }
    }
    return this.keys.get(kid);
  }

  async verify(token: string | null | undefined): Promise<boolean> {
    if (!token) return false;
    const parts = token.split(".");
    if (parts.length !== 3) return false;
    const header = decodeJson(parts[0]!);
    const payload = decodeJson(parts[1]!);
    if (!header || !payload || header.alg !== "RS256" || typeof header.kid !== "string") return false;
    const key = await this.key(header.kid);
    if (!key) return false;
    let valid = false;
    try {
      valid = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, b64url(parts[2]!), new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
    } catch {
      return false;
    }
    if (!valid) return false;
    const t = this.now() / 1000;
    const aud = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
    if (!aud.includes(this.cfg.aud)) return false;
    if (payload.iss !== `https://${this.cfg.teamDomain}`) return false;
    if (typeof payload.exp !== "number" || payload.exp + CLOCK_SKEW_S < t) return false;
    if (typeof payload.nbf === "number" && payload.nbf - CLOCK_SKEW_S > t) return false;
    return true;
  }
}
