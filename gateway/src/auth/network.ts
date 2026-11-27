/**
 * Where a request comes from. `local`: a direct loopback connection (scripts, the nuo MCP server).
 * `lan`: home network or VPN, through Caddy. `internet`: through the Cloudflare Tunnel, after Cloudflare Access.
 * Forwarding headers are only believed from the configured proxies; any Cloudflare header makes the request
 * `internet` whatever its source, since adding one can only lower an attacker's privileges.
 */
export type Zone = "local" | "lan" | "internet";

export interface NetworkConfig {
  /** Peers that run cloudflared: their Cf-Connecting-Ip is the client address. */
  tunnelSources: Set<string>;
  /** Peers that run Caddy (LAN/VPN): their X-Forwarded-For is the client address. */
  proxySources: Set<string>;
}

const LOOPBACK = /^(127\.\d+\.\d+\.\d+|::1|::ffff:127\.\d+\.\d+\.\d+)$/;
const PRIVATE = /^(::ffff:)?(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)|^(fd|fc|fe80)/i;

const list = (s: string | undefined) => new Set((s ?? "").split(",").map((x) => x.trim()).filter(Boolean));
const bare = (ip: string) => ip.replace(/^::ffff:/, "");

export function networkConfigFromEnv(env: Record<string, string | undefined> = process.env): NetworkConfig {
  return {
    tunnelSources: list(env.NUO_TUNNEL_SOURCES),
    proxySources: list(env.NUO_PROXY_SOURCES ?? "127.0.0.1,::1"),
  };
}

export const DEFAULT_NETWORK: NetworkConfig = { tunnelSources: new Set(), proxySources: new Set(["127.0.0.1", "::1"]) };

export interface Origin {
  zone: Zone;
  /** Real client address, for rate limits and the audit log. */
  ip: string;
}

const hasCloudflare = (h: Headers) => h.has("cf-connecting-ip") || h.has("cf-ray") || h.has("cf-access-jwt-assertion");
const isForwarded = (h: Headers) => h.has("x-forwarded-for") || h.has("forwarded") || h.has("x-real-ip");

export function classify(peer: string | undefined, headers: Headers, cfg: NetworkConfig): Origin {
  const p = peer ? bare(peer) : "?";
  if (hasCloudflare(headers)) {
    const viaTunnel = cfg.tunnelSources.has(p);
    const cf = headers.get("cf-connecting-ip")?.trim();
    return { zone: "internet", ip: viaTunnel && cf ? cf : p };
  }
  // cloudflared on the gateway host itself shares 127.0.0.1 with local scripts: there, its Cloudflare headers decide.
  if (cfg.tunnelSources.has(p) && !LOOPBACK.test(p)) return { zone: "internet", ip: p };
  if (isForwarded(headers)) {
    const fwd = headers.get("x-forwarded-for")?.split(",")[0]?.trim();
    if (cfg.proxySources.has(p) && fwd) return { zone: PRIVATE.test(fwd) || LOOPBACK.test(fwd) ? "lan" : "internet", ip: fwd };
    return { zone: PRIVATE.test(p) || LOOPBACK.test(p) ? "lan" : "internet", ip: p };
  }
  if (LOOPBACK.test(p)) return { zone: "local", ip: p };
  return { zone: PRIVATE.test(p) ? "lan" : "internet", ip: p };
}
