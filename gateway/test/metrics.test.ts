import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { LatencyRecorder, latencyReport, quantile } from "../src/metrics/latency";
import type { ServerEvent } from "../src/protocol";
import { Hub } from "../src/runner/hub";
import { openDb } from "../src/store/db";
import { Store, type TurnMetric } from "../src/store/store";
import { botConfig, Socket, startTestApp, type TestApp } from "./helpers";

let dir: string | undefined;
let t: TestApp | undefined;
afterEach(async () => {
  if (dir) rmSync(dir, { recursive: true, force: true });
  dir = undefined;
  await t?.close();
  t = undefined;
});

function freshStore() {
  dir = mkdtempSync(join(tmpdir(), "nuo-metrics-"));
  const store = new Store(openDb(dir));
  const botId = store.createBot(botConfig({ name: "Homelab", emoji: "🖥️" }) as any, "Homelab");
  const conv = store.createConversation(botId, true, "Espace disque du NAS");
  return { store, botId, conv };
}

/** A clock the test moves by hand, so each delay is exact. */
function manualClock(start = Date.parse("2026-10-28T08:00:00Z")) {
  let at = start;
  return { now: () => at, advance: (ms: number) => (at += ms) };
}

test("records the delays of an agent answer from the broadcast events", () => {
  const { store, botId, conv } = freshStore();
  const clock = manualClock();
  const hub = new Hub();
  new LatencyRecorder(store, clock.now).attach(hub);
  const ids = { conversationId: conv.id, messageId: "msg-nas-disk" };
  const at = new Date(clock.now()).toISOString();
  hub.broadcast({ type: "message.start", ...ids, botId, role: "assistant", at, phase: "queued" });
  clock.advance(400);
  hub.broadcast({ type: "turn.phase", ...ids, phase: "thinking" });
  clock.advance(800);
  hub.broadcast({ type: "thought.delta", ...ids, text: "Je regarde df -h" });
  clock.advance(300);
  hub.broadcast({ type: "tool.start", ...ids, toolCallId: "t1", title: "df -h /mnt/nas", kind: "execute" });
  clock.advance(2_000);
  hub.broadcast({ type: "tool.end", ...ids, toolCallId: "t1", status: "completed", durationMs: 2_000 });
  hub.broadcast({ type: "message.delta", ...ids, text: "\n" });
  clock.advance(500);
  hub.broadcast({ type: "message.delta", ...ids, text: "Le NAS est plein à 87 %." });
  clock.advance(700);
  hub.broadcast({ type: "message.end", ...ids, durationMs: 4_700, steps: 1, stopReason: "end_turn", agent: "claude", model: "claude-sonnet-4-5" });

  expect(store.turnMetrics("2026-10-01T00:00:00Z", ["user"])).toEqual([
    {
      messageId: "msg-nas-disk",
      botId,
      conversationId: conv.id,
      origin: "user",
      startedAt: at,
      firstEventMs: 1_200,
      firstTextMs: 4_000,
      durationMs: 4_700,
      toolMs: 2_000,
      steps: 1,
      stopReason: "end_turn",
      agent: "claude",
      model: "claude-sonnet-4-5",
    },
  ]);
});

test("marks scheduled and resumed turns, and skips answers the gateway wrote itself", () => {
  const { store, botId, conv } = freshStore();
  const clock = manualClock();
  const rec = new LatencyRecorder(store, clock.now);
  const turn = (messageId: string, end: Partial<Extract<ServerEvent, { type: "message.end" }>> = { agent: "codex" }) => {
    rec.observe({ type: "message.start", conversationId: conv.id, botId, messageId, role: "assistant", at: new Date(clock.now()).toISOString() });
    clock.advance(1_500);
    rec.observe({ type: "message.delta", conversationId: conv.id, messageId, text: "Sauvegarde terminée." });
    rec.observe({ type: "message.end", conversationId: conv.id, messageId, durationMs: 1_600, steps: 0, stopReason: "end_turn", ...end });
  };

  const task = store.createTask({
    botId,
    title: "Sauvegarde nocturne",
    prompt: "Vérifie la sauvegarde restic de cette nuit",
    schedule: { kind: "cron", expr: "0 7 * * *", timezone: "Europe/Paris" },
    enabled: true,
    conversation: "dedicated",
    conversationId: conv.id,
    notify: true,
    createdBy: "user",
  });
  store.addTaskRun({ id: "run-backup", taskId: task.id, conversationId: conv.id, startedAt: new Date(clock.now()).toISOString(), status: "running" });
  turn("msg-scheduled");
  store.finishTaskRun("run-backup", { status: "ok", endedAt: new Date(clock.now()).toISOString() });

  rec.observe({ type: "notice", conversationId: conv.id, kind: "resumed", text: "Reprise après le redémarrage de la passerelle" });
  turn("msg-resumed");
  turn("msg-compaction", {});
  turn("msg-user");

  const origins = store.turnMetrics("2026-10-01T00:00:00Z", ["user", "scheduled", "resumed"]).map((m) => [m.messageId, m.origin]);
  expect(origins).toEqual([
    ["msg-scheduled", "scheduled"],
    ["msg-resumed", "resumed"],
    ["msg-user", "user"],
  ]);
});

