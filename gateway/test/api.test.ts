import { NuoTools } from "../src/mcp/nuo-server";
import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, readlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createPairCode } from "../src/auth/service";
import { base32Decode, totp } from "../src/auth/totp";
import { AgentDirectory, runtimesFrom } from "../src/runner/runtimes";
import { botConfig, FakeRuntime, newDeviceKey, startTestApp, type TestApp } from "./helpers";

let t: TestApp;
afterEach(async () => t?.close());

describe("pairing and auth", () => {
  test("health is public, other routes need a token", async () => {
    t = await startTestApp();
    const health = await t.api("GET", "/api/health", undefined, "");
    expect(health.status).toBe(200);
    expect(health.data.ok).toBe(true);
    expect(health.data.agents[0]).toMatchObject({ id: "claude", available: true, models: [{ id: "fake-model" }] });
    expect((await t.api("GET", "/api/bots", undefined, "")).status).toBe(401);
    expect((await t.api("GET", "/api/bots", undefined, "nope")).status).toBe(401);
    expect((await t.api("GET", "/api/bots")).status).toBe(200);
    expect((await t.api("GET", "/api/nothing")).data).toEqual({ error: "not found" });
  });

  test("a code is single use and stored hashed", async () => {
    t = await startTestApp();
    const code = createPairCode(t.app.store);
    const rows = t.app.store.db.query("SELECT code_hash FROM pair_codes").all() as { code_hash: string }[];
    expect(rows.map((r) => r.code_hash)).not.toContain(code);
    const { spki } = await newDeviceKey();
    const second = totp(base32Decode(t.totpSecret), Date.now() + 30_000);
    const ok = await t.api("POST", "/api/pair", { profile: "owner", code, totp: second, deviceName: "iPad", platform: "iPadOS", publicKey: spki }, "");
    expect(ok.status).toBe(200);
    expect(ok.data.accessToken).toHaveLength(43);
    expect(Object.keys(ok.data.extensionTokens).sort()).toEqual(["share", "watch", "widgets"]);
    expect((await t.api("POST", "/api/pair", { profile: "owner", code, totp: second, deviceName: "iPad", publicKey: spki }, "")).status).toBe(401);
    expect((await t.api("GET", "/api/bots", undefined, ok.data.accessToken)).status).toBe(200);
  });

  test("an old app without device key or 2FA code is told to update", async () => {
    t = await startTestApp();
    const r = await t.api("POST", "/api/pair", { code: createPairCode(t.app.store), deviceName: "x" }, "");
    expect(r.status).toBe(400);
    const { spki } = await newDeviceKey();
    const noProfile = await t.api("POST", "/api/pair", { code: createPairCode(t.app.store), totp: "123456", publicKey: spki }, "");
    expect(noProfile.status).toBe(400);
  });

  test("notify accepts the local token only on /api/notify", async () => {
    t = await startTestApp({ localToken: "local-secret" });
    expect((await t.api("GET", "/api/bots", undefined, "local-secret")).status).toBe(401);
    await t.api("POST", "/api/devices", { apnsToken: "ab".repeat(32), environment: "development" });
    const r = await t.api("POST", "/api/notify", { title: "Alerte", body: "Vol retardé" }, "local-secret");
    expect(r.status).toBe(204);
    expect(t.pusher.sent).toHaveLength(1);
    expect(t.pusher.sent[0]!.payload).toMatchObject({ title: "Alerte", body: "Vol retardé", destination: { kind: "home" } });
    expect(t.pusher.sent[0]!.device.apnsEnv).toBe("development");
  });

  test("notify opens the bot, or the nuo:// link it is given", async () => {
    t = await startTestApp({ localToken: "local-secret" });
    await t.api("POST", "/api/devices", { apnsToken: "ab".repeat(32), environment: "development" });
    const alert = { title: "✈️ Voyages", body: "Ton vol AF1234 pour Lisbonne est retardé de 40 min" };
    expect((await t.api("POST", "/api/notify", { ...alert, botId: "voyages" }, "local-secret")).status).toBe(204);
    expect((await t.api("POST", "/api/notify", { ...alert, botId: "voyages", url: "nuo://docs/voyages/lisbonne-2026.md" }, "local-secret")).status).toBe(204);
    expect(t.pusher.sent.map((s) => s.payload.destination)).toEqual([
      { kind: "bot", id: "voyages" },
      { kind: "link", url: "nuo://docs/voyages/lisbonne-2026.md" },
    ]);
    expect(t.pusher.sent[1]!.payload).toMatchObject({ botId: "voyages", url: "nuo://docs/voyages/lisbonne-2026.md" });
    expect((await t.api("POST", "/api/notify", { ...alert, url: "https://www.airfrance.fr" }, "local-secret")).status).toBe(400);
  });

  test("a bot alerting from one of its conversations opens that conversation", async () => {
    t = await startTestApp({ localToken: "local-secret" });
    await t.api("POST", "/api/devices", { apnsToken: "ab".repeat(32), environment: "development" });
    const voyages = (await t.api("POST", "/api/bots", { name: "Voyages" })).data;
    const cirque = (await t.api("POST", "/api/bots", { name: "Cirque" })).data;
    const lisbonne = (await t.api("POST", "/api/conversations", { botId: voyages.id, useDraft: true })).data;
    await t.api("POST", "/api/conversations", { botId: voyages.id, useDraft: true });
    const illusions = (await t.api("POST", "/api/conversations", { botId: cirque.id, useDraft: true })).data;

    const tools = new NuoTools({ url: t.base, token: "local-secret", botId: voyages.id, conversationId: lisbonne.id });
    expect(await tools.call("notify_user", { title: "✈️ Voyages", body: "Ton vol AF1234 pour Lisbonne est retardé de 40 min" })).toBe("Notification envoyée.");
    const alert = { title: "✈️ Voyages", body: "Porte d'embarquement changée : K42", botId: voyages.id };
    await t.api("POST", "/api/notify", { ...alert, conversationId: illusions.id }, "local-secret");
    await t.api("POST", "/api/notify", { ...alert, conversationId: "conv-supprimee" }, "local-secret");
    await t.api("POST", "/api/notify", { ...alert, conversationId: lisbonne.id, url: "nuo://docs/voyages/lisbonne-2026.md" }, "local-secret");

    expect(t.pusher.sent.map((s) => s.payload.destination)).toEqual([
      { kind: "conversation", id: lisbonne.id, botId: voyages.id },
      { kind: "bot", id: voyages.id },
      { kind: "bot", id: voyages.id },
      { kind: "link", url: "nuo://docs/voyages/lisbonne-2026.md" },
    ]);
    expect(t.pusher.sent[0]!.payload).toMatchObject({ botId: voyages.id, conversationId: lisbonne.id });
  });

  test("the same alert key notifies once per window, from the bot's notify_user tool too", async () => {
    t = await startTestApp({ localToken: "local-secret" });
    await t.api("POST", "/api/devices", { apnsToken: "ab".repeat(32), environment: "development" });
    const alert = { title: "Illusions Tour", body: "Séance du 2 novembre à 14h : 4 places gratuites réservées.", botId: "cirque", key: "illusions-2321184" };
    expect((await t.api("POST", "/api/notify", alert, "local-secret")).status).toBe(204);
    const again = await t.api("POST", "/api/notify", { ...alert, body: "Séance du 2 novembre à 14h : toujours disponible." }, "local-secret");
    expect(again.status).toBe(200);
    expect(again.data.sent).toBe(false);
    expect((await t.api("POST", "/api/notify", { ...alert, key: "illusions-2321190" }, "local-secret")).status).toBe(204);
    expect((await t.api("POST", "/api/notify", { ...alert, botId: "voyages" }, "local-secret")).status).toBe(204);
    expect(t.pusher.sent).toHaveLength(3);

    const tools = new NuoTools({ url: t.base, token: "local-secret", botId: "cirque" });
    expect(await tools.call("notify_user", { title: "Illusions Tour", body: "Séance du 9 novembre à 17h disponible.", key: "illusions-2321201" })).toBe("Notification envoyée.");
    expect(await tools.call("notify_user", { title: "Illusions Tour", body: "Séance du 9 novembre à 17h disponible.", key: "illusions-2321201" })).toContain("Déjà notifié");
    expect(t.pusher.sent).toHaveLength(4);
    expect((await t.api("POST", "/api/notify", { ...alert, key: 42 }, "local-secret")).status).toBe(400);
  });
});

