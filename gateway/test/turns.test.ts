import { afterEach, expect, test } from "bun:test";
import type { ServerEvent } from "../src/protocol";
import { botConfig, Socket, startTestApp, type TestApp } from "./helpers";

let t: TestApp;
const sockets: Socket[] = [];
afterEach(async () => {
  for (const s of sockets.splice(0)) s.close();
  await t?.close();
});

async function open() {
  const s = await Socket.open(t);
  sockets.push(s);
  return s;
}

async function setup() {
  t = await startTestApp();
  const bot = (await t.api("POST", "/api/bots", { name: "Cobot" })).data;
  await t.api("PUT", `/api/bots/${bot.id}/draft`, botConfig({ name: "Cobot" }));
  await t.api("POST", `/api/bots/${bot.id}/publish`, {});
  const conv = (await t.api("POST", "/api/conversations", { botId: bot.id })).data;
  return { bot, conv, sock: await open() };
}

/** Starts a turn that stops on a running tool ("gog mail") after one finished tool, a thought and some text. */
async function hangingTurn(sock: Socket, conversationId: string) {
  sock.send({ type: "prompt", conversationId, text: "hang" });
  const start = await sock.next("message.start");
  for (let i = 0; i < 100 && !sock.events.some((e) => e.type === "tool.start" && e.toolCallId === "t2"); i++) await Bun.sleep(5);
  return start;
}

test("a connected socket gets an empty snapshot first", async () => {
  await setup();
  const s = await open();
  expect(await s.next("turns.snapshot")).toEqual({ type: "turns.snapshot", turns: [] });
});

test("message.start is sent before the agent session is ready", async () => {
  const { bot, conv, sock } = await setup();
  t.runtime.startDelayMs = 300;
  const sent = Date.now();
  sock.send({ type: "prompt", conversationId: conv.id, text: "Bonjour" });
  const start = await sock.next("message.start");
  expect(Date.now() - sent).toBeLessThan(250);
  expect(start).toMatchObject({ conversationId: conv.id, botId: bot.id, phase: "queued" });
  expect(t.runtime.starts).toHaveLength(0);
  const listed = (await t.api("GET", `/api/conversations?botId=${bot.id}`)).data[0];
  expect(listed.activeTurn).toMatchObject({ messageId: start.messageId, phase: "queued", steps: 0 });
  expect(await sock.next("turn.phase")).toMatchObject({ messageId: start.messageId, phase: "thinking" });
  const end = await sock.next("message.end");
  expect(end).toMatchObject({ messageId: start.messageId, stopReason: "end_turn" });
  expect((await t.api("GET", `/api/conversations?botId=${bot.id}`)).data[0].activeTurn).toBeUndefined();
});

test("a reconnecting socket rebuilds the running turn from the snapshot", async () => {
  const { bot, conv, sock } = await setup();
  const start = await hangingTurn(sock, conv.id);
  sock.close();

  const again = await open();
  const snap = await again.next("turns.snapshot");
  expect(snap.turns).toHaveLength(1);
  const turn = snap.turns[0]!;
  expect(turn).toMatchObject({
    conversationId: conv.id,
    botId: bot.id,
    messageId: start.messageId,
    startedAt: start.at,
    phase: "working",
    currentTool: "gog mail",
    text: "Voici",
    thoughts: "plan",
  });
  expect(turn.steps.map((s) => [s.toolCallId, s.status])).toEqual([
    ["t1", "completed"],
    ["t2", "running"],
  ]);
  expect(turn.steps[0]!.durationMs).toBeGreaterThanOrEqual(0);

  again.send({ type: "turns.sync" });
  expect((await again.next("turns.snapshot")).turns[0]).toEqual(turn);

  again.send({ type: "cancel", conversationId: conv.id });
  const end = await again.next("message.end");
  expect(end).toMatchObject({ messageId: start.messageId, stopReason: "cancelled" });
  const persisted = (await t.api("GET", `/api/conversations/${conv.id}/messages`)).data[1];
  expect(persisted).toMatchObject({ id: turn.messageId, text: turn.text, thoughts: turn.thoughts });

  const third = await open();
  expect((await third.next("turns.snapshot")).turns).toEqual([]);
});

test("conversations and bots expose the running turn", async () => {
  const { bot, conv, sock } = await setup();
  const idle = (await t.api("POST", "/api/conversations", { botId: bot.id })).data;
  const start = await hangingTurn(sock, conv.id);

  const list = (await t.api("GET", `/api/conversations?botId=${bot.id}`)).data;
  const running = list.find((c: any) => c.id === conv.id);
  expect(running.activeTurn).toEqual({ messageId: start.messageId, startedAt: start.at, phase: "working", currentTool: "gog mail", steps: 2, partialText: "Voici" });
  expect(list.find((c: any) => c.id === idle.id).activeTurn).toBeUndefined();

  const single = (await t.api("GET", `/api/conversations/${conv.id}`)).data;
  expect(single).toMatchObject({ id: conv.id, activeTurn: { phase: "working", partialText: "Voici" }, turn: { messageId: start.messageId, text: "Voici" } });
  expect(single.agentSessionId).toBeUndefined();
  const quiet = (await t.api("GET", `/api/conversations/${idle.id}`)).data;
  expect(quiet.activeTurn).toBeUndefined();
  expect(quiet.turn).toBeUndefined();
  expect((await t.api("GET", "/api/conversations/missing")).status).toBe(404);

  const bots = (await t.api("GET", "/api/bots")).data;
  expect(bots.find((b: any) => b.id === bot.id)).toMatchObject({ activeTurns: 1, activeConversationId: conv.id });
  expect((await t.api("GET", `/api/bots/${bot.id}`)).data).toMatchObject({ activeTurns: 1, activeConversationId: conv.id });

  sock.send({ type: "cancel", conversationId: conv.id });
  await sock.next("message.end");
  const after = (await t.api("GET", `/api/bots/${bot.id}`)).data;
  expect(after.activeTurns).toBe(0);
  expect(after.activeConversationId).toBeUndefined();
});

test("the list keeps only the end of a long partial text", async () => {
  const { bot, conv, sock } = await setup();
  const start = await hangingTurn(sock, conv.id);
  const long = "x".repeat(500);
  // Deltas only come from the agent: feed one through the same path a real agent would.
  (t.app.runner as any).emit({ type: "message.delta", conversationId: conv.id, messageId: start.messageId, text: long } satisfies ServerEvent);
  const listed = (await t.api("GET", `/api/conversations?botId=${bot.id}`)).data[0].activeTurn.partialText as string;
  expect(listed).toBe(`…${("Voici" + long).slice(-200)}`);
  expect((await t.api("GET", `/api/conversations/${conv.id}`)).data.activeTurn.partialText).toBe("Voici" + long);
  sock.send({ type: "cancel", conversationId: conv.id });
  await sock.next("message.end");
});

test("a pending permission is in the snapshot and its answer restores the phase", async () => {
  const { conv, sock } = await setup();
  sock.send({ type: "prompt", conversationId: conv.id, text: "perm" });
  const req = await sock.next("permission.request");
  const snap = (await (await open()).next("turns.snapshot")).turns[0]!;
  expect(snap).toMatchObject({ phase: "waiting_permission", permission: { requestId: req.requestId, title: "Run rm?" } });
  expect(snap.permission!.options).toHaveLength(2);
  sock.send({ type: "permission", requestId: req.requestId, optionId: "allow_once" });
  await sock.next("message.end");
  const phases = sock.turnEvents.filter((e) => e.type === "turn.phase").map((e) => (e as { phase: string }).phase);
  expect(phases).toEqual(["thinking", "thinking"]);
});
