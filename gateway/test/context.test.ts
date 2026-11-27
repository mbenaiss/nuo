import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  compactionFromRawOutput,
  contextWindow,
  estimateConversationTokens,
  estimateTokens,
  HANDOFF_DELTA_PREFIX,
  HANDOFF_FULL_PREFIX,
  HANDOFF_MESSAGE_MAX_CHARS,
  handoffTranscript,
  noticeLine,
  usageFromPromptResponse,
  usageFromUpdate,
} from "../src/agents/context";
import type { Message } from "../src/protocol";
import { AUTO_COMPACT_RATIO, SEED_PREFIX, shouldAutoCompact, SUMMARY_PROMPT } from "../src/runner/runner";
import { preview } from "../src/store/store";
import { botConfig, Socket, startTestApp, type TestApp } from "./helpers";

describe("handoff transcript", () => {
  const msg = (role: Message["role"], text: string, extra: Partial<Message> = {}): Message => ({
    id: crypto.randomUUID(),
    conversationId: "conv-rome",
    role,
    text,
    createdAt: "2026-10-18T08:30:00.000Z",
    ...extra,
  });

  test("labels who spoke, notes attachments and skips notices and empty answers", () => {
    const text = handoffTranscript(
      [
        msg("user", "Voici ma carte d'embarquement", { attachments: [{ kind: "image", mime: "image/jpeg" }, { kind: "file", mime: "application/pdf", name: "billet-AF1084.pdf" }] }),
        msg("assistant", "Vol AF1084, départ 9 h 40 de CDG terminal 2E.", { agent: "claude", model: "claude-opus-5-5" }),
        msg("assistant", noticeLine({ kind: "switched", text: "Passage à Codex · GPT-5.6 Sol", agent: "codex", model: "gpt-5.6-sol" })),
        msg("assistant", "", { agent: "codex", stopReason: "error" }),
      ],
      false,
    );
    expect(text.split("\n")).toEqual([
      HANDOFF_FULL_PREFIX,
      "<historique>",
      "Utilisateur : Voici ma carte d'embarquement [image jointe] [fichier joint : billet-AF1084.pdf]",
      "Assistant (claude · claude-opus-5-5) : Vol AF1084, départ 9 h 40 de CDG terminal 2E.",
      "</historique>",
      "",
      "Nouveau message :",
      "",
    ]);
  });

  test("keeps the newest messages within the budget and cuts long ones", () => {
    const history = Array.from({ length: 30 }, (_, i) => msg(i % 2 ? "assistant" : "user", `Étape ${String(i).padStart(2, "0")} ${"x".repeat(990)}`));
    const text = handoffTranscript(history, true, 5_000);
    expect(text).toStartWith(HANDOFF_DELTA_PREFIX);
    expect(text).toContain("(26 messages plus anciens omis)");
    expect(text).not.toContain("Étape 25");
    expect(text).toContain("Étape 26");
    expect(text).toContain("Étape 29");

    const long = handoffTranscript([msg("assistant", "a".repeat(HANDOFF_MESSAGE_MAX_CHARS + 500), { agent: "grok" })], false);
    expect(long).toContain(`Assistant (grok) : ${"a".repeat(HANDOFF_MESSAGE_MAX_CHARS)} […]`);
  });

  test("a single message larger than the budget is still handed over", () => {
    expect(handoffTranscript([msg("user", "b".repeat(3_000))], false, 1_000)).toContain("Utilisateur : bbb");
    expect(handoffTranscript([], false)).toBe("");
  });
});