describe("bots", () => {
  test("draft → publish → edit → rollback → delete", async () => {
    t = await startTestApp();
    const created = await t.api("POST", "/api/bots", { name: "Voyages" });
    expect(created.status).toBe(200);
    const id = created.data.id;
    expect(created.data.draft).toMatchObject({ name: "Voyages", agent: "claude", model: "fake-model" });
    expect(created.data.published).toBeUndefined();

    const bad = await t.api("PUT", `/api/bots/${id}/draft`, botConfig({ name: "", model: "", toolServers: ["nope"], agent: "zzz" }));
    expect(bad.status).toBe(400);
    expect(bad.data.error).toContain("name must be 1 to 40 characters");
    expect(bad.data.error).toContain("unknown tool servers: nope");
    expect(bad.data.error).toContain('unknown agent "zzz"');
    expect(bad.data.error).toContain("model is required");

    expect((await t.api("PUT", `/api/bots/${id}/draft`, botConfig())).status).toBe(200);
    const v1 = await t.api("POST", `/api/bots/${id}/publish`, { note: "first" });
    expect(v1.data.published).toMatchObject({ version: 1, note: "first", config: { name: "Voyages" } });
    expect(v1.data.draft).toBeUndefined();
    expect((await t.api("POST", `/api/bots/${id}/publish`, {})).status).toBe(400);

    await t.api("PUT", `/api/bots/${id}/draft`, botConfig({ instructions: "v2" }));
    const v2 = await t.api("POST", `/api/bots/${id}/publish`, {});
    expect(v2.data.published.version).toBe(2);

    await t.api("PUT", `/api/bots/${id}/draft`, botConfig({ instructions: "draft" }));
    const discarded = await t.api("DELETE", `/api/bots/${id}/draft`);
    expect(discarded.data.draft).toBeUndefined();

    const rb = await t.api("POST", `/api/bots/${id}/rollback`, { version: 1 });
    expect(rb.data.published).toMatchObject({ version: 3, config: { instructions: "Tu es l'assistant voyages." } });
    const versions = await t.api("GET", `/api/bots/${id}/versions`);
    expect(versions.data.map((v: any) => v.version)).toEqual([3, 2, 1]);
    expect((await t.api("POST", `/api/bots/${id}/rollback`, { version: 9 })).status).toBe(404);
    expect(() => t.app.store.db.query("UPDATE bot_versions SET note = 'x'").run()).toThrow();

    const clone = await t.api("POST", "/api/bots", { name: "Voyages 2", fromBotId: id });
    expect(clone.data.draft).toMatchObject({ name: "Voyages 2", toolServers: ["travel"] });

    expect((await t.api("DELETE", `/api/bots/${id}`)).status).toBe(204);
    expect((await t.api("GET", `/api/bots/${id}`)).status).toBe(404);
    expect((await t.api("GET", "/api/bots")).data).toHaveLength(1);
  });

  test("permissions switch from a chat updates the published version and keeps the draft pending", async () => {
    t = await startTestApp();
    const id = (await t.api("POST", "/api/bots", { name: "Voyages" })).data.id;
    await t.api("PUT", `/api/bots/${id}/draft`, botConfig());
    await t.api("POST", `/api/bots/${id}/publish`, {});
    await t.api("PUT", `/api/bots/${id}/draft`, botConfig({ instructions: "pending" }));

    const r = await t.api("PUT", `/api/bots/${id}/permissions`, { permissionPolicy: "auto" });
    expect(r.status).toBe(200);
    expect(r.data.published).toMatchObject({ version: 2, config: { permissionPolicy: "auto", instructions: "Tu es l'assistant voyages." } });
    expect(r.data.draft).toMatchObject({ permissionPolicy: "auto", instructions: "pending" });
    expect((await t.api("PUT", `/api/bots/${id}/permissions`, { permissionPolicy: "yolo" })).status).toBe(400);
  });

  test("an agent whose CLI hangs is listed as not responding without holding back the others", async () => {
    const hung = { id: "gemini" as const, name: "Gemini", status: () => new Promise<never>(() => {}), models: () => new Promise<never>(() => {}), start: () => Promise.reject(new Error("hung")) };
    const dir = new AgentDirectory(runtimesFrom([new FakeRuntime(), hung]), 50);
    const info = await dir.info();
    expect(info[0]).toMatchObject({ id: "claude", available: true, models: [{ id: "fake-model" }] });
    expect(info[1]).toEqual({ id: "gemini", name: "Gemini", available: false, authenticated: false, note: "not responding", models: [] });
  });

  test("tools catalog hides launch details", async () => {
    t = await startTestApp();
    const tools = await t.api("GET", "/api/tools");
    expect(tools.data).toEqual([{ id: "travel", name: "Voyages", description: "Vols", tools: ["flight_status"] }]);
  });

  test("every published bot gets the current instructions when the gateway starts, before any session", async () => {
    t = await startTestApp({ seed: [{ config: botConfig({ name: "Cobot", toolServers: [] }) }, { config: botConfig({ name: "Coach" }) }] });
    const bots = (await t.api("GET", "/api/bots")).data as { slug: string }[];
    for (const b of bots) {
      const path = join(t.profileHome, "instructions", `${b.slug}.md`);
      for (let i = 0; i < 50 && !existsSync(path); i++) await Bun.sleep(20);
      expect(readFileSync(path, "utf8")).toContain("## Speed");
    }
    expect(t.runtime.starts).toHaveLength(0);
  });

  test("seeding happens once", async () => {
    t = await startTestApp({ seed: [{ config: botConfig({ name: "Cobot", toolServers: [] }) }, { config: botConfig({ name: "Coach" }) }] });
    const bots = (await t.api("GET", "/api/bots")).data;
    expect(bots).toHaveLength(2);
    for (const b of bots) expect(b.published.version).toBe(1);
    for (const b of bots) await t.api("DELETE", `/api/bots/${b.id}`);
    t.app.bots.seed(join(t.configDir, "bots.seed.json"));
    expect((await t.api("GET", "/api/bots")).data).toHaveLength(0);
  });
});

