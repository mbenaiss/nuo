import { HttpError } from "../bots/service";
import type { Zone } from "../auth/network";
import type { AuthContext, AuthEventType, AuthService } from "../auth/service";
import type { Device } from "../store/store";
import type { SecretStore } from "./store";
import { appHeader } from "../compat/app-names";
import { t as i18n } from "../i18n/language";
import type { MessageKey } from "../i18n/messages";

type Ctx = { req: Request; params: string[]; url: URL; device: Device; ip: string; auth: AuthContext; zone: Zone };
export type SecretsRoute = [string, RegExp, (ctx: Ctx) => unknown];

/** Reveals and changes per device in the window: a stolen session cannot empty the folder in one go. */
const RATE_WINDOW_MS = 10 * 60 * 1000;
const RATE_MAX = 20;

const ALERT_TITLE = {
  secret_reveal: "secrets.alert.secret_reveal",
  secret_create: "secrets.alert.secret_create",
  secret_update: "secrets.alert.secret_update",
  secret_delete: "secrets.alert.secret_delete",
} satisfies Record<string, MessageKey>;

function parse(text: string): Record<string, unknown> {
  try {
    const b = JSON.parse(text);
    if (b && typeof b === "object" && !Array.isArray(b)) return b as Record<string, unknown>;
  } catch {}
  throw new HttpError(400, "invalid JSON body");
}

/**
 * Paired app only (the gate refuses extension and local tokens). Listing is open to the app anywhere; every
 * reveal and change works from home or the VPN only, and carries a signature of that exact call by the
 * device's Face ID bound action key. Each one goes to the security log and is pushed to every device, with
 * the file and the name, never the value.
 */
export function secretsRoutes(s: SecretStore, auth: AuthService, now: () => number = Date.now): SecretsRoute[] {
  const recent = new Map<string, number[]>();

  const guarded = async <T>(type: AuthEventType, ctx: Ctx, run: (body: Record<string, unknown>) => T): Promise<T | Response> => {
    const method = ctx.req.method;
    const text = method === "DELETE" ? "" : await ctx.req.text();
    const body = method === "DELETE" ? Object.fromEntries(ctx.url.searchParams) : parse(text);
    const info = { ip: ctx.ip, deviceId: ctx.device.id, deviceName: ctx.device.name, detail: `${String(body.source).slice(0, 120)} · ${String(body.key).slice(0, 128)}` };
    const refuse = (status: number, error: string, extra: Record<string, unknown> = {}) => {
      auth.event(type, false, { ...info, detail: `${info.detail}: ${error}` });
      return Response.json({ error, ...extra }, { status });
    };

    if (ctx.zone === "internet") return refuse(403, "secrets can only be shown or changed from home or the VPN", { lanOnly: true });
    const t = now();
    const times = (recent.get(ctx.device.id) ?? []).filter((x) => t - x < RATE_WINDOW_MS);
    if (times.length >= RATE_MAX) return refuse(429, "too many secret operations, try again later");
    if (!auth.hasActionKey(ctx.device.id)) return refuse(403, "this device has no Face ID key for secrets yet", { actionKey: true });
    const nonce = appHeader(ctx.req.headers, "action-nonce");
    const signature = nonce && ctx.req.headers.get(`x-${nonce.name}-action-signature`);
    const denied = auth.verifyAction(ctx.auth, nonce?.value, signature, method, ctx.url.pathname + ctx.url.search, text);
    if (denied) return refuse(denied.status, denied.error, { action: true });
    times.push(t);
    recent.set(ctx.device.id, times);

    try {
      const out = run(body);
      auth.event(type, true, info);
      const title = ALERT_TITLE[type as keyof typeof ALERT_TITLE];
      auth.alert(title ? i18n(title) : type, i18n("secrets.alertBody", { detail: info.detail.replace(" · ", " › "), device: ctx.device.name }));
      return out;
    } catch (e) {
      auth.event(type, false, { ...info, detail: `${info.detail}: ${e instanceof HttpError ? e.message : "error"}` });
      throw e;
    }
  };

  return [
    ["GET", /^\/api\/secrets$/, () => s.list()],
    ["POST", /^\/api\/secrets\/reveal$/, (ctx) => guarded("secret_reveal", ctx, (b) => ({ value: s.reveal(b.source, b.key) }))],
    [
      "POST",
      /^\/api\/secrets\/entries$/,
      async (ctx) => {
        const out = await guarded("secret_create", ctx, (b) => s.create(b.source, b.key, b.value, b.createSource === true));
        return out instanceof Response ? out : Response.json(out, { status: 201 });
      },
    ],
    ["PUT", /^\/api\/secrets\/entries$/, (ctx) => guarded("secret_update", ctx, (b) => s.update(b.source, b.key, b.value))],
    ["DELETE", /^\/api\/secrets\/entries$/, (ctx) => guarded("secret_delete", ctx, (b) => s.delete(b.source, b.key))],
  ];
}
