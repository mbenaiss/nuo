import { afterEach, expect, test } from "bun:test";
import { existsSync, mkdtempSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { botConfig, pairDevice, Socket, startTestApp, stepUp, type TestApp } from "./helpers";

let t: TestApp;
let sock: Socket | undefined;
afterEach(async () => {
  sock?.close();
  sock = undefined;
  await t?.close();
});

async function setup(opts: Parameters<typeof startTestApp>[0] = {}) {
  t = await startTestApp(opts);
  const bot = (await t.api("POST", "/api/bots", { name: "Voyages" })).data;
  await t.api("PUT", `/api/bots/${bot.id}/draft`, botConfig());
  await t.api("POST", `/api/bots/${bot.id}/publish`, {});
  const conv = (await t.api("POST", "/api/conversations", { botId: bot.id })).data;
  sock = await Socket.open(t);
  return { bot, conv, sock };
}

test("websocket requires a token", async () => {
  t = await startTestApp();
  expect((await fetch(`${t.base}/api/ws`, { headers: { authorization: "Bearer nope" } })).status).toBe(401);
  const closed = (first: unknown) =>
    new Promise<number>((resolve) => {
      const ws = new WebSocket(t.base.replace("http", "ws") + "/api/ws");
      ws.onopen = () => ws.send(JSON.stringify(first));
      ws.onclose = (e) => resolve(e.code);
    });
  expect(await closed({ type: "ping" })).toBe(4401);
  expect(await closed({ type: "auth", accessToken: "nope" })).toBe(4401);
  const ws = new WebSocket(t.base.replace("http", "ws") + "/api/ws");
  const received: unknown[] = [];
  const pong = new Promise<void>(
    (resolve) =>
      (ws.onmessage = (m) => {
        const e = JSON.parse(String(m.data));
        received.push(e);
        if (e.type === "pong") resolve();
      }),
  );
  ws.onopen = () => {
    ws.send(JSON.stringify({ type: "auth", accessToken: t.token }));
    ws.send(JSON.stringify({ type: "ping" }));
  };
  await pong;
  expect(received).toEqual([{ type: "turns.snapshot", turns: [] }, { type: "pong" }]);
  ws.close();
});

test("ping/pong and invalid events", async () => {
  const { sock } = await setup();
  sock.send({ type: "ping" });
  expect(await sock.next("pong")).toEqual({ type: "pong" });
  sock.send({ type: "prompt", conversationId: "missing", text: "hi" });
  expect((await sock.next("error")).message).toBe("conversation not found");
});

test("prompt streams events in order and persists the turn", async () => {
  const { bot, conv, sock } = await setup();
  sock.send({ type: "prompt", conversationId: conv.id, text: "Bonjour, quel temps fait-il à Rome demain matin ? Donne-moi aussi les vols disponibles" });
  const end = await sock.next("message.end");
  const types = sock.events.map((e) => e.type);
  expect(types).toEqual(["message.start", "thought.delta", "message.delta", "message.delta", "context", "message.end"]);
  expect(end).toMatchObject({ conversationId: conv.id, steps: 0, stopReason: "end_turn" });
  expect(end.durationMs).toBeGreaterThanOrEqual(0);

  const opts = t.runtime.starts[0]!;
  expect(opts.workdir).toBe(join(t.profileHome, "bots", bot.slug));
  expect(existsSync(join(opts.workdir, "CLAUDE.md"))).toBe(true);
  expect(opts.model).toBe("fake-model");
  expect(opts.permissionPolicy).toBe("ask");
  expect(opts.mcpServers[0]).toMatchObject({ name: "travel", command: "/bin/sh" });
  expect(opts.mcpServers[0]!.args.slice(-3)).toEqual(["/opt/travel", "node", "server.js"]);
  expect(opts.mcpServers[0]!.env).toMatchObject({ NUO_MEDIA_DIR: join(t.dataDir, "media") });

  const msgs = (await t.api("GET", `/api/conversations/${conv.id}/messages`)).data;
  expect(msgs.map((m: any) => m.role)).toEqual(["user", "assistant"]);
  expect(msgs[1]).toMatchObject({ id: end.messageId, text: "Hello world", thoughts: "thinking", stopReason: "end_turn" });
  const c = (await t.api("GET", `/api/conversations?botId=${bot.id}`)).data[0];
  expect(c.title.length).toBeLessThanOrEqual(60);
  expect(c.title).toStartWith("Bonjour, quel temps");
  expect(c.title).toEndWith("…");
  expect((await t.api("GET", `/api/bots/${bot.id}`)).data.lastMessagePreview).toBe("Hello world");
});

test("no secret of a tool server reaches the agent's command line, yet the server gets them all", async () => {
  const secrets = mkdtempSync(join(tmpdir(), "nuo-amadeus-"));
  const envFile = join(secrets, "amadeus.env");
  writeFileSync(envFile, "AMADEUS_API_KEY=ak_live_7Hq2Lw9Zr4\nAMADEUS_API_SECRET=\"s3cr3t with spaces and a ' quote\"\n");
  try {
    const { sock, conv } = await setup({
      tools: [{ id: "travel", name: "Voyages", description: "Vols", tools: ["flight_status"], command: "/usr/bin/env", args: [], envFile, env: { AMADEUS_REGION: "eu-west" } }],
    });
    sock.send({ type: "prompt", conversationId: conv.id, text: "Vols Paris-Lisbonne vendredi ?" });
    await sock.next("message.end");
    const specs = t.runtime.starts[0]!.mcpServers;
    const shown = JSON.stringify(specs);
    for (const secret of ["ak_live_7Hq2Lw9Zr4", "s3cr3t with spaces", "eu-west"]) expect(shown).not.toContain(secret);
    const travel = specs.find((sp) => sp.name === "travel")!;
    expect(travel.env).toMatchObject({ NUO_MEDIA_DIR: join(t.dataDir, "media") });
    const sealed = travel.args[3]!;
    expect((statSync(sealed).mode & 0o777).toString(8)).toBe("600");
    // The sealed spec as the agent starts it: its shell sources the file, then becomes the server (here `env`).
    const run = Bun.spawnSync([travel.command, ...travel.args], { env: travel.env });
    const got = Object.fromEntries(run.stdout.toString().trim().split("\n").map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]));
    expect(got).toMatchObject({ AMADEUS_API_KEY: "ak_live_7Hq2Lw9Zr4", AMADEUS_API_SECRET: "s3cr3t with spaces and a ' quote", AMADEUS_REGION: "eu-west", NUO_MEDIA_DIR: join(t.dataDir, "media") });
  } finally {
    rmSync(secrets, { recursive: true, force: true });
  }
});

