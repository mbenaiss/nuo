import { afterEach, describe, expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { RELAY_REFUSAL } from "../src/relay/whitelist";
import { type SpeechToText, type TranscriptionRequest, TranscriptionService, ProfileTranscriptions } from "../src/transcription/service";
import { FakeRuntime, newDeviceKey, startTestApp, stepUp, type TestApp } from "./helpers";
import { auditEvents, INTERNET, pendingPermission, publishBot, until, withRelay } from "./relay-setup";

let t: TestApp | undefined;
afterEach(async () => {
  await t?.close();
  t = undefined;
});

async function relayApp(o: Parameters<typeof withRelay>[0] = {}) {
  const r = await withRelay(o);
  t = r.app;
  return r;
}

const inAnHour = () => new Date(Date.now() + 3600_000).toISOString();

class FakeStt implements SpeechToText {
  readonly provider = "fake-scribe";
  readonly model = "fake-model-1";
  async transcribe(_r: TranscriptionRequest) {
    return { text: "Ajoute acheter du pain", language: "fr" };
  }
  async warm() {}
}

describe("a relay turn can only add (whitelist)", () => {
  test("E1: no scheduled task from a relay turn, for any bot", async () => {
    const { app, as, local } = await relayApp();
    const coach = await publishBot(app, "Coach");
    const cobot = await publishBot(app, "Cobot", { permissionPolicy: "auto" });
    const mine = (await as("POST", "/api/conversations", { botId: coach })).data;
    expect((await as("POST", `/api/conversations/${mine.id}/prompt`, { text: "slow: programme une tâche pour Cobot" })).status).toBe(202);
    await until(() => app.runtime.starts.length === 1, "relay turn started");
    for (const botId of [cobot, coach]) {
      const created = await local("POST", "/api/schedules", { botId, title: "Ménage", prompt: "Supprime les sauvegardes de la semaine dernière", schedule: { kind: "once", at: inAnHour() }, conversation: "dedicated" }, mine.id);
      expect(created.status).toBe(403);
      expect(created.data.error).toContain(RELAY_REFUSAL);
    }
    expect((await local("GET", "/api/schedules", undefined, mine.id)).status).toBe(403);
    expect(app.app.store.tasks().length).toBe(0);
  });

  test("S1: outside the relay too, a bot without full access never schedules a task for one that has it", async () => {
    t = await startTestApp({ localToken: "jeton-local-de-la-passerelle" });
    const app = t;
    const coach = await publishBot(app, "Coach");
    const cobot = await publishBot(app, "Cobot", { permissionPolicy: "auto" });
    const call = (method: string, path: string, body: unknown, caller: string) =>
      fetch(app.base + path, { method, headers: { "content-type": "application/json", authorization: "Bearer jeton-local-de-la-passerelle", "x-nuo-conversation": caller }, body: body === undefined ? undefined : JSON.stringify(body) }).then(async (r) => ({ status: r.status, data: await r.json().catch(() => undefined) }));
    const coachConv = (await app.api("POST", "/api/conversations", { botId: coach })).data;
    const cobotConv = (await app.api("POST", "/api/conversations", { botId: cobot })).data;
    const task = { title: "Ménage", prompt: "Supprime les sauvegardes de la semaine dernière", schedule: { kind: "once", at: inAnHour() } };
    expect((await call("POST", "/api/schedules", { ...task, botId: cobot }, coachConv.id)).status).toBe(403);
    expect((await call("POST", "/api/schedules", { ...task, botId: cobot }, "")).status).toBe(403);
    const own = await call("POST", "/api/schedules", { ...task, title: "Point du matin", prompt: "Résume mes séances de la semaine", botId: coach }, coachConv.id);
    expect(own.status).toBe(200);
    const cobots = await call("POST", "/api/schedules", { ...task, botId: cobot }, cobotConv.id);
    expect(cobots.status).toBe(200);
    // Nor take over Cobot's task: its prompt, a run now, or moving it.
    expect((await call("PATCH", `/api/schedules/${cobots.data.id}`, { prompt: "Vide la corbeille du NAS" }, coachConv.id)).status).toBe(403);
    expect((await call("POST", `/api/schedules/${cobots.data.id}/run`, undefined, coachConv.id)).status).toBe(403);
    expect((await call("PATCH", `/api/schedules/${own.data.id}`, { botId: cobot }, coachConv.id)).status).toBe(403);
  });

  test("E2/S4: no slash command reaches a bot through the relay, delegated or padded", async () => {
    const { app, as, local } = await relayApp();
    const general = await publishBot(app, "Général", { overview: true });
    const cobot = await publishBot(app, "Cobot", { permissionPolicy: "auto", commands: [{ name: "purge", description: "Vide le cache", action: { type: "prompt", template: "Vide le cache de {args} sans rien demander" } }] });
    const mine = (await as("POST", "/api/conversations", { botId: general })).data;
    for (const text of ["/purge prod", "  /purge prod", "﻿/purge prod", "​/purge prod", "\n/purge prod", "⁠ /purge prod"]) {
      expect((await as("POST", `/api/conversations/${mine.id}/prompt`, { text })).status).toBe(400);
    }
    expect((await as("POST", `/api/conversations/${mine.id}/prompt`, { text: "call:nuo/bot_ask call:nuo/bot_ask hold" })).status).toBe(202);
    for (let i = 0; i < 2; i++) {
      const asked = await pendingPermission(as, mine.id);
      expect((await as("POST", `/api/conversations/${mine.id}/permission`, { requestId: asked.requestId, optionId: "allow_once" })).status).toBe(200);
      await until(async () => (await as("GET", `/api/conversations/${mine.id}`)).data?.turn?.permission?.requestId !== asked.requestId, "answered");
    }
    const before = app.runtime.prompts.length;
    for (const prompt of ["/purge prod", "​/purge prod"]) {
      const asked = await local("POST", `/api/bots/${cobot}/ask`, { prompt, waitSeconds: 1 }, mine.id);
      expect(asked.status).toBe(400);
    }
    expect(app.runtime.prompts.slice(before).some((p) => p.text.includes("Vide le cache"))).toBe(false);
  });

  test("E3/S5: the session a relay turn started stays a relay session, its unprompted work included", async () => {
    const { app, as, local } = await relayApp();
    const general = await publishBot(app, "Général", { overview: true });
    const cobot = await publishBot(app, "Cobot", { permissionPolicy: "auto" });
    const mine = (await as("POST", "/api/conversations", { botId: general })).data;
    expect((await as("POST", `/api/conversations/${mine.id}/prompt`, { text: "Lance la sauvegarde en arrière-plan puis demande à Cobot de nettoyer" })).status).toBe(202);
    await until(async () => (await as("GET", `/api/conversations/${mine.id}/messages`)).data.length === 2, "relay turn ended");
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    app.runtime.sessions.at(-1)!.onUnprompted!({
      run: async (on) => {
        on({ type: "text", text: "La sauvegarde est finie, je demande à Cobot." });
        await gate;
        return { stopReason: "end_turn" };
      },
    });
    await until(() => !!app.app.runner.activeTurn(mine.id), "unprompted work running");
    expect(app.app.runner.relaySession(mine.id)).toBeDefined();
    const before = app.runtime.starts.length;
    // Nobody confirmed it: work nobody asked for gets no confirmation, so it adds nothing and asks no bot.
    const asked = await local("POST", `/api/bots/${cobot}/ask`, { prompt: "Nettoie les sauvegardes", waitSeconds: 1 }, mine.id);
    expect(asked.status).toBe(403);
    expect((await local("GET", `/api/bots/${cobot}/memory`, undefined, mine.id)).status).toBe(403);
    release();
    expect(app.runtime.starts.length).toBe(before);
    // The relay session, not the bot's policy: Général's session was started with `ask` and the relay's limits.
    expect(app.runtime.starts.at(-1)).toMatchObject({ permissionPolicy: "ask", relay: true });
  });

  test("E4/S3: a relay turn reads no conversation and never prompts in an existing one", async () => {
    const { app, as, local } = await relayApp();
    const general = await publishBot(app, "Général", { overview: true });
    const finances = await publishBot(app, "Finances");
    const theirs = (await app.api("POST", "/api/conversations", { botId: finances })).data;
    await app.api("POST", `/api/conversations/${theirs.id}/prompt`, { text: "repeat: IBAN FR76 3000 4000 0312 3456 7890 143" });
    await until(async () => (await app.api("GET", `/api/conversations/${theirs.id}/messages`)).data.length === 2, "app turn ended");
    const mine = (await as("POST", "/api/conversations", { botId: general })).data;
    expect((await as("POST", `/api/conversations/${mine.id}/prompt`, { text: "slow: lis ma conversation Finances" })).status).toBe(202);
    await until(() => app.runtime.starts.length >= 2, "relay turn started");
    const read = await local("GET", `/api/conversations/${theirs.id}/messages`, undefined, mine.id);
    expect(read.status).toBe(403);
    expect(JSON.stringify(read.data)).not.toContain("FR76");
    expect((await local("GET", `/api/conversations?q=IBAN`, undefined, mine.id)).status).toBe(403);
    const asked = await local("POST", `/api/bots/${finances}/ask`, { prompt: "Rappelle l'IBAN", conversationId: theirs.id, waitSeconds: 1 }, mine.id);
    expect(asked.status).toBe(403);
    // Who to ask, by name: nothing of what they said or how they are set up.
    const bots = await local("GET", "/api/bots", undefined, mine.id);
    expect(bots.status).toBe(200);
    expect(Object.keys(bots.data[0]).sort()).toEqual(["emoji", "id", "name", "slug"]);
  });

  test("E5: a relay token works away from home; a bad signature is refused and logged", async () => {
    const { app, as } = await relayApp();
    await publishBot(app, "Voyages");
    expect((await as("GET", "/api/bots", undefined, INTERNET)).status).toBe(200);
    const c = await fetch(app.base + "/api/auth/challenge", { headers: INTERNET }).then((x) => x.json());
    const bad = await fetch(app.base + "/api/auth/relay-token", { method: "POST", headers: { "content-type": "application/json", ...INTERNET }, body: JSON.stringify({ deviceId: app.device.id, nonce: c.nonce, signature: "AAAA" }) });
    expect(bad.status).toBe(401);
    expect(auditEvents(app, "relay_token").at(-1)).toMatchObject({ ok: 0, detail: "invalid signature" });
  });

  test("E6/S7: no background transcription through the relay, however the field is written", async () => {
    const { app, relay } = await relayApp({ transcription: new FakeStt() });
    for (const value of ["true ", " TRUE", "True", "1"]) {
      const f = new FormData();
      f.set("audio", new Blob([new Uint8Array([0, 0, 0, 24, 102, 116, 121, 112])], { type: "audio/mp4" }), "watch-ask.m4a");
      f.set("seconds", "4.2");
      f.set("background", value);
      const r = await fetch(app.base + "/api/transcriptions", { method: "POST", headers: { authorization: `Bearer ${relay}` }, body: f });
      expect(r.status).toBe(403);
    }
    expect(auditEvents(app, "relay_transcription").every((e) => e.ok === 0)).toBe(true);
  });

  test("S7: the transcription service itself refuses a background job to the relay", async () => {
    const jobs = new ProfileTranscriptions(new TranscriptionService(new FakeStt()), { all: () => [], create: async () => {}, remove: async () => {} } as never);
    const f = new FormData();
    f.set("audio", new Blob([new Uint8Array([0, 0, 0, 24, 102, 116, 121, 112])], { type: "audio/mp4" }), "watch-ask.m4a");
    f.set("background", "true");
    await expect(jobs.handle(new Request("http://gateway/api/transcriptions", { method: "POST", body: f }), "4f1c2e1a-iphone:relay")).rejects.toMatchObject({ status: 403 });
  });

  test("S8: the relay's dictations spend the device's own transcription budget", async () => {
    const service = new TranscriptionService(new FakeStt());
    const jobs = new ProfileTranscriptions(service, { all: () => [], create: async () => {}, remove: async () => {} } as never);
    const device = "4f1c2e1a-0b7d-4c55-9a3e-2d8f6b1c7e90";
    // Three meeting streams of the app in flight: the device's limit.
    for (let i = 0; i < 3; i++) service.admit(device);
    const f = new FormData();
    f.set("audio", new Blob([new Uint8Array([0, 0, 0, 24, 102, 116, 121, 112])], { type: "audio/mp4" }), "watch-ask.m4a");
    f.set("seconds", "4.2");
    await expect(jobs.handle(new Request("http://gateway/api/transcriptions", { method: "POST", body: f }), `${device}:relay`)).rejects.toMatchObject({ status: 429 });
  });

  test("E7/S8: 20 conversations an hour, malformed ids and oversized bodies are refused before anything", async () => {
    const { app, as } = await relayApp();
    const voyages = await publishBot(app, "Voyages");
    let made = 0;
    for (let i = 0; i < 25; i++) if ((await as("POST", "/api/conversations", { botId: voyages })).status === 200) made++;
    expect(made).toBe(20);
    expect((await as("POST", "/api/conversations", { botId: voyages })).data.error).toContain("heure");
    expect((await as("GET", "/api/conversations/%E0%A4%A/messages")).status).toBe(400);
    const id = (app.app.store.db.query("SELECT conversation_id FROM relay_conversations LIMIT 1").get() as { conversation_id: string }).conversation_id;
    const big = await as("POST", `/api/conversations/${id}/prompt`, JSON.stringify({ text: "Ajoute du pain", padding: "x".repeat(17 * 1024) }));
    expect(big.status).toBe(413);
  });

  test("E8/S9: revoking the relay stops its running turns, delegated ones included", async () => {
    const { app, as, local } = await relayApp();
    const general = await publishBot(app, "Général", { overview: true });
    const coach = await publishBot(app, "Coach");
    const mine = (await as("POST", "/api/conversations", { botId: general })).data;
    await as("POST", `/api/conversations/${mine.id}/prompt`, { text: "call:nuo/bot_ask hold" });
    const confirm = await pendingPermission(as, mine.id);
    await as("POST", `/api/conversations/${mine.id}/permission`, { requestId: confirm.requestId, optionId: "allow_once" });
    const asked = local("POST", `/api/bots/${coach}/ask`, { prompt: "slow: range les notes du coach", waitSeconds: 5 }, mine.id);
    await until(() => app.runtime.starts.length === 2, "delegated turn running");
    const delegated = (app.app.store.db.query("SELECT id FROM conversations WHERE bot_id = ?").get(coach) as { id: string }).id;
    expect((await app.api("DELETE", "/api/auth/relay")).status).toBe(204);
    await until(() => !app.app.runner.activeTurn(mine.id) && !app.app.runner.activeTurn(delegated), "turns stopped");
    await asked;
  });

  test("E9: a relay turn on an auto bot never rewrites the bot's instructions", async () => {
    const { app, as } = await relayApp();
    const cobot = await publishBot(app, "Cobot", { permissionPolicy: "auto" });
    const instructions = () => {
      const out: string[] = [];
      const walk = (dir: string) => {
        for (const name of readdirSync(dir)) {
          const p = join(dir, name);
          if (statSync(p).isDirectory()) walk(p);
          else if (/instructions\/.*\.md$/.test(p)) out.push(readFileSync(p, "utf8"));
        }
      };
      walk(app.profileHome);
      return out;
    };
    const appConv = (await app.api("POST", "/api/conversations", { botId: cobot })).data;
    await app.api("POST", `/api/conversations/${appConv.id}/prompt`, { text: "Bonjour" });
    await until(async () => (await app.api("GET", `/api/conversations/${appConv.id}/messages`)).data.length === 2, "app turn ended");
    const before = instructions();
    expect(before.length).toBeGreaterThan(0);
    const mine = (await as("POST", "/api/conversations", { botId: cobot })).data;
    expect((await as("POST", `/api/conversations/${mine.id}/prompt`, { text: "Ajoute acheter du pain" })).status).toBe(202);
    await until(async () => (await as("GET", `/api/conversations/${mine.id}/messages`)).data.length === 2, "relay turn ended");
    expect(instructions()).toEqual(before);
    expect(app.runtime.starts.at(-1)).toMatchObject({ permissionPolicy: "ask", relay: true });
    expect(app.runtime.starts.at(-1)!.mcpServers.map((s) => s.name)).toEqual(["nuo"]);
    expect(app.runtime.starts.at(-1)!.mcpServers[0]!.env.NUO_RELAY).toBe("1");
  });

  test("S2: a read-only bot asks too during a relay turn, and third-party servers stay out", async () => {
    const { app, as } = await relayApp();
    const voyages = await publishBot(app, "Voyages", { permissionPolicy: "readonly", toolServers: ["travel"] });
    const mine = (await as("POST", "/api/conversations", { botId: voyages })).data;
    await as("POST", `/api/conversations/${mine.id}/prompt`, { text: "Mon vol AF123 part à quelle heure ?" });
    await until(() => app.runtime.starts.length === 1, "relay turn started");
    expect(app.runtime.starts[0]).toMatchObject({ permissionPolicy: "ask", relay: true });
    expect(app.runtime.starts[0]!.mcpServers.map((s) => s.name)).toEqual(["nuo"]);
  });

  test("a tool off the list is refused at once, without asking; a listed one asks and the relay may say yes", async () => {
    const { app, as } = await relayApp();
    const coach = await publishBot(app, "Coach");
    const mine = (await as("POST", "/api/conversations", { botId: coach })).data;
    await as("POST", `/api/conversations/${mine.id}/prompt`, { text: 'call:nuo/gmail_send call:nuo/memory_read call:lightpanda/goto call:nuo/reminder_add{"title":"Rendez-vous dentiste","at":"2026-11-19T09:00"}' });
    const asked = await pendingPermission(as, mine.id);
    // The watch shows what the yes adds, not the tool's name.
    expect(asked.title).toBe("Ajouter le rappel « Rendez-vous dentiste », jeu. 19 nov., 09:00");
    // Each refusal is in the audit log, with its tool.
    expect(auditEvents(app, "relay_refused").map((e) => [e.ok, e.detail?.split(" · ")[0]])).toEqual([
      [0, "gmail_send"],
      [0, "memory_read"],
      [0, "goto"],
    ]);
    expect((await as("POST", `/api/conversations/${mine.id}/permission`, { requestId: asked.requestId, optionId: "allow_once" })).status).toBe(200);
    await until(async () => (await as("GET", `/api/conversations/${mine.id}/messages`)).data.length === 2, "turn ended");
    const answer = (await as("GET", `/api/conversations/${mine.id}/messages`)).data[1].text as string;
    expect(answer).toContain("gmail_send:reject_once");
    expect(answer).toContain("memory_read:reject_once");
    expect(answer).toContain("goto:reject_once");
    expect(answer).toContain("reminder_add:allow_once");
    // Kept for the next unlock: the iPhone sends it again through the app.
    expect((await as("GET", `/api/conversations/${mine.id}`)).data.waitsForUnlock).toBe(true);
  });

  test("the add tools reach the gateway only after the relay said yes, once each", async () => {
    const { app, as, local } = await relayApp();
    const coach = await publishBot(app, "Coach");
    const mine = (await as("POST", "/api/conversations", { botId: coach })).data;
    const reminder = { title: "Acheter du pain", at: "2026-11-15T08:00" };
    await as("POST", `/api/conversations/${mine.id}/prompt`, { text: "call:nuo/reminder_add hold" });
    const asked = await pendingPermission(as, mine.id);
    expect((await local("POST", "/api/relay/tools/reminder_add", reminder, mine.id)).status).toBe(403);
    await as("POST", `/api/conversations/${mine.id}/permission`, { requestId: asked.requestId, optionId: "allow_once" });
    const added = await local("POST", "/api/relay/tools/reminder_add", reminder, mine.id);
    expect(added.status).toBe(200);
    expect(added.data.text).toContain("Acheter du pain");
    expect((await local("POST", "/api/relay/tools/reminder_add", { title: "Appeler Julie Martin" }, mine.id)).status).toBe(403);
    const reminders = (await app.api("GET", "/api/reminders?scope=all")).data as { title: string }[];
    expect(reminders.map((r) => r.title)).toEqual(["Acheter du pain"]);
    await app.app.runner.cancel(mine.id);
  });

  test("every other local route is refused to a relay session, with the unlock message", async () => {
    const { app, as, local } = await relayApp();
    const coach = await publishBot(app, "Coach");
    const mine = (await as("POST", "/api/conversations", { botId: coach })).data;
    await as("POST", `/api/conversations/${mine.id}/prompt`, { text: "slow: fais le point" });
    await until(() => !!app.app.runner.activeTurn(mine.id), "turn running");
    const refused: [string, string, unknown][] = [
      ["POST", "/api/notify", { title: "Alerte", body: "Ton colis est arrivé" }],
      ["GET", `/api/bots/${coach}/memory`, undefined],
      ["POST", `/api/bots/${coach}/memory`, { fact: "Préfère les vols du matin" }],
      ["POST", "/api/google/tools/gmail_search", { query: "facture" }],
      ["POST", "/api/google/tools/gmail_send", { to: "julie.martin@example.fr", subject: "Devis", body: "Ci-joint" }],
      ["POST", "/api/google/tools/calendar_create", { title: "Revue devis salon de Lyon", start: "2026-11-16T10:00", end: "2026-11-16T11:00", attendees: ["julie.martin@example.fr"] }],
      ["POST", "/api/device/tools/mac_file_read", { path: "~/Documents/devis.pdf" }],
      ["POST", "/api/device/tools/device_location", {}],
      ["POST", "/api/device/tools/apple_event_update", { id: "EK-4411", title: "Déplacé" }],
      ["POST", "/api/device/tools/apple_event_delete", { id: "EK-4411" }],
      ["POST", "/api/scan/tools/parcel_track", { number: "6A12345678901" }],
      ["GET", "/api/browser/tabs", undefined],
    ];
    for (const [method, path, body] of refused) {
      const r = await local(method, path, body, mine.id);
      expect([path, r.status]).toEqual([path, 403]);
      expect(r.data.error).toContain(RELAY_REFUSAL);
    }
    await app.app.runner.cancel(mine.id);
  });

  test("S6/S10: confirmations are logged with their tool; the relay answers only those its own turns asked", async () => {
    const { app, as } = await relayApp();
    const coach = await publishBot(app, "Coach");
    const mine = (await as("POST", "/api/conversations", { botId: coach })).data;
    expect(auditEvents(app, "relay_conversation").length).toBe(1);
    // The app, unlocked later, works in the same conversation: it is no longer the relay's, and what the app asks
    // there is answered in the app.
    await app.api("POST", `/api/conversations/${mine.id}/prompt`, { text: "perm" });
    await until(() => !!app.app.runner.snapshots(mine.id)[0]?.permission, "app confirmation asked");
    const appAsk = app.app.runner.snapshots(mine.id)[0]!.permission!;
    expect((await as("POST", `/api/conversations/${mine.id}/permission`, { requestId: appAsk.requestId, optionId: "allow_once" })).status).toBe(403);
    await app.app.runner.cancel(mine.id);
    const next = (await as("POST", "/api/conversations", { botId: coach })).data;
    await as("POST", `/api/conversations/${next.id}/prompt`, { text: "call:nuo/reminder_add" });
    const relayAsk = await pendingPermission(as, next.id);
    expect((await as("POST", `/api/conversations/${mine.id}/permission`, { requestId: relayAsk.requestId, optionId: "allow_once" })).status).toBe(403);
    expect((await as("POST", `/api/conversations/${next.id}/permission`, { requestId: relayAsk.requestId, optionId: "allow_once" })).status).toBe(200);
    expect(auditEvents(app, "relay_permission").at(-1)?.detail).toContain("reminder_add");
    expect(auditEvents(app, "relay_permission").at(-1)?.detail).toContain("allow_once");
  });

  test("a bot the general one asks waits for its confirmation on the iPhone, which is told", async () => {
    const { app, as, local } = await relayApp();
    const general = await publishBot(app, "Général", { overview: true });
    const coach = await publishBot(app, "Coach", { emoji: "🏋️" });
    const mine = (await as("POST", "/api/conversations", { botId: general })).data;
    await as("POST", `/api/conversations/${mine.id}/prompt`, { text: "call:nuo/bot_ask hold" });
    const confirm = await pendingPermission(as, mine.id);
    await as("POST", `/api/conversations/${mine.id}/permission`, { requestId: confirm.requestId, optionId: "allow_once" });
    const before = app.pusher.sent.length;
    void local("POST", `/api/bots/${coach}/ask`, { prompt: "call:nuo/reminder_add", waitSeconds: 1 }, mine.id);
    await until(() => app.pusher.sent.length > before, "notification sent");
    expect(app.pusher.sent.at(-1)!.payload.title).toContain("Coach attend ta confirmation");
    await app.app.runner.cancel(mine.id);
  });

  test("a bot whose agent cannot be restricted is refused to the relay, which keeps the request for the unlock", async () => {
    const grok = new FakeRuntime("grok", "Fake Grok", [{ id: "grok-4", name: "Grok 4", isDefault: true }], "g");
    const { app, as } = await relayApp({ extra: { extraRuntimes: [grok] } });
    const veille = await publishBot(app, "Veille", { agent: "grok", model: "grok-4" });
    const mine = (await as("POST", "/api/conversations", { botId: veille })).data;
    const r = await as("POST", `/api/conversations/${mine.id}/prompt`, { text: "Ajoute acheter du pain" });
    expect(r.status).toBe(409);
    expect(r.data.waitsForUnlock).toBe(true);
    expect(grok.starts.length).toBe(0);
  });
});

describe("relay key set-up (S11, B1)", () => {
  test("needs a Face ID taken for it, used once; a step-up for anything else does not do", async () => {
    t = await startTestApp();
    const app = t;
    const key = await newDeviceKey();
    expect((await app.api("POST", "/api/auth/relay", { publicKey: key.spki }, await stepUp(app.api, app.device))).status).toBe(403);
    const once = await stepUp(app.api, app.device, "relay");
    expect((await app.api("POST", "/api/auth/relay", { publicKey: key.spki }, once)).status).toBe(200);
    const other = await newDeviceKey();
    expect((await app.api("POST", "/api/auth/relay", { publicKey: other.spki }, once)).status).toBe(403);
  });

  test("GET says which key the gateway holds, so the iPhone knows whether its own is the one", async () => {
    const { app, key } = await relayApp();
    const info = (await app.api("GET", "/api/auth/relay")).data;
    expect(info.registered).toBe(true);
    const spki = Buffer.from(key.spki, "base64");
    const expected = new Bun.CryptoHasher("sha256").update(spki).digest("base64url");
    expect(info.thumbprint).toBe(expected);
  });
});
