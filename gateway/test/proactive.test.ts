import { afterEach, describe, expect, test } from "bun:test";
import { isNothingToPropose, PROACTIVE_PROMPT } from "../src/scheduler/proactive";
import { botConfig, startTestApp, type TestApp } from "./helpers";

let t: TestApp;
let clock = Date.parse("2026-10-17T10:00:00Z"); // Saturday, 12:00 in Paris

afterEach(async () => {
  await t?.app.scheduler.idle();
  await t?.close();
});

async function setup() {
  clock = Date.parse("2026-10-17T10:00:00Z");
  t = await startTestApp({ scheduler: { now: () => clock } });
}

async function publish(botId: string, over: Record<string, unknown>) {
  expect((await t.api("PUT", `/api/bots/${botId}/draft`, botConfig({ name: "Maison", emoji: "🏡", ...over }))).status).toBe(200);
  expect((await t.api("POST", `/api/bots/${botId}/publish`, {})).status).toBe(200);
}

async function makeBot(proactive: boolean) {
  const bot = (await t.api("POST", "/api/bots", { name: "Maison" })).data;
  await publish(bot.id, { proactive });
  return bot;
}

const proposals = async (botId: string) => (await t.api("GET", `/api/schedules?botId=${botId}`)).data.filter((x: any) => x.createdBy === "gateway");

async function advance(to: string) {
  clock = Date.parse(to);
  t.app.scheduler.tick();
  await t.app.scheduler.idle();
}

