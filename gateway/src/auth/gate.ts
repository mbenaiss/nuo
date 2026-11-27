import { classify, type NetworkConfig, type Origin } from "./network";
import { BOUND_STEP_UP, needsBody, scopeAllows, SINGLE_USE_STEP_UP, stepUpRequired } from "./policy";
import { deviceAuthRoute, failure, publicAuthRoute, type GateAuth } from "./routes";
import { bearer, isFailure, type AuthContext } from "./service";

const KB = 1024;
const MB = 1024 * KB;
/** Attachments travel base64 in prompt bodies: a 50 MB file is ~67 MB encoded. */
export const MAX_PROMPT_BODY = 72 * MB;

/** Largest accepted body per route; everything not listed gets 256 KB. */
export function bodyLimit(method: string, path: string): number {
  if (method === "GET" || method === "HEAD" || method === "DELETE") return 0;
  if (/^\/api\/conversations\/[^/]+\/prompt$/.test(path)) return MAX_PROMPT_BODY;
  if (path === "/api/docs/file") return 10 * MB;
  if (path === "/api/docs/upload") return 50 * MB;
  // A meeting stream in AAC at 48 kbit/s: about 21 MB an hour, voice only.
  if (path === "/api/transcriptions") return 64 * MB;
  // A file the bot hands to a folder of the Mac travels base64 (see MAX_MAC_FILE_BYTES).
  if (path === "/api/device/tools/mac_file_write") return 48 * MB;
  if (/^\/api\/data\/collections\/[^/]+\/rows\/[^/]+\/files\/[^/]+$/.test(path)) return 50 * MB;
  if (/^\/api\/bots\/[^/]+\/(memory|draft)$/.test(path)) return 1 * MB;
  if (path.startsWith("/api/data/")) return 2 * MB;
  if (path.startsWith("/api/calendar/")) return 4 * MB;
  return 256 * KB;
}

const json = (data: unknown, status = 200) => Response.json(data, { status });
const notFound = () => json({ error: "not found" }, 404);

/** The machine token belongs to no device and never expires; it is revoked by removing it from the config. */
export const MACHINE_DEVICE = "machine";
const machineContext = (profileId: string): AuthContext => ({
  profileId,
  deviceId: MACHINE_DEVICE,
  deviceName: "Machine",
  scope: "machine",
  expiresAt: Number.MAX_SAFE_INTEGER,
});

export type GateResult =
  | { kind: "response"; response: Response; origin: Origin; ctx?: AuthContext }
  | { kind: "local"; origin: Origin; profileId: string }
  /** WebSocket opened without an Authorization header: the first message must be `{type:"auth", accessToken}`. */
  | { kind: "ws-pending"; origin: Origin }
  | { kind: "device"; origin: Origin; ctx: AuthContext };

export interface GateDeps {
  auth: GateAuth;
  network: NetworkConfig;
  /** When set, a request from the internet must carry a valid Cloudflare Access token for this application. */
  cfAccess?: { verify(token: string | null | undefined): Promise<boolean> };
}

export class Gate {
  constructor(private d: GateDeps) {}

  origin(peer: string | undefined, headers: Headers): Origin {
    return classify(peer, headers, this.d.network);
  }

  /** Internet clients get no hint about why a credential was refused, only whether to refresh or pair again. */
  private refuse(origin: Origin, f: { status: number; error: string; reauth?: boolean; retryAt?: string }): Response {
    if (origin.zone !== "internet") return failure(f);
    return failure({ ...f, error: f.status === 429 ? "too many requests" : f.status === 401 ? "unauthorized" : f.error });
  }

