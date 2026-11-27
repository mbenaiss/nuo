import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AntigravityRuntime, agyArgs, parseAgyModels } from "../../src/agents/antigravity";
import { LOCAL_HOST, type AgentHost } from "../../src/agents/host";
import type { PermissionPolicy } from "../../src/protocol";
import type { AgentSession, RunEvent } from "../../src/agents/types";

const FAKE = join(import.meta.dir, "fake-agy.ts");
const dirs: string[] = [];
afterAll(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

function tempDir() {
  const d = mkdtempSync(join(tmpdir(), "nuo-agy-test-"));
  dirs.push(d);
  return d;
}

function fakeHost(argsFile: string): AgentHost {
  return {
    ...LOCAL_HOST,
    which: (name) => (name === "agy" ? "agy" : null),
    spawn: (_command, args, o) => LOCAL_HOST.spawn(process.execPath, [FAKE, ...args], { ...o, env: { ...o.env, FAKE_AGY_ARGS: argsFile } }),
  };
}

async function start(policy: PermissionPolicy = "auto", extra: { model?: string; effort?: string; resumeId?: string } = {}) {
  const dir = tempDir();
  const argsFile = join(dir, "args.ndjson");
  const rt = new AntigravityRuntime(fakeHost(argsFile), { promptIdleMs: 500, killGraceMs: 200 });
  const session = await rt.start({ workdir: dir, model: extra.model ?? "", effort: extra.effort, mcpServers: [], permissionPolicy: policy, resumeId: extra.resumeId });
  const calls = () =>
    readFileSync(argsFile, "utf8")
      .trim()
      .split("\n")
      .map((l) => JSON.parse(l) as string[]);
  return { session, calls };
}

async function run(s: AgentSession, text: string) {
  const events: RunEvent[] = [];
  const result = await s.prompt(text, [], (e) => events.push(e), async () => "never");
  return { result, events, text: events.flatMap((e) => (e.type === "text" ? [e.text] : [])).join("") };
}

describe("agyArgs", () => {
  test("maps policy, model, effort and resume", () => {
    expect(agyArgs({ prompt: "-hi", model: "gemini-3.1-pro", effort: "high", policy: "auto", conversationId: "c1" })).toEqual([
      "--print", "-hi", "--output-format", "stream-json", "--conversation", "c1", "--model", "gemini-3.1-pro", "--effort", "high", "--dangerously-skip-permissions",
    ]);
    expect(agyArgs({ prompt: "x", policy: "readonly" })).toEqual(["--print", "x", "--output-format", "stream-json"]);
    expect(agyArgs({ prompt: "x", policy: "ask", model: "gemini-4-argon-low", effort: "high" })).not.toContain("--effort");
  });
});

describe("parseAgyModels", () => {
  test("groups effort variants under their base slug", () => {
    const out = "gemini-3.1-pro-low\tGemini 3.1 Pro (Low)\ngemini-3.1-pro-high\tGemini 3.1 Pro (High)\nclaude-sonnet-4-6\tClaude Sonnet 4.6 (Thinking)\n";
    expect(parseAgyModels(out)).toEqual([
      { id: "gemini-3.1-pro", name: "Gemini 3.1 Pro", efforts: ["low", "high"], isDefault: true },
      { id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6 (Thinking)" },
    ]);
  });

  test("accepts a JSON list", () => {
    expect(parseAgyModels(JSON.stringify([{ id: "gpt-oss-120b", display_name: "GPT-OSS 120B" }]))).toEqual([{ id: "gpt-oss-120b", name: "GPT-OSS 120B", isDefault: true }]);
  });
});

describe("AntigravitySession", () => {
  test("streams text, reports context usage and learns the conversation id", async () => {
    const { session, calls } = await start("auto", { model: "claude-opus-5-5", effort: "max" });
    expect(session.agentSessionId).toBe("");
    const { result, events, text } = await run(session, "hello");
    expect(text).toBe("Hello");
    expect(events.filter((e) => e.type === "usage")).toEqual([{ type: "usage", usedTokens: 1020, maxTokens: 200_000 }]);
    expect(result).toEqual({ stopReason: "end_turn", usage: { usedTokens: 1020, maxTokens: 200_000 } });
    expect(session.agentSessionId).toBe("conv-1");
    await run(session, "again");
    const [first, second] = calls();
    expect(first).not.toContain("--conversation");
    expect(first).toContain("--dangerously-skip-permissions");
    expect(second!.slice(second!.indexOf("--conversation"), second!.indexOf("--conversation") + 2)).toEqual(["--conversation", "conv-1"]);
  });

  test("resumes a stored conversation and applies a new model on the next prompt", async () => {
    const { session, calls } = await start("readonly", { resumeId: "conv-9" });
    await session.setModel("gemini-3.8-flash", "low");
    await run(session, "hello");
    const [args] = calls();
    expect(args).toContain("conv-9");
    expect(args!.slice(args!.indexOf("--model"), args!.indexOf("--model") + 4)).toEqual(["--model", "gemini-3.8-flash", "--effort", "low"]);
    expect(args).not.toContain("--dangerously-skip-permissions");
  });

  test("tool steps start once and end with their status", async () => {
    const { session } = await start();
    const { events } = await run(session, "tool");
    expect(events.filter((e) => e.type.startsWith("tool."))).toEqual([
      { type: "tool.start", toolCallId: "t1-1", title: "run_command: ls", kind: "execute" },
      { type: "tool.end", toolCallId: "t1-1", status: "completed" },
      { type: "tool.start", toolCallId: "t1-2", title: "view_file: /x", kind: "read" },
      { type: "tool.end", toolCallId: "t1-2", status: "failed" },
    ]);
  });

  test("a long command in a step title is cut before an emoji, not inside it", async () => {
    const { session } = await start();
    const { events } = await run(session, "long-command");
    const title = (events.find((e) => e.type === "tool.start") as { title: string }).title;
    expect(title).toBe(`run_command: ${"grep -rn 'Sortie Z2' ~/Documents/entrainements/2026/novembre/ | sort ".padEnd(76, "-")}…`);
    expect(title.isWellFormed()).toBe(true);
  });

  test("errors carry the result error or stderr", async () => {
    const { session } = await start();
    const failed = await run(session, "fail");
    expect(failed.result.stopReason).toBe("error");
    expect(failed.result.error).toContain("quota exceeded");
    const auth = await run(session, "auth");
    expect(auth.result.stopReason).toBe("error");
    expect(auth.result.error).toContain("authentication required");
  });

  test("a response only present in the result is still delivered", async () => {
    const { session } = await start();
    const { result, text } = await run(session, "silent");
    expect(result.stopReason).toBe("end_turn");
    expect(text).toBe("Only in result");
  });

  test("cancel kills the process and idle prompts time out", async () => {
    const { session } = await start();
    const pending = run(session, "hang");
    await Bun.sleep(150);
    await session.cancel();
    expect((await pending).result.stopReason).toBe("cancelled");
    const idle = await run(session, "hang");
    expect(idle.result.stopReason).toBe("error");
    expect(idle.result.error).toContain("no activity");
  });
});
