import { afterEach, describe, expect, test } from "bun:test";
import { RELAY_RULES, scopeAllows, stepUpRequired } from "../src/auth/policy";
import { RELAY_PROMPTS_PER_HOUR, RELAY_TTL_MS, signedMessage } from "../src/auth/service";
import { type SpeechToText, type TranscriptionRequest, TranscriptionService } from "../src/transcription/service";
import { botConfig, newDeviceKey, startTestApp, stepUp, type TestApp } from "./helpers";

let t: TestApp | undefined;
afterEach(async () => {
  await t?.close();
  t = undefined;
});

const LAN_FROM_INTERNET = { "cf-ray": "8a1b2c3d4e5f-CDG", "cf-connecting-ip": "203.0.113.24" };

class FakeStt implements SpeechToText {
  readonly provider = "fake-scribe";
  readonly model = "fake-model-1";
  seen: TranscriptionRequest[] = [];
  async transcribe(r: TranscriptionRequest) {
    this.seen.push(r);
    return { text: "Ajoute acheter du pain et appeler Julie Martin demain à 9 h", language: "fr" };
  }
  async warm() {}
}

/** A published bot; `auto` needs the owner's face, as in the app. */
async function bot(app: TestApp, name: string, over: Record<string, unknown> = {}) {
  const created = (await app.api("POST", "/api/bots", { name })).data;
  await app.api("PUT", `/api/bots/${created.id}/draft`, botConfig({ name, ...over }));
  const published = await app.api("POST", `/api/bots/${created.id}/publish`, {}, await stepUp(app.api, app.device));
  expect(published.status).toBe(200);
  return created.id as string;
}

/** The app registers a relay key (Face ID, from home), then the locked iPhone signs for relay tokens with it. */
async function withRelay(o: { transcription?: SpeechToText; localToken?: string } = {}) {
  const app = await startTestApp({ ...(o.transcription ? { transcription: new TranscriptionService(o.transcription) } : {}), localToken: o.localToken });
  t = app;
  const key = await newDeviceKey();
  const register = await app.api("POST", "/api/auth/relay", { publicKey: key.spki }, await stepUp(app.api, app.device, "relay"));
  expect(register.status).toBe(200);
  const token = async (signer = key) => {
    const { data: c } = await app.api("GET", "/api/auth/challenge", undefined, "");
    return app.api("POST", "/api/auth/relay-token", { deviceId: app.device.id, nonce: c.nonce, signature: await signer.sign(signedMessage("relay", app.device.id, c.nonce)) }, "");
  };
  const relay = (await token()).data.token as string;
  const as = (method: string, path: string, body?: unknown, x: { headers?: Record<string, string> } = {}) =>
    fetch(app.base + path, {
      method,
      headers: { "content-type": "application/json", authorization: `Bearer ${relay}`, ...x.headers },
      body: body === undefined ? undefined : JSON.stringify(body),
    }).then(async (r) => ({ status: r.status, data: await r.json().catch(() => undefined) }));
  return { app, key, token, relay, as };
}

const relayEvents = (app: TestApp, type: string) =>
  (app.app.store.db.query("SELECT ok, detail FROM auth_events WHERE type = ? ORDER BY id").all(type) as { ok: number; detail: string | null }[]);

