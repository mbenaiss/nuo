import { HttpError } from "../bots/service";
import type { Device } from "../store/store";
import type { DeviceBridge } from "./bridge";

type Ctx = { req: Request; params: string[]; url: URL; device: Device };
type LocalCtx = { req: Request; params: string[]; url: URL };
export type DeviceRoute = [string, RegExp, (ctx: Ctx) => unknown];
export type DeviceLocalRoute = [string, RegExp, (ctx: LocalCtx) => unknown];

async function body(req: Request): Promise<Record<string, unknown>> {
  if (req.headers.get("content-length") === "0") return {};
  try {
    const b = await req.json();
    if (b && typeof b === "object" && !Array.isArray(b)) return b as Record<string, unknown>;
  } catch {}
  throw new HttpError(400, "invalid JSON body");
}

/** Paired app only: extension tokens never reach these paths (src/auth/policy.ts). */
export function deviceRoutes(bridge: DeviceBridge): DeviceRoute[] {
  return [
    ["GET", /^\/api\/device\/capabilities$/, ({ device }) => bridge.capabilities(device.id) ?? { tools: [] }],
    ["PUT", /^\/api\/device\/capabilities$/, async ({ req, device }) => bridge.setCapabilities(device.id, await body(req))],
    [
      "POST",
      /^\/api\/device\/requests\/([^/]+)\/claim$/,
      ({ params, device }) => {
        const r = bridge.claim(params[0]!, device.id);
        if (r === "missing") throw new HttpError(404, "request not found or already answered");
        if (r === "taken") throw new HttpError(409, "another device took this request");
        return r;
      },
    ],
    [
      "POST",
      /^\/api\/device\/requests\/([^/]+)\/result$/,
      async ({ req, params, device }) => {
        const b = await body(req);
        if (typeof b.ok !== "boolean") throw new HttpError(400, "ok must be a boolean");
        if (b.error !== undefined && typeof b.error !== "string") throw new HttpError(400, "error must be a string");
        const taken = bridge.answer(params[0]!, device.id, { ok: b.ok, result: b.result, error: b.error as string | undefined });
        if (!taken) throw new HttpError(409, "request expired, not claimed by this device, or answered");
        return new Response(null, { status: 204 });
      },
    ],
  ];
}

/** For the profile's `nuo` MCP server (local token). */
export function deviceLocalRoutes(bridge: DeviceBridge): DeviceLocalRoute[] {
  return [
    [
      "POST",
      /^\/api\/device\/tools\/([a-z_]+)$/,
      async ({ req, params }) => {
        const result = await bridge.call(params[0]!, await body(req));
        return { text: typeof result === "string" ? result : JSON.stringify(result) };
      },
    ],
  ];
}
