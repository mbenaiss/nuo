import { expect } from "bun:test";
import { signedMessage } from "../src/auth/service";
import { CALLER_HEADER } from "../src/mcp/overview-tools";
import { type SpeechToText, TranscriptionService } from "../src/transcription/service";
import { botConfig, newDeviceKey, startTestApp, stepUp, type TestApp } from "./helpers";

export const LOCAL = "jeton-local-de-la-passerelle";
export const INTERNET = { "cf-ray": "8a1b2c3d4e5f-CDG", "cf-connecting-ip": "203.0.113.24" };

type Reply = { status: number; data: any };

/** A published bot; `auto` needs the owner's face, as in the app. */
export async function publishBot(app: TestApp, name: string, over: Record<string, unknown> = {}): Promise<string> {
  const created = (await app.api("POST", "/api/bots", { name })).data;
  await app.api("PUT", `/api/bots/${created.id}/draft`, botConfig({ name, ...over }));
  const published = await app.api("POST", `/api/bots/${created.id}/publish`, {}, await stepUp(app.api, app.device));
  expect(published.status).toBe(200);
  return created.id as string;
}

/**
 * The app registers a relay key (Face ID for that very action, from home), then the locked iPhone signs for relay
 * tokens with it. `as` calls with the relay token; `local` is what the bot's `nuo` MCP server sends (local token,
 * naming the conversation it runs in).
 */
export async function withRelay(o: { transcription?: SpeechToText; extra?: Parameters<typeof startTestApp>[0] } = {}) {
  const app = await startTestApp({ localToken: LOCAL, ...(o.transcription ? { transcription: new TranscriptionService(o.transcription) } : {}), ...o.extra });
  const key = await newDeviceKey();
  const registered = await app.api("POST", "/api/auth/relay", { publicKey: key.spki }, await stepUp(app.api, app.device, "relay"));
  expect(registered.status).toBe(200);
  const token = async (signer = key) => {
    const { data: c } = await app.api("GET", "/api/auth/challenge", undefined, "");
    return app.api("POST", "/api/auth/relay-token", { deviceId: app.device.id, nonce: c.nonce, signature: await signer.sign(signedMessage("relay", app.device.id, c.nonce)) }, "");
  };
  const relay = (await token()).data.token as string;
  const send = (auth: string, method: string, path: string, body?: unknown, headers: Record<string, string> = {}): Promise<Reply> =>
    fetch(app.base + path, {
      method,
      headers: { "content-type": "application/json", authorization: `Bearer ${auth}`, ...headers },
      body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
    }).then(async (r) => ({ status: r.status, data: await r.json().catch(() => undefined) }));
  const as = (method: string, path: string, body?: unknown, headers: Record<string, string> = {}) => send(relay, method, path, body, headers);
  const local = (method: string, path: string, body: unknown, caller: string) => send(LOCAL, method, path, body, { [CALLER_HEADER]: caller });
  return { app, key, token, relay, as, local };
}

export async function until(ok: () => boolean | Promise<boolean>, what: string) {
  for (let i = 0; i < 300; i++) {
    if (await ok()) return;
    await Bun.sleep(10);
  }
  throw new Error(`timeout: ${what}`);
}

/** The confirmation a running turn waits for, as the relay reads it. */
export async function pendingPermission(as: (m: string, p: string) => Promise<Reply>, conversationId: string): Promise<{ requestId: string; title: string }> {
  let found: { requestId: string; title: string } | undefined;
  await until(async () => {
    found = (await as("GET", `/api/conversations/${conversationId}`)).data?.turn?.permission;
    return !!found;
  }, "confirmation asked");
  return found!;
}

export const auditEvents = (app: TestApp, type: string) =>
  app.app.store.db.query("SELECT ok, detail FROM auth_events WHERE type = ? ORDER BY id").all(type) as { ok: number; detail: string | null }[];
