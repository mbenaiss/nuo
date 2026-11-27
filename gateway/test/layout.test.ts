import { Database } from "bun:sqlite";
import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { claudeProjectDir, moveClaudeProject } from "../src/agents/claude";
import { memoryExcerpt } from "../src/bots/memory";
import { defaultLayout, seedConfig } from "../src/paths";
import { MIGRATIONS, openDb } from "../src/store/db";
import { slugify } from "../src/store/slug";
import { botConfig, Socket, startTestApp, type TestApp } from "./helpers";

const LOCAL = "local-secret";
let t: TestApp | undefined;
const dirs: string[] = [];
afterEach(async () => {
  await t?.close();
  t = undefined;
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
});
const tmp = () => {
  const d = mkdtempSync(join(tmpdir(), "nuo-layout-"));
  dirs.push(d);
  return d;
};

describe("layout", () => {
  test("NUO_HOME drives every path, NUO_DATA_DIR overrides data only", () => {
    expect(defaultLayout({ NUO_HOME: "/r" })).toEqual({
      home: "/r",
      nuo: "/r",
      browser: "/r/browser",
      agentHome: "/r/home",
      config: "/r/config",
      data: "/r/data",
      bots: "/r/bots",
      instructions: "/r/instructions",
      memory: "/r/memory",
      dataDb: "/r/data/data.db",
      dataFiles: "/r/data/files",
      docs: "/r/docs",
      dashboards: "/r/dashboards",
    });
    const l = defaultLayout({ NUO_HOME: "/r", NUO_DATA_DIR: "/d" });
    expect([l.data, l.bots, l.config]).toEqual(["/d", "/r/bots", "/r/config"]);
  });

  test("config files are copied from the repo defaults only when missing", () => {
    const root = tmp();
    const defaults = join(root, "defaults");
    const live = join(root, "config");
    mkdirSync(defaults);
    mkdirSync(live);
    writeFileSync(join(defaults, "tools.json"), "[1]");
    writeFileSync(join(defaults, "bots.seed.json"), "[2]");
    writeFileSync(join(live, "tools.json"), "[edited]");
    expect(seedConfig(live, defaults)).toEqual(["bots.seed.json"]);
    expect(readFileSync(join(live, "tools.json"), "utf8")).toBe("[edited]");
    expect(seedConfig(live, defaults)).toEqual([]);
  });
});

describe("slugs", () => {
  test("slugify keeps readable ascii", () => {
    expect(slugify("Cobot")).toBe("cobot");
    expect(slugify("Été à Paris !")).toBe("ete-a-paris");
    expect(slugify("🦊")).toBe("bot");
  });

  test("the migration backfills unique slugs from the bot names", () => {
    const dir = tmp();
    const db = new Database(join(dir, "nuo.db"), { create: true, strict: true });
    for (const m of MIGRATIONS.slice(0, 3)) db.exec(m as string);
    db.exec("PRAGMA user_version = 3");
    const add = (id: string, at: string, published?: string, draft?: string) => {
      db.query("INSERT INTO bots (id, draft, created_at, updated_at) VALUES (?, ?, ?, ?)").run(id, draft ? JSON.stringify({ name: draft }) : null, at, at);
      if (published) db.query("INSERT INTO bot_versions (bot_id, version, config, published_at) VALUES (?, 1, ?, ?)").run(id, JSON.stringify({ name: published }), at);
    };
    add("a", "2026-01-01", "Cobot");
    add("b", "2026-01-02", "Coach", "Coach renommé");
    add("c", "2026-01-03", "Coach");
    add("d", "2026-01-04", undefined, "Été");
    db.close();
    const migrated = openDb(dir);
    const slugs = Object.fromEntries((migrated.query("SELECT id, slug FROM bots").all() as { id: string; slug: string }[]).map((r) => [r.id, r.slug]));
    expect(slugs).toEqual({ a: "cobot", b: "coach", c: "coach-2", d: "ete" });
    migrated.close();
  });

  test("new bots get a unique slug that survives a rename", async () => {
    t = await startTestApp();
    const a = (await t.api("POST", "/api/bots", { name: "Voyages" })).data;
    const b = (await t.api("POST", "/api/bots", { name: "Voyages" })).data;
    expect([a.slug, b.slug]).toEqual(["voyages", "voyages-2"]);
    await t.api("PUT", `/api/bots/${a.id}/draft`, botConfig({ name: "Trips" }));
    await t.api("POST", `/api/bots/${a.id}/publish`, {});
    expect((await t.api("GET", `/api/bots/${a.id}`)).data.slug).toBe("voyages");
    expect(t.app.bots.botDir(a.id)).toBe(join(t.profileHome, "bots", "voyages"));
  });

  test("folders named after the bot id move to the slug folder", async () => {
    t = await startTestApp();
    const bot = (await t.api("POST", "/api/bots", { name: "Coach" })).data;
    const old = join(t.profileHome, "bots", bot.id, ".nuo", "attachments", "x");
    mkdirSync(old, { recursive: true });
    writeFileSync(join(old, "a.pdf"), "pdf");
    const claudeProject = claudeProjectDir(join(t.profileHome, "bots", bot.id), join(t.home, "claude"));
    mkdirSync(claudeProject, { recursive: true });
    writeFileSync(join(claudeProject, "s1.jsonl"), "{}");
    t.app.bots.migrateFolders((from, to) => moveClaudeProject(from, to, join(t.home, "claude")));
    expect(existsSync(join(t.profileHome, "bots", bot.id))).toBe(false);
    expect(existsSync(join(claudeProjectDir(join(t.profileHome, "bots", "coach"), join(t.home, "claude")), "s1.jsonl"))).toBe(true);
    expect(readFileSync(join(t.profileHome, "bots", "coach", ".nuo", "attachments", "x", "a.pdf"), "utf8")).toBe("pdf");
  });
});