describe("proactive bots", () => {
  test("publishing turns it on: one daily 9:00 Paris task, never duplicated", async () => {
    await setup();
    const bot = await makeBot(true);
    expect((await t.api("GET", `/api/bots/${bot.id}`)).data.published.config.proactive).toBe(true);
    const [task, ...more] = await proposals(bot.id);
    expect(more).toEqual([]);
    expect(task).toMatchObject({
      title: "Today's proposals",
      prompt: PROACTIVE_PROMPT,
      schedule: { kind: "cron", expr: "0 9 * * *", timezone: "Europe/Paris" },
      conversation: "dedicated",
      notify: true,
      enabled: true,
      createdBy: "gateway",
      nextRunAt: "2026-10-18T07:00:00.000Z",
    });

    // The user moved it to 8:00: later publishes and a restart keep that task as it is.
    await t.api("PATCH", `/api/schedules/${task.id}`, { schedule: { kind: "cron", expr: "0 8 * * 1-5" } });
    await publish(bot.id, { proactive: true, instructions: "Tu gères la maison : travaux, factures, rendez-vous." });
    await t.api("PUT", `/api/bots/${bot.id}/permissions`, { permissionPolicy: "readonly" });
    await t.app.scheduler.stop();
    t.app.scheduler.start();
    const after = await proposals(bot.id);
    expect(after.map((x: any) => [x.id, x.schedule.expr])).toEqual([[task.id, "0 8 * * 1-5"]]);
  });

  test("a draft does not create it, and a bot without the setting gets none", async () => {
    await setup();
    const quiet = await makeBot(false);
    const drafted = (await t.api("POST", "/api/bots", { name: "Jardin" })).data;
    await t.api("PUT", `/api/bots/${drafted.id}/draft`, botConfig({ name: "Jardin", proactive: true }));
    expect(await proposals(quiet.id)).toEqual([]);
    expect(await proposals(drafted.id)).toEqual([]);
    expect((await t.api("GET", `/api/bots/${quiet.id}`)).data.published.config.proactive).toBeUndefined();
  });

  test("turning it off removes the task, a rollback brings it back, deleting the bot removes it", async () => {
    await setup();
    const bot = await makeBot(true);
    const other = await makeBot(true);
    expect(await proposals(bot.id)).toHaveLength(1);

    await publish(bot.id, { proactive: false });
    expect(await proposals(bot.id)).toEqual([]);
    await t.api("POST", `/api/bots/${bot.id}/rollback`, { version: 1 });
    expect(await proposals(bot.id)).toHaveLength(1);

    expect((await t.api("DELETE", `/api/bots/${bot.id}`)).status).toBe(204);
    expect((await t.api("GET", "/api/schedules")).data.map((x: any) => x.botId)).toEqual([other.id]);
  });

  test("a publish that bypassed the bot service is caught up at start", async () => {
    await setup();
    const bot = await makeBot(false);
    t.app.store.publish(bot.id, { ...(botConfig({ name: "Maison" }) as any), proactive: true }, "Import", true);
    expect(await proposals(bot.id)).toEqual([]);
    await t.app.scheduler.stop();
    t.app.scheduler.start();
    expect(await proposals(bot.id)).toHaveLength(1);
  });

  test("the marker of a proposals task created with the French prompt still counts", () => {
    expect(isNothingToPropose(" NOTHING\n")).toBe(true);
    expect(isNothingToPropose("RIEN")).toBe(true);
    expect(isNothingToPropose("Rien de neuf côté factures, mais le contrat d'assurance arrive à échéance.")).toBe(false);
  });

  test("proactive must be a boolean", async () => {
    await setup();
    const bot = (await t.api("POST", "/api/bots", { name: "Maison" })).data;
    const bad = await t.api("PUT", `/api/bots/${bot.id}/draft`, botConfig({ name: "Maison", proactive: "oui" }));
    expect(bad.status).toBe(400);
    expect(bad.data.error).toContain("proactive must be a boolean");
  });

  test("NOTHING: no push, and neither the prompt nor the answer stays in the conversation", async () => {
    await setup();
    await t.api("POST", "/api/devices", { apnsToken: "ab".repeat(32), environment: "development" });
    const bot = await makeBot(true);
    const [task] = await proposals(bot.id);
    await t.api("PATCH", `/api/schedules/${task.id}`, { prompt: "repeat:   NOTHING  " });

    await advance("2026-10-18T07:00:05Z");
    const [run] = (await t.api("GET", `/api/schedules/${task.id}/runs`)).data;
    expect(run).toMatchObject({ status: "ok", preview: "Nothing to propose today" });
    expect(t.pusher.sent).toEqual([]);
    expect((await t.api("GET", `/api/conversations/${run.conversationId}/messages`)).data).toEqual([]);
    expect((await t.api("GET", `/api/conversations?botId=${bot.id}`)).data).toEqual([]);

    // The next morning has something: the same conversation shows only that turn, and it is pushed.
    await t.api("PATCH", `/api/schedules/${task.id}`, { prompt: "repeat: Le contrat d'assurance habitation arrive à échéance le 30/11." });
    await advance("2026-10-19T07:00:05Z");
    const msgs = (await t.api("GET", `/api/conversations/${run.conversationId}/messages`)).data;
    expect(msgs.map((m: any) => m.role)).toEqual(["user", "assistant"]);
    expect((await t.api("GET", `/api/conversations?botId=${bot.id}`)).data.map((c: any) => c.id)).toEqual([run.conversationId]);
    expect(t.pusher.sent).toHaveLength(1);
  });

  test("a useful answer is pushed with its prose and kept with its cards", async () => {
    await setup();
    await t.api("POST", "/api/devices", { apnsToken: "ab".repeat(32), environment: "development" });
    const bot = await makeBot(true);
    const [task] = await proposals(bot.id);
    const answer =
      'Je peux relancer le plombier pour le devis de la salle de bain.\n::question {"question":"Je relance le plombier ?","options":["Oui, fais-le","Plus tard","Non merci"]}';
    await t.api("PATCH", `/api/schedules/${task.id}`, { prompt: `repeat: ${answer}` });

    await advance("2026-10-18T07:00:05Z");
    const [run] = (await t.api("GET", `/api/schedules/${task.id}/runs`)).data;
    expect(t.pusher.sent.map((s) => s.payload)).toEqual([
      {
        title: "🏡 Today's proposals",
        body: "Je peux relancer le plombier pour le devis de la salle de bain.",
        botId: bot.id,
        conversationId: run.conversationId,
        taskId: task.id,
        destination: { kind: "conversation", id: run.conversationId, botId: bot.id },
      },
    ]);
    const msgs = (await t.api("GET", `/api/conversations/${run.conversationId}/messages`)).data;
    expect(msgs.at(-1)).toMatchObject({ role: "assistant", text: answer });
  });

  test("a message the user sent during the run, and its answer, stay when RIEN is removed", async () => {
    await setup();
    const store = t.app.store;
    const bot = await makeBot(true);
    const conv = store.createConversation(bot.id, false, "Propositions du jour");
    const at = "2026-10-18T07:00:00.000Z";
    store.addMessage({ id: "msg-proposals", conversationId: conv.id, role: "user", text: "Regarde ce que tu peux prendre en charge", task: { id: "task-proposals", title: "Propositions du jour" }, createdAt: at });
    store.addMessage({ id: "msg-typed", conversationId: conv.id, role: "user", text: "Rappelle-moi la révision de la Clio", createdAt: at });
    store.addMessage({ id: "msg-rien", conversationId: conv.id, role: "assistant", text: "RIEN", createdAt: at });
    store.addMessage({ id: "msg-clio", conversationId: conv.id, role: "assistant", text: "Rappel créé pour le 12 novembre.", createdAt: at });
    store.deleteMessages(conv.id, ["msg-proposals", "msg-rien"]);
    expect(store.messages(conv.id).map((m) => m.id)).toEqual(["msg-typed", "msg-clio"]);
  });

  test("a task the user made keeps a RIEN answer and its push", async () => {
    await setup();
    await t.api("POST", "/api/devices", { apnsToken: "ab".repeat(32), environment: "development" });
    const bot = await makeBot(false);
    const task = (
      await t.api("POST", "/api/schedules", { botId: bot.id, title: "Factures en retard", prompt: "repeat: RIEN", schedule: { kind: "cron", expr: "0 9 * * *" } })
    ).data;
    await advance("2026-10-18T07:00:05Z");
    const [run] = (await t.api("GET", `/api/schedules/${task.id}/runs`)).data;
    expect(run.preview).toBe("RIEN");
    expect(t.pusher.sent.map((s) => s.payload.body)).toEqual(["RIEN"]);
    expect((await t.api("GET", `/api/conversations/${run.conversationId}/messages`)).data).toHaveLength(2);
  });
});
