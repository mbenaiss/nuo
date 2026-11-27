import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { extractVersion, MachineToolDiscovery, parseFrontmatter, sortMachineTools } from "../src/machine/discovery";
import { parseToolTags, taggedTools, toolHint } from "../src/machine/tags";
import type { MachineTool } from "../src/protocol";
import { botConfig, Socket, startTestApp, type TestApp } from "./helpers";

const tool = (over: Partial<MachineTool> & { id: string }): MachineTool => ({
  name: over.id,
  kind: "cli",
  description: `desc ${over.id}`,
  usage: `usage ${over.id}`,
  needsShell: true,
  available: true,
  ...over,
});

describe("discovery", () => {
  let root: string;
  let bin: string;
  let home: string;
  let catalogPath: string;

  const stub = (name: string, body: string, mode = 0o755) => {
    const p = join(bin, name);
    writeFileSync(p, `#!/bin/sh\n${body}\n`);
    chmodSync(p, mode);
  };

  beforeAll(() => {
    root = mkdtempSync(join(tmpdir(), "nuo-machine-"));
    bin = join(root, "bin");
    home = join(root, "home");
    mkdirSync(bin);
    mkdirSync(join(home, ".claude", "skills", "web", "scripts"), { recursive: true });
    mkdirSync(join(home, ".claude", "skills", "notes"), { recursive: true });
    mkdirSync(join(home, ".claude", "skills", "empty"), { recursive: true });
    stub("foo", 'echo "foo version 1.2.3 (build 9)"');
    stub("errver", 'echo "errver v0.9.0-beta" >&2');
    stub("slow", "/bin/sleep 5");
    stub("noexec", "echo 1", 0o644);
    stub("counted", `echo x >> "${join(root, "calls")}"; echo 2.0.0`);
    writeFileSync(
      join(home, ".claude.json"),
      JSON.stringify({ mcpServers: { lightpanda: { command: "x" }, "My Server": { url: "https://x" } }, projects: { "/p": { mcpServers: { hidden: {} } } } }),
    );
    writeFileSync(
      join(home, ".claude", "skills", "web", "SKILL.md"),
      "---\nname: web-fetch\ndescription: Fetch web pages. Use when browsing.\nallowed-tools: Bash(curl:*)\n---\n# body",
    );
    writeFileSync(join(home, ".claude", "skills", "notes", "SKILL.md"), "---\nname: Notes\ndescription: >\n  Takes notes\n  in a file.\nallowed-tools: Read, Write\n---\n");
    catalogPath = join(root, "machine-tools.json");
    writeFileSync(
      catalogPath,
      JSON.stringify([
        { id: "foo", name: "Foo", kind: "cli", description: "Foo tool", usage: "foo --run", needsShell: true },
        { id: "errver", name: "Err", kind: "cli", description: "", needsShell: true },
        { id: "slow", name: "Slow", kind: "cli", description: "", needsShell: true },
        { id: "noexec", name: "No exec", kind: "cli", description: "", needsShell: true },
        { id: "absent", name: "Absent", kind: "cli", description: "", needsShell: true },
        { id: "aliased", name: "Aliased", kind: "cli", description: "", binary: "foo", versionArgs: [], needsShell: false },
        { id: "lightpanda", name: "Lightpanda", kind: "cli", description: "", binary: join(bin, "foo"), needsShell: true },
        { id: "counted", name: "Counted", kind: "cli", description: "", needsShell: true },
        { id: "Bad Id", name: "Bad", kind: "cli", description: "", needsShell: true },
      ]),
    );
  });
  afterAll(() => rmSync(root, { recursive: true, force: true }));

  test("resolves binaries on the given PATH, probes versions and adds MCP servers and skills", async () => {
    const d = new MachineToolDiscovery({ catalogPath, path: `${join(root, "nope")}:${bin}`, home, versionTimeoutMs: 300 });
    const started = Date.now();
    const tools = await d.list();
    expect(Date.now() - started).toBeLessThan(2000);
    const byId = Object.fromEntries(tools.map((t) => [t.id, t]));
    expect(byId.foo).toMatchObject({ available: true, version: "1.2.3", usage: "foo --run", kind: "cli", needsShell: true });
    expect(byId.errver).toMatchObject({ available: true, version: "0.9.0-beta" });
    expect(byId.slow).toMatchObject({ available: true });
    expect(byId.slow!.version).toBeUndefined();
    expect(byId.noexec!.available).toBe(false);
    expect(byId.absent!.available).toBe(false);
    expect(byId.aliased).toMatchObject({ available: true, needsShell: false });
    expect(byId.aliased!.version).toBeUndefined();
    expect(byId.lightpanda).toMatchObject({ kind: "cli", available: true });
    expect(byId["Bad Id"]).toBeUndefined();

    expect(byId["lightpanda-mcp"]).toMatchObject({ name: "lightpanda", kind: "mcp", needsShell: false, available: true });
    expect(byId["my-server"]).toMatchObject({ name: "My Server", kind: "mcp" });
    expect(byId.hidden).toBeUndefined();
    expect(byId["web-fetch"]).toMatchObject({ kind: "skill", needsShell: true, description: "Fetch web pages. Use when browsing." });
    expect(byId.notes).toMatchObject({ kind: "skill", name: "Notes", needsShell: false, description: "Takes notes in a file." });
    expect(byId.empty).toBeUndefined();

    const order = tools.map((t) => `${t.available ? 1 : 0}:${t.kind}:${t.id}`);
    expect(order).toEqual([
      "1:cli:aliased",
      "1:cli:counted",
      "1:cli:errver",
      "1:cli:foo",
      "1:cli:lightpanda",
      "1:cli:slow",
      "1:mcp:lightpanda-mcp",
      "1:mcp:my-server",
      "1:skill:notes",
      "1:skill:web-fetch",
      "0:cli:absent",
      "0:cli:noexec",
    ]);
  });

  test("results are cached until the TTL expires", async () => {
    const calls = join(root, "calls");
    rmSync(calls, { force: true });
    const d = new MachineToolDiscovery({ catalogPath, path: bin, home, versionTimeoutMs: 300, ttlMs: 60_000 });
    const [a, b] = await Promise.all([d.list(), d.list()]);
    expect(a).toBe(b);
    await d.list();
    expect(await Bun.file(calls).text()).toBe("x\n");

    const expiring = new MachineToolDiscovery({ catalogPath, path: bin, home, versionTimeoutMs: 300, ttlMs: 0 });
    await expiring.list();
    await Bun.sleep(5);
    await expiring.list();
    expect(await Bun.file(calls).text()).toBe("x\nx\nx\n");
  });

  test("a missing catalog and home still work", async () => {
    const d = new MachineToolDiscovery({ catalogPath: join(root, "none.json"), path: bin, home: join(root, "nohome") });
    expect(await d.list()).toEqual([]);
  });

  test("version extraction", () => {
    expect(extractVersion("OpenSSH_9.2p1 Debian-2+deb12u10, OpenSSL 3.0")).toBe("9.2p1");
    expect(extractVersion("\ngh version 2.102.0 (2026-09-30)\nhttps://x")).toBe("2.102.0");
    expect(extractVersion("v0.9.0 (99d957581f61 2026-01-24T19:52:46Z)")).toBe("0.9.0");
    expect(extractVersion("/bin/x: command not found")).toBeUndefined();
  });

  test("frontmatter parsing", () => {
    expect(parseFrontmatter("no frontmatter")).toEqual({});
    expect(parseFrontmatter("---\nname: 'x'\ndescription: \"a: b\"\n---")).toEqual({ name: "x", description: "a: b" });
    expect(parseFrontmatter("---\ndescription: |\n  line one\n\n  line two\nname: y\n---")).toEqual({ description: "line one line two", name: "y" });
  });

  test("sorting puts available first, then kind, then name", () => {
    const sorted = sortMachineTools([
      tool({ id: "z", kind: "skill" }),
      tool({ id: "b", available: false }),
      tool({ id: "m", kind: "mcp" }),
      tool({ id: "a" }),
    ]);
    expect(sorted.map((t) => t.id)).toEqual(["a", "m", "z", "b"]);
  });
});