test("tool steps carry measured durations", async () => {
  const { conv, sock } = await setup();
  sock.send({ type: "prompt", conversationId: conv.id, text: "tool please" });
  const start = await sock.next("tool.start");
  expect(start).toMatchObject({ toolCallId: "t1", title: "flight_status", kind: "fetch" });
  const toolEnd = await sock.next("tool.end");
  expect(toolEnd.durationMs).toBeGreaterThanOrEqual(15);
  const end = await sock.next("message.end");
  expect(end.steps).toBe(1);
  const msgs = (await t.api("GET", `/api/conversations/${conv.id}/messages`)).data;
  expect(msgs[1].steps).toEqual([{ toolCallId: "t1", title: "flight_status", kind: "fetch", status: "completed", durationMs: toolEnd.durationMs }]);
});

test("a command's description is sent to the app and kept with its step", async () => {
  const { conv, sock } = await setup();
  sock.send({ type: "prompt", conversationId: conv.id, text: "Surveille le deploy de main" });
  expect(await sock.next("tool.detail")).toMatchObject({ toolCallId: "t1", detail: "Wait for the deploy workflow on main" });
  await sock.next("message.end");
  const msgs = (await t.api("GET", `/api/conversations/${conv.id}/messages`)).data;
  expect(msgs[1].steps[0]).toMatchObject({ title: "Terminal", detail: "Wait for the deploy workflow on main", status: "completed" });
});