describe("relay key", () => {
  test("is set up by the app with a fresh Face ID, from home only, and differs from the device key", async () => {
    t = await startTestApp();
    const app = t;
    const key = await newDeviceKey();
    expect(stepUpRequired("POST", "/api/auth/relay", undefined, { isFinanceCollection: () => false, isCommandTask: () => false })).toBe("relay");
    expect((await app.api("POST", "/api/auth/relay", { publicKey: key.spki }, app.device.accessToken)).data).toMatchObject({ stepUp: true, reason: "relay" });
    const internet = await fetch(app.base + "/api/auth/relay", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${await stepUp(app.api, app.device, "relay")}`, ...LAN_FROM_INTERNET },
      body: JSON.stringify({ publicKey: key.spki }),
    });
    expect(internet.status).toBe(403);
    expect((await app.api("POST", "/api/auth/relay", { publicKey: "pas une clé" }, await stepUp(app.api, app.device, "relay"))).status).toBe(400);
    expect((await app.api("GET", "/api/auth/relay")).data).toEqual({ registered: false });
    expect((await app.api("POST", "/api/auth/relay", { publicKey: key.spki }, await stepUp(app.api, app.device, "relay"))).status).toBe(200);
    expect((await app.api("GET", "/api/auth/relay")).data).toMatchObject({ registered: true });
    expect(relayEvents(app, "relay_key").map((e) => e.detail)).toEqual(["registered"]);
    expect(JSON.stringify(app.pusher.sent)).toContain("Accès de relais");
  });

  test("signs for 15-minute tokens; a wrong key, a replayed nonce or no key get nothing", async () => {
    const { app, token } = await withRelay();
    const minted = await token();
    expect(minted.status).toBe(200);
    expect(new Date(minted.data.expiresAt).getTime() - Date.now()).toBeLessThanOrEqual(RELAY_TTL_MS);
    expect(new Date(minted.data.expiresAt).getTime() - Date.now()).toBeGreaterThan(RELAY_TTL_MS - 60_000);
    expect((await token(await newDeviceKey())).status).toBe(401);
    // The device key itself does not sign for relay tokens.
    expect((await token({ sign: app.device.sign } as never)).status).toBe(401);
    const { data: c } = await app.api("GET", "/api/auth/challenge", undefined, "");
    const signed = await app.device.sign(signedMessage("refresh", app.device.id, c.nonce));
    expect((await app.api("POST", "/api/auth/relay-token", { deviceId: app.device.id, nonce: c.nonce, signature: signed }, "")).status).toBe(401);
    expect(relayEvents(app, "relay_token").map((e) => e.ok)).toEqual([1, 1, 0, 0, 0]);
  });

  test("revoking the key, or the device, ends its tokens at once", async () => {
    const { app, as, token } = await withRelay();
    expect((await as("GET", "/api/bots")).status).toBe(200);
    expect((await app.api("DELETE", "/api/auth/relay")).status).toBe(204);
    expect((await as("GET", "/api/bots")).status).toBe(401);
    expect((await token()).status).toBe(401);
    expect(relayEvents(app, "relay_key").map((e) => e.detail)).toEqual(["registered", "revoked"]);

    const again = await withRelay();
    expect((await again.app.api("DELETE", `/api/devices/${again.app.device.id}`, undefined, await stepUp(again.app.api, again.app.device))).status).toBe(204);
    expect((await again.as("GET", "/api/bots")).status).toBe(401);
  });
});

describe("relay token", () => {
  test("reaches only its routes: no data, docs, devices, secrets, settings or socket", async () => {
    const { as, app } = await withRelay();
    for (const [method, path] of [
      ["GET", "/api/conversations"],
      ["GET", "/api/conversations/search?q=pain"],
      ["GET", "/api/data/collections"],
      ["GET", "/api/docs/tree"],
      ["GET", "/api/devices"],
      ["GET", "/api/secrets"],
      ["GET", "/api/reminders"],
      ["GET", "/api/calendar/events"],
      ["GET", "/api/schedules"],
      ["PUT", "/api/bots/x/permissions"],
      ["GET", "/api/bots/x"],
      ["POST", "/api/auth/step-up"],
      ["POST", "/api/auth/relay"],
      ["DELETE", "/api/auth/relay"],
      ["POST", "/api/transcriptions/warm"],
    ] as const) {
      const r = await as(method, path, method === "GET" || method === "DELETE" ? undefined : {});
      expect([method, path, r.status]).toEqual([method, path, 403]);
    }
    expect(scopeAllows("relay", "GET", "/api/ws")).toBe(false);
    const socket = await fetch(app.base.replace("http", "http") + "/api/ws", { headers: { authorization: `Bearer ${(await withRelay()).relay}`, upgrade: "websocket" } });
    expect(socket.status).toBeGreaterThanOrEqual(400);
    expect(RELAY_RULES.length).toBe(9);
  });

  test("lists bots by name only, the general one marked", async () => {
    const { app, as } = await withRelay();
    const general = await bot(app, "Général", { emoji: "🧭", overview: true, instructions: "Tu vois tous les bots." });
    const list = (await as("GET", "/api/bots")).data as Record<string, unknown>[];
    expect(list).toContainEqual({ id: general, name: "Général", emoji: "🧭", overview: true });
    for (const b of list) expect(Object.keys(b).sort()).toEqual(expect.arrayContaining(["emoji", "id", "name"]));
    expect(JSON.stringify(list)).not.toContain("Tu vois tous les bots");
  });

  test("prompts, reads and confirms only in the conversations it opened", async () => {
    const { app, as } = await withRelay();
    const voyages = await bot(app, "Voyages");
    const mine = (await as("POST", "/api/conversations", { botId: voyages })).data;
    expect(mine.id).toBeString();
    const theirs = (await app.api("POST", "/api/conversations", { botId: voyages })).data;
    expect((await as("POST", `/api/conversations/${theirs.id}/prompt`, { text: "Résume mes mails" })).status).toBe(403);
    expect((await as("GET", `/api/conversations/${theirs.id}/messages`)).status).toBe(403);
    expect((await as("GET", `/api/conversations/${theirs.id}`)).status).toBe(403);
    expect((await as("POST", `/api/conversations/${mine.id}/prompt`, { text: "Ajoute acheter du pain" })).status).toBe(202);
    for (let i = 0; i < 200 && (await as("GET", `/api/conversations/${mine.id}/messages`)).data.length < 2; i++) await Bun.sleep(10);
    expect((await as("GET", `/api/conversations/${mine.id}/messages`)).data.map((m: { role: string }) => m.role)).toEqual(["user", "assistant"]);
    // Text only: no command, no attachment, nothing long.
    expect((await as("POST", `/api/conversations/${mine.id}/prompt`, { text: "/deploy nuo" })).status).toBe(400);
    expect((await as("POST", `/api/conversations/${mine.id}/prompt`, { text: "Bonjour", attachments: [{ kind: "file" }] })).status).toBe(400);
    expect((await as("POST", `/api/conversations/${mine.id}/prompt`, { text: "x".repeat(5000) })).status).toBe(413);
  });

  test("answers a confirmation once, either way, in its own conversation only", async () => {
    const { app, as } = await withRelay();
    const coach = await bot(app, "Coach");
    const mine = (await as("POST", "/api/conversations", { botId: coach })).data;
    expect((await as("POST", `/api/conversations/${mine.id}/prompt`, { text: "call:nuo/reminder_add" })).status).toBe(202);
    let permission: { requestId: string; options: { id: string; kind: string }[] } | undefined;
    for (let i = 0; i < 200 && !permission; i++) {
      permission = (await as("GET", `/api/conversations/${mine.id}`)).data.turn?.permission;
      if (!permission) await Bun.sleep(10);
    }
    // Only « once » answers are offered: a yes counts for one call (S-5).
    expect(permission?.options.map((o) => o.kind)).toEqual(["allow_once", "reject_once"]);
    const other = (await as("POST", "/api/conversations", { botId: coach })).data;
    expect((await as("POST", `/api/conversations/${other.id}/permission`, { requestId: permission!.requestId, optionId: "allow_once" })).status).toBe(404);
    expect((await as("POST", `/api/conversations/${mine.id}/permission`, { requestId: permission!.requestId, optionId: "allow_always" })).status).toBe(403);
    expect((await as("POST", `/api/conversations/${mine.id}/permission`, { requestId: permission!.requestId, optionId: "reject_once" })).status).toBe(200);
    for (let i = 0; i < 200; i++) {
      const messages = (await as("GET", `/api/conversations/${mine.id}/messages`)).data;
      if (messages.at(-1)?.role === "assistant") {
        expect(messages.at(-1).text.trim()).toBe("reminder_add:reject_once");
        return;
      }
      await Bun.sleep(10);
    }
    throw new Error("the turn did not end");
  });

  test("a turn it passes on runs `ask` in a relay session even for a bot set to `auto`; the app's next turn is `auto` again", async () => {
    const { app, as } = await withRelay();
    const general = await bot(app, "Général", { overview: true, permissionPolicy: "auto" });
    const mine = (await as("POST", "/api/conversations", { botId: general })).data;
    expect((await as("POST", `/api/conversations/${mine.id}/prompt`, { text: "Mets réunion devis salon de Lyon jeudi 14 h au calendrier" })).status).toBe(202);
    for (let i = 0; i < 200 && app.runtime.starts.length === 0; i++) await Bun.sleep(10);
    expect(app.runtime.starts.at(-1)).toMatchObject({ permissionPolicy: "ask", relay: true });
    for (let i = 0; i < 200 && (await as("GET", `/api/conversations/${mine.id}/messages`)).data.length < 2; i++) await Bun.sleep(10);
    const before = app.runtime.starts.length;
    expect((await app.api("POST", `/api/conversations/${mine.id}/prompt`, { text: "Merci" })).status).toBe(202);
    for (let i = 0; i < 200 && app.runtime.starts.length === before; i++) await Bun.sleep(10);
    expect(app.runtime.starts.at(-1)?.permissionPolicy).toBe("auto");
    expect(app.runtime.starts.at(-1)?.relay).toBeUndefined();
  });

  test("a bot the general one asks during a relay turn runs `ask` too, and its confirmations stay on the iPhone", async () => {
    const LOCAL = "local-secret";
    const { app, as } = await withRelay({ localToken: LOCAL });
    const general = await bot(app, "Général", { overview: true });
    const cobot = await bot(app, "Cobot", { permissionPolicy: "auto" });
    const mine = (await as("POST", "/api/conversations", { botId: general })).data;
    // « hold » keeps the general bot's relay turn running once the watch said yes to its bot_ask.
    expect((await as("POST", `/api/conversations/${mine.id}/prompt`, { text: "call:nuo/bot_ask hold" })).status).toBe(202);
    let confirm: { requestId: string } | undefined;
    for (let i = 0; i < 200 && !confirm; i++) {
      confirm = (await as("GET", `/api/conversations/${mine.id}`)).data.turn?.permission;
      if (!confirm) await Bun.sleep(10);
    }
    expect((await as("POST", `/api/conversations/${mine.id}/permission`, { requestId: confirm!.requestId, optionId: "allow_once" })).status).toBe(200);
    const asked = await fetch(`${app.base}/api/bots/${cobot}/ask`, {
      method: "POST",
      headers: { authorization: `Bearer ${LOCAL}`, "content-type": "application/json", "x-nuo-conversation": mine.id },
      body: JSON.stringify({ prompt: "État des services sur dev ?", waitSeconds: 2 }),
    }).then((r) => r.json());
    expect(asked.conversationId).toBeString();
    expect(app.runtime.starts.at(-1)).toMatchObject({ permissionPolicy: "ask", relay: true });
    // Cobot's conversation is not the relay's: the watch cannot answer there.
    expect((await as("GET", `/api/conversations/${asked.conversationId}/messages`)).status).toBe(403);
    await app.api("POST", `/api/conversations/${mine.id}/cancel`).catch(() => undefined);
  });

  test(`passes on ${RELAY_PROMPTS_PER_HOUR} prompts an hour, each written to the audit log`, async () => {
    const { app, as } = await withRelay();
    const voyages = await bot(app, "Voyages");
    const mine = (await as("POST", "/api/conversations", { botId: voyages })).data;
    // The limit counts what the log holds: earlier prompts of the hour are written there directly.
    for (let i = 0; i < RELAY_PROMPTS_PER_HOUR - 1; i++) app.app.auth.relayPrompt({ ...ctxOf(app) }, `Voyages · ${mine.id}`);
    expect((await as("POST", `/api/conversations/${mine.id}/prompt`, { text: "Mon vol de lundi est à l'heure ?" })).status).toBe(202);
    expect((await as("POST", `/api/conversations/${mine.id}/prompt`, { text: "Et celui de mardi ?" })).status).toBe(429);
    const prompts = relayEvents(app, "relay_prompt");
    expect(prompts.filter((e) => e.ok).length).toBe(RELAY_PROMPTS_PER_HOUR);
    expect(prompts.at(-1)).toMatchObject({ ok: 0, detail: `limit: Voyages · ${mine.id}` });
  });

  test("transcribes a short dictation only, and never sees the app's jobs", async () => {
    const stt = new FakeStt();
    const { app, relay } = await withRelay({ transcription: stt });
    const form = (over: Record<string, string> = {}) => {
      const f = new FormData();
      f.set("audio", new Blob([new Uint8Array([0, 0, 0, 24, 102, 116, 121, 112])], { type: "audio/mp4" }), "watch-ask.m4a");
      f.set("language", "fr");
      f.set("seconds", "4.2");
      for (const [k, v] of Object.entries(over)) f.set(k, v);
      return f;
    };
    const send = (f: FormData, headers: Record<string, string> = {}) =>
      fetch(app.base + "/api/transcriptions", { method: "POST", headers: { authorization: `Bearer ${relay}`, ...headers }, body: f });
    const ok = await send(form());
    expect(ok.status).toBe(200);
    expect((await ok.json()).text).toBe("Ajoute acheter du pain et appeler Julie Martin demain à 9 h");
    expect((await send(form({ background: "true" }))).status).toBe(403);
    expect((await send(form(), { "x-nuo-transcription-id": "3f6c2a1e-8d4b-4f0a-9c1e-5a7b2d9e4c10" })).status).toBe(403);
    const meeting = form({ background: "true", seconds: "5400" });
    const started = await fetch(app.base + "/api/transcriptions", { method: "POST", headers: { authorization: `Bearer ${app.token}` }, body: meeting });
    const { id } = await started.json();
    const read = await fetch(`${app.base}/api/transcriptions/${id}`, { headers: { authorization: `Bearer ${relay}` } });
    expect(read.status).toBe(404);
  });
});

function ctxOf(app: TestApp) {
  return { profileId: "owner", deviceId: app.device.id, deviceName: app.device.name, scope: "relay" as const, expiresAt: Date.now() + 60_000 };
}