  async check(req: Request, path: string, origin: Origin): Promise<GateResult> {
    const respond = (response: Response, ctx?: AuthContext): GateResult => ({ kind: "response", response, origin, ctx });
    const internet = origin.zone === "internet";

    const limit = bodyLimit(req.method, path);
    const length = req.headers.get("content-length");
    if (length !== null && Number(length) > limit) return respond(json({ error: "request body too large" }, 413));
    if (length === null && limit > 0 && internet && req.body) return respond(json({ error: "content-length required" }, 411));

    if (internet && this.d.cfAccess && !(await this.d.cfAccess.verify(req.headers.get("cf-access-jwt-assertion")))) {
      return respond(json({ error: "forbidden" }, 403));
    }
    if (path === "/api/pair" && internet) return respond(notFound());
    const pub = await publicAuthRoute(this.d.auth, path, req, origin.ip);
    if (pub) return respond(internet && pub.status === 401 ? this.refuse(origin, { status: 401, error: "", ...(await pub.clone().json()) }) : pub);

    const localProfile = this.d.auth.localProfile(req);
    if (localProfile) {
      if (origin.zone === "local") return { kind: "local", origin, profileId: localProfile };
      this.d.auth.event("local_token_rejected", false, { ip: origin.ip, detail: `${origin.zone} ${req.method} ${path}` });
      return respond(json({ error: "unauthorized" }, 401));
    }

    const machine = this.d.auth.machineProfile(req);
    if (machine) {
      // Never from the internet: this token is a file on another machine of the house, not something a person holds.
      if (internet) {
        this.d.auth.event("machine_token_rejected", false, { ip: origin.ip, detail: `${origin.zone} ${req.method} ${path}` });
        return respond(json({ error: "unauthorized" }, 401));
      }
      const ctx = machineContext(machine);
      if (!scopeAllows(ctx.scope, req.method, path)) {
        return respond(json({ error: `a machine token cannot call ${req.method} ${path}` }, 403), ctx);
      }
      return { kind: "device", origin, ctx };
    }

    if (path === "/api/ws" && !bearer(req) && req.headers.get("upgrade")?.toLowerCase() === "websocket") return { kind: "ws-pending", origin };

    const ctx = this.d.auth.authenticate(req, origin.ip);
    if (isFailure(ctx)) return respond(this.refuse(origin, ctx));
    const p = this.d.auth.profile(ctx.profileId);
    if (!p) return respond(this.refuse(origin, { status: 401, error: "unauthorized", reauth: false }));
    if (!scopeAllows(ctx.scope, req.method, path)) return respond(json({ error: internet ? "forbidden" : `a ${ctx.scope} token cannot call ${req.method} ${path}` }, 403), ctx);
    const reason = stepUpRequired(req.method, path, needsBody(req.method, path) ? await req.clone().json().catch(() => undefined) : undefined, p.lookups);
    if (reason && (!p.auth.stepUpFresh(ctx) || (SINGLE_USE_STEP_UP.has(reason) && !p.auth.consumeStepUp(req, BOUND_STEP_UP.has(reason) ? reason : undefined)))) {
      return respond(json({ error: "this action needs a recent biometric confirmation (step-up)", stepUp: true, reason }, 403), ctx);
    }
    if (ctx.scope === "app") {
      const r = await deviceAuthRoute(p.auth, p.hub, path, req, ctx, origin.ip, origin.zone);
      if (r) return respond(r, ctx);
    }
    return { kind: "device", origin, ctx };
  }

  /** Same checks as a header token, for the first message of a socket opened without one. */
  socketToken(token: unknown, origin: Origin): AuthContext | undefined {
    if (typeof token !== "string") return undefined;
    const ctx = this.d.auth.authenticate(new Request("http://nuo/api/ws", { headers: { authorization: `Bearer ${token}` } }), origin.ip);
    if (isFailure(ctx) || !scopeAllows(ctx.scope, "GET", "/api/ws")) return undefined;
    return ctx;
  }
}

const SECURITY_HEADERS: Record<string, string> = {
  "x-content-type-options": "nosniff",
  "x-frame-options": "DENY",
  "referrer-policy": "no-referrer",
  "content-security-policy": "default-src 'none'; frame-ancestors 'none'",
  "cross-origin-resource-policy": "same-origin",
};

/** No CORS headers are ever set: browsers cannot call the API from another origin. */
export function secure(res: Response, origin: Origin): Response {
  let out = res;
  // Internet clients cannot tell an existing path with the wrong method from a missing one.
  if (origin.zone === "internet" && res.status === 405) out = notFound();
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) out.headers.set(k, v);
  if (!out.headers.has("cache-control")) out.headers.set("cache-control", "no-store");
  return out;
}