describe("usage mapping", () => {
  test("usage_update", () => {
    expect(usageFromUpdate({ used: 25290, size: 1_000_000 })).toEqual({ usedTokens: 25290, maxTokens: 1_000_000 });
    expect(usageFromUpdate({ used: 10, size: 0 })).toEqual({ usedTokens: 10 });
    expect(usageFromUpdate({ size: 10 })).toBeUndefined();
  });

  test("prompt response: grok _meta first, then standard usage, zero means unknown", () => {
    expect(usageFromPromptResponse({ _meta: { totalTokens: 20485, inputTokens: 20454, outputTokens: 24 } })).toEqual({ usedTokens: 20478 });
    expect(usageFromPromptResponse({ _meta: { totalTokens: 0, inputTokens: 20454, outputTokens: 24 } })).toBeUndefined();
    expect(usageFromPromptResponse({ usage: { totalTokens: 16586, inputTokens: 5317, outputTokens: 5 } })).toEqual({ usedTokens: 16586 });
    expect(usageFromPromptResponse({ usage: { totalTokens: 0, inputTokens: 0, outputTokens: 0 } })).toBeUndefined();
    expect(usageFromPromptResponse(null)).toBeUndefined();
  });

  test("compaction raw output", () => {
    expect(compactionFromRawOutput({ trigger: "manual", preTokens: 25290, postTokens: 4869 })).toEqual({ beforeTokens: 25290, afterTokens: 4869 });
    expect(compactionFromRawOutput({ stdout: "x" })).toBeUndefined();
    expect(compactionFromRawOutput("text")).toBeUndefined();
  });
});