test("every bot gets the browser's MCP server, whatever its permissions, unless its tools already have it", async () => {
  const browserMcp = { name: "lightpanda", command: "/home/julie/.local/bin/lightpanda", args: ["mcp"], env: {} };
  const { bot, conv, sock } = await setup({ browserMcp });
  sock.send({ type: "prompt", conversationId: conv.id, text: "Quels vols pour Lisbonne ?" });
  await sock.next("message.end");
  expect(t.runtime.starts[0]!.mcpServers.map((s) => s.name)).toEqual(["travel", "nuo", "lightpanda"]);

  await t.api("PUT", `/api/bots/${bot.id}/draft`, botConfig({ permissionPolicy: "auto" }));
  await t.api("POST", `/api/bots/${bot.id}/publish`, {});
  sock.send({ type: "prompt", conversationId: conv.id, text: "Et pour Porto ?" });
  await sock.next("message.end");
  expect(t.runtime.starts.at(-1)!.mcpServers.map((s) => s.name)).toEqual(["travel", "nuo", "lightpanda"]);
});

test("prompts are queued per conversation and the session is reused", async () => {
  const { conv, sock } = await setup();
  sock.send({ type: "prompt", conversationId: conv.id, text: "tool one" });
  sock.send({ type: "prompt", conversationId: conv.id, text: "second", model: "other-model" });
  await sock.next("message.end");
  await sock.next("message.end");
  const starts = sock.events.filter((e) => e.type === "message.start" || e.type === "message.end").map((e) => e.type);
  expect(starts).toEqual(["message.start", "message.end", "message.start", "message.end"]);
  expect(t.runtime.starts).toHaveLength(1);
  expect(t.runtime.modelChanges).toEqual(["other-model"]);
  expect((await t.api("GET", `/api/conversations?botId=${conv.botId}`)).data[0].model).toBe("other-model");
});

test("cancel stops the running turn", async () => {
  const { conv, sock } = await setup();
  sock.send({ type: "prompt", conversationId: conv.id, text: "slow" });
  await sock.next("message.delta");
  sock.send({ type: "cancel", conversationId: conv.id });
  const end = await sock.next("message.end");
  expect(end.stopReason).toBe("cancelled");
  const msgs = (await t.api("GET", `/api/conversations?botId=${conv.botId}`)).data;
  expect(msgs).toHaveLength(1);
  const persisted = (await t.api("GET", `/api/conversations/${conv.id}/messages`)).data[1];
  expect(persisted).toMatchObject({ text: "partial", stopReason: "cancelled" });
  expect(t.pusher.sent).toHaveLength(0);
});

test("permission round trip", async () => {
  const { conv, sock } = await setup();
  sock.send({ type: "prompt", conversationId: conv.id, text: "perm" });
  const req = await sock.next("permission.request");
  expect(req).toMatchObject({ conversationId: conv.id, title: "Run rm?" });
  expect(req.options.map((o) => o.id)).toEqual(["allow_once", "reject_once"]);
  sock.send({ type: "permission", requestId: req.requestId, optionId: "allow_once" });
  await sock.next("message.end");
  expect(sock.events.find((e) => e.type === "message.delta")).toMatchObject({ text: "chosen:allow_once" });
  sock.send({ type: "permission", requestId: req.requestId, optionId: "allow_once" });
  expect((await sock.next("error")).message).toContain("unknown or expired");
});

test("unanswered permission is rejected on timeout", async () => {
  const { conv, sock } = await setup();
  sock.send({ type: "prompt", conversationId: conv.id, text: "perm" });
  await sock.next("permission.request");
  await sock.next("message.end", 4000);
  expect(sock.events.find((e) => e.type === "message.delta")).toMatchObject({ text: "chosen:reject_once" });
});

