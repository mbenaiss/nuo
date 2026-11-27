import { afterEach, describe, expect, test } from "bun:test";
import { scopeAllows } from "../src/auth/policy";
import { botConfig, startTestApp, type TestApp } from "./helpers";

const TOKEN = "jeton-machine-forma";

describe("machine token", () => {
  let t: TestApp | undefined;
  afterEach(async () => {
    await t?.close();
    t = undefined;
  });

  async function appWithBot() {
    t = await startTestApp({ machineToken: TOKEN, network: { proxySources: new Set(["127.0.0.1"]), tunnelSources: new Set() } });
    const bot = (await t.api("POST", "/api/bots", { name: "Forma" })).data;
    await t.api("PUT", `/api/bots/${bot.id}/draft`, botConfig({ name: "Forma" }));
    await t.api("POST", `/api/bots/${bot.id}/publish`, {});
    return bot;
  }

  /** What Forma's server does: open a conversation with its bot and ask it something. */
  test("holds a conversation with a bot", async () => {
    const bot = await appWithBot();
    const conv = await t!.api("POST", "/api/conversations", { botId: bot.id }, TOKEN);
    expect(conv.status).toBe(200);

    const prompt = await t!.api("POST", `/api/conversations/${conv.data.id}/prompt`, { text: "Un crochet de casque de 90 mm" }, TOKEN);
    expect(prompt.status).toBe(202);

    expect((await t!.api("GET", `/api/conversations/${conv.data.id}`, undefined, TOKEN)).status).toBe(200);
    expect((await t!.api("GET", `/api/conversations/${conv.data.id}/messages`, undefined, TOKEN)).status).toBe(200);
  });

  test("reaches nothing else", async () => {
    await appWithBot();
    expect((await t!.api("GET", "/api/conversations", undefined, TOKEN)).status).toBe(403);
    expect((await t!.api("GET", "/api/devices", undefined, TOKEN)).status).toBe(403);
    expect((await t!.api("POST", "/api/bots", { name: "X" }, TOKEN)).status).toBe(403);
    const refused = await t!.api("GET", "/api/devices", undefined, TOKEN);
    expect(refused.data.error).toContain("machine token");
  });

  /** The token sits in a file on another machine of the house; from outside it is worth nothing. */
  test("is refused from the internet and logged", async () => {
    await appWithBot();
    const res = await fetch(`${t!.base}/api/bots`, { headers: { authorization: `Bearer ${TOKEN}`, "cf-connecting-ip": "203.0.113.9" } });
    expect(res.status).toBe(401);
    expect(await res.json()).toEqual({ error: "unauthorized" });
    expect(t!.app.auth.events().filter((e) => e.type === "machine_token_rejected")).toHaveLength(1);
  });

  test("works through the home proxy, like any device on the network", async () => {
    const bot = await appWithBot();
    const res = await fetch(`${t!.base}/api/conversations`, {
      method: "POST",
      headers: { authorization: `Bearer ${TOKEN}`, "content-type": "application/json", "x-forwarded-for": "10.20.0.42" },
      body: JSON.stringify({ botId: bot.id }),
    });
    expect(res.status).toBe(200);
  });

  test("a wrong token is still unauthorized", async () => {
    await appWithBot();
    expect((await t!.api("GET", "/api/bots", undefined, "jeton-machine-form")).status).toBe(401);
  });

  test("without the token configured nothing changes", async () => {
    t = await startTestApp();
    expect((await t.api("GET", "/api/bots", undefined, TOKEN)).status).toBe(401);
  });

  test("the scope has no socket and no reach beyond conversations", () => {
    expect(scopeAllows("machine", "GET", "/api/ws")).toBe(false);
    expect(scopeAllows("machine", "POST", "/api/conversations/abc/prompt")).toBe(true);
    expect(scopeAllows("machine", "DELETE", "/api/conversations/abc")).toBe(false);
    expect(scopeAllows("machine", "POST", "/api/schedules")).toBe(false);
    expect(scopeAllows("machine", "GET", "/api/secrets")).toBe(false);
  });
});
