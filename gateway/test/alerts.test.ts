import { afterEach, describe, expect, test } from "bun:test";
import { recordingPusher } from "../src/push/recording";
import { Hub } from "../src/runner/hub";
import { botConfig, FakePusher, pairDevice, Socket, startTestApp, type TestApp } from "./helpers";

const LOCAL = "local-secret";
let t: TestApp;
let sock: Socket | undefined;

afterEach(async () => {
  sock?.close();
  sock = undefined;
  await t?.close();
});

async function waitFor<T>(read: () => Promise<T> | T, ok: (v: T) => boolean): Promise<T> {
  for (let i = 0; i < 100; i++) {
    const v = await read();
    if (ok(v)) return v;
    await Bun.sleep(20);
  }
  throw new Error("timeout");
}

describe("alert history", () => {
  test("a script alert without a conversation is kept once for two devices, then marked read", async () => {
    t = await startTestApp({ localToken: LOCAL });
    await t.api("POST", "/api/devices", { apnsToken: "ab".repeat(32), environment: "production" });
    const mac = await pairDevice({ base: t.base, api: t.api, store: t.app.store, totpSecret: t.totpSecret, now: Date.now(), name: "MacBook Air" });
    await t.api("POST", "/api/devices", { apnsToken: "cd".repeat(32), environment: "production" }, mac.accessToken);
    // Pairing the Mac alerted the iPhone: a security alert, kept like the others.
    const [pairing] = (await t.api("GET", "/api/alerts")).data;
    expect(pairing).toMatchObject({ destination: { kind: "settings" } });
    t.pusher.sent = [];
    sock = await Socket.open(t);

    const backup = { title: "💾 Sauvegarde Time Machine", body: "Le disque « Archives 2026 » est plein à 97 %." };
    expect((await t.api("POST", "/api/notify", backup, LOCAL)).status).toBe(204);
    expect(t.pusher.sent.map((s) => s.device.name).sort()).toEqual(["MacBook Air", "Test iPhone"]);

    const alerts = (await t.api("GET", "/api/alerts")).data;
    expect(alerts).toEqual([{ id: expect.any(String), ...backup, destination: { kind: "home" }, createdAt: expect.any(String) }, pairing]);
    expect((await sock.next("alert")).alert).toEqual(alerts[0]);
    expect((await t.api("GET", "/api/alerts", undefined, mac.accessToken)).data).toEqual(alerts);

    const parcel = { title: "📦 Colis Vinted", body: "Ton colis est disponible au relais Pickup.", botId: "achats" };
    await t.api("POST", "/api/notify", parcel, LOCAL);
    const [latest, first] = (await t.api("GET", "/api/alerts")).data;
    expect(first.id).toBe(alerts[0].id);
    expect(latest).toMatchObject({ ...parcel, destination: { kind: "bot", id: "achats" } });

    expect((await t.api("POST", "/api/alerts/read", { ids: [first.id] })).status).toBe(204);
    let read = (await t.api("GET", "/api/alerts")).data;
    expect(read.map((a: any) => !!a.readAt)).toEqual([false, true, false]);

    expect((await t.api("POST", "/api/alerts/read", {})).status).toBe(204);
    read = (await t.api("GET", "/api/alerts")).data;
    expect(read.every((a: any) => typeof a.readAt === "string")).toBe(true);
    expect((await t.api("POST", "/api/alerts/read", { ids: "tout" })).status).toBe(400);
  });

  test("deletes one alert, then the read ones, then all of them", async () => {
    t = await startTestApp({ localToken: LOCAL });
    const notify = (title: string, body: string) => t.api("POST", "/api/notify", { title, body }, LOCAL);
    await notify("💾 Sauvegarde Time Machine", "Le disque « Archives 2026 » est plein à 97 %.");
    await notify("📦 Colis Vinted", "Ton colis est disponible au relais Pickup.");
    await notify("⚠️ Lumen API prod", "Échec : 3 erreurs 500 sur /api/training-plan-jobs");
    await notify("🏃 HYROX Paris", "2 places libérées en Open Men samedi 14h.");
    const titles = async () => (await t.api("GET", "/api/alerts")).data.map((a: any) => a.title);
    const [hyrox, apiWatch, parcel] = (await t.api("GET", "/api/alerts")).data;

    expect((await t.api("DELETE", `/api/alerts/${apiWatch.id}`)).status).toBe(204);
    expect(await titles()).toEqual(["🏃 HYROX Paris", "📦 Colis Vinted", "💾 Sauvegarde Time Machine"]);
    expect((await t.api("DELETE", `/api/alerts/${apiWatch.id}`)).status).toBe(404);

    await t.api("POST", "/api/alerts/read", { ids: [hyrox.id, parcel.id] });
    expect((await t.api("DELETE", "/api/alerts?read=1")).status).toBe(204);
    expect(await titles()).toEqual(["💾 Sauvegarde Time Machine"]);

    expect((await t.api("DELETE", "/api/alerts")).status).toBe(204);
    expect(await titles()).toEqual([]);
  });

  test("a chat answer pushed to an away device is not kept: it is already in its conversation", async () => {
    t = await startTestApp();
    const bot = (await t.api("POST", "/api/bots", { name: "Voyages" })).data;
    await t.api("PUT", `/api/bots/${bot.id}/draft`, botConfig());
    await t.api("POST", `/api/bots/${bot.id}/publish`, {});
    const conv = (await t.api("POST", "/api/conversations", { botId: bot.id })).data;
    await t.api("POST", "/api/devices", { apnsToken: "ab".repeat(32), environment: "development" });

    await t.api("POST", `/api/conversations/${conv.id}/prompt`, { text: "Quel temps à Lisbonne demain ?" });
    const sent = await waitFor(() => t.pusher.sent, (s) => s.length === 1);
    expect(sent[0]!.payload).toMatchObject({ messageId: expect.any(String), destination: { kind: "conversation", id: conv.id } });
    expect((await t.api("GET", "/api/alerts")).data).toEqual([]);
  });

  test("the same alert is kept again once the dedup window has passed", async () => {
    t = await startTestApp();
    let clock = Date.parse("2026-11-13T08:00:00Z");
    const inner = new FakePusher();
    const pusher = recordingPusher(inner, t.app.store, new Hub(), { now: () => clock });
    const iphone = { id: "iphone-julie", name: "iPhone de Julie", apnsToken: "ab".repeat(32) };
    const reminder = { title: "Payer l'URSSAF", body: "Avant le 20", category: "nuo.reminder", reminderId: "rem-urssaf-t4", destination: { kind: "reminder" as const, id: "rem-urssaf-t4" } };

    await pusher.send(iphone, reminder);
    clock += 5_000;
    await pusher.send(iphone, reminder);
    expect(t.app.store.alerts()).toHaveLength(1);
    clock += 10_000;
    await pusher.send(iphone, reminder);
    expect(t.app.store.alerts()).toHaveLength(2);
    expect(inner.sent).toHaveLength(3);

    await pusher.sendBackground(iphone, { deviceRequest: "req-calendar" });
    expect(t.app.store.alerts()).toHaveLength(2);
  });

  test("keeps the last 500 alerts of the last 60 days", async () => {
    t = await startTestApp();
    const store = t.app.store;
    const at = (iso: string, i = 0) => new Date(Date.parse(iso) + i * 1000).toISOString();
    store.addAlert({ title: "🔐 Nouvelle connexion", body: "MacBook Air depuis Lyon", destination: { kind: "settings" } }, at("2026-09-01T09:00:00Z"));
    store.addAlert({ title: "📅 Réservation", body: "Julie Martin, jeudi 10h", destination: { kind: "booking", id: "bk-julie-martin" } }, at("2026-11-12T09:00:00Z"));
    expect(store.alerts().map((a) => a.title)).toEqual(["📅 Réservation"]);

    for (let i = 0; i < 510; i++) store.addAlert({ title: `Colis ${i}`, body: "En cours d'acheminement", destination: { kind: "home" } }, at("2026-11-13T00:00:00Z", i));
    expect((store.db.query("SELECT COUNT(*) AS n FROM alerts").get() as { n: number }).n).toBe(500);
    const listed = store.alerts();
    expect(listed).toHaveLength(200);
    expect(listed[0]!.title).toBe("Colis 509");
  });
});