describe("conversations", () => {
  test("cannot chat with an unpublished bot unless using the draft", async () => {
    t = await startTestApp();
    const bot = (await t.api("POST", "/api/bots", { name: "Draft" })).data;
    expect((await t.api("POST", "/api/conversations", { botId: bot.id })).status).toBe(400);
    const c = await t.api("POST", "/api/conversations", { botId: bot.id, useDraft: true });
    expect(c.data).toMatchObject({ botId: bot.id, useDraft: true });
    expect(c.data.agentSessionId).toBeUndefined();
    expect((await t.api("GET", `/api/conversations?botId=${bot.id}`)).data).toHaveLength(1);
    expect((await t.api("DELETE", `/api/conversations/${c.data.id}`)).status).toBe(204);
    expect((await t.api("GET", `/api/conversations/${c.data.id}/messages`)).status).toBe(404);
  });

  test("workspace files carry the effective instructions", async () => {
    t = await startTestApp();
    const { prepareWorkspace } = await import("../src/bots/instructions");
    const dir = join(t.profileHome, "bots", "x");
    const instructionsPath = join(t.profileHome, "instructions", "x.md");
    writeFileSync((mkdirSync(dir, { recursive: true }), join(dir, "CLAUDE.md")), "stale copy from the old layout");
    await prepareWorkspace({ slug: "x", botDir: dir, instructionsPath }, botConfig({ workdir: "/srv/repo" }) as any, "- 2026-10-18 Préfère les vols du matin\n");
    for (const f of ["CLAUDE.md", "AGENTS.md", "GEMINI.md"]) {
      expect(readlinkSync(join(dir, f))).toBe("../../instructions/x.md");
      expect(readFileSync(join(dir, f), "utf8")).toBe(readFileSync(instructionsPath, "utf8"));
    }
    const text = readFileSync(join(dir, "AGENTS.md"), "utf8");
    expect(text).toContain("## Memory");
    expect(text).toContain("Préfère les vols du matin");
    expect(text).toStartWith("Tu es l'assistant voyages.");
    expect(text).toContain("::flight");
    expect(text).toContain("/srv/repo");
    expect(text).toContain("1 to 3 short sentences");
  });
});

describe("responses", () => {
  test("large JSON answers are gzipped for clients that accept it", async () => {
    t = await startTestApp();
    const get = (path: string, encoding: string) =>
      fetch(`${t.base}${path}`, { headers: { authorization: `Bearer ${t.token}`, "accept-encoding": encoding }, decompress: false } as RequestInit);
    const gz = await get("/api/data/collections", "gzip, deflate, br");
    expect(gz.headers.get("content-encoding")).toBe("gzip");
    expect(gz.headers.get("x-content-type-options")).toBe("nosniff");
    const plain = await get("/api/data/collections", "identity");
    expect(plain.headers.get("content-encoding")).toBeNull();
    expect(JSON.parse(Buffer.from(Bun.gunzipSync(new Uint8Array(await gz.arrayBuffer()))).toString())).toEqual(await plain.json());
    expect((await get("/api/data/collections", "gzip;q=0")).headers.get("content-encoding")).toBeNull();
    expect((await get("/api/reminders/lists", "gzip")).headers.get("content-encoding")).toBeNull();
  });
});