test("a throwing observer does not stop the broadcast to other observers", () => {
  const hub = new Hub();
  const seen: string[] = [];
  hub.observe(() => {
    throw new Error("database is locked");
  });
  const stop = hub.observe((e) => seen.push(e.type));
  hub.broadcast({ type: "pong" });
  stop();
  hub.broadcast({ type: "pong" });
  expect(seen).toEqual(["pong"]);
});

test("quantile interpolates between ranks", () => {
  expect(quantile([], 0.5)).toBeUndefined();
  expect(quantile([1_000, 3_000], 0.5)).toBe(2_000);
  expect(quantile([5, 1, 3, 2, 4, 6, 7, 8, 9, 10], 0.9)).toBe(9);
});

test("GET /api/metrics/latency summarises each bot and day", async () => {
  t = await startTestApp();
  const bot = (await t.api("POST", "/api/bots", { name: "Homelab" })).data;
  await t.api("PUT", `/api/bots/${bot.id}/draft`, botConfig({ name: "Homelab", emoji: "🖥️", color: "#DDE8F0" }));
  await t.api("POST", `/api/bots/${bot.id}/publish`, {});
  const coach = (await t.api("POST", "/api/bots", { name: "Coach" })).data;
  await t.api("PUT", `/api/bots/${coach.id}/draft`, botConfig({ name: "Coach", emoji: "🏋️" }));
  await t.api("POST", `/api/bots/${coach.id}/publish`, {});
  const conv = (await t.api("POST", "/api/conversations", { botId: bot.id })).data;

  // A real turn through the runner: the recorder sees what the socket sees.
  const sock = await Socket.open(t);
  sock.send({ type: "prompt", conversationId: conv.id, text: "Combien reste-t-il de place sur le NAS ?" });
  await sock.next("message.end");
  sock.close();

  const day = (offset: number, hour: number) => {
    const d = new Date();
    d.setDate(d.getDate() - offset);
    d.setHours(hour, 0, 0, 0);
    return d.toISOString();
  };
  const metric = (over: Partial<TurnMetric>): TurnMetric => ({
    messageId: crypto.randomUUID(),
    botId: coach.id,
    conversationId: "conv-seance",
    origin: "user",
    startedAt: day(1, 9),
    firstEventMs: 900,
    firstTextMs: 2_000,
    durationMs: 9_000,
    toolMs: 3_000,
    steps: 2,
    stopReason: "end_turn",
    agent: "claude",
    model: "claude-sonnet-4-5",
    ...over,
  });
  const store = t.app.store;
  store.addTurnMetric(metric({ startedAt: day(1, 9), firstTextMs: 2_000, durationMs: 9_000, steps: 2 }));
  store.addTurnMetric(metric({ startedAt: day(1, 18), firstTextMs: 4_000, durationMs: 11_000, steps: 4 }));
  store.addTurnMetric(metric({ startedAt: day(0, 7), firstTextMs: 6_000, durationMs: 30_000, steps: 3, stopReason: "cancelled" }));
  store.addTurnMetric(metric({ startedAt: day(0, 6), firstTextMs: 50_000, origin: "scheduled" }));
  store.addTurnMetric(metric({ startedAt: day(20, 9), firstTextMs: 90_000 }));

  const { status, data } = await t.api("GET", "/api/metrics/latency?days=7");
  expect(status).toBe(200);
  expect(data.days).toBe(7);
  expect(data.scheduled).toBe(false);
  expect(data.bots.map((b: any) => b.name)).toEqual(["Coach", "Homelab"]);
  const [c, h] = data.bots;
  expect(c).toMatchObject({ botId: coach.id, emoji: "🏋️", responses: 3, firstTextMedianMs: 4_000, firstTextP90Ms: 5_600, durationMedianMs: 10_000, toolMedianMs: 3_000, avgSteps: 3 });
  expect(c.daily.map((d: any) => [d.responses, d.firstTextMedianMs])).toEqual([
    [2, 3_000],
    [1, 6_000],
  ]);
  const today = new Date();
  expect(c.daily[1].day).toBe(`${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, "0")}-${String(today.getDate()).padStart(2, "0")}`);
  expect(h).toMatchObject({ botId: bot.id, color: "#DDE8F0", responses: 1, avgSteps: 0 });
  expect(h.firstTextMedianMs).toBeGreaterThanOrEqual(h.firstEventMedianMs);
  expect(h.durationMedianMs).toBeGreaterThanOrEqual(h.firstTextMedianMs);

  const withTasks = (await t.api("GET", "/api/metrics/latency?days=7&scheduled=1")).data;
  expect(withTasks.bots.find((b: any) => b.botId === coach.id).responses).toBe(4);
  const month = (await t.api("GET", "/api/metrics/latency?days=30")).data;
  expect(month.bots.find((b: any) => b.botId === coach.id).responses).toBe(4);
  expect((await t.api("GET", "/api/metrics/latency?days=5000")).data.days).toBe(90);
});