describe("tag parsing", () => {
  test("finds tags at word boundaries, case-insensitive, deduplicated in order", () => {
    expect(parseToolTags("#gog quels rdv demain ?")).toEqual(["gog"]);
    expect(parseToolTags("avec #NTN et #gog, puis #ntn.")).toEqual(["ntn", "gog"]);
    expect(parseToolTags("(#gh)\n#docker-compose #home_assistant")).toEqual(["gh", "docker-compose", "home_assistant"]);
    expect(parseToolTags("fin de phrase #gog-")).toEqual(["gog"]);
  });

  test("ignores code, URLs, numbers, headings and mid-word hashes", () => {
    expect(parseToolTags("ticket #123 et #42abc")).toEqual([]);
    expect(parseToolTags("lance `#gog` puis\n```\n#ntn\n```")).toEqual([]);
    expect(parseToolTags("voir https://example.com/page#gog et www.site.fr/#ntn")).toEqual([]);
    expect(parseToolTags("# Titre\n## gog\nC#gog a&#gog ##gog x/#gog")).toEqual([]);
    expect(parseToolTags("```\nnon fermé #gog")).toEqual([]);
  });

  test("only known available tools are kept", () => {
    const tools = [tool({ id: "gog" }), tool({ id: "ntn", available: false })];
    expect(taggedTools("#ntn #gog #inconnu", tools).map((t) => t.id)).toEqual(["gog"]);
    expect(taggedTools("rien", tools)).toEqual([]);
  });
});