test("agent failure ends the message with an error and drops the session", async () => {
  const { conv, sock } = await setup();
  sock.send({ type: "prompt", conversationId: conv.id, text: "boom" });
  const err = await sock.next("error");
  expect(err).toMatchObject({ conversationId: conv.id, message: "agent crashed" });
  expect((await sock.next("message.end")).stopReason).toBe("error");
  expect(t.app.runner.liveCount).toBe(0);
  sock.send({ type: "prompt", conversationId: conv.id, text: "again" });
  await sock.next("message.end");
  expect(t.runtime.starts.at(-1)!.resumeId).toBe("s1");
});

test("voice prompts get a brevity prefix and images are stored", async () => {
  const { conv, sock } = await setup();
  const png = Buffer.from("89504e470d0a1a0a", "hex").toString("base64");
  sock.send({ type: "prompt", conversationId: conv.id, text: "Quoi ?", voice: true, attachments: [{ kind: "image", mime: "image/png", dataBase64: png }] });
  await sock.next("message.end");
  const p = t.runtime.prompts[0]!;
  expect(p.text).toStartWith("[Réponse vocale");
  expect(p.text).toEndWith("Quoi ?");
  expect(p.attachments[0]).toMatchObject({ kind: "image", mime: "image/png", dataBase64: png });
  const user = (await t.api("GET", `/api/conversations/${conv.id}/messages`)).data[0];
  expect(user.text).toBe("Quoi ?");
  expect(user.attachments[0].dataBase64).toBeUndefined();
  const media = await fetch(t.base + user.attachments[0].url, { headers: { authorization: `Bearer ${t.token}` } });
  expect(media.status).toBe(200);
  expect(media.headers.get("content-type")).toContain("image/png");
  expect((await fetch(t.base + "/api/media/..%2Fx.png", { headers: { authorization: `Bearer ${t.token}` } })).status).toBe(404);
});

test("push is sent when the device has no live socket", async () => {
  const { conv, sock } = await setup();
  await t.api("POST", "/api/devices", { apnsToken: "cd".repeat(32), environment: "production" });
  sock.send({ type: "prompt", conversationId: conv.id, text: "hello" });
  await sock.next("message.end");
  expect(t.pusher.sent).toHaveLength(0);
  sock.close();
  await Bun.sleep(50);
  await t.app.runner.prompt({ conversationId: conv.id, text: "hello again" });
  for (let i = 0; i < 50 && t.pusher.sent.length === 0; i++) await Bun.sleep(10);
  expect(t.pusher.sent[0]!.payload).toMatchObject({ title: "✈️ Voyages", body: "Hello world", conversationId: conv.id });
});

test("no push for a reply while the app is in the foreground on another device", async () => {
  const { conv, sock } = await setup();
  const phone = await pairDevice({ base: t.base, api: t.api, store: t.app.store, totpSecret: t.totpSecret, now: Date.now(), name: "iPhone" });
  const phoneToken = await stepUp(t.api, phone);
  await t.api("POST", "/api/devices", { apnsToken: "cd".repeat(32), environment: "production" }, phoneToken);
  t.pusher.sent.length = 0;
  sock.send({ type: "presence", active: true });
  sock.send({ type: "prompt", conversationId: conv.id, text: "hello" });
  await sock.next("message.end");
  await Bun.sleep(50);
  expect(t.pusher.sent).toHaveLength(0);
  sock.send({ type: "presence", active: false });
  sock.send({ type: "prompt", conversationId: conv.id, text: "hello again" });
  await sock.next("message.end");
  for (let i = 0; i < 50 && t.pusher.sent.length === 0; i++) await Bun.sleep(10);
  expect(t.pusher.sent.map((p) => p.device.name)).toEqual(["iPhone"]);
});

test("live sessions are capped (LRU eviction)", async () => {
  const { conv, sock } = await setup({ maxSessions: 1 });
  const other = (await t.api("POST", "/api/conversations", { botId: conv.botId })).data;
  sock.send({ type: "prompt", conversationId: conv.id, text: "a" });
  await sock.next("message.end");
  sock.send({ type: "prompt", conversationId: other.id, text: "b" });
  await sock.next("message.end");
  expect(t.app.runner.liveCount).toBe(1);
  expect(t.runtime.closed).toEqual(["s1"]);
});
