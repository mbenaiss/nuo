import { afterEach, describe, expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { expandTemplate, parseCommand, toolArguments } from "../src/bots/commands";
import { mergeCommands, syncSeedCommands } from "../src/bots/sync-seed";
import { ToolCatalog } from "../src/bots/catalog";
import type { BotCommand } from "../src/protocol";
import { botConfig, Socket, startTestApp, type TestApp } from "./helpers";

const FAKE_SERVER = join(import.meta.dir, "fake-mcp-server.ts");
const TOOLS = [
  { id: "travel", name: "Voyages", description: "Vols", tools: ["flight_status"], command: "node", args: ["server.js"] },
  { id: "fake", name: "Fake", description: "Test server", tools: ["echo", "chart", "fail", "env"], command: process.execPath, args: ["run", FAKE_SERVER] },
];

const COMMANDS: BotCommand[] = [
  { name: "vol", description: "Statut", args: "<vol> [date]", action: { type: "tool", server: "fake", tool: "echo", params: ["flight_no", "date"] } },
  { name: "runs", description: "Courses", action: { type: "tool", server: "fake", tool: "echo", params: ["limit"], fixedArgs: { date: "2026-10-17" } } },
  { name: "graph", description: "Graphique", action: { type: "tool", server: "fake", tool: "chart" } },
  { name: "casse", description: "Erreur", action: { type: "tool", server: "fake", tool: "fail" } },
  { name: "env", description: "Env", action: { type: "tool", server: "fake", tool: "env" } },
  { name: "court", description: "Résumé", action: { type: "prompt", template: "Résume en bref : {args}", model: "haiku", effort: "low" } },
  { name: "chrono", description: "Chrono", action: { type: "open", url: "https://example.com/chrono" } },
];

let t: TestApp;
let sock: Socket | undefined;
afterEach(async () => {
  sock?.close();
  sock = undefined;
  await t?.close();
});

async function setup(commands: BotCommand[] = COMMANDS) {
  t = await startTestApp({ tools: TOOLS });
  const bot = (await t.api("POST", "/api/bots", { name: "Voyages" })).data;
  const saved = await t.api("PUT", `/api/bots/${bot.id}/draft`, botConfig({ toolServers: ["travel", "fake"], commands }));
  expect(saved.status).toBe(200);
  await t.api("POST", `/api/bots/${bot.id}/publish`, {});
  const conv = (await t.api("POST", "/api/conversations", { botId: bot.id })).data;
  sock = await Socket.open(t);
  return { bot, conv, sock };
}

async function send(text: string, conversationId: string) {
  const before = sock!.events.length;
  sock!.send({ type: "prompt", conversationId, text });
  const end = await sock!.next("message.end", 10_000);
  return { end, events: sock!.events.slice(before) };
}

describe("parsing", () => {
  const config = botConfig({ commands: COMMANDS }) as any;

  test("matches the first word against the bot's commands", () => {
    expect(parseCommand("/vol TO8285 2026-10-20", config)).toMatchObject({ command: { name: "vol" }, args: "TO8285 2026-10-20" });
    expect(parseCommand("  /graph", config)).toMatchObject({ command: { name: "graph" }, args: "" });
    expect(parseCommand("/inconnu x", config)).toBeUndefined();
    expect(parseCommand("vol TO8285", config)).toBeUndefined();
    expect(parseCommand("/vol", { ...config, commands: undefined })).toBeUndefined();
  });

  test("positional words fill params, the remainder goes to the last one", () => {
    expect(toolArguments(["flight_no", "date"], undefined, "TO8285")).toEqual({ flight_no: "TO8285" });
    expect(toolArguments(["flight_no", "date"], undefined, "TO8285  20 oct  2026")).toEqual({ flight_no: "TO8285", date: "20 oct 2026" });
    expect(toolArguments(undefined, { a: 1 }, "ignored words")).toEqual({ a: 1 });
    expect(toolArguments(["day"], { day: "fixed" }, "typed")).toEqual({ day: "fixed" });
  });

  test("templates expand {args}", () => {
    expect(expandTemplate("Statut de {args} ({args})", "TO1")).toBe("Statut de TO1 (TO1)");
  });
});

describe("validation", () => {
  test("rejects invalid commands with readable errors", async () => {
    t = await startTestApp({ tools: TOOLS });
    const bot = (await t.api("POST", "/api/bots", { name: "Voyages" })).data;
    const bad = [
      { name: "Vol", description: "x", action: { type: "prompt", template: "x" } },
      { name: "dup", description: "x", action: { type: "prompt", template: "x" } },
      { name: "dup", description: "x", action: { type: "prompt", template: "x" } },
      { name: "off", description: "x", action: { type: "tool", server: "fake", tool: "echo" } },
      { name: "unknown_tool", description: "x", action: { type: "tool", server: "travel", tool: "sync_everything" } },
      { name: "nodesc", description: "", action: { type: "app", action: "teleport" } },
      { name: "link", description: "x", action: { type: "open", url: "javascript:alert(1)" } },
      { name: "tpl", description: "x", action: { type: "prompt", template: " " } },
    ];
    const res = await t.api("PUT", `/api/bots/${bot.id}/draft`, botConfig({ toolServers: ["travel"], commands: bad }));
    expect(res.status).toBe(400);
    const msg: string = res.data.error;
    expect(msg).toContain("command /Vol: name must match");
    expect(msg).toContain("command /dup: duplicate command name");
    expect(msg).toContain('command /off: tool server "fake" is not enabled on this bot');
    expect(msg).toContain('command /unknown_tool: tool "sync_everything" is not listed for server "travel"');
    expect(msg).toContain("command /nodesc: description is required");
    expect(msg).toContain("command /nodesc: app action must be one of");
    expect(msg).toContain("command /link: url must be an http(s) URL");
    expect(msg).toContain("command /tpl: template is required");
    expect((await t.api("PUT", `/api/bots/${bot.id}/draft`, botConfig({ commands: {} }))).data.error).toContain("commands must be an array");
  });

  test("valid commands are kept in the saved config", async () => {
    const { bot } = await setup();
    const got = (await t.api("GET", `/api/bots/${bot.id}`)).data;
    expect(got.published.config.commands).toEqual(COMMANDS);
  });
});

describe("tool commands", () => {
  test("call the MCP tool directly with mapped arguments", async () => {
    const { conv } = await setup();
    const { end, events } = await send("/vol TO8285 20 octobre", conv.id);
    expect(events.map((e) => e.type)).toEqual(["message.start", "tool.start", "tool.end", "message.delta", "message.end"]);
    expect(events[1]).toMatchObject({ title: "echo" });
    expect(events[2]).toMatchObject({ status: "completed" });
    expect((events[2] as any).durationMs).toBeGreaterThanOrEqual(0);
    expect((events[3] as any).text).toBe('args:\n{"flight_no":"TO8285","date":"20 octobre"}');
    expect(end).toMatchObject({ steps: 1, stopReason: "end_turn" });
    expect(t.runtime.starts).toHaveLength(0);

    const msgs = (await t.api("GET", `/api/conversations/${conv.id}/messages`)).data;
    expect(msgs.map((m: any) => [m.role, m.text])).toEqual([
      ["user", "/vol TO8285 20 octobre"],
      ["assistant", 'args:\n{"flight_no":"TO8285","date":"20 octobre"}'],
    ]);
    expect(msgs[1].steps[0]).toMatchObject({ title: "echo", status: "completed" });
  });

  test("numbers are coerced from the tool schema and fixedArgs are merged", async () => {
    const { conv } = await setup();
    const { events } = await send("/runs 3", conv.id);
    expect((events.find((e) => e.type === "message.delta") as any).text).toBe('args:\n{"limit":3,"date":"2026-10-17"}');
  });

  test("image content is stored as media and shown as an ::image card", async () => {
    const { conv } = await setup();
    const { events } = await send("/graph", conv.id);
    const text: string = (events.find((e) => e.type === "message.delta") as any).text;
    const [first, card] = text.split("\n");
    expect(first).toBe("Voici le graphique");
    expect(card).toMatch(/^::image \{"url":"\/api\/media\/[0-9a-f-]+\.png"\}$/);
    const url = JSON.parse(card!.slice("::image ".length)).url;
    const media = await fetch(t.base + url, { headers: { authorization: `Bearer ${t.token}` } });
    expect(media.status).toBe(200);
  });

  test("a tool error ends with a readable message", async () => {
    const { conv } = await setup();
    const { end, events } = await send("/casse", conv.id);
    expect(events.find((e) => e.type === "tool.end")).toMatchObject({ status: "failed" });
    expect((events.find((e) => e.type === "message.delta") as any).text).toBe("La commande /casse a échoué : date invalide");
    expect(end).toMatchObject({ steps: 1, stopReason: "error" });
    const msgs = (await t.api("GET", `/api/conversations/${conv.id}/messages`)).data;
    expect(msgs[1]).toMatchObject({ stopReason: "error", text: "La commande /casse a échoué : date invalide" });
  });

  test("a server that cannot start ends with a readable message", async () => {
    const { conv } = await setup();
    const tools = [TOOLS[0], { ...TOOLS[1], command: "/nonexistent/bin" }];
    writeFileSync(join(t.configDir, "tools.json"), JSON.stringify(tools));
    (t.app as any).runner.catalog.reload();
    const { end, events } = await send("/vol X", conv.id);
    expect(end.stopReason).toBe("error");
    expect((events.find((e) => e.type === "message.delta") as any).text).toStartWith("Impossible d'exécuter /vol : ");
  });

  test("the server gets NUO_MEDIA_DIR and its client is reused", async () => {
    const { conv } = await setup();
    const first = (await send("/env", conv.id)).events.find((e) => e.type === "message.delta") as any;
    const second = (await send("/env", conv.id)).events.find((e) => e.type === "message.delta") as any;
    const [dir, pid] = first.text.split("|");
    expect(dir).toBe(join(t.dataDir, "media"));
    expect(second.text.split("|")[1]).toBe(pid);
  });

  test("commands are serialized with agent turns", async () => {
    const { conv, sock } = await setup();
    sock.send({ type: "prompt", conversationId: conv.id, text: "slow" });
    await sock.next("message.delta");
    sock.send({ type: "prompt", conversationId: conv.id, text: "/vol TO1" });
    await Bun.sleep(300);
    expect(sock.events.filter((e) => e.type === "tool.start")).toHaveLength(0);
    sock.send({ type: "cancel", conversationId: conv.id });
    await sock.next("message.end");
    const end = await sock.next("message.end", 10_000);
    expect(end.stopReason).toBe("end_turn");
  });
});

describe("prompt, open and unknown commands", () => {
  test("prompt commands expand the template and override the model for one turn", async () => {
    const { conv } = await setup();
    await send("Bonjour", conv.id);
    await send("/court la météo", conv.id);
    expect(t.runtime.prompts[1]!.text).toBe("Résume en bref : la météo");
    expect(t.runtime.modelChanges).toEqual(["haiku"]);
    await send("Merci", conv.id);
    expect(t.runtime.modelChanges).toEqual(["haiku", "fake-model"]);
    expect(t.runtime.starts).toHaveLength(1);
    const msgs = (await t.api("GET", `/api/conversations/${conv.id}/messages`)).data;
    expect(msgs[2]).toMatchObject({ role: "user", text: "/court la météo" });
    const c = (await t.api("GET", `/api/conversations?botId=${conv.botId}`)).data[0];
    expect(c.model).toBeUndefined();
  });

  test("a prompt command starting a session uses the override model", async () => {
    const { conv } = await setup();
    await send("/court x", conv.id);
    expect(t.runtime.starts[0]!.model).toBe("haiku");
    expect(t.runtime.starts[0]!.effort).toBe("low");
    await send("Suite", conv.id);
    expect(t.runtime.modelChanges).toEqual(["fake-model"]);
  });

  test("open and app commands get a short local answer", async () => {
    const { conv } = await setup();
    const { end, events } = await send("/chrono", conv.id);
    expect((events.find((e) => e.type === "message.delta") as any).text).toContain("gérée par l'app");
    expect(end).toMatchObject({ steps: 0, stopReason: "end_turn" });
    expect(t.runtime.prompts).toHaveLength(0);
  });

  test("unknown commands go to the agent unchanged", async () => {
    const { conv } = await setup();
    await send("/inconnu bonjour", conv.id);
    expect(t.runtime.prompts[0]!.text).toBe("/inconnu bonjour");
  });
});

describe("sync-seed", () => {
  test("publishes the seed commands once and keeps everything else", async () => {
    t = await startTestApp({ tools: TOOLS });
    const bot = (await t.api("POST", "/api/bots", { name: "Voyages" })).data;
    const custom: BotCommand = { name: "perso", description: "À moi", action: { type: "prompt", template: "x" } };
    await t.api("PUT", `/api/bots/${bot.id}/draft`, botConfig({ toolServers: ["travel", "fake"], commands: [custom] }));
    await t.api("POST", `/api/bots/${bot.id}/publish`, {});
    await t.api("PUT", `/api/bots/${bot.id}/draft`, botConfig({ toolServers: ["travel", "fake"], instructions: "brouillon" }));
    const seedPath = join(t.dataDir, "seed.json");
    writeFileSync(seedPath, JSON.stringify([{ config: botConfig({ commands: COMMANDS.slice(0, 2) }) }, { config: botConfig({ name: "Absent" }) }]));
    const catalog = new ToolCatalog(join(t.configDir, "tools.json"));

    const first = syncSeedCommands(t.app.store, catalog, seedPath);
    expect(first).toEqual([
      { name: "Voyages", status: "published", version: 2 },
      { name: "Absent", status: "missing" },
    ]);
    const got = (await t.api("GET", `/api/bots/${bot.id}`)).data;
    expect(got.published.note).toBe("Ajout des commandes");
    expect(got.published.config.commands.map((c: BotCommand) => c.name)).toEqual(["vol", "runs", "perso"]);
    expect(got.published.config.instructions).toBe("Tu es l'assistant voyages.");
    expect(got.draft.instructions).toBe("brouillon");
    expect(got.draft.commands.map((c: BotCommand) => c.name)).toEqual(["vol", "runs", "perso"]);

    expect(syncSeedCommands(t.app.store, catalog, seedPath)[0]).toEqual({ name: "Voyages", status: "unchanged", version: 2 });
  });

  test("seed commands replace same-named ones", () => {
    const old: BotCommand = { name: "vol", description: "old", action: { type: "prompt", template: "x" } };
    expect(mergeCommands([old], [COMMANDS[0]!])).toEqual([COMMANDS[0]!]);
  });
});

test("the shipped seed commands are valid against the shipped tools.json", async () => {
  const configDir = join(import.meta.dir, "..", "config");
  t = await startTestApp({ tools: JSON.parse(await Bun.file(join(configDir, "tools.json")).text()) });
  const seed = JSON.parse(await Bun.file(join(configDir, "bots.seed.json")).text()) as { config: any }[];
  for (const { config } of seed) {
    const bot = (await t.api("POST", "/api/bots", { name: config.name })).data;
    const res = await t.api("PUT", `/api/bots/${bot.id}/draft`, config);
    expect(res.data.error).toBeUndefined();
    expect(res.data.draft.commands).toEqual(config.commands);
  }
});
