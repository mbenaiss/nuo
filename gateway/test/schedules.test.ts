import { afterEach, describe, expect, test } from "bun:test";
import { readFileSync, realpathSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { GOOGLE_TOOLS } from "../src/google/tools";
import { DEVICE_TOOLS } from "../src/device/tools";
import { SCAN_TOOLS } from "../src/scan/tools";
import { NUO_MCP_SERVER } from "../src/runner/runner";
import { botConfig, Socket, startTestApp, type TestApp } from "./helpers";

const LOCAL = "local-secret";
let t: TestApp;
let sock: Socket | undefined;
let clock = Date.parse("2026-10-17T10:00:00Z"); // Saturday, 12:00 in Paris

afterEach(async () => {
  sock?.close();
  sock = undefined;
  await t?.app.scheduler.idle();
  await t?.close();
});

async function setup(opts: Parameters<typeof startTestApp>[0] = {}) {
  clock = Date.parse("2026-10-17T10:00:00Z");
  t = await startTestApp({ localToken: LOCAL, scheduler: { now: () => clock }, ...opts });
  const bot = await makeBot("Voyages", "✈️");
  return { bot };
}

async function makeBot(name: string, emoji: string, over: Record<string, unknown> = {}) {
  const bot = (await t.api("POST", "/api/bots", { name })).data;
  await t.api("PUT", `/api/bots/${bot.id}/draft`, botConfig({ name, emoji, ...over }));
  await t.api("POST", `/api/bots/${bot.id}/publish`, {});
  return bot;
}

const cron = (expr: string, timezone?: string) => ({ kind: "cron", expr, ...(timezone ? { timezone } : {}) });

async function advance(to: string) {
  clock = Date.parse(to);
  t.app.scheduler.tick();
  await t.app.scheduler.idle();
}

describe("REST", () => {
  test("CRUD with defaults", async () => {
    const { bot } = await setup();
    const created = await t.api("POST", "/api/schedules", { botId: bot.id, title: " Séance du jour ", prompt: "Ma séance ?", schedule: cron("0 7 * * 1-5") });
    expect(created.status).toBe(200);
    expect(created.data).toMatchObject({
      botId: bot.id,
      title: "Séance du jour",
      prompt: "Ma séance ?",
      schedule: { kind: "cron", expr: "0 7 * * 1-5", timezone: "Europe/Paris" },
      enabled: true,
      conversation: "dedicated",
      notify: true,
      createdBy: "user",
      nextRunAt: "2026-10-19T05:00:00.000Z",
    });
    const id = created.data.id;
    const other = await makeBot("Fitness", "💪");
    await t.api("POST", "/api/schedules", { botId: other.id, title: "Pesée", prompt: "Pèse-moi", schedule: cron("0 8 * * *"), notify: false, conversation: "new" });

    expect((await t.api("GET", "/api/schedules")).data).toHaveLength(2);
    expect((await t.api("GET", `/api/schedules?botId=${bot.id}`)).data.map((x: any) => x.id)).toEqual([id]);

    const paused = await t.api("PATCH", `/api/schedules/${id}`, { enabled: false, title: "Séance" });
    expect(paused.data).toMatchObject({ enabled: false, title: "Séance" });
    expect(paused.data.nextRunAt).toBeUndefined();
    const moved = await t.api("PATCH", `/api/schedules/${id}`, { enabled: true, schedule: cron("30 6 * * *", "UTC") });
    expect(moved.data).toMatchObject({ enabled: true, nextRunAt: "2026-10-18T06:30:00.000Z" });

    expect((await t.api("DELETE", `/api/schedules/${id}`)).status).toBe(204);
    expect((await t.api("PATCH", `/api/schedules/${id}`, { title: "x" })).status).toBe(404);
    expect((await t.api("GET", `/api/schedules/${id}/runs`)).status).toBe(404);
    expect((await t.api("GET", "/api/schedules")).data).toHaveLength(1);
  });

  test("validation lists every problem", async () => {
    const { bot } = await setup();
    const bad = await t.api("POST", "/api/schedules", { botId: "nope", title: "", prompt: "x".repeat(4001), schedule: cron("61 * * * *") });
    expect(bad.status).toBe(400);
    for (const m of ['unknown bot "nope"', "title must be 1 to 60 characters", "prompt must be 1 to 4000 characters", "invalid cron"]) expect(bad.data.error).toContain(m);
    const post = (schedule: unknown, extra = {}) => t.api("POST", "/api/schedules", { botId: bot.id, title: "T", prompt: "P", schedule, ...extra });
    expect((await post(cron("0 7 * * *", "Mars/Olympus"))).data.error).toContain("unknown timezone");
    expect((await post(cron("0 0 31 2 *"))).data.error).toContain("never runs");
    expect((await post({ kind: "once", at: "2026-10-17T08:30:00Z" })).data.error).toContain("in the past");
    expect((await post({ kind: "once", at: "demain" })).data.error).toContain("ISO date");
    expect((await post({ kind: "weekly" })).data.error).toContain("schedule.kind");
    expect((await post(cron("0 7 * * *"), { notify: "yes", conversation: "shared" })).data.error).toMatch(/conversation must be.*notify must be a boolean/);
    expect((await post({ kind: "once", at: "2026-10-17T09:30:00Z" })).status).toBe(200); // < 1 h late is accepted
    expect((await post(cron("0 7 * * *"), { botId: "voyages" })).data.botId).toBe(bot.id); // by name
  });

  test("auth: the local token works on schedules and notify only", async () => {
    const { bot } = await setup();
    expect((await t.api("GET", "/api/schedules", undefined, "")).status).toBe(401);
    expect((await t.api("GET", "/api/schedules", undefined, "wrong")).status).toBe(401);
    const byBot = await t.api("POST", "/api/schedules", { botId: bot.id, title: "T", prompt: "P", schedule: cron("0 7 * * *") }, LOCAL);
    expect(byBot.data.createdBy).toBe("bot");
    expect((await t.api("GET", "/api/schedules", undefined, LOCAL)).data).toHaveLength(1);
    expect((await t.api("PATCH", `/api/schedules/${byBot.data.id}`, { notify: false }, LOCAL)).data.notify).toBe(false);
    expect((await t.api("GET", "/api/bots", undefined, LOCAL)).status).toBe(401);
    expect((await t.api("GET", "/api/conversations", undefined, LOCAL)).status).toBe(401);
    expect((await t.api("GET", "/api/schedulesx", undefined, LOCAL)).status).toBe(401);
    expect((await t.api("PUT", "/api/schedules", {}, LOCAL)).status).toBe(405);
    expect((await t.api("DELETE", `/api/schedules/${byBot.data.id}`, undefined, LOCAL)).status).toBe(204);
  });
});

describe("scheduler", () => {
  test("runs a cron task in its dedicated conversation and advances", async () => {
    const { bot } = await setup();
    const task = (await t.api("POST", "/api/schedules", { botId: bot.id, title: "Point voyages", prompt: "Mes prochains vols ?", schedule: cron("0 7 * * *") })).data;
    expect(task.nextRunAt).toBe("2026-10-18T05:00:00.000Z");
    await advance("2026-10-18T04:59:00Z");
    expect((await t.api("GET", `/api/schedules/${task.id}/runs`)).data).toEqual([]);

    await advance("2026-10-18T05:00:10Z");
    const [run] = (await t.api("GET", `/api/schedules/${task.id}/runs`)).data;
    expect(run).toMatchObject({ taskId: task.id, status: "ok", preview: "Hello world", startedAt: "2026-10-18T05:00:10.000Z" });
    const after = (await t.api("GET", `/api/schedules`)).data[0];
    expect(after).toMatchObject({ conversationId: run.conversationId, lastStatus: "ok", lastRunAt: run.startedAt, nextRunAt: "2026-10-19T05:00:00.000Z" });
    const conv = (await t.api("GET", `/api/conversations?botId=${bot.id}`)).data;
    expect(conv).toHaveLength(1);
    expect(conv[0].title).toBe("Point voyages");
    const msgs = (await t.api("GET", `/api/conversations/${run.conversationId}/messages`)).data;
    expect(msgs.map((m: any) => [m.role, m.text])).toEqual([
      ["user", "Mes prochains vols ?"],
      ["assistant", "Hello world"],
    ]);

    await advance("2026-10-19T05:00:00Z");
    const runs = (await t.api("GET", `/api/schedules/${task.id}/runs`)).data;
    expect(runs).toHaveLength(2);
    expect(runs[0].conversationId).toBe(run.conversationId);
    expect((await t.api("GET", `/api/conversations/${run.conversationId}/messages`)).data).toHaveLength(4);
    expect(t.runtime.starts).toHaveLength(1); // the live session is reused
  });

  test("marks the prompt of a run with its task and keeps it out of the bot preview", async () => {
    await setup();
    const bot = await makeBot("Homelab", "🏠");
    const prompt = "Relevé quotidien des températures de nuit (chauffage collectif). Lance `python3 -I ~/homelab/temperatures_nuits.py --report` et résume les pièces sous 19 °C.";
    const task = (await t.api("POST", "/api/schedules", { botId: bot.id, title: "Températures de nuit", prompt, schedule: cron("30 7 * * *") })).data;
    await advance("2026-10-18T05:30:05Z");

    const [run] = (await t.api("GET", `/api/schedules/${task.id}/runs`)).data;
    expect(t.runtime.prompts.at(-1)?.text).toStartWith(prompt);
    const msgs = (await t.api("GET", `/api/conversations/${run.conversationId}/messages`)).data;
    expect(msgs[0]).toMatchObject({ role: "user", text: prompt, task: { id: task.id, title: "Températures de nuit" } });
    expect(msgs[1].role).toBe("assistant");
    expect(msgs[1].task).toBeUndefined();
    const listed = () => t.api("GET", "/api/bots").then((r) => r.data.find((b: any) => b.id === bot.id));
    expect((await listed()).lastMessagePreview).toBe("Hello world");

    // While a run is still answering, its prompt is the last message: the list keeps the previous answer.
    t.app.store.addMessage({ id: "msg-temperatures-2", conversationId: run.conversationId, role: "user", text: prompt, task: { id: task.id, title: task.title }, createdAt: "2026-10-19T05:30:05.000Z" });
    expect((await listed()).lastMessagePreview).toBe("Hello world");

    const typed = t.app.store.createConversation(bot.id, false, "Chambre d'Inès");
    await (await t.app.runner.prompt({ conversationId: typed.id, text: "Et la chambre d'Inès cette nuit ?" })).done;
    expect((await t.api("GET", `/api/conversations/${typed.id}/messages`)).data[0].task).toBeUndefined();
  });

  test("conversation \"new\" creates one conversation per run", async () => {
    const { bot } = await setup();
    const task = (await t.api("POST", "/api/schedules", { botId: bot.id, title: "Veille", prompt: "Quoi de neuf ?", schedule: cron("0 * * * *"), conversation: "new" })).data;
    await advance("2026-10-17T11:00:00Z");
    await advance("2026-10-17T12:00:00Z");
    const runs = (await t.api("GET", `/api/schedules/${task.id}/runs`)).data;
    expect(runs).toHaveLength(2);
    expect(runs[0].conversationId).not.toBe(runs[1].conversationId);
    expect((await t.api("GET", `/api/schedules`)).data[0].conversationId).toBeUndefined();
    expect((await t.api("GET", `/api/conversations?botId=${bot.id}`)).data.map((c: any) => c.title)).toEqual(["Veille", "Veille"]);
  });

  test("a deleted dedicated conversation is recreated", async () => {
    const { bot } = await setup();
    const task = (await t.api("POST", "/api/schedules", { botId: bot.id, title: "Veille", prompt: "Quoi de neuf ?", schedule: cron("0 * * * *") })).data;
    await advance("2026-10-17T11:00:00Z");
    const first = (await t.api("GET", `/api/schedules`)).data[0].conversationId;
    await t.api("DELETE", `/api/conversations/${first}`);
    await advance("2026-10-17T12:00:00Z");
    const second = (await t.api("GET", `/api/schedules`)).data[0].conversationId;
    expect(second).toBeString();
    expect(second).not.toBe(first);
  });

  test("once tasks run once and are disabled", async () => {
    const { bot } = await setup();
    const task = (await t.api("POST", "/api/schedules", { botId: bot.id, title: "Rappel", prompt: "Rappelle-moi le passeport", schedule: { kind: "once", at: "2026-10-17T10:30:00Z" } })).data;
    expect(task.nextRunAt).toBe("2026-10-17T10:30:00.000Z");
    await advance("2026-10-17T10:31:00Z");
    await advance("2026-10-17T11:31:00Z");
    expect((await t.api("GET", `/api/schedules/${task.id}/runs`)).data).toHaveLength(1);
    const after = (await t.api("GET", "/api/schedules")).data[0];
    expect(after.enabled).toBe(false);
    expect(after.nextRunAt).toBeUndefined();
    expect((await t.api("PATCH", `/api/schedules/${task.id}`, { enabled: true })).data.error).toContain("in the past");
  });

  test("restart skips missed cron runs but replays a once task less than 1 h late", async () => {
    const { bot } = await setup();
    const store = t.app.store;
    const base = { botId: bot.id, prompt: "P", enabled: true, conversation: "dedicated" as const, notify: false, createdBy: "user" as const };
    const daily = store.createTask({ ...base, title: "Quotidien", schedule: { kind: "cron", expr: "0 7 * * *", timezone: "Europe/Paris" }, nextRunAt: "2026-10-17T05:00:00.000Z" });
    const late = store.createTask({ ...base, title: "En retard", schedule: { kind: "once", at: "2026-10-17T09:20:00.000Z" }, nextRunAt: "2026-10-17T09:20:00.000Z" });
    const stale = store.createTask({ ...base, title: "Trop tard", schedule: { kind: "once", at: "2026-10-17T08:00:00.000Z" }, nextRunAt: "2026-10-17T08:00:00.000Z" });
    await t.app.scheduler.stop();
    t.app.scheduler.start();
    await t.app.scheduler.idle();
    expect(store.taskRuns(daily.id)).toHaveLength(0);
    expect(store.task(daily.id)!.nextRunAt).toBe("2026-10-18T05:00:00.000Z");
    expect(store.taskRuns(late.id)).toHaveLength(1);
    expect(store.taskRuns(stale.id)).toHaveLength(0);
    expect(store.task(stale.id)!.enabled).toBe(false);
  });

  test("pushes the answer even with a socket connected, once, with the task id", async () => {
    const { bot } = await setup();
    await t.api("POST", "/api/devices", { apnsToken: "ab".repeat(32), environment: "development" });
    sock = await Socket.open(t);
    const task = (await t.api("POST", "/api/schedules", { botId: bot.id, title: "Point du matin", prompt: "Hello", schedule: cron("0 * * * *") })).data;
    await advance("2026-10-17T11:00:00Z");
    expect(await sock.next("message.end")).toMatchObject({ stopReason: "end_turn", scheduled: true });
    expect(t.pusher.sent).toHaveLength(1);
    const run = (await t.api("GET", `/api/schedules/${task.id}/runs`)).data[0];
    expect(t.pusher.sent[0]!.payload).toEqual({
      title: "✈️ Point du matin",
      body: "Hello world",
      botId: bot.id,
      conversationId: run.conversationId,
      taskId: task.id,
      destination: { kind: "conversation", id: run.conversationId, botId: bot.id },
    });

    await t.api("PATCH", `/api/schedules/${task.id}`, { notify: false });
    sock.close();
    sock = undefined;
    await advance("2026-10-17T12:00:00Z");
    expect(t.pusher.sent).toHaveLength(1); // no task push, and no "away" push either
  });

  test("errors are recorded and pushed", async () => {
    const { bot } = await setup();
    await t.api("POST", "/api/devices", { apnsToken: "ab".repeat(32), environment: "development" });
    const task = (await t.api("POST", "/api/schedules", { botId: bot.id, title: "Cassé", prompt: "boom", schedule: cron("0 * * * *") })).data;
    await advance("2026-10-17T11:00:00Z");
    const run = (await t.api("GET", `/api/schedules/${task.id}/runs`)).data[0];
    expect(run).toMatchObject({ status: "error", error: "agent crashed" });
    expect((await t.api("GET", "/api/schedules")).data[0].lastStatus).toBe("error");
    expect(t.pusher.sent.map((s) => s.payload.body)).toEqual(["Error: agent crashed"]);
  });

  test("the push is in the language the user's device last sent, English otherwise", async () => {
    const { bot } = await setup();
    await t.api("POST", "/api/devices", { apnsToken: "ab".repeat(32), environment: "development" });
    const task = (await t.api("POST", "/api/schedules", { botId: bot.id, title: "Relevé des compteurs", prompt: "boom", schedule: cron("0 * * * *") })).data;
    await advance("2026-10-17T11:00:00Z");
    await fetch(`${t.base}/api/schedules`, { headers: { authorization: `Bearer ${t.token}`, "accept-language": "fr-FR,fr;q=0.9,en;q=0.8" } });
    await advance("2026-10-17T12:00:00Z");
    expect(t.pusher.sent.map((s) => s.payload.body)).toEqual(["Error: agent crashed", "Erreur : agent crashed"]);
    expect((await t.api("GET", `/api/schedules/${task.id}/runs`)).data).toHaveLength(2);
  });

  test("a task without notification runs out of the conversation list; one that notifies stays in it", async () => {
    const { bot } = await setup();
    const watch = (await t.api("POST", "/api/schedules", { botId: bot.id, title: "Illusions Tour : places gratuites", prompt: "Toujours épuisé ?", schedule: cron("0 * * * *"), notify: false })).data;
    const brief = (await t.api("POST", "/api/schedules", { botId: bot.id, title: "Brief du matin", prompt: "Mon agenda ?", schedule: cron("0 * * * *") })).data;
    await advance("2026-10-17T11:00:00Z");
    const [watchRun] = (await t.api("GET", `/api/schedules/${watch.id}/runs`)).data;
    const [briefRun] = (await t.api("GET", `/api/schedules/${brief.id}/runs`)).data;
    const listed = (await t.api("GET", `/api/conversations?botId=${bot.id}`)).data.map((c: any) => c.id);
    expect(listed).toContain(briefRun.conversationId);
    expect(listed).not.toContain(watchRun.conversationId);
    expect((await t.api("GET", `/api/conversations/${watchRun.conversationId}/messages`)).status).toBe(200);
  });

  test("a silent task's conversation that alerted the user is listed, with the alert as a message", async () => {
    const { bot } = await setup();
    await t.api("POST", "/api/devices", { apnsToken: "ab".repeat(32), environment: "development" });
    const watch = (await t.api("POST", "/api/schedules", { botId: bot.id, title: "Illusions Tour : places gratuites", prompt: "Toujours épuisé ?", schedule: cron("0 * * * *"), notify: false })).data;
    await advance("2026-10-17T11:00:00Z");
    const [run] = (await t.api("GET", `/api/schedules/${watch.id}/runs`)).data;
    const alert = { title: "🎪 Illusions Tour", body: "Séance du 9 novembre à 17h disponible.", botId: bot.id, conversationId: run.conversationId };
    expect((await t.api("POST", "/api/notify", alert, LOCAL)).status).toBe(204);

    expect(t.pusher.sent.map((s) => s.payload.destination)).toEqual([{ kind: "conversation", id: run.conversationId, botId: bot.id }]);
    const listed = (await t.api("GET", `/api/conversations?botId=${bot.id}`)).data.map((c: any) => c.id);
    expect(listed).toContain(run.conversationId);
    const messages = (await t.api("GET", `/api/conversations/${run.conversationId}/messages`)).data;
    expect(messages.at(-1)).toMatchObject({ role: "assistant", text: "🔔 **🎪 Illusions Tour**\n\nSéance du 9 novembre à 17h disponible." });
  });

  test("run now returns the running run and refuses a concurrent one", async () => {
    const { bot } = await setup();
    const task = (await t.api("POST", "/api/schedules", { botId: bot.id, title: "Lent", prompt: "slow", schedule: cron("0 7 * * *") })).data;
    const r = await t.api("POST", `/api/schedules/${task.id}/run`);
    expect(r.data).toMatchObject({ taskId: task.id, status: "running" });
    expect((await t.api("GET", "/api/schedules")).data[0]).toMatchObject({ lastStatus: "running", nextRunAt: "2026-10-18T05:00:00.000Z" });
    expect((await t.api("POST", `/api/schedules/${task.id}/run`)).status).toBe(409);
    await Bun.sleep(30);
    await t.app.runner.cancel(r.data.conversationId);
    await t.app.scheduler.idle();
    expect((await t.api("GET", `/api/schedules/${task.id}/runs`)).data[0]).toMatchObject({ status: "error", error: "cancelled" });
  });

  test("a run cut by a restart of the gateway pushes no error: its turn resumes once the gateway is back", async () => {
    const { bot } = await setup();
    const task = (await t.api("POST", "/api/schedules", { botId: bot.id, title: "Recherche d'emploi du jour", prompt: "slow: offres LCB-FT publiées depuis hier", schedule: cron("0 9 * * *") })).data;
    const run = (await t.api("POST", `/api/schedules/${task.id}/run`)).data;
    await Bun.sleep(30);
    await t.app.scheduler.stop();
    await t.app.runner.shutdown();
    await t.app.scheduler.idle();
    expect(t.pusher.sent).toHaveLength(0);
    expect((await t.api("GET", `/api/schedules/${task.id}/runs`)).data[0]).toMatchObject({ status: "error", error: "cut by the gateway restart, resumed once it is back" });
    expect(JSON.parse(t.app.store.getMeta("runner.interrupted")!)).toEqual([run.conversationId]);
  });

  test("at most 2 scheduled runs at a time", async () => {
    const { bot } = await setup({ maxSessions: 5 });
    for (const title of ["A", "B", "C"]) await t.api("POST", "/api/schedules", { botId: bot.id, title, prompt: "slow", schedule: cron("0 * * * *") });
    clock = Date.parse("2026-10-17T11:00:00Z");
    t.app.scheduler.tick();
    await Bun.sleep(30);
    const statuses = () => t.app.store.tasks().map((x) => x.lastStatus);
    expect(statuses().filter((s) => s === "running")).toHaveLength(2);
    for (const c of t.app.store.conversations()) await t.app.runner.cancel(c.id);
    await Bun.sleep(30);
    t.app.scheduler.tick();
    await Bun.sleep(30);
    expect(statuses().filter((s) => s === "running")).toHaveLength(1);
    for (const c of t.app.store.conversations()) await t.app.runner.cancel(c.id);
  });
});

describe("command tasks", () => {
  const command = (cmd: string, over: Record<string, unknown> = {}) => ({ type: "command", command: cmd, ...over });
  const create = (title: string, action: Record<string, unknown>, extra: Record<string, unknown> = {}, token?: string) =>
    t.api("POST", "/api/schedules", { botId: botId, title, schedule: cron("0 * * * *"), action, ...extra }, token);
  let botId = "";
  const runs = async (id: string) => (await t.api("GET", `/api/schedules/${id}/runs`)).data;

  async function setupCommands(opts: Parameters<typeof startTestApp>[0] = {}) {
    const { bot } = await setup({ scheduler: { now: () => clock, commandHome: undefined }, ...opts });
    botId = bot.id;
    await t.api("POST", "/api/devices", { apnsToken: "ab".repeat(32), environment: "development" });
    return bot;
  }

  test("defaults, no prompt, and older clients keep working", async () => {
    await setupCommands();
    const r = await create("HYROX: places", command("echo hi"));
    expect(r.status).toBe(200);
    expect(r.data).toMatchObject({ prompt: "", notify: true, action: { type: "command", command: "echo hi", timeoutSec: 600, notifyOn: "failure" } });
    const off = await t.api("PATCH", `/api/schedules/${r.data.id}`, { notify: false });
    expect(off.data).toMatchObject({ notify: false, action: { notifyOn: "never" } });
    const prompt = await t.api("POST", "/api/schedules", { botId, title: "P", prompt: "Hello", schedule: cron("0 7 * * *") });
    expect(prompt.data.action).toEqual({ type: "prompt" });
    const bad = await create("X", command("", { cwd: "relative", timeoutSec: 0, notifyOn: "sometimes", env: { "1A": "x" } }));
    expect(bad.status).toBe(400);
    for (const m of ["action.command", "action.cwd", "action.timeoutSec", "action.notifyOn", "action.env"]) expect(bad.data.error).toContain(m);
    const toPrompt = await t.api("PATCH", `/api/schedules/${r.data.id}`, { action: { type: "prompt" } });
    expect(toPrompt.data.error).toContain("prompt must be");
  });

  test("bots (local token) cannot create command tasks or change what they run, and only see env names", async () => {
    await setupCommands();
    expect((await create("C", command("true"), {}, LOCAL)).status).toBe(403);
    const task = (await create("C", command("true", { env: { TOKEN: "s3cret" } }))).data;
    const listed = (await t.api("GET", "/api/schedules", undefined, LOCAL)).data[0];
    expect(listed.action.env).toEqual({ TOKEN: "•••" });
    const timing = await t.api("PATCH", `/api/schedules/${task.id}`, { title: "D", schedule: cron("*/20 * * * *"), enabled: false }, LOCAL);
    expect(timing.status).toBe(200);
    expect(timing.data).toMatchObject({ title: "D", enabled: false, schedule: { expr: "*/20 * * * *" }, action: { command: "true" } });
    expect((await t.api("PATCH", `/api/schedules/${task.id}`, { prompt: "x" }, LOCAL)).status).toBe(403);
    expect((await t.api("PATCH", `/api/schedules/${task.id}`, { action: command("id") }, LOCAL)).status).toBe(403);
    expect((await t.api("DELETE", `/api/schedules/${task.id}`, undefined, LOCAL)).status).toBe(403);
    expect((await t.api("POST", `/api/schedules/${task.id}/run`, undefined, LOCAL)).status).toBe(403);
    const prompt = (await t.api("POST", "/api/schedules", { botId, title: "P", prompt: "Hello", schedule: cron("0 7 * * *") }, LOCAL)).data;
    expect((await t.api("PATCH", `/api/schedules/${prompt.id}`, { action: command("id") }, LOCAL)).status).toBe(403);
    expect((await t.api("GET", "/api/schedules")).data[0].action.env).toEqual({ TOKEN: "s3cret" });
  });

  test("runs with cwd, env file and env, in a clean environment, without a conversation", async () => {
    await setupCommands();
    process.env.NUO_TEST_SECRET = "leak";
    writeFileSync(join(t.home, "job.env"), '# comment\nexport FOO="from file"\nBAR=overridden\n');
    const task = (
      await create("Env", command('printf "\\033[31m%s|%s|%s|%s\\n" "$FOO" "$BAR" "$(pwd)" "${NUO_TEST_SECRET:-none}"', { cwd: t.home, envFile: join(t.home, "job.env"), env: { BAR: "inline" }, notifyOn: "always" }))
    ).data;
    await advance("2026-10-17T11:00:00Z");
    delete process.env.NUO_TEST_SECRET;
    const [run] = await runs(task.id);
    expect(run).toMatchObject({ status: "ok", exitCode: 0, conversationId: "", output: `from file|inline|${realpathSync(t.home)}|none` });
    expect(run.durationMs).toBeGreaterThanOrEqual(0);
    expect(t.app.store.conversations()).toHaveLength(0);
    expect(t.pusher.sent.map((s) => s.payload)).toEqual([{ title: "Env", body: run.output, botId, taskId: task.id, runId: run.id, destination: { kind: "task", id: task.id, botId, runId: run.id } }]);
    expect((await t.api("GET", "/api/schedules")).data[0]).toMatchObject({ lastStatus: "ok", nextRunAt: "2026-10-17T12:00:00.000Z" });
  });

  test("a failure is pushed once per outage, then its recovery", async () => {
    await setupCommands();
    const flag = join(t.home, "ok");
    const task = (await create("Cloud budget guard", command(`test -f ${flag} && echo fine || { echo "quota exceeded" >&2; exit 3; }`))).data;
    await advance("2026-10-17T11:00:00Z");
    expect((await runs(task.id))[0]).toMatchObject({ status: "error", exitCode: 3, error: "exit code 3", output: "quota exceeded" });
    await advance("2026-10-17T12:00:00Z");
    expect((await runs(task.id))[0].status).toBe("error");
    writeFileSync(flag, "");
    await advance("2026-10-17T13:00:00Z");
    await advance("2026-10-17T14:00:00Z");
    expect(t.pusher.sent.map((s) => [s.payload.title, s.payload.body])).toEqual([
      ["⚠️ Cloud budget guard", "exit code 3\nquota exceeded"],
      ["✅ Cloud budget guard recovered", "fine"],
    ]);
    expect((await runs(task.id)).map((r: any) => r.status)).toEqual(["ok", "ok", "error", "error"]);
  });

  test("a failure points to its run and stays in the alert history", async () => {
    await setupCommands();
    sock = await Socket.open(t);
    const task = (await create("Sauvegarde NAS", command(`echo "rsync: connection refused (111)" >&2; exit 12`))).data;
    await advance("2026-10-17T11:00:00Z");
    const [run] = await runs(task.id);
    expect(run).toMatchObject({ status: "error", exitCode: 12 });
    const destination = { kind: "task", id: task.id, botId, runId: run.id };
    expect(t.pusher.sent.map((s) => s.payload)).toEqual([
      { title: "⚠️ Sauvegarde NAS", body: "exit code 12\nrsync: connection refused (111)", botId, taskId: task.id, runId: run.id, destination },
    ]);
    const alerts = (await t.api("GET", "/api/alerts")).data;
    expect(alerts).toEqual([{ id: expect.any(String), title: "⚠️ Sauvegarde NAS", body: "exit code 12\nrsync: connection refused (111)", botId, destination, createdAt: expect.any(String) }]);
    expect((await sock.next("alert")).alert).toEqual(alerts[0]);
  });

  test("a timeout kills the whole process group", async () => {
    await setupCommands();
    const pidFile = join(t.home, "child.pid");
    const task = (await create("Lent", command(`sleep 30 & echo $! > ${pidFile}; wait`, { timeoutSec: 1, notifyOn: "never" }))).data;
    await advance("2026-10-17T11:00:00Z");
    const [run] = await runs(task.id);
    expect(run).toMatchObject({ status: "error", error: "timed out (1 s): command stopped" });
    const child = Number(readFileSync(pidFile, "utf8"));
    await Bun.sleep(100);
    expect(() => process.kill(child, 0)).toThrow();
    expect(t.pusher.sent).toHaveLength(0);
  }, 10_000);

  test("command runs do not wait for agent sessions", async () => {
    await setupCommands({ maxSessions: 1 });
    const busy = (await t.api("POST", "/api/schedules", { botId, title: "Lent", prompt: "slow", schedule: cron("0 7 * * *") })).data;
    await t.api("POST", `/api/schedules/${busy.id}/run`);
    await Bun.sleep(30);
    expect(t.app.runner.busyCount).toBe(1);
    const task = (await create("Cmd", command("echo done"))).data;
    clock = Date.parse("2026-10-17T11:00:00Z");
    t.app.scheduler.tick();
    for (let i = 0; i < 50 && !(await runs(task.id))[0]?.endedAt; i++) await Bun.sleep(20);
    expect((await runs(task.id))[0]).toMatchObject({ status: "ok", output: "done" });
    for (const c of t.app.store.conversations()) await t.app.runner.cancel(c.id);
  });
});

describe("nuo MCP server", () => {
  test("is injected into every session, not listed as a tool server", async () => {
    const { bot } = await setup();
    const conv = (await t.api("POST", "/api/conversations", { botId: bot.id })).data;
    sock = await Socket.open(t);
    sock.send({ type: "prompt", conversationId: conv.id, text: "hi" });
    await sock.next("message.end");
    const spec = t.runtime.starts[0]!.mcpServers.find((s) => s.name === "nuo")!;
    expect(spec.args).toEqual(["run", NUO_MCP_SERVER]);
    const envFile = join(t.profileHome, "agent-env", "nuo.env");
    expect(spec.env).toMatchObject({ NUO_ENV_FILE: envFile, NUO_BOT_ID: bot.id, NUO_CONVERSATION_ID: conv.id });
    // Claude's adapter puts every MCP spec on the `claude` command line, which any local user reads with ps.
    expect(JSON.stringify(t.runtime.starts[0]!.mcpServers)).not.toContain(LOCAL);
    expect(spec.env.NUO_LOCAL_TOKEN).toBeUndefined();
    expect(readFileSync(envFile, "utf8")).toBe(`NUO_URL=${t.base}\nNUO_LOCAL_TOKEN=${LOCAL}\n`);
    expect((statSync(envFile).mode & 0o777).toString(8)).toBe("600");
    expect((statSync(join(t.profileHome, "agent-env")).mode & 0o777).toString(8)).toBe("700");
    expect((await t.api("GET", "/api/tools")).data.map((x: any) => x.id)).not.toContain("nuo");
  });

  test("tools create, list, update and delete tasks", async () => {
    const { bot } = await setup({ scheduler: { now: () => Date.now() } });
    const fitness = await makeBot("Fitness", "💪");
    const conv = (await t.api("POST", "/api/conversations", { botId: bot.id })).data;
    const client = new Client({ name: "test", version: "1" });
    await client.connect(
      new StdioClientTransport({
        command: process.execPath,
        args: ["run", NUO_MCP_SERVER],
        env: { NUO_ENV_FILE: join(t.profileHome, "agent-env", "nuo.env"), NUO_BOT_ID: bot.id, NUO_CONVERSATION_ID: conv.id },
        stderr: "ignore",
      }),
    );
    try {
      const call = async (name: string, args: Record<string, unknown>) => {
        const r = (await client.callTool({ name, arguments: args })) as { content: { text: string }[]; isError?: boolean };
        return { text: r.content.map((c) => c.text).join("\n"), isError: !!r.isError };
      };
      const { tools } = await client.listTools();
      expect(tools.map((x) => x.name)).toEqual(["schedule_create", "notify_user", "schedule_list", "schedule_update", "schedule_delete", "memory_read", "memory_add", "memory_write", ...GOOGLE_TOOLS.map((x) => x.name), ...DEVICE_TOOLS.map((x) => x.name), ...SCAN_TOOLS.map((x) => x.name)]);
      const google = await call("gmail_search", { query: "is:unread" });
      expect(google).toEqual({ text: expect.stringContaining("Settings › Google Accounts"), isError: true });
      expect(tools[0]!.description).toContain("Now:");
      expect(tools[0]!.description).toContain("Europe/Paris");

      const daily = await call("schedule_create", { title: "Météo", prompt: "La météo du jour à Paris", cron: "0 7 * * *" });
      expect(daily.isError).toBe(false);
      expect(daily.text).toContain("Task scheduled");
      const reminder = await call("schedule_create", { title: "Rappel", prompt: "Rappelle le passeport", in_minutes: 90, conversation: "current", notify: false });
      expect(reminder.isError).toBe(false);
      const local = await call("schedule_create", { title: "Pesée", prompt: "Pèse-moi", at: "2099-01-02T08:00", bot: "fitness" });
      expect(local.isError).toBe(false);

      const all = t.app.store.tasks();
      expect(all.map((x) => [x.title, x.botId, x.createdBy])).toEqual([
        ["Météo", bot.id, "bot"],
        ["Rappel", bot.id, "bot"],
        ["Pesée", fitness.id, "bot"],
      ]);
      expect(all[0]!.schedule).toEqual({ kind: "cron", expr: "0 7 * * *", timezone: "Europe/Paris" });
      expect(all[1]).toMatchObject({ conversation: "dedicated", conversationId: conv.id, notify: false, schedule: { kind: "once" } });
      expect(all[2]!.schedule).toEqual({ kind: "once", at: "2099-01-02T07:00:00.000Z" }); // 08:00 in Paris (winter)

      const mine = await call("schedule_list", {});
      expect(mine.text).toContain("2 scheduled task(s)");
      expect(mine.text).toContain(all[0]!.id);
      expect((await call("schedule_list", { all_bots: true })).text).toContain("3 scheduled task(s)");

      const upd = await call("schedule_update", { id: all[0]!.id, cron: "30 6 * * 1-5", enabled: false });
      expect(upd.text).toContain("next run: disabled");
      expect(t.app.store.task(all[0]!.id)).toMatchObject({ enabled: false, schedule: { expr: "30 6 * * 1-5", timezone: "Europe/Paris" } });

      const bad = await call("schedule_create", { title: "X", prompt: "Y", cron: "nope" });
      expect(bad.isError).toBe(true);
      expect(bad.text).toContain("invalid cron");
      expect((await call("schedule_create", { title: "X", prompt: "Y" })).isError).toBe(true);
      expect((await call("schedule_delete", { id: "missing" })).isError).toBe(true);

      expect((await call("schedule_delete", { id: all[0]!.id })).text).toContain("deleted");
      expect(t.app.store.tasks()).toHaveLength(2);
    } finally {
      await client.close();
    }
  }, 20_000);
});