describe("context windows", () => {
  test("table", () => {
    expect(contextWindow("claude", "claude-opus-5-5")).toBe(200_000);
    expect(contextWindow("claude", "claude-sonnet-5[1m]")).toBe(1_000_000);
    expect(contextWindow("claude", "claude-haiku-4-5")).toBe(200_000);
    expect(contextWindow("grok", "grok-4.7")).toBe(256_000);
    expect(contextWindow("gemini", "gemini-3-pro-preview")).toBe(1_000_000);
    expect(contextWindow("other", "x")).toBeUndefined();
  });

  test("codex reads models_cache.json", () => {
    const dir = mkdtempSync(join(tmpdir(), "nuo-codex-"));
    try {
      writeFileSync(
        join(dir, "models_cache.json"),
        JSON.stringify({ models: [{ slug: "gpt-6.1-sol", context_window: 500_000, effective_context_window_percent: 95 }] }),
      );
      expect(contextWindow("codex", "gpt-6.1-sol", dir)).toBe(475_000);
      expect(contextWindow("codex", "unknown", dir)).toBe(258_400);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

test("estimation counts chars / 4 including thoughts and steps", () => {
  expect(estimateTokens(["abcd", "efgh", undefined, "i"])).toBe(3);
  const n = estimateConversationTokens("x".repeat(400), [
    { id: "1", conversationId: "c", role: "user", text: "y".repeat(40), createdAt: "" },
    { id: "2", conversationId: "c", role: "assistant", text: "z".repeat(40), thoughts: "t".repeat(16), steps: [{ toolCallId: "a", title: "abcd", status: "completed" }], createdAt: "" },
  ]);
  expect(n).toBe(125);
});

test("auto-compact threshold", () => {
  const ctx = (usedTokens: number, maxTokens?: number) => ({ usedTokens, maxTokens, compactions: 0, updatedAt: "" });
  expect(AUTO_COMPACT_RATIO).toBe(0.85);
  expect(shouldAutoCompact(ctx(170_000, 200_000))).toBe(false);
  expect(shouldAutoCompact(ctx(170_001, 200_000))).toBe(true);
  expect(shouldAutoCompact(ctx(900_000))).toBe(false);
  expect(shouldAutoCompact(undefined)).toBe(false);
});

test("notice line is a single card line", () => {
  expect(noticeLine({ kind: "compacted", text: "Conversation compactée", beforeTokens: 120000, afterTokens: 8000 })).toBe(
    '::notice {"kind":"compacted","text":"Conversation compactée","beforeTokens":120000,"afterTokens":8000}',
  );
});

describe("runner", () => {
  let t: TestApp;
  let sock: Socket | undefined;
  afterEach(async () => {
    sock?.close();
    sock = undefined;
    await t?.close();
  });

  async function setup(opts: Parameters<typeof startTestApp>[0] = {}) {
    t = await startTestApp(opts);
    const bot = (await t.api("POST", "/api/bots", { name: "Voyages" })).data;
    await t.api("PUT", `/api/bots/${bot.id}/draft`, botConfig());
    await t.api("POST", `/api/bots/${bot.id}/publish`, {});
    const conv = (await t.api("POST", "/api/conversations", { botId: bot.id })).data;
    sock = await Socket.open(t);
    return { bot, conv, sock };
  }

  async function say(s: Socket, conversationId: string, text: string) {
    s.send({ type: "prompt", conversationId, text });
    return s.next("message.end", 5000);
  }

  test("reported usage is broadcast and listed with the conversation", async () => {
    const { bot, conv, sock } = await setup();
    t.runtime.reportedUsage = 42_000;
    await say(sock, conv.id, "bonjour");
    const ev = await sock.next("context");
    expect(ev.context).toMatchObject({ usedTokens: 42_000, maxTokens: 200_000, compactions: 0 });
    const listed = (await t.api("GET", `/api/conversations?botId=${bot.id}`)).data[0];
    expect(listed.context).toMatchObject({ usedTokens: 42_000, maxTokens: 200_000, compactions: 0 });
  });

  test("without a report the usage is estimated and grows each turn", async () => {
    const { conv, sock } = await setup();
    await say(sock, conv.id, "bonjour");
    const first = (await sock.next("context")).context;
    expect(first.usedTokens).toBeGreaterThan(0);
    expect(first.maxTokens).toBe(200_000);
    await say(sock, conv.id, "encore une question un peu plus longue");
    const second = (await sock.next("context")).context;
    expect(second.usedTokens).toBeGreaterThan(first.usedTokens);
  });

  test("/compact uses the agent's native command", async () => {
    const { conv, sock } = await setup();
    t.runtime.commands = ["compact"];
    await say(sock, conv.id, "bonjour");
    await sock.next("context");
    const end = await say(sock, conv.id, "/compact");
    expect(end.stopReason).toBe("end_turn");
    const notice = await sock.next("notice");
    expect(notice).toMatchObject({ kind: "compacted", text: "Conversation compactée", beforeTokens: 90000, afterTokens: 5000 });
    const ctx = (await sock.next("context")).context;
    expect(ctx).toMatchObject({ usedTokens: 5000, maxTokens: 200_000, compactions: 1 });
    expect(t.runtime.prompts.at(-1)!.text).toBe("/compact");
    expect(t.runtime.starts).toHaveLength(1);

    const msgs = (await t.api("GET", `/api/conversations/${conv.id}/messages`)).data;
    expect(msgs.at(-1)).toMatchObject({
      id: end.messageId,
      role: "assistant",
      text: '::notice {"kind":"compacted","text":"Conversation compactée","beforeTokens":90000,"afterTokens":5000}',
    });
    const types = sock.events.map((e) => e.type);
    expect(types.slice(types.lastIndexOf("message.start"))).toEqual(["message.start", "notice", "context", "message.end"]);
  });

  test("/compress falls back to a summary that seeds a fresh session", async () => {
    const { conv, sock } = await setup();
    t.runtime.reportedUsage = 60_000;
    await say(sock, conv.id, "bonjour");
    t.runtime.reportedUsage = undefined;
    const firstSession = t.app.store.conversation(conv.id)!.agentSessionId;
    await say(sock, conv.id, "/compress");
    const notice = await sock.next("notice");
    expect(notice).toMatchObject({ kind: "compacted", beforeTokens: 60_000, afterTokens: 1200 });
    expect(t.runtime.closed).toContain(firstSession!);
    expect(t.runtime.starts).toHaveLength(2);
    expect(t.runtime.starts[1]!.resumeId).toBeUndefined();
    const texts = t.runtime.prompts.map((p) => p.text);
    expect(texts.at(-2)).toBe(SUMMARY_PROMPT);
    expect(texts.at(-1)).toBe(`${SEED_PREFIX}Résumé : l'utilisateur part à Rome le 20/10.`);
    expect(t.app.store.conversation(conv.id)!.agentSessionId).not.toBe(firstSession);
    expect(t.app.store.conversation(conv.id)!.context).toMatchObject({ usedTokens: 1200, compactions: 1 });

    // The next turn runs in the fresh session, not a resume of the old one.
    await say(sock, conv.id, "et ensuite ?");
    expect(t.runtime.starts).toHaveLength(2);
  });

  test("/compact before any agent turn says there is nothing to compact", async () => {
    const { conv, sock } = await setup();
    await say(sock, conv.id, "/compact");
    expect(t.runtime.starts).toHaveLength(0);
    const msgs = (await t.api("GET", `/api/conversations/${conv.id}/messages`)).data;
    expect(msgs.at(-1).text).toStartWith("Rien à compacter");
  });

  test("a nearly full context is compacted before the next prompt", async () => {
    const { conv, sock } = await setup();
    t.runtime.commands = ["compact"];
    t.runtime.reportedUsage = 180_000;
    await say(sock, conv.id, "bonjour");
    t.runtime.reportedUsage = 6_000;
    sock.send({ type: "prompt", conversationId: conv.id, text: "suite" });
    const notice = await sock.next("notice", 5000);
    expect(notice).toMatchObject({ kind: "compacted", afterTokens: 5000 });
    await sock.next("message.end", 5000);
    await sock.next("message.end", 5000);
    expect(t.runtime.prompts.map((p) => p.text)).toEqual(["bonjour", "/compact", "suite"]);
    expect(t.app.store.conversation(conv.id)!.context).toMatchObject({ usedTokens: 6_000, compactions: 1 });
  });

  describe("a big context left idle", () => {
    const idleCompact = { afterMs: 60, minTokens: 150_000 };

    test("is compacted in the background, without a turn or a push", async () => {
      const { conv, sock } = await setup({ idleCompact });
      t.runtime.commands = ["compact"];
      t.runtime.reportedUsage = 160_000;
      const end = await say(sock, conv.id, "Résume-moi le dossier de prêt immobilier");
      const notice = await sock.next("notice", 2000);
      expect(notice).toMatchObject({ kind: "compacted", beforeTokens: 90000, afterTokens: 5000 });
      expect((await sock.next("context")).context).toMatchObject({ usedTokens: 160_000, compactions: 0 });
      expect((await sock.next("context")).context).toMatchObject({ usedTokens: 5000, compactions: 1 });
      const types = sock.events.map((e) => e.type);
      expect(types.slice(types.indexOf("message.end") + 1)).toEqual(["notice", "context"]);
      expect(t.runtime.prompts.map((p) => p.text)).toEqual(["Résume-moi le dossier de prêt immobilier", "/compact"]);
      expect(t.runtime.starts).toHaveLength(1);
      expect(t.app.runner.snapshots()).toEqual([]);
      expect(t.pusher.sent).toEqual([]);
      const msgs = (await t.api("GET", `/api/conversations/${conv.id}/messages`)).data;
      expect(msgs.at(-2).id).toBe(end.messageId);
      expect(msgs.at(-1).text).toStartWith('::notice {"kind":"compacted"');
      // The compacted session is the one the next turn resumes.
      expect(t.app.store.conversation(conv.id)!.agentSessions?.claude?.syncedTo).toBe(msgs.at(-1).id);
    });

    test("is left alone under the threshold or while the agent waits for a background task", async () => {
      const { conv, sock } = await setup({ idleCompact });
      t.runtime.commands = ["compact"];
      t.runtime.reportedUsage = 120_000;
      await say(sock, conv.id, "Où en est la déclaration d'impôts ?");
      await Bun.sleep(150);
      (t.runtime.sessions[0] as { awaitsBackground?: boolean }).awaitsBackground = true;
      t.runtime.reportedUsage = 160_000;
      await say(sock, conv.id, "Lance le calcul du prélèvement à la source");
      await Bun.sleep(150);
      expect(t.runtime.prompts.map((p) => p.text)).not.toContain("/compact");
      expect(t.app.store.conversation(conv.id)!.context).toMatchObject({ usedTokens: 160_000, compactions: 0 });
    });

    test("is left alone for an agent that can only compact by summarising", async () => {
      const { conv, sock } = await setup({ idleCompact });
      t.runtime.reportedUsage = 160_000;
      await say(sock, conv.id, "Récapitule le dossier du notaire pour la vente de l'appartement");
      await Bun.sleep(150);
      expect(t.runtime.prompts).toHaveLength(1);
      expect(t.runtime.starts).toHaveLength(1);
      expect(t.app.store.conversation(conv.id)!.context).toMatchObject({ usedTokens: 160_000, compactions: 0 });
    });

    test("a new message drops the planned compaction", async () => {
      const { conv, sock } = await setup({ idleCompact: { afterMs: 200, minTokens: 150_000 } });
      t.runtime.commands = ["compact"];
      t.runtime.reportedUsage = 160_000;
      await say(sock, conv.id, "Compare les offres de mutuelle");
      t.runtime.reportedUsage = 8_000;
      await say(sock, conv.id, "Garde celle de la MGEN");
      await Bun.sleep(350);
      expect(t.runtime.prompts.map((p) => p.text)).toEqual(["Compare les offres de mutuelle", "Garde celle de la MGEN"]);
      expect(t.app.store.conversation(conv.id)!.context).toMatchObject({ usedTokens: 8_000, compactions: 0 });
    });

    test("a message sent while it runs stops it and is answered at once", async () => {
      const { conv, sock } = await setup({ idleCompact });
      t.runtime.commands = ["compact"];
      t.runtime.holdCompact = true;
      t.runtime.reportedUsage = 160_000;
      await say(sock, conv.id, "Prépare le planning de la semaine");
      for (let i = 0; i < 50 && t.runtime.prompts.at(-1)?.text !== "/compact"; i++) await Bun.sleep(10);
      expect(t.runtime.prompts.at(-1)?.text).toBe("/compact");
      sock.send({ type: "prompt", conversationId: conv.id, text: "Ajoute le dentiste jeudi à 18h", steer: true });
      const end = await sock.next("message.end", 2000);
      expect(end.stopReason).toBe("end_turn");
      expect(t.runtime.steered).toEqual([]);
      expect(t.runtime.prompts.map((p) => p.text)).toEqual(["Prépare le planning de la semaine", "/compact", "Ajoute le dentiste jeudi à 18h"]);
      expect(sock.events.some((e) => e.type === "notice")).toBe(false);
      expect(t.app.store.conversation(conv.id)!.context).toMatchObject({ compactions: 0 });
      expect(t.runtime.closed).toEqual([]);
    });

    test("a running one is not resumed as an interrupted turn after a restart", async () => {
      const { conv, sock } = await setup({ idleCompact });
      t.runtime.commands = ["compact"];
      t.runtime.holdCompact = true;
      t.runtime.reportedUsage = 160_000;
      await say(sock, conv.id, "Classe les factures d'électricité");
      for (let i = 0; i < 50 && t.runtime.prompts.at(-1)?.text !== "/compact"; i++) await Bun.sleep(10);
      await t.app.runner.shutdown();
      expect(JSON.parse(t.app.store.getMeta("runner.interrupted") ?? "[]")).toEqual([]);
    });
  });

  test("auto-compact can be disabled", async () => {
    const { conv, sock } = await setup({ autoCompact: false });
    t.runtime.commands = ["compact"];
    t.runtime.reportedUsage = 190_000;
    await say(sock, conv.id, "bonjour");
    await say(sock, conv.id, "suite");
    expect(t.runtime.prompts.map((p) => p.text)).toEqual(["bonjour", "suite"]);
  });
});

test("push preview drops card lines and markdown and keeps ~120 chars", () => {
  const text = `::weather {"location":"Rome"}\n**Demain** il fera [beau](https://meteo.example) à Rome. ${"x".repeat(200)}`;
  const body = preview(text, 120);
  expect(body).toStartWith("Demain il fera beau à Rome.");
  expect(body.length).toBe(120);
  expect(body).toEndWith("…");
});
