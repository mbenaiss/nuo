import { describe, expect, test } from "bun:test";
import { apnsBody } from "../src/push/apns";

describe("apnsBody", () => {
  test("a bot answer opens its conversation and keeps the ids inline replies need", () => {
    const body = apnsBody({
      title: "✈️ Voyages",
      body: "Ton itinéraire Lisbonne est prêt",
      botId: "voyages",
      conversationId: "c-voyages-lisbonne",
      messageId: "m-8f2c",
      destination: { kind: "conversation", id: "c-voyages-lisbonne", botId: "voyages" },
    });
    expect(body).toEqual({
      aps: { alert: { title: "✈️ Voyages", body: "Ton itinéraire Lisbonne est prêt" }, sound: "default", category: "nuo.answer", "thread-id": "voyages" },
      destination: { kind: "conversation", id: "c-voyages-lisbonne", botId: "voyages" },
      botId: "voyages",
      conversationId: "c-voyages-lisbonne",
    });
  });

  test("an alert without a conversation cannot be answered inline", () => {
    const bot = apnsBody({
      title: "🏃 HYROX Paris",
      body: "2 places libérées en Open Men samedi 14h",
      botId: "sport",
      destination: { kind: "bot", id: "sport" },
    });
    expect(bot.aps).toMatchObject({ category: "nuo.alert", "thread-id": "sport" });
    const alert = apnsBody({ title: "Sauvegarde NAS", body: "Terminée en 42 min", destination: { kind: "home" } });
    expect(alert.aps).toMatchObject({ category: "nuo.alert" });
  });

  test("every other kind travels as is next to its category", () => {
    const reminder = apnsBody({
      title: "Payer l'URSSAF",
      body: "Avant le 20",
      reminderId: "rem-urssaf-t3",
      category: "nuo.reminder",
      destination: { kind: "reminder", id: "rem-urssaf-t3" },
    });
    expect(reminder).toMatchObject({ aps: { category: "nuo.reminder" }, reminderId: "rem-urssaf-t3", destination: { kind: "reminder", id: "rem-urssaf-t3" } });

    const task = apnsBody({
      title: "⚠️ Sauvegarde NAS",
      body: "rsync: connection refused",
      botId: "ops",
      taskId: "task-nas-backup",
      runId: "run-2026-10-17-0300",
      destination: { kind: "task", id: "task-nas-backup", botId: "ops", runId: "run-2026-10-17-0300" },
    });
    expect(task).toMatchObject({ taskId: "task-nas-backup", runId: "run-2026-10-17-0300", destination: { kind: "task", id: "task-nas-backup", botId: "ops", runId: "run-2026-10-17-0300" } });
    expect(task).not.toHaveProperty("conversationId");
    expect(task.aps).toMatchObject({ category: "nuo.alert" });

    const browser = apnsBody({
      title: "Connexion requise sur LinkedIn",
      body: "Un agent attend que tu te connectes",
      category: "nuo.browser",
      url: "nuo://browser",
      destination: { kind: "browser" },
    });
    expect(browser).toMatchObject({ url: "nuo://browser", destination: { kind: "browser" } });
    expect(browser.aps).not.toHaveProperty("thread-id");
  });
});
