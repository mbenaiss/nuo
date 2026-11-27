import type { Hub } from "../runner/hub";
import type { Zone } from "./network";
import type { PolicyLookups } from "./policy";
import { isFailure, type AuthContext, type AuthService, type Failure, type TokenGrant } from "./service";

/** What the gate needs from the profiles: the routes before authentication and the profile of a credential. */
export interface GateAuth {
  pair(b: Record<string, unknown>, ip: string): Promise<TokenGrant | Failure>;
  challenge(): { nonce: string; expiresAt: string };
  refresh(b: Record<string, unknown>, ip: string): TokenGrant | Failure;
  /** A relay token, signed for with the device's relay key. */
  relayToken(b: Record<string, unknown>, ip: string): { token: string; expiresAt: string } | Failure;
  /** Profile whose local token the request carries. */
  localProfile(req: Request): string | undefined;
  /** Profile whose machine token the request carries. */
  machineProfile(req: Request): string | undefined;
  authenticate(req: Request, ip: string): AuthContext | Failure;
  profile(id: string): { auth: AuthService; hub: Hub; lookups: PolicyLookups } | undefined;
  /** Audit events not tied to a device go to the owner's log. */
  event: AuthService["event"];
}

const json = (data: unknown, status = 200) => Response.json(data, { status });
export const failure = (f: Failure) => json({ error: f.error, ...(f.reauth !== undefined ? { reauth: f.reauth } : {}), ...(f.retryAt ? { retryAt: f.retryAt } : {}) }, f.status);

async function body(req: Request): Promise<Record<string, unknown>> {
  try {
    const b = await req.json();
    if (b && typeof b === "object" && !Array.isArray(b)) return b as Record<string, unknown>;
  } catch {}
  return {};
}

/** Routes reachable without an access token: pairing, the challenge and refresh. */
export async function publicAuthRoute(auth: GateAuth, path: string, req: Request, ip: string): Promise<Response | undefined> {
  if (path === "/api/pair" && req.method === "POST") {
    const r = await auth.pair(await body(req), ip);
    return isFailure(r) ? failure(r) : json(r);
  }
  if (path === "/api/auth/challenge" && req.method === "GET") return json(auth.challenge());
  if (path === "/api/auth/refresh" && req.method === "POST") {
    const r = auth.refresh(await body(req), ip);
    return isFailure(r) ? failure(r) : json(r);
  }
  if (path === "/api/auth/relay-token" && req.method === "POST") {
    const r = auth.relayToken(await body(req), ip);
    return isFailure(r) ? failure(r) : json(r);
  }
  return undefined;
}

/** Routes that need an access token; device management is for the app scope only (checked by the caller). */
export async function deviceAuthRoute(auth: AuthService, hub: Hub, path: string, req: Request, ctx: AuthContext, ip: string, zone: Zone = "lan"): Promise<Response | undefined> {
  if (path === "/api/auth/action-key" && req.method === "POST") {
    // Registered from home only: a stolen token and passcode away from home cannot plant a key of their own.
    if (zone === "internet") return json({ error: "the Face ID key can only be set up from home or the VPN", lanOnly: true }, 403);
    const r = auth.setActionKey(ctx, (await body(req)).publicKey, ip);
    return isFailure(r) ? failure(r) : json(r);
  }
  if (path === "/api/auth/relay" && req.method === "POST") {
    // Like the Face ID key: a stolen token and passcode away from home cannot plant a relay key of their own.
    if (zone === "internet") return json({ error: "the relay access can only be set up from home or the VPN", lanOnly: true }, 403);
    const r = auth.setRelayKey(ctx, (await body(req)).publicKey, ip);
    return isFailure(r) ? failure(r) : json(r);
  }
  if (path === "/api/auth/relay" && req.method === "GET") return json(auth.relayKeyInfo(ctx.deviceId));
  if (path === "/api/auth/relay" && req.method === "DELETE") {
    auth.revokeRelayKey(ctx, ip);
    return new Response(null, { status: 204 });
  }
  if (path === "/api/auth/step-up" && req.method === "POST") {
    const r = auth.stepUp(ctx, await body(req), ip);
    return isFailure(r) ? failure(r) : json(r);
  }
  if (path === "/api/devices" && req.method === "GET") {
    return json(auth.devices().map((d) => ({ ...d, current: d.id === ctx.deviceId })));
  }
  const m = path.match(/^\/api\/devices\/([^/]+)$/);
  if (m && req.method === "DELETE") {
    const id = decodeURIComponent(m[1]!);
    if (!auth.revoke(id, { ctx, ip })) return json({ error: "device not found" }, 404);
    hub.closeDevice(id);
    return new Response(null, { status: 204 });
  }
  if (path === "/api/auth/network" && req.method === "GET") return json(auth.networkInfo());
  if (path === "/api/auth/activity" && req.method === "GET") return json(auth.activity());
  if (path === "/api/auth/events" && req.method === "GET") {
    const limit = Math.min(Number(new URL(req.url).searchParams.get("limit")) || 50, 500);
    return json(auth.events(limit));
  }
  return undefined;
}