describe("hint", () => {
  const gog = tool({ id: "gog", name: "Google", usage: "ligne 1\nligne 2" });
  const mcp = tool({ id: "lightpanda", kind: "mcp", needsShell: false, usage: "mcp usage" });

  test("lists usage for auto bots", () => {
    expect(toolHint([gog, mcp], "auto")).toBe(
      "Outils demandés par l'utilisateur pour ce message :\n- gog (Google) : ligne 1\n  ligne 2\n- lightpanda (lightpanda) : mcp usage\nUtilise-les en priorité.\n\n",
    );
    expect(toolHint([], "auto")).toBe("");
  });

  test("shell tools are unavailable to bots without the auto policy", () => {
    const h = toolHint([gog, mcp], "readonly");
    expect(h).toContain("- gog (Google) : indisponible pour ce bot");
    expect(h).toContain("Cobot");
    expect(h).toContain("- lightpanda (lightpanda) : mcp usage");
    expect(h).toContain("Utilise-les en priorité.");
    const only = toolHint([gog], "ask");
    expect(only).toContain("indisponible");
    expect(only).not.toContain("Utilise-les en priorité.");
  });
});

describe("gateway integration", () => {
  let t: TestApp;
  let sock: Socket | undefined;
  afterEach(async () => {
    sock?.close();
    sock = undefined;
    await t?.close();
  });

  const machine = {
    list: async () =>
      sortMachineTools([
        tool({ id: "gog", name: "Google", usage: "gog calendar events" }),
        tool({ id: "lightpanda", kind: "mcp", needsShell: false, usage: "mcp lightpanda" }),
        tool({ id: "gone", available: false }),
      ]),
  };

  async function setup(over: Record<string, unknown> = {}) {
    t = await startTestApp({ machine });
    const bot = (await t.api("POST", "/api/bots", { name: "Voyages" })).data;
    await t.api("PUT", `/api/bots/${bot.id}/draft`, botConfig(over));
    await t.api("POST", `/api/bots/${bot.id}/publish`, {});
    const conv = (await t.api("POST", "/api/conversations", { botId: bot.id })).data;
    sock = await Socket.open(t);
    return { bot, conv, sock };
  }

  test("GET /api/machine/tools needs auth and returns the sorted list", async () => {
    t = await startTestApp({ machine });
    expect((await t.api("GET", "/api/machine/tools", undefined, "")).status).toBe(401);
    const r = await t.api("GET", "/api/machine/tools");
    expect(r.status).toBe(200);
    expect(r.data.map((x: MachineTool) => x.id)).toEqual(["gog", "lightpanda", "gone"]);
  });

  test("a tagged prompt gets the hint for this turn only and history keeps the typed text", async () => {
    const { conv, sock } = await setup({ permissionPolicy: "auto" });
    sock.send({ type: "prompt", conversationId: conv.id, text: "#gog quels rdv demain ?" });
    await sock.next("message.end");
    sock.send({ type: "prompt", conversationId: conv.id, text: "et après ?" });
    await sock.next("message.end");
    const [first, second] = t.runtime.prompts;
    expect(first!.text).toBe(
      "Outils demandés par l'utilisateur pour ce message :\n- gog (Google) : gog calendar events\nUtilise-les en priorité.\n\n#gog quels rdv demain ?",
    );
    expect(second!.text).toBe("et après ?");
    const msgs = (await t.api("GET", `/api/conversations/${conv.id}/messages`)).data;
    expect(msgs[0]).toMatchObject({ role: "user", text: "#gog quels rdv demain ?" });
  });

  test("shell tools are refused to non-auto bots, MCP tools are not", async () => {
    const { conv, sock } = await setup({ permissionPolicy: "readonly" });
    sock.send({ type: "prompt", conversationId: conv.id, text: "#gog #lightpanda #gone vols ?" });
    await sock.next("message.end");
    const text = t.runtime.prompts[0]!.text;
    expect(text).toContain("- gog (Google) : indisponible pour ce bot");
    expect(text).toContain("- lightpanda (lightpanda) : mcp lightpanda");
    expect(text).toEndWith("Utilise-les en priorité.\n\n#gog #lightpanda #gone vols ?");
    expect(text.split("\n").filter((l) => l.startsWith("- "))).toHaveLength(2);
  });

  test("prompt templates of slash commands are scanned too, after the voice prefix", async () => {
    const { conv, sock } = await setup({
      permissionPolicy: "auto",
      commands: [{ name: "agenda", description: "Agenda", action: { type: "prompt", template: "#gog Agenda de {args}" } }],
    });
    sock.send({ type: "prompt", conversationId: conv.id, text: "/agenda demain", voice: true });
    await sock.next("message.end");
    const text = t.runtime.prompts[0]!.text;
    expect(text).toStartWith("[Réponse vocale");
    expect(text).toContain("Outils demandés par l'utilisateur pour ce message :\n- gog (Google)");
    expect(text).toEndWith("#gog Agenda de demain");
    const msgs = (await t.api("GET", `/api/conversations/${conv.id}/messages`)).data;
    expect(msgs[0].text).toBe("/agenda demain");
  });

  test("untagged prompts and a failing source leave the text untouched", async () => {
    t = await startTestApp({ machine: { list: async () => Promise.reject(new Error("boom source")) } });
    const bot = (await t.api("POST", "/api/bots", { name: "Voyages" })).data;
    await t.api("PUT", `/api/bots/${bot.id}/draft`, botConfig({ permissionPolicy: "auto" }));
    await t.api("POST", `/api/bots/${bot.id}/publish`, {});
    const conv = (await t.api("POST", "/api/conversations", { botId: bot.id })).data;
    sock = await Socket.open(t);
    sock.send({ type: "prompt", conversationId: conv.id, text: "#gog salut" });
    await sock.next("message.end");
    expect(t.runtime.prompts[0]!.text).toBe("#gog salut");
  });
});
