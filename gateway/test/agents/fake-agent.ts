// Minimal ACP agent driven by the prompt text, used by the runtime tests.
import * as acp from "@agentclientprotocol/sdk";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Readable, Writable } from "node:stream";

const legacy = process.env.FAKE_LEGACY === "1";
const images = process.env.FAKE_NO_IMAGES !== "1";
// Like Claude Code, which keeps sessions per project folder: a session can only be loaded from the cwd that created it.
const projectScoped = process.env.FAKE_PROJECT_SCOPED === "1";
const marker = (cwd: string, id: string) => join(cwd, ".fake-sessions", id);

let model = "m-large";
let effort = "medium";
let mode = "default";
const loaded: string[] = [];
const sessions = new Set<string>();
let pending: AbortController | null = null;

function configOptions(): acp.SessionConfigOption[] {
  return [
    {
      id: "mode",
      name: "Mode",
      category: "mode",
      type: "select",
      currentValue: mode,
      options: [
        { value: "default", name: "Default" },
        { value: "read-only", name: "Read only" },
      ],
    },
    {
      id: "model",
      name: "Model",
      category: "model",
      type: "select",
      currentValue: model,
      options: [
        { value: "m-large", name: "Large 1.0" },
        { value: "m-small-20250101", name: "Small 1.0" },
      ],
    },
    {
      id: "effort",
      name: "Effort",
      category: "thought_level",
      type: "select",
      currentValue: effort,
      options: [
        { value: "low", name: "Low" },
        { value: "medium", name: "Medium" },
        { value: "high", name: "High" },
      ],
    },
  ];
}

function sessionState() {
  if (legacy) {
    return {
      models: {
        currentModelId: `${model}[${effort}]`,
        availableModels: ["m-large", "m-small"].flatMap((m) =>
          ["low", "high"].map((e) => ({ modelId: `${m}[${e}]`, name: `${m} (${e})` })),
        ),
      },
    };
  }
  return { configOptions: configOptions() };
}

const sleep = (ms: number, signal?: AbortSignal) =>
  new Promise<void>((resolve, reject) => {
    const t = setTimeout(resolve, ms);
    signal?.addEventListener("abort", () => {
      clearTimeout(t);
      reject(new Error("aborted"));
    });
  });

