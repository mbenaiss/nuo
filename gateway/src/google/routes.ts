import { HttpError } from "../bots/service";
import { isEmail } from "../calendar/validate";
import type { Device } from "../store/store";
import type { GoogleAccounts } from "./accounts";
import { GoogleTools } from "./api";
import { APP_RETURN_URL, idTokenClaims, parseServices, servicesOf, type GoogleOAuth } from "./oauth";
import { GOOGLE_TOOL_NAMES } from "./tools";
import type { GoalGuard } from "../runner/goal";

type Ctx = { req: Request; params: string[]; url: URL; device: Device };
type LocalCtx = { req: Request; params: string[]; url: URL };
export type GoogleRoute = [string, RegExp, (ctx: Ctx) => unknown];
export type GoogleLocalRoute = [string, RegExp, (ctx: LocalCtx) => unknown];

async function body(req: Request): Promise<Record<string, unknown>> {
  if (req.headers.get("content-length") === "0") return {};
  try {
    const b = await req.json();
    if (b && typeof b === "object" && !Array.isArray(b)) return b as Record<string, unknown>;
  } catch {}
  throw new HttpError(400, "invalid JSON body");
}

const DRAFT_ID = /^[A-Za-z0-9_-]{1,200}$/;

/** The account named by `?account=`; a missing or unauthorised one is a 400, never a 404 or 403 the app would misread. */
function draftAccount(g: GoogleAccounts, url: URL): string {
  try {
    return g.resolve("gmail", url.searchParams.get("account") ?? undefined);
  } catch (e) {
    if (e instanceof HttpError && (e.status === 404 || e.status === 403)) throw new HttpError(400, e.message);
    throw e;
  }
}

function draftId(raw: string): string {
  const id = decodeURIComponent(raw);
  if (!DRAFT_ID.test(id)) throw new HttpError(400, "invalid draft id");
  return id;
}

/** Paired app only: the gate refuses extension tokens on these paths. */
export function googleRoutes(g: GoogleAccounts): GoogleRoute[] {
  const tools = new GoogleTools(g);
  return [
    // The `::email` card: the user reads, edits and sends the bot's draft himself, so no goal confirmation applies.
    ["GET", /^\/api\/google\/drafts\/([^/]+)$/, ({ params, url }) => tools.readDraft(draftAccount(g, url), draftId(params[0]!))],
    ["PUT", /^\/api\/google\/drafts\/([^/]+)$/, async ({ req, params, url }) => tools.updateDraft(draftAccount(g, url), draftId(params[0]!), await body(req))],
    [
      "POST",
      /^\/api\/google\/drafts\/([^/]+)\/send$/,
      async ({ params, url, device }) => {
        const email = draftAccount(g, url);
        const id = draftId(params[0]!);
        const sent = await tools.sendDraft(email, id);
        g.audit("google_send", true, { deviceId: device.id, deviceName: device.name, detail: `${email}: draft ${id}` });
        return { sent: true, ...sent };
      },
    ],
    ["GET", /^\/api\/google\/accounts$/, () => ({ configured: g.oauth.configured && g.canStore, accounts: g.list() })],
    [
      "POST",
      /^\/api\/google\/connect$/,
      async ({ req, device }) => {
        const b = await body(req);
        const services = parseServices(b.services);
        const email = typeof b.email === "string" && isEmail(b.email.trim()) ? b.email.trim().toLowerCase() : undefined;
        if (!g.canStore) throw new HttpError(503, "NUO_AUTH_KEY is missing on the gateway: Google tokens cannot be stored");
        return g.oauth.begin({ profileId: g.profileId, deviceId: device.id, deviceName: device.name, services }, email);
      },
    ],
    [
      "DELETE",
      /^\/api\/google\/accounts\/([^/]+)$/,
      async ({ params, device }) => {
        await g.remove(params[0]!, { deviceId: device.id, deviceName: device.name });
        return new Response(null, { status: 204 });
      },
    ],
  ];
}

