import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ModelInfo, PermissionPolicy } from "../../src/protocol";
import { AcpRuntime, resolveOption, type AcpSession, type SpawnSpec, type Status, type Timeouts } from "../../src/agents/acp";
import { parseGrokModels } from "../../src/agents/grok";
import { ClaudeRuntime } from "../../src/agents/claude";
import { LOCAL_HOST } from "../../src/agents/host";
import type { PermissionAsk, RunEvent, SessionOptions, UnpromptedWork } from "../../src/agents/types";
import type { ToolRule } from "../../src/protocol";

const FAKE = join(import.meta.dir, "fake-agent.ts");

class FakeRuntime extends AcpRuntime {
  readonly id = "claude" as const;
  readonly name = "Fake";
  constructor(
    private readonly env: Record<string, string> = {},
    timeouts: Partial<Timeouts> = {},
    private readonly withModes = false,
  ) {
    super();
    this.timeouts = timeouts;
  }
  protected async spawnSpec(): Promise<SpawnSpec> {
    return { command: process.execPath, args: [FAKE], env: this.env };
  }
  protected modeFor(policy: PermissionPolicy): string | undefined {
    return this.withModes && policy === "readonly" ? "read-only" : undefined;
  }
  async status(): Promise<Status> {
    return { available: true, authenticated: true };
  }
  protected async fallbackModels(): Promise<ModelInfo[]> {
    return [];
  }
}