describe("memory", () => {
  test("the app and the bot's nuo server read and write the bot's memory", async () => {
    t = await startTestApp({ localToken: LOCAL });
    const bot = (await t.api("POST", "/api/bots", { name: "Coach" })).data;
    const path = `/api/bots/${bot.id}/memory`;
    expect((await t.api("GET", path)).data).toEqual({ content: "" });
    expect((await t.api("POST", path, { fact: "Préfère courir le matin\nvraiment" }, LOCAL)).status).toBe(200);
    const m = (await t.api("GET", path, undefined, LOCAL)).data;
    expect(m.content).toMatch(/^- \d{4}-\d{2}-\d{2} Préfère courir le matin vraiment\n$/);
    expect(m.updatedAt).toBeString();
    expect(readFileSync(join(t.profileHome, "memory", "coach", "MEMORY.md"), "utf8")).toBe(m.content);
    expect((await t.api("PUT", path, { content: "- tout neuf" })).data.content).toBe("- tout neuf\n");
    expect((await t.api("POST", path, { fact: "  " }, LOCAL)).status).toBe(400);
    expect((await t.api("GET", `/api/bots/nope/memory`, undefined, LOCAL)).status).toBe(404);
    expect((await t.api("GET", `/api/bots/${bot.id}`, undefined, LOCAL)).status).toBe(401);
    expect((await t.api("GET", path, undefined, "wrong")).status).toBe(401);
  });

  test("the memory is injected in the instructions and goes away with the bot", async () => {
    t = await startTestApp({ localToken: LOCAL });
    const bot = (await t.api("POST", "/api/bots", { name: "Voyages" })).data;
    await t.api("PUT", `/api/bots/${bot.id}/draft`, botConfig());
    await t.api("POST", `/api/bots/${bot.id}/publish`, {});
    await t.api("POST", `/api/bots/${bot.id}/memory`, { fact: "Vols du matin uniquement" }, LOCAL);
    const conv = (await t.api("POST", "/api/conversations", { botId: bot.id })).data;
    const sock = await Socket.open(t);
    sock.send({ type: "prompt", conversationId: conv.id, text: "Salut" });
    await sock.next("message.end");
    sock.close();
    const text = readFileSync(join(t.profileHome, "instructions", "voyages.md"), "utf8");
    expect(text).toContain("## Mémoire");
    expect(text).toContain("Vols du matin uniquement");
    expect(readFileSync(join(t.profileHome, "bots", "voyages", "CLAUDE.md"), "utf8")).toBe(text);

    expect((await t.api("DELETE", `/api/bots/${bot.id}`)).status).toBe(204);
    for (const p of ["bots/voyages", "instructions/voyages.md", "memory/voyages"]) expect(existsSync(join(t.profileHome, p))).toBe(false);
  });

  test("the injected excerpt keeps the newest lines", () => {
    const lines = Array.from({ length: 400 }, (_, i) => `- fact ${i} ${"x".repeat(30)}`).join("\n");
    const excerpt = memoryExcerpt(lines, 1024);
    expect(Buffer.byteLength(excerpt)).toBeLessThanOrEqual(1024);
    expect(excerpt.endsWith(`- fact 399 ${"x".repeat(30)}`)).toBe(true);
    expect(excerpt).not.toContain("- fact 0 ");
  });
});