acp
  .agent({ name: "fake-agent" })
  .onRequest("initialize", () => ({
    protocolVersion: acp.PROTOCOL_VERSION,
    agentCapabilities: { loadSession: true, promptCapabilities: { image: images } },
  }))
  .onRequest("session/new", async (ctx) => {
    const sessionId = crypto.randomUUID();
    sessions.add(sessionId);
    if (projectScoped) {
      mkdirSync(join(ctx.params.cwd, ".fake-sessions"), { recursive: true });
      writeFileSync(marker(ctx.params.cwd, sessionId), "");
    }
    // Like grok, announces commands before session/new returns.
    await ctx.client.notify("session/update", {
      sessionId,
      update: { sessionUpdate: "available_commands_update", availableCommands: [{ name: "compact", description: "Compact" }] },
    });
    return { sessionId, ...sessionState() };
  })
  .onRequest("session/load", async (ctx) => {
    if (projectScoped && !existsSync(marker(ctx.params.cwd, ctx.params.sessionId))) {
      throw acp.RequestError.resourceNotFound(ctx.params.sessionId);
    }
    sessions.add(ctx.params.sessionId);
    loaded.push(ctx.params.sessionId);
    // Replayed history must not leak into the next prompt's events.
    await ctx.client.notify("session/update", {
      sessionId: ctx.params.sessionId,
      update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "REPLAYED" } },
    });
    return sessionState();
  })
  .onRequest("session/set_config_option", (ctx) => {
    const p = ctx.params as { configId: string; value: string };
    if (p.configId === "model") model = p.value;
    if (p.configId === "effort") effort = p.value;
    if (p.configId === "mode") mode = p.value;
    return { configOptions: configOptions() };
  })
  .onRequest("session/set_model", (p: unknown) => p as { modelId: string }, (ctx) => {
    const m = /^(.*)\[(.*)\]$/.exec(ctx.params.modelId);
    if (m) {
      model = m[1]!;
      effort = m[2]!;
    }
    return {};
  })
  .onNotification("session/cancel", () => pending?.abort())
  .onRequest("session/prompt", async (ctx) => {
    const { sessionId } = ctx.params;
    if (!sessions.has(sessionId)) throw acp.RequestError.invalidParams(undefined, "unknown session");
    const text = ctx.params.prompt.map((b) => (b.type === "text" ? b.text : "")).join("");
    const imageCount = ctx.params.prompt.filter((b) => b.type === "image").length;
    const send = (update: acp.SessionUpdate) => ctx.client.notify("session/update", { sessionId, update });
    const say = (t: string) => send({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: t } });
    pending = new AbortController();
    const signal = pending.signal;
    const cmd = text.split("\n")[0]!;

    if (cmd === "hello") {
      await send({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "thinking" } });
      await say("Hel");
      await say("lo");
    } else if (cmd === "tool") {
      await send({ sessionUpdate: "tool_call", toolCallId: "t1", title: "Read file", kind: "read", status: "pending" });
      await send({ sessionUpdate: "tool_call", toolCallId: "t1", title: "Read file", kind: "read", status: "in_progress" });
      await send({ sessionUpdate: "tool_call_update", toolCallId: "t1", status: "completed" });
      await send({ sessionUpdate: "tool_call", toolCallId: "t2", title: "Run ls", kind: "execute", status: "pending" });
      await send({ sessionUpdate: "tool_call_update", toolCallId: "t2", status: "failed" });
      await send({ sessionUpdate: "tool_call_update", toolCallId: "t3", title: "Late tool", status: "completed" });
      await say("done");
    } else if (cmd === "described-tool") {
      // Claude streams a shell command's input: its description shows up partial, then whole, then repeated.
      await send({ sessionUpdate: "tool_call", toolCallId: "d1", title: "Terminal", kind: "execute", status: "pending", rawInput: {} });
      await send({ sessionUpdate: "tool_call_update", toolCallId: "d1", rawInput: { command: "gh run watch", description: "Wait for the deploy" } });
      await send({ sessionUpdate: "tool_call_update", toolCallId: "d1", rawInput: { command: "gh run watch", description: "Wait for the deploy workflow on main" } });
      await send({ sessionUpdate: "tool_call_update", toolCallId: "d1", status: "completed", rawInput: { command: "gh run watch", description: "Wait for the deploy workflow on main" } });
      await send({ sessionUpdate: "tool_call_update", toolCallId: "d2", rawInput: { description: "Not started yet" } });
    } else if (cmd === "described-tool-emoji") {
      // 199 characters, then a runner emoji whose two halves sit on either side of the 200-character cut.
      const description = `${"Programme la sortie Z2 de 45 min sur l'Apple Watch de Julie Martin ".repeat(3).slice(0, 199)}🏃 puis vérifie`;
      await send({ sessionUpdate: "tool_call", toolCallId: "d1", title: "Terminal", kind: "execute", status: "pending", rawInput: {} });
      await send({ sessionUpdate: "tool_call_update", toolCallId: "d1", status: "completed", rawInput: { command: "workout_schedule", description } });
    } else if (cmd === "open-tool") {
      await send({ sessionUpdate: "tool_call", toolCallId: "o1", title: "Never ends", kind: "other", status: "in_progress" });
    } else if (cmd.startsWith("perm:") || cmd.startsWith("permtool:")) {
      // permtool:<Claude tool name> names the tool like Claude Code does (`Bash`, `mcp__nuo__gmail_search`).
      const named = cmd.startsWith("permtool:") ? cmd.slice(9) : undefined;
      const kind = (named ? (named.startsWith("mcp__") ? "other" : "execute") : cmd.slice(5)) as acp.ToolKind;
      const toolCall = {
        toolCallId: "p1",
        title: named ?? `Do ${kind}`,
        kind,
        status: "pending" as const,
        ...(named ? { _meta: { claudeCode: { toolName: named } } } : {}),
      };
      await send({ sessionUpdate: "tool_call", ...toolCall });
      const r: acp.RequestPermissionResponse = await ctx.client.request("session/request_permission", {
        sessionId,
        toolCall,
        options: [
          { optionId: "always", name: "Always", kind: "allow_always" },
          { optionId: "once", name: "Once", kind: "allow_once" },
          { optionId: "no", name: "No", kind: "reject_once" },
        ],
      });
      const chosen = r.outcome.outcome === "selected" ? r.outcome.optionId : "cancelled";
      await send({ sessionUpdate: "tool_call_update", toolCallId: "p1", status: chosen === "no" || chosen === "cancelled" ? "failed" : "completed" });
      if (signal.aborted) return { stopReason: "cancelled" };
      await say(`chosen:${chosen}`);
    } else if (cmd === "hang") {
      try {
        await sleep(60_000, signal);
      } catch {
        return { stopReason: "cancelled" };
      }
    } else if (cmd === "deaf") {
      await sleep(60_000);
    } else if (cmd === "silent") {
      await sleep(60_000, signal).catch(() => {});
      return { stopReason: "cancelled" };
    } else if (cmd === "crash-emoji") {
      // The last 1500 characters start on the second half of the runner emoji.
      process.stderr.write(`séance 🏃${"x".repeat(1499)}`);
      process.exit(3);
    } else if (cmd === "crash") {
      await say("partial");
      process.stderr.write("boom: fatal failure in fake agent\n");
      process.exit(3);
    } else if (cmd === "model?") {
      await say(`${model}/${effort}/${mode}`);
    } else if (cmd === "image?") {
      await say(`images:${imageCount} text:${text.includes("saved at:") ? "path" : "none"}`);
    } else if (cmd === "loaded?") {
      await say(`loaded:${loaded.join(",")}`);
    } else if (cmd === "usage") {
      await send({ sessionUpdate: "usage_update", used: 42000, size: 200000 } as acp.SessionUpdate);
      await say("counted");
    } else if (cmd === "meta-usage") {
      await say("grok-like");
      return { stopReason: "end_turn", _meta: { totalTokens: 20485, inputTokens: 20454, outputTokens: 24 } };
    } else if (cmd === "/compact") {
      await send({ sessionUpdate: "tool_call", toolCallId: "c1", title: "Compact conversation", kind: "think", status: "in_progress" });
      await send({ sessionUpdate: "tool_call_update", toolCallId: "c1", status: "completed" });
      await send({ sessionUpdate: "tool_call_update", toolCallId: "c1", rawOutput: { trigger: "manual", preTokens: 25290, postTokens: 4869 } });
      await send({ sessionUpdate: "usage_update", used: 4869, size: 200000 } as acp.SessionUpdate);
      return { stopReason: "end_turn", usage: { totalTokens: 0, inputTokens: 0, outputTokens: 0 } };
    } else if (cmd === "background" || cmd === "background-quiet") {
      // Claude backgrounds a command, ends its turn, and comes back by itself once the command finished.
      await send({ sessionUpdate: "tool_call", toolCallId: "bg1", title: "bun run build", kind: "execute", status: "completed", rawInput: { command: "bun run build", run_in_background: true } });
      await say("Je lance la compilation, je reviens quand elle est finie.");
      setTimeout(async () => {
        await send({ sessionUpdate: "tool_call", toolCallId: "bg2", title: "Read build output", kind: "read", status: "in_progress" });
        await send({ sessionUpdate: "tool_call_update", toolCallId: "bg2", status: "completed" });
        await say("La compilation est terminée : 0 erreur.");
        if (cmd === "background") {
          await send({ sessionUpdate: "usage_update", used: 51000, size: 200000, _meta: { "_claude/origin": { kind: "task-notification" } } } as acp.SessionUpdate);
        }
      }, 150);
    } else if (cmd.startsWith("delegate")) {
      // Claude's subagents RFD: the mission as a message to the child, the answer as the launching tool call's result.
      const child = "child-1";
      const parent = (update: unknown) => ctx.client.notify("session/update", { sessionId, update: update as acp.SessionUpdate });
      const inChild = (update: unknown) => ctx.client.notify("session/update", { sessionId: child, update: update as acp.SessionUpdate });
      await send({ sessionUpdate: "tool_call", toolCallId: "agent-1", title: "Task", kind: "think", status: "in_progress" });
      await parent({ sessionUpdate: "subagent_update", sessionId: child, title: "Explore", state: { state: "running" } });
      await inChild({ sessionUpdate: "session_message", messageId: "agent-1", recipientSessionId: child, content: [{ type: "text", text: "Compte les fichiers de /etc/systemd" }] });
      await inChild({ sessionUpdate: "tool_call", toolCallId: "c1", title: "find /etc/systemd -type f", kind: "search", status: "completed" });
      await send({ sessionUpdate: "tool_call_update", toolCallId: "agent-1", status: "completed", content: [{ type: "content", content: { type: "text", text: "Il y a 12 fichiers dans /etc/systemd." } }] });
      if (text.includes("handback")) {
        // Claude Code 2.x: the subagent hands its report back with a tool call; the launching call's result points at it.
        const handback = { _meta: { claudeCode: { toolName: "SubagentHandback", parentToolUseId: "agent-1" } }, toolCallId: "hb-1", title: "SubagentHandback" };
        await inChild({ sessionUpdate: "tool_call", ...handback, kind: "other", status: "in_progress", rawInput: { message: "Rapport : 12 fichiers, dont 3 timers." } });
        await inChild({ sessionUpdate: "tool_call_update", ...handback, status: "completed" });
        await send({ sessionUpdate: "tool_call_update", toolCallId: "agent-1", status: "completed", content: [{ type: "content", content: { type: "text", text: "This agent's report was delivered to you as a message." } }] });
      }
      if (text.includes("meta")) {
        // Its copy in the launching call's result, when the handback itself was not seen.
        await send({ sessionUpdate: "tool_call_update", toolCallId: "agent-1", status: "completed", _meta: { claudeCode: { toolName: "Agent", toolResponse: { handbackReport: { text: "Rapport : 12 fichiers, copie du résultat." } } } }, content: [{ type: "content", content: { type: "text", text: "This agent's report was delivered to you as a message." } }] } as acp.SessionUpdate);
      }
      await parent({ sessionUpdate: "subagent_update", sessionId: child, state: { state: "idle", stopReason: "end_turn" } });
      await say("12 fichiers.");
    } else if (cmd === "error") {
      throw acp.RequestError.internalError(undefined, "model overloaded");
    } else {
      await say(`echo:${text}`);
    }
    return { stopReason: "end_turn" };
  })
  .connect(acp.ndJsonStream(Writable.toWeb(process.stdout) as WritableStream<Uint8Array>, Readable.toWeb(process.stdin) as unknown as ReadableStream<Uint8Array>));