/** For the profile's `nuo` MCP server (local token): the tools run here, with tokens the agent never sees. */
export function googleLocalRoutes(g: GoogleAccounts, guard?: GoalGuard): GoogleLocalRoute[] {
  const tools = new GoogleTools(g);
  return [
    ["GET", /^\/api\/google\/accounts$/, () => ({ accounts: g.list() })],
    [
      "POST",
      /^\/api\/google\/tools\/([a-z_]+)$/,
      async ({ req, params }) => {
        if (!GOOGLE_TOOL_NAMES.has(params[0]!)) throw new HttpError(404, `unknown Google tool ${params[0]}`);
        const args = await body(req);
        await guard?.(req, params[0]!, args, () => tools.draftSummary(args));
        return { text: await tools.call(params[0]!, args) };
      },
    ],
  ];
}

const PAGE_HEADERS: Record<string, string> = {
  "content-type": "text/html; charset=utf-8",
  "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  "referrer-policy": "no-referrer",
  "cache-control": "no-store",
  "x-content-type-options": "nosniff",
  "x-robots-tag": "noindex, nofollow",
};

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

/** Redirects to the app (which closes the authentication sheet); the page is what a regular browser shows. */
function backToApp(params: Record<string, string>, title: string, text: string): Response {
  const location = `${APP_RETURN_URL}?${new URLSearchParams(params)}`;
  const page = `<!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(title)}</title>
<style>body{font:17px -apple-system,system-ui,sans-serif;margin:0;display:grid;place-items:center;min-height:100vh;background:#f6f5f2;color:#1b1b1b}main{max-width:26rem;padding:2rem;text-align:center}a{color:inherit}</style></head>
<body><main><h1>${esc(title)}</h1><p>${esc(text)}</p><p><a href="${esc(location)}">Revenir dans Nuo</a></p></main></body></html>`;
  return new Response(page, { status: 302, headers: { ...PAGE_HEADERS, location } });
}

/**
 * GET /oauth/google/callback: reached by the user's browser without any gateway credential, so the state (random,
 * single use, 10 min, bound to the profile and device that asked) is the only proof; the code is exchanged here.
 */
export async function googleCallback(oauth: GoogleOAuth, url: URL, accountsOf: (profileId: string) => GoogleAccounts | undefined): Promise<Response> {
  const pending = oauth.take(url.searchParams.get("state"));
  const accounts = pending && accountsOf(pending.profileId);
  if (!pending || !accounts) return backToApp({ error: "expired" }, "Lien expiré", "Recommence depuis Nuo : Réglages › Comptes Google.");
  const by = { deviceId: pending.deviceId, deviceName: pending.deviceName };
  const denied = url.searchParams.get("error");
  if (denied) {
    accounts.audit("google_connect", false, { ...by, detail: `consent: ${denied.slice(0, 60)}` });
    return backToApp({ error: denied === "access_denied" ? "denied" : "failed" }, "Connexion annulée", "Aucun compte n'a été connecté. Tu peux revenir dans Nuo.");
  }
  const code = url.searchParams.get("code");
  if (!code) return backToApp({ error: "failed" }, "Connexion impossible", "Google n'a pas renvoyé d'autorisation. Recommence depuis Nuo.");
  try {
    const t = await oauth.exchange(code, pending.verifier);
    const { email, sub } = idTokenClaims(t.idToken);
    if (!email || !isEmail(email)) throw new Error("Google returned no email address (openid email scopes missing)");
    accounts.save({ email, sub, scopes: t.scopes, refreshToken: t.refreshToken, accessToken: t.accessToken, expiresAt: t.expiresAt });
    const granted = servicesOf(t.scopes);
    const missing = pending.services.filter((s) => !granted.includes(s));
    accounts.audit("google_connect", true, { ...by, detail: `${email}: ${granted.join(", ") || "no service"}${missing.length ? ` (refused: ${missing.join(", ")})` : ""}` });
    return backToApp(
      { email, services: granted.join(","), ...(missing.length ? { missing: missing.join(",") } : {}) },
      "Compte connecté",
      `${email} est connecté à Nuo. Tu peux revenir dans l'app.`,
    );
  } catch (e) {
    const message = (e as Error)?.message ?? String(e);
    console.warn(`[google] connection for profile ${pending.profileId} failed: ${message}`);
    accounts.audit("google_connect", false, { ...by, detail: message.slice(0, 200) });
    return backToApp({ error: "failed" }, "Connexion impossible", "Google a refusé la connexion. Recommence depuis Nuo.");
  }
}
