import { afterEach, describe, expect, test } from "bun:test";
import { ClaudeRuntime } from "../src/agents/claude";
import { LOCAL_HOST } from "../src/agents/host";
import type { SessionOptions } from "../src/agents/types";
import type { MachineTool } from "../src/protocol";
import { botConfig, FakeRuntime, Socket, startTestApp, type TestApp } from "./helpers";

let t: TestApp | undefined;
let sock: Socket | undefined;
afterEach(async () => {
  sock?.close();
  sock = undefined;
  await t?.close();
  t = undefined;
});

/** The bot that writes the meeting notes, as an app that does not know `noTools` sends it. */
const notesBot = (over: Record<string, unknown> = {}) =>
  botConfig({
    name: "Comptes rendus",
    instructions: "Tu rédiges le compte rendu d'une réunion à partir de sa transcription.",
    toolServers: [],
    permissionPolicy: "readonly",
    ...over,
  });

describe("a bot without any tool", () => {
  async function published() {
    const b = (await t!.api("POST", "/api/bots", { name: "Comptes rendus" })).data;
    await t!.api("PUT", `/api/bots/${b.id}/draft`, notesBot());
    expect((await t!.api("POST", `/api/bots/${b.id}/publish`, {})).status).toBe(200);
    return b as { id: string };
  }
  const setNoTools = (id: string, noTools: unknown) => t!.api("PUT", `/api/bots/${id}/no-tools`, { noTools });

  test("only its own route turns it on or off, on the published version and the draft alike", async () => {
    t = await startTestApp();
    const b = await published();
    await t.api("PUT", `/api/bots/${b.id}/draft`, notesBot({ instructions: "Compte rendu en cinq sections, sans rien inventer." }));
    const on = await setNoTools(b.id, true);
    expect(on.status).toBe(200);
    expect(on.data.published.config.noTools).toBe(true);
    expect(on.data.published.config.instructions).toBe("Tu rédiges le compte rendu d'une réunion à partir de sa transcription.");
    expect(on.data.draft).toMatchObject({ noTools: true, instructions: "Compte rendu en cinq sections, sans rien inventer." });
    expect((await t.api("GET", `/api/bots/${b.id}/versions`)).data[0].note).toBe("Sans outil : oui");

    // An app that does not know the field, or sends it, keeps it as it is.
    expect((await t.api("PUT", `/api/bots/${b.id}/draft`, notesBot())).data.draft.noTools).toBe(true);
    expect((await t.api("PUT", `/api/bots/${b.id}/draft`, notesBot({ noTools: false }))).data.draft.noTools).toBe(true);
    expect((await t.api("POST", `/api/bots/${b.id}/publish`, {})).data.published.config.noTools).toBe(true);
    expect((await t.api("POST", `/api/bots/${b.id}/rollback`, { version: 1 })).data.published.config.noTools).toBe(true);

    const off = await setNoTools(b.id, false);
    expect(off.data.published.config.noTools).toBeUndefined();
    expect((await t.api("PUT", `/api/bots/${b.id}/draft`, notesBot({ noTools: true }))).data.draft.noTools).toBeUndefined();
  });

  test("it refuses what would give the bot a tool", async () => {
    t = await startTestApp({ extraRuntimes: [new FakeRuntime("codex", "Codex")] });
    const b = await published();
    expect((await setNoTools(b.id, "oui")).data.error).toContain("noTools must be a boolean");
    const refused = async (over: Record<string, unknown>) => {
      await t!.api("PUT", `/api/bots/${b.id}/draft`, notesBot(over));
      const r = await setNoTools(b.id, true);
      await t!.api("DELETE", `/api/bots/${b.id}/draft`);
      return r.data.error as string;
    };
    expect(await refused({ toolServers: ["travel"] })).toContain("cannot have toolServers");
    expect(await refused({ overview: true })).toContain("cannot see every bot");
    expect(await refused({ commands: [{ name: "colis", description: "Colis en cours", action: { type: "tool", server: "nuo", tool: "parcel_list" } }] })).toContain(
      "cannot have tool commands",
    );
    expect(await refused({ agent: "codex" })).toContain("Codex cannot run without tools");
    expect((await t.api("GET", `/api/bots/${b.id}`)).data.published.config.noTools).toBeUndefined();

    expect((await setNoTools(b.id, true)).status).toBe(200);
    expect((await t.api("PUT", `/api/bots/${b.id}/draft`, notesBot({ toolServers: ["travel"] }))).data.error).toContain("cannot have toolServers");
  });

  test("extension tokens cannot change it", async () => {
    t = await startTestApp();
    const b = await published();
    for (const scope of ["share", "watch"]) expect((await t.api("PUT", `/api/bots/${b.id}/no-tools`, { noTools: false }, t.device.extensionTokens[scope]!.token)).status).toBe(403);
  });

  async function notes(browserMcp?: { name: string; command: string; args: string[]; env: Record<string, string> }) {
    const gog: MachineTool = { id: "gog", name: "Google", kind: "cli", description: "Agenda et mails", usage: "gog calendar events", needsShell: true, available: true };
    t = await startTestApp({ browserMcp, extraRuntimes: [new FakeRuntime("codex", "Codex")], machine: { list: async () => [gog] } });
    const b = await published();
    expect((await setNoTools(b.id, true)).status).toBe(200);
    const conv = (await t.api("POST", "/api/conversations", { botId: b.id })).data;
    sock = await Socket.open(t);
    return { bot: b, conv, sock };
  }

  test("its session has no MCP server, not even nuo nor the browser, and runs without tools", async () => {
    const { conv, sock } = await notes({ name: "lightpanda", command: "/home/julie/.local/bin/lightpanda", args: ["mcp"], env: {} });
    sock.send({ type: "prompt", conversationId: conv.id, text: "Rédige le compte rendu du point budget EDF du 12 novembre." });
    await sock.next("message.end");
    const opts = t!.runtime.starts[0]!;
    expect(opts.mcpServers).toEqual([]);
    expect(opts.noTools).toBe(true);
  });

  test("a slash from the owner too reaches it as text, not as one of Claude Code's commands", async () => {
    const { conv, sock } = await notes();
    sock.send({ type: "prompt", conversationId: conv.id, text: "/fiche-client Julie Martin" });
    await sock.next("message.end");
    expect(t!.runtime.prompts[0]!.text).toBe("\uFF0Ffiche-client Julie Martin");
  });

  test("a tagged machine tool adds no hint for it", async () => {
    const { conv, sock } = await notes();
    sock.send({ type: "prompt", conversationId: conv.id, text: "#gog compte rendu du point budget EDF du 12 novembre" });
    await sock.next("message.end");
    expect(t!.runtime.prompts[0]!.text).toBe("#gog compte rendu du point budget EDF du 12 novembre");
  });

  test("a conversation moved to an agent that keeps its own tools is refused", async () => {
    const { conv, sock } = await notes();
    sock.send({ type: "prompt", conversationId: conv.id, text: "Rédige le compte rendu du point budget EDF du 12 novembre.", agent: "codex" });
    expect((await sock.next("error")).message).toContain("ce bot n'a aucun outil");
    expect((await sock.next("message.end")).stopReason).toBe("error");
    expect(t!.runtime.starts).toHaveLength(0);
  });

  test("Claude gets no built-in tool and keeps its instructions file", () => {
    class InspectedClaude extends ClaudeRuntime {
      meta(opts: Partial<SessionOptions>) {
        return (this.sessionMeta({ workdir: "/home/julie/nuo/bots/comptes-rendus", model: "claude-opus-5-5", mcpServers: [], permissionPolicy: "readonly", ...opts }) as {
          claudeCode: { options: { tools: string[]; extraArgs: Record<string, string | null> } };
        }).claudeCode.options;
      }
    }
    const claude = new InspectedClaude({ ...LOCAL_HOST, which: (name: string) => `/home/linuxbrew/.linuxbrew/bin/${name}` });
    const none = claude.meta({ noTools: true });
    expect(none.tools).toEqual([]);
    // A deny rule on reads would stop the mentions, and the loading of CLAUDE.md with them.
    expect(none.extraArgs).toEqual({ "strict-mcp-config": null });
    expect(claude.meta({}).tools).toContain("ToolSearch");
    expect(claude.toolless).toBe(true);
  });
});