const dirs: string[] = [];
const sessions: AcpSession[] = [];
afterAll(async () => {
  await Promise.all(sessions.map((s) => s.close()));
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

async function start(
  policy: PermissionPolicy = "auto",
  rt: AcpRuntime = new FakeRuntime(),
  extra: Partial<Pick<SessionOptions, "model" | "effort" | "resumeId" | "noTools" | "relay" | "toolRule">> = {},
) {
  const workdir = mkdtempSync(join(tmpdir(), "nuo-acp-test-"));
  dirs.push(workdir);
  const s = (await rt.start({ workdir, mcpServers: [], permissionPolicy: policy, ...extra, model: extra.model ?? "" })) as AcpSession;
  sessions.push(s);
  return s;
}

async function run(s: AcpSession, text: string, ask?: (a: PermissionAsk) => Promise<string>, attachments = []) {
  const events: RunEvent[] = [];
  const result = await s.prompt(text, attachments, (e) => events.push(e), ask ?? (async () => "never"));
  const textOut = events.flatMap((e) => (e.type === "text" ? [e.text] : [])).join("");
  return { result, events, text: textOut };
}

describe("event mapping", () => {
  test("text and thoughts", async () => {
    const s = await start();
    const { result, events, text } = await run(s, "hello");
    expect(result).toEqual({ stopReason: "end_turn" });
    expect(text).toBe("Hello");
    expect(events[0]).toEqual({ type: "thought", text: "thinking" });
  });

  test("tool calls start once and end with their status", async () => {
    const s = await start();
    const { events } = await run(s, "tool");
    const tools = events.filter((e) => e.type.startsWith("tool."));
    expect(tools).toEqual([
      { type: "tool.start", toolCallId: "t1", title: "Read file", kind: "read" },
      { type: "tool.end", toolCallId: "t1", status: "completed" },
      { type: "tool.start", toolCallId: "t2", title: "Run ls", kind: "execute" },
      { type: "tool.end", toolCallId: "t2", status: "failed" },
      { type: "tool.start", toolCallId: "t3", title: "Late tool" },
      { type: "tool.end", toolCallId: "t3", status: "completed" },
    ]);
  });

  test("a shell command's description reaches its step once it changes, never for a tool not yet started", async () => {
    const s = await start();
    const { events } = await run(s, "described-tool");
    expect(events.filter((e) => e.type.startsWith("tool."))).toEqual([
      { type: "tool.start", toolCallId: "d1", title: "Terminal", kind: "execute" },
      { type: "tool.detail", toolCallId: "d1", detail: "Wait for the deploy" },
      { type: "tool.detail", toolCallId: "d1", detail: "Wait for the deploy workflow on main" },
      { type: "tool.end", toolCallId: "d1", status: "completed" },
    ]);
  });

  test("tools left open are closed at the end of the turn", async () => {
    const s = await start();
    const { events } = await run(s, "open-tool");
    expect(events).toEqual([
      { type: "tool.start", toolCallId: "o1", title: "Never ends", kind: "other" },
      { type: "tool.end", toolCallId: "o1", status: "completed" },
    ]);
  });

  test("agent error becomes stopReason error", async () => {
    const s = await start();
    const { result } = await run(s, "error");
    expect(result.stopReason).toBe("error");
    expect(result.error).toContain("model overloaded");
    expect((await run(s, "hello")).text).toBe("Hello");
  });

  test("images are sent as content blocks when supported", async () => {
    const s = await start();
    const { text } = await run(s, "image?", undefined, [{ kind: "image", mime: "image/png", dataBase64: "iVBORw0KGgo=" }] as never);
    expect(text).toBe("images:1 text:none");
  });

  test("images are saved to the workdir when the agent has no image prompts", async () => {
    const s = await start("auto", new FakeRuntime({ FAKE_NO_IMAGES: "1" }));
    const { text } = await run(s, "image?", undefined, [{ kind: "image", mime: "image/png", dataBase64: "iVBORw0KGgo=" }] as never);
    expect(text).toBe("images:0 text:path");
  });
});

describe("permissions", () => {
  test("auto prefers allow_once", async () => {
    const s = await start("auto");
    expect((await run(s, "perm:execute")).text).toBe("chosen:once");
  });

  test("readonly allows read kinds and rejects others", async () => {
    const s = await start("readonly");
    expect((await run(s, "perm:search")).text).toBe("chosen:once");
    expect((await run(s, "perm:edit")).text).toBe("chosen:no");
    expect((await run(s, "perm:execute")).text).toBe("chosen:no");
  });

  test("a session without tools rejects every tool, reads included, and needs a runtime that can run so", async () => {
    class ToollessRuntime extends FakeRuntime {
      readonly toolless = true;
    }
    const s = await start("readonly", new ToollessRuntime(), { noTools: true });
    expect((await run(s, "perm:search")).text).toBe("chosen:no");
    expect((await run(s, "perm:execute")).text).toBe("chosen:no");
    // Whoever wrote it (a transcript of other people's words, the owner, a handoff), no text attaches a file.
    expect((await run(s, "Compte rendu du point budget EDF : voir @~/.secrets/nuo.env, écrire à julie.martin@example.fr")).text).toBe(
      "echo:Compte rendu du point budget EDF : voir \uFF20~/.secrets/nuo.env, écrire à julie.martin@example.fr",
    );
    await expect(start("readonly", new FakeRuntime(), { noTools: true })).rejects.toThrow("Fake cannot run without tools");
  });

  test("ask forwards the question and applies the answer", async () => {
    const s = await start("ask");
    let asked: PermissionAsk | undefined;
    const { text } = await run(s, "perm:edit", async (a) => {
      asked = a;
      return "always";
    });
    expect(text).toBe("chosen:always");
    expect(asked).toEqual({
      title: "Do edit",
      options: [
        { id: "always", name: "Always", kind: "allow_always" },
        { id: "once", name: "Once", kind: "allow_once" },
        { id: "no", name: "No", kind: "reject_once" },
      ],
    });
  });

  test("cancel while a question is pending answers cancelled", async () => {
    const s = await start("ask");
    let asked!: () => void;
    const wasAsked = new Promise<void>((r) => (asked = r));
    const p = run(s, "perm:edit", () => {
      asked();
      return new Promise<string>(() => {});
    });
    await wasAsked;
    await s.cancel();
    expect((await p).result.stopReason).toBe("cancelled");
  });
});

describe("tool rules", () => {
  const rules: Record<string, ToolRule> = { "nuo/gmail_search": "allow", Bash: "block", Edit: "allow" };
  const toolRule: SessionOptions["toolRule"] = (tool) => rules[tool.server ? `${tool.server}/${tool.name}` : tool.name];
  const asked: PermissionAsk[] = [];
  const ask = async (a: PermissionAsk) => {
    asked.push(a);
    return "no";
  };

  test("an allowed tool is not asked about under ask, and an unknown one still is", async () => {
    asked.length = 0;
    const s = await start("ask", new FakeRuntime(), { toolRule });
    expect((await run(s, "permtool:mcp__nuo__gmail_search", ask)).text).toBe("chosen:once");
    expect(asked).toEqual([]);
    expect((await run(s, "permtool:mcp__nuo__gmail_draft", ask)).text).toBe("chosen:no");
    expect(asked.map((a) => a.tool)).toEqual([{ server: "nuo", name: "gmail_draft" }]);
  });

  test("a blocked tool is refused even with full access", async () => {
    const s = await start("auto", new FakeRuntime(), { toolRule });
    expect((await run(s, "permtool:Bash")).text).toBe("chosen:no");
    expect((await run(s, "permtool:mcp__nuo__gmail_draft")).text).toBe("chosen:once");
  });

  test("an allow rule does not widen a read-only bot", async () => {
    const s = await start("readonly", new FakeRuntime(), { toolRule });
    expect((await run(s, "permtool:Edit")).text).toBe("chosen:no");
  });

  test("a call the agent does not name is never decided by a rule", async () => {
    const s = await start("auto", new FakeRuntime(), { toolRule: () => "block" });
    expect((await run(s, "perm:execute")).text).toBe("chosen:once");
  });

  test("a relay session ignores the rules and keeps its whitelist", async () => {
    asked.length = 0;
    const s = await start("ask", new FakeRuntime(), { relay: true, toolRule: () => "allow" });
    expect((await run(s, "permtool:mcp__nuo__apple_event_create", ask)).text).toBe("chosen:no");
    expect(asked.map((a) => a.tool?.name)).toEqual(["apple_event_create"]);
  });
});

describe("cancel and crashes", () => {
  test("cancel ends a running turn", async () => {
    const s = await start();
    const p = run(s, "hang");
    await Bun.sleep(200);
    await s.cancel();
    expect((await p).result).toEqual({ stopReason: "cancelled" });
    expect((await run(s, "hello")).text).toBe("Hello");
  });

  test("an agent ignoring cancel is killed", async () => {
    const s = await start("auto", new FakeRuntime({}, { cancelGraceMs: 300, killGraceMs: 300 }));
    const p = run(s, "deaf");
    await Bun.sleep(200);
    const t0 = Date.now();
    await s.cancel();
    expect((await p).result.stopReason).toBe("cancelled");
    expect(Date.now() - t0).toBeLessThan(3_000);
  });

  test("a long command description is cut before an emoji, not inside it", async () => {
    const s = await start();
    const { events } = await run(s, "described-tool-emoji");
    const detail = events.find((e) => e.type === "tool.detail") as { detail: string };
    expect(detail.detail).toBe("Programme la sortie Z2 de 45 min sur l'Apple Watch de Julie Martin ".repeat(3).slice(0, 199));
    expect(detail.detail.isWellFormed()).toBe(true);
  });

  test("the stderr tail of a crash never starts on half of an emoji", async () => {
    const s = await start();
    const { result } = await run(s, "crash-emoji");
    expect(result.stopReason).toBe("error");
    expect(result.error).toContain(`stderr: ${"x".repeat(1499)}`);
    expect(result.error!.isWellFormed()).toBe(true);
  });

  test("process crash during a prompt reports the stderr tail", async () => {
    const s = await start();
    const { result, text } = await run(s, "crash");
    expect(text).toBe("partial");
    expect(result.stopReason).toBe("error");
    expect(result.error).toContain("code 3");
    expect(result.error).toContain("boom: fatal failure");
    const again = await run(s, "hello");
    expect(again.result.stopReason).toBe("error");
  });

  test("idle timeout cancels a silent turn", async () => {
    const s = await start("auto", new FakeRuntime({}, { promptIdleMs: 300 }));
    const { result } = await run(s, "silent");
    expect(result.stopReason).toBe("error");
    expect(result.error).toContain("no activity");
  });

  test("a second prompt while one is running is refused", async () => {
    const s = await start();
    const p = run(s, "hang");
    await Bun.sleep(100);
    expect((await run(s, "hello")).result.stopReason).toBe("error");
    await s.cancel();
    await p;
  });

  test("start fails cleanly when the binary does not exist", async () => {
    class Missing extends FakeRuntime {
      protected async spawnSpec(): Promise<SpawnSpec> {
        return { command: "/nonexistent/agent-binary", args: [] };
      }
    }
    await expect(start("auto", new Missing())).rejects.toThrow(/cannot start|ENOENT/);
  });
});

describe("models and sessions", () => {
  test("another model keeps the same session, also once resumed", async () => {
    const rt = new FakeRuntime();
    const s = await start("auto", rt, { model: "m-large", effort: "medium" });
    const id = s.agentSessionId;
    await s.setModel("Small 1.0", "low");
    expect(s.agentSessionId).toBe(id);
    expect((await run(s, "model?")).text).toBe("m-small-20250101/low/default");
    await s.close();
    const resumed = await start("auto", rt, { resumeId: id, model: "m-large", effort: "high" });
    expect(resumed.agentSessionId).toBe(id);
    expect((await run(resumed, "model?")).text).toBe("m-large/high/default");
  });

  test("model and effort are applied through config options", async () => {
    const s = await start("auto", new FakeRuntime(), { model: "Small 1.0", effort: "high" });
    expect((await run(s, "model?")).text).toBe("m-small-20250101/high/default");
    await s.setModel("m-large", "low");
    expect((await run(s, "model?")).text).toBe("m-large/low/default");
  });

  test("legacy models use session/set_model with an effort suffix", async () => {
    const s = await start("auto", new FakeRuntime({ FAKE_LEGACY: "1" }), { model: "m-small", effort: "low" });
    expect((await run(s, "model?")).text).toBe("m-small/low/default");
  });

  test("readonly policy switches the agent mode", async () => {
    const s = await start("readonly", new FakeRuntime({}, {}, true));
    expect((await run(s, "model?")).text).toBe("m-large/medium/read-only");
  });

  test("resume loads the previous session without leaking replayed history", async () => {
    const rt = new FakeRuntime();
    const first = await start("auto", rt);
    const id = first.agentSessionId;
    await first.close();
    const s = await start("auto", rt, { resumeId: id });
    expect(s.agentSessionId).toBe(id);
    const { text } = await run(s, "loaded?");
    expect(text).toBe(`loaded:${id}`);
  });

  test("a session that cannot be loaded from the new cwd falls back to a fresh one", async () => {
    const rt = new FakeRuntime({ FAKE_PROJECT_SCOPED: "1" });
    const first = await start("auto", rt);
    const id = first.agentSessionId;
    await first.close();
    const s = await start("auto", rt, { resumeId: id });
    expect(s.agentSessionId).not.toBe(id);
    const { result, events, text } = await run(s, "hello");
    expect(result).toEqual({ stopReason: "end_turn" });
    expect(text).toBe("Hello");
    expect(events.some((e) => e.type === "error")).toBe(false);
  });

  test("models come from config options", async () => {
    const rt = new FakeRuntime();
    expect(await rt.models()).toEqual([
      { id: "m-large", name: "Large 1.0", isDefault: true, efforts: ["low", "medium", "high"] },
      { id: "m-small-20250101", name: "Small 1.0", efforts: ["low", "medium", "high"] },
    ]);
  });

  test("legacy models are grouped by base id", async () => {
    const rt = new FakeRuntime({ FAKE_LEGACY: "1" });
    expect(await rt.models()).toEqual([
      { id: "m-large", name: "m-large", efforts: ["low", "high"] },
      { id: "m-small", name: "m-small", efforts: ["low", "high"] },
    ]);
  });
});

describe("helpers", () => {
  const claudeOptions = [
    { value: "default", name: "Default (recommended)", description: "Opus 5.5" },
    { value: "opus", name: "Opus 5.5" },
    { value: "claude-haiku-4-5-20251001", name: "Haiku 4.5" },
    { value: "claude-sonnet-5", name: "Sonnet 5" },
  ];

  test("resolveOption matches canonical ids, names and dated values", () => {
    expect(resolveOption("claude-opus-5-5", claudeOptions)).toBe("opus");
    expect(resolveOption("claude-haiku-4-5", claudeOptions)).toBe("claude-haiku-4-5-20251001");
    expect(resolveOption("claude-sonnet-5", claudeOptions)).toBe("claude-sonnet-5");
    expect(resolveOption("gpt-9", claudeOptions)).toBeUndefined();
  });

  test("claude agents keep only the bots' tools, found with ToolSearch, without the account's claude.ai connectors", async () => {
    class InspectedClaude extends ClaudeRuntime {
      spec() {
        return this.spawnSpec();
      }
      meta() {
        return this.sessionMeta({ workdir: "/home/julie/nuo/bots/homelab", model: "claude-opus-5-5", mcpServers: [], permissionPolicy: "auto" });
      }
    }
    const host = { ...LOCAL_HOST, which: (name: string) => `/home/linuxbrew/.linuxbrew/bin/${name}` };
    const claude = new InspectedClaude(host);
    const spec = await claude.spec();
    expect(spec.command).toBe("/home/linuxbrew/.linuxbrew/bin/claude-agent-acp");
    const options = (claude.meta() as { claudeCode: { options: { tools: string[]; env: Record<string, string>; settings: Record<string, string>; promptSuggestions: boolean; extraArgs: Record<string, null> } } }).claudeCode.options;
    expect(options.env).toEqual({ ENABLE_TOOL_SEARCH: "true", ENABLE_CLAUDEAI_MCP_SERVERS: "false" });
    expect(options.settings).toEqual({ language: "French" });
    const tutor = (claude as unknown as { sessionMeta(o: unknown): { claudeCode: { options: { settings: Record<string, string> } } } }).sessionMeta({ workdir: "/home/julie/nuo/bots/tutor", model: "claude-opus-5-5", mcpServers: [], permissionPolicy: "auto", language: "English" });
    expect(tutor.claudeCode.options.settings).toEqual({ language: "English" });
    expect(options.tools).toContain("ToolSearch");
    expect(options.promptSuggestions).toBe(false);
    expect(options.extraArgs).toEqual({ "strict-mcp-config": null });
    expect(options.tools).toContain("Bash");
    expect(options.tools).toContain("Monitor");
    expect(options.tools).not.toContain("Workflow");
    expect(options.tools).not.toContain("CronCreate");
  });

  test("claude models get stable canonical ids", () => {
    const rt = new ClaudeRuntime();
    const models = rt.modelsFrom({
      configOptions: [
        { id: "model", name: "Model", category: "model", type: "select", currentValue: "default", options: claudeOptions },
        {
          id: "effort",
          name: "Effort",
          category: "thought_level",
          type: "select",
          currentValue: "high",
          options: [
            { value: "default", name: "Default" },
            { value: "low", name: "Low" },
            { value: "high", name: "High" },
          ],
        },
      ],
    });
    expect(models.map((m) => [m.id, !!m.isDefault])).toEqual([
      ["claude-opus-5-5", true],
      ["claude-haiku-4-5", false],
      ["claude-sonnet-5", false],
    ]);
    expect(models[0]!.efforts).toEqual(["low", "high"]);
  });

  test("grok models output is parsed", () => {
    const out = "You are logged in with grok.com.\nDefault model: grok-4.7\nAvailable models:\n  * grok-4.7 (default)\n  - grok-4.6\n";
    expect(parseGrokModels(out).map((m) => [m.id, !!m.isDefault])).toEqual([
      ["grok-4.7", true],
      ["grok-4.6", false],
    ]);
  });
});

describe("context usage", () => {
  test("usage_update becomes a usage event and the advertised commands are kept", async () => {
    const s = await start();
    expect(s.commands).toContain("compact");
    const { result, events } = await run(s, "usage");
    expect(events.filter((e) => e.type === "usage")).toEqual([{ type: "usage", usedTokens: 42000, maxTokens: 200000 }]);
    expect(result.usage).toBeUndefined();
    expect(s.lastUsage).toEqual({ usedTokens: 42000, maxTokens: 200000 });
  });

  test("prompt response _meta counts are used when no usage_update came", async () => {
    const s = await start();
    const { result } = await run(s, "meta-usage");
    expect(result.usage).toEqual({ usedTokens: 20478 });
  });

  test("native compaction reports before/after tokens", async () => {
    const s = await start();
    const { result, events } = await run(s, "/compact");
    expect(result.stopReason).toBe("end_turn");
    expect(events.find((e) => e.type === "compacted")).toEqual({ type: "compacted", beforeTokens: 25290, afterTokens: 4869 });
    expect(events.filter((e) => e.type === "usage").at(-1)).toEqual({ type: "usage", usedTokens: 4869, maxTokens: 200000 });
  });
});

describe("work the agent does by itself", () => {
  const take = (s: AcpSession) =>
    new Promise<{ events: RunEvent[]; result: Awaited<ReturnType<UnpromptedWork["run"]>> }>((resolve) => {
      s.onUnprompted = (work) => {
        const events: RunEvent[] = [];
        void work.run((e) => events.push(e), async () => "never").then((result) => resolve({ events, result }));
      };
    });

  test("Claude's follow-up after a background command is a turn of its own, closed by the agent", async () => {
    const s = await start();
    const followUp = take(s);
    const first = await run(s, "background");
    expect(first.text).toBe("Je lance la compilation, je reviens quand elle est finie.");
    expect(s.awaitsBackground).toBe(true);
    const { events, result } = await followUp;
    expect(result.stopReason).toBe("end_turn");
    expect(events.flatMap((e) => (e.type === "text" ? [e.text] : [])).join("")).toBe("La compilation est terminée : 0 erreur.");
    expect(events.filter((e) => e.type === "tool.start").map((e) => (e as { title: string }).title)).toEqual(["Read build output"]);
    expect(events.some((e) => e.type === "usage")).toBe(true);
    expect(s.awaitsBackground).toBe(false);
    // The session takes prompts again.
    expect((await run(s, "hello")).text).toBe("Hello");
  });

  test("without an end from the agent, the follow-up ends after a quiet stretch", async () => {
    const s = await start("auto", new FakeRuntime({}, { unpromptedIdleMs: 200 }));
    const followUp = take(s);
    await run(s, "background-quiet");
    const { events, result } = await followUp;
    expect(result.stopReason).toBe("end_turn");
    expect(events.some((e) => e.type === "text" && e.text.includes("0 erreur"))).toBe(true);
  });

  test("a prompt takes the follow-up over, and a cancel ends it", async () => {
    const s = await start("auto", new FakeRuntime({}, { unpromptedIdleMs: 60_000 }));
    const followUp = take(s);
    await run(s, "background-quiet");
    await Bun.sleep(300);
    expect((await run(s, "hello")).text).toBe("Hello");
    expect((await followUp).result.stopReason).toBe("end_turn");

    const again = take(s);
    await run(s, "background-quiet");
    await Bun.sleep(300);
    await s.cancel();
    expect((await again).result.stopReason).toBe("cancelled");
  });

  test("without a taker, updates outside a turn are dropped as before", async () => {
    const s = await start();
    await run(s, "background");
    await Bun.sleep(300);
    expect((await run(s, "hello")).text).toBe("Hello");
  });
});

describe("Claude's subagents", () => {
  test("the mission and the answer of a subagent come with it", async () => {
    const s = await start();
    const { events } = await run(s, "delegate");
    const sub = events.filter((e): e is Extract<RunEvent, { type: "subagent" }> => e.type === "subagent" && e.id === "child-1");
    expect(sub.find((e) => e.description)?.description).toBe("Compte les fichiers de /etc/systemd");
    expect(sub.find((e) => e.result)?.result).toBe("Il y a 12 fichiers dans /etc/systemd.");
    expect(sub.at(-1)?.state).toBe("completed");
    expect(events.some((e) => e.type === "subagent.tool" && e.title === "find /etc/systemd -type f")).toBe(true);
  });

  test("a report handed back wins over the tool result that points at it, and is not a step", async () => {
    const s = await start();
    const { events } = await run(s, "delegate handback");
    const results = events.flatMap((e) => (e.type === "subagent" && e.result ? [e.result] : []));
    expect(results.at(-1)).toBe("Rapport : 12 fichiers, dont 3 timers.");
    expect(results).not.toContain("This agent's report was delivered to you as a message.");
    expect(events.some((e) => e.type === "subagent.tool" && e.toolCallId === "hb-1")).toBe(false);
  });

  test("without the handback, its copy in the launching call's result is taken", async () => {
    const s = await start();
    const { events } = await run(s, "delegate meta");
    const results = events.flatMap((e) => (e.type === "subagent" && e.result ? [e.result] : []));
    expect(results.at(-1)).toBe("Rapport : 12 fichiers, copie du résultat.");
  });
});
