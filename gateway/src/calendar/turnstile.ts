const VERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify";

export interface TurnstileConfig {
  siteKey?: string;
  secret?: string;
  fetch?: typeof fetch;
}

export interface Turnstile {
  readonly enabled: boolean;
  readonly siteKey?: string;
  verify(token: unknown, ip: string): Promise<boolean>;
}

export function createTurnstile(c: TurnstileConfig): Turnstile {
  const doFetch = c.fetch ?? fetch;
  if (!c.secret || !c.siteKey) {
    return { enabled: false, verify: async () => true };
  }
  const secret = c.secret;
  return {
    enabled: true,
    siteKey: c.siteKey,
    async verify(token, ip) {
      if (typeof token !== "string" || !token || token.length > 2048) return false;
      try {
        const body = new URLSearchParams({ secret, response: token, remoteip: ip });
        const res = await doFetch(VERIFY_URL, { method: "POST", body, signal: AbortSignal.timeout(10_000) });
        if (!res.ok) return false;
        const out = (await res.json()) as { success?: boolean };
        return out.success === true;
      } catch (e) {
        console.warn(`[booking] Turnstile verification failed: ${(e as Error)?.message ?? e}`);
        return false;
      }
    },
  };
}
