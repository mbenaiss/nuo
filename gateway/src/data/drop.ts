import { HttpError } from "../bots/service";
import type { Fetch } from "../scan/products";

const TIMEOUT_MS = 60_000;
/** drop's per-file limit: refused here, before sending megabytes it would reject. */
export const DROP_MAX_BYTES = 25 * 1024 * 1024;
/** The lifetimes drop's own page offers, in minutes; 0 keeps the link forever. */
export const DROP_TTLS = [60, 1440, 10080, 0];

export interface DropLink {
  url: string;
  /** ISO date, null for a permanent link. */
  expiresAt: string | null;
}

/**
 * Publishes a document on drop (static file host) as a public link. The API key stays on the gateway: the apps
 * only send the document's path and the link's lifetime.
 */
export class DropPublisher {
  private base: string;

  constructor(
    base: string,
    private key: string,
    private fetcher: Fetch = fetch,
  ) {
    this.base = base.replace(/\/+$/, "");
  }

  async publish(name: string, file: Blob, ttlMinutes: unknown): Promise<DropLink> {
    if (typeof ttlMinutes !== "number" || !DROP_TTLS.includes(ttlMinutes)) throw new HttpError(400, `ttl must be one of ${DROP_TTLS.join(", ")}`);
    if (file.size > DROP_MAX_BYTES) throw new HttpError(413, "drop n'accepte pas les fichiers de plus de 25 Mo");
    const form = new FormData();
    form.set("access", "public");
    form.set("ttl", String(ttlMinutes));
    form.set("file", file, name);
    let res: Response;
    try {
      res = await this.fetcher(`${this.base}/api/sites`, {
        method: "POST",
        headers: { authorization: `Bearer ${this.key}` },
        body: form,
        signal: AbortSignal.timeout(TIMEOUT_MS),
      });
    } catch (e) {
      throw new HttpError(502, `drop injoignable : ${(e as Error)?.message ?? e}`);
    }
    const body = (await res.json().catch(() => undefined)) as { url?: string; expiresAt?: number | null } | undefined;
    if (res.status === 401 || res.status === 403) throw new HttpError(502, "clé drop (NUO_DROP_API_KEY) refusée");
    if (res.status === 413) throw new HttpError(413, "drop n'accepte pas les fichiers de plus de 25 Mo");
    if (!res.ok || !body?.url) throw new HttpError(502, `drop a répondu ${res.status}`);
    return { url: body.url, expiresAt: typeof body.expiresAt === "number" ? new Date(body.expiresAt).toISOString() : null };
  }
}

export function dropFromEnv(env: Record<string, string | undefined> = process.env): DropPublisher | undefined {
  const base = env.NUO_DROP_URL?.trim();
  const key = env.NUO_DROP_API_KEY?.trim();
  return base && key ? new DropPublisher(base, key) : undefined;
}
