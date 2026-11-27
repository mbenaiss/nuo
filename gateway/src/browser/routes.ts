import { HttpError } from "../bots/service";
import type { BrowserManager } from "./manager";

type Ctx = { req: Request; params: string[]; url: URL };
export type BrowserRoute = [string, RegExp, (ctx: Ctx) => unknown];

async function body(req: Request): Promise<Record<string, unknown>> {
  if (req.headers.get("content-length") === "0") return {};
  try {
    const b = await req.json();
    if (b && typeof b === "object" && !Array.isArray(b)) return b as Record<string, unknown>;
  } catch {}
  throw new HttpError(400, "invalid JSON body");
}

/** Paired app only (extension tokens are refused by the gate); the live view is the `/api/browser/ws` socket. */
export function browserRoutes(m: BrowserManager): BrowserRoute[] {
  return [
    ["GET", /^\/api\/browser$/, () => m.status()],
    [
      "POST",
      /^\/api\/browser\/start$/,
      async () => {
        await m.ensure();
        return m.status();
      },
    ],
    [
      "POST",
      /^\/api\/browser\/stop$/,
      async () => {
        await m.stop();
        return new Response(null, { status: 204 });
      },
    ],
    ["POST", /^\/api\/browser\/done$/, () => ({ completed: m.completeLogins() })],
  ];
}

/** Agents on `dev` (local token): keep the browser up and ask the user to log in. */
export function browserLocalRoutes(m: BrowserManager): BrowserRoute[] {
  return [
    ["GET", /^\/api\/browser$/, () => m.status()],
    [
      "POST",
      /^\/api\/browser\/start$/,
      async () => {
        await m.ensure();
        return { endpoint: m.endpoint };
      },
    ],
    ["POST", /^\/api\/browser\/login-requests$/, async ({ req }) => Response.json(m.requestLogin(await body(req)), { status: 201 })],
    ["GET", /^\/api\/browser\/login-requests\/([^/]+)$/, ({ params }) => m.login(params[0]!)],
  ];
}
