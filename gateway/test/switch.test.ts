import { afterEach, expect, test } from "bun:test";
import { HANDOFF_DELTA_PREFIX, HANDOFF_FULL_PREFIX } from "../src/agents/context";
import { botConfig, FakeRuntime, Socket, startTestApp, type TestApp } from "./helpers";

let t: TestApp;
let sock: Socket | undefined;
afterEach(async () => {
  sock?.close();
  sock = undefined;
  await t?.close();
});

const CLAUDE_MODELS = [
  { id: "claude-opus-5-5", name: "Opus 5.5", isDefault: true, efforts: ["low", "medium", "high"] },
  { id: "claude-sonnet-5", name: "Sonnet 5", efforts: ["low", "medium", "high"] },
];

async function setup() {
  const codex = new FakeRuntime("codex", "Codex", [{ id: "gpt-5.6-sol", name: "GPT-5.6 Sol", isDefault: true, efforts: ["low", "medium", "high", "xhigh"] }], "codex-s");
  t = await startTestApp({ extraRuntimes: [codex] });
  t.runtime.modelList = CLAUDE_MODELS;
  const bot = (await t.api("POST", "/api/bots", { name: "Voyages" })).data;
  await t.api("PUT", `/api/bots/${bot.id}/draft`, botConfig({ model: "claude-opus-5-5", effort: "medium" }));
  await t.api("POST", `/api/bots/${bot.id}/publish`, {});
  const conv = (await t.api("POST", "/api/conversations", { botId: bot.id })).data;
  sock = await Socket.open(t);
  const s = sock;
  const say = async (text: string, extra: Record<string, unknown> = {}) => {
    s.send({ type: "prompt", conversationId: conv.id, text, ...extra });
    return s.next("message.end");
  };
  const messages = async () => (await t.api("GET", `/api/conversations/${conv.id}/messages`)).data as any[];
  return { bot, conv, sock: s, codex, say, messages };
}

test("another model of the same agent keeps the session and leaves a marker", async () => {
  const { conv, sock, say, messages } = await setup();
  const first = await say("Quels vols pour Rome le 20 octobre ?");
  expect(first).toMatchObject({ agent: "claude", model: "claude-opus-5-5" });

  const second = await say("Et le retour le 27 ?", { model: "claude-sonnet-5" });
  expect(second).toMatchObject({ agent: "claude", model: "claude-sonnet-5", stopReason: "end_turn" });
  expect(t.runtime.starts).toHaveLength(1);
  expect(t.runtime.modelChanges).toEqual(["claude-sonnet-5"]);
  expect(t.runtime.prompts.map((p) => p.text)).toEqual(["Quels vols pour Rome le 20 octobre ?", "Et le retour le 27 ?"]);
  expect(await sock.next("notice")).toMatchObject({
    conversationId: conv.id,
    kind: "switched",
    text: "Passage à Fake Claude · Sonnet 5",
    agent: "claude",
    model: "claude-sonnet-5",
  });

  const msgs = await messages();
  expect(msgs.map((m) => m.role)).toEqual(["user", "assistant", "assistant", "user", "assistant"]);
  expect(JSON.parse(msgs[2].text.slice("::notice ".length))).toEqual({ kind: "switched", text: "Passage à Fake Claude · Sonnet 5", agent: "claude", model: "claude-sonnet-5" });
  expect(msgs[1]).toMatchObject({ agent: "claude", model: "claude-opus-5-5" });
  expect(msgs[4]).toMatchObject({ agent: "claude", model: "claude-sonnet-5" });

  await say("Plutôt en fin de matinée", { model: "claude-sonnet-5" });
  expect((await messages()).filter((m) => m.text.startsWith("::notice "))).toHaveLength(1);
});

test("another agent gets the history; switching back resumes the first session with only what it missed", async () => {
  const { bot, conv, codex, say, messages } = await setup();
  await say("Je pars à Rome le 20 octobre, trouve-moi un vol depuis Paris");

  const onCodex = await say("Compare avec un départ de Lyon", { agent: "codex", model: "gpt-5.6-sol" });
  expect(onCodex).toMatchObject({ agent: "codex", model: "gpt-5.6-sol", stopReason: "end_turn" });
  expect(codex.starts).toHaveLength(1);
  expect(codex.starts[0]).toMatchObject({ model: "gpt-5.6-sol", resumeId: undefined });
  expect(t.runtime.closed).toEqual(["s1"]);
  const seeded = codex.prompts[0]!.text;
  expect(seeded).toStartWith(HANDOFF_FULL_PREFIX);
  expect(seeded).toContain("Utilisateur : Je pars à Rome le 20 octobre, trouve-moi un vol depuis Paris");
  expect(seeded).toContain("Assistant (claude · claude-opus-5-5) : Hello world");
  expect(seeded).not.toContain("::notice");
  expect(seeded).toEndWith("Nouveau message :\nCompare avec un départ de Lyon");

  const c = (await t.api("GET", `/api/conversations/${conv.id}`)).data;
  expect(c).toMatchObject({ agent: "codex", model: "gpt-5.6-sol" });
  expect(c.agentSessions).toBeUndefined();
  expect((await t.api("GET", `/api/bots/${bot.id}`)).data.published.config).toMatchObject({ agent: "claude", model: "claude-opus-5-5" });

  await say("Finalement je garde Paris", { agent: "claude", model: "claude-opus-5-5" });
  expect(t.runtime.starts[1]!.resumeId).toBe("s1");
  const delta = t.runtime.prompts[1]!.text;
  expect(delta).toStartWith(HANDOFF_DELTA_PREFIX);
  expect(delta).toContain("Utilisateur : Compare avec un départ de Lyon");
  expect(delta).toContain("Assistant (codex · gpt-5.6-sol) : Hello world");
  expect(delta).not.toContain("Je pars à Rome");
  expect(delta).toEndWith("Nouveau message :\nFinalement je garde Paris");

  await say("Réserve le vol de 9 h 40");
  expect(t.runtime.prompts[2]!.text).toBe("Réserve le vol de 9 h 40");

  await say("Vérifie les bagages inclus", { agent: "codex", model: "gpt-5.6-sol" });
  expect(codex.starts[1]!.resumeId).toBe("codex-s1");
  const back = codex.prompts[1]!.text;
  expect(back).toStartWith(HANDOFF_DELTA_PREFIX);
  expect(back).toContain("Utilisateur : Finalement je garde Paris");
  expect(back).toContain("Utilisateur : Réserve le vol de 9 h 40");
  expect(back).not.toContain("Compare avec un départ de Lyon");

  const notices = (await messages()).filter((m) => m.text.startsWith("::notice ")).map((m) => JSON.parse(m.text.slice("::notice ".length)).text);
  expect(notices).toEqual(["Passage à Codex · GPT-5.6 Sol", "Passage à Fake Claude · Opus 5.5", "Passage à Codex · GPT-5.6 Sol"]);
  const sessions = t.app.store.conversation(conv.id)!.agentSessions!;
  expect(sessions.claude!.sessionId).toBe("s1");
  expect(sessions.codex!.sessionId).toBe("codex-s1");
});

test("the override is stored: a session closed in between resumes on the chosen agent without a handoff", async () => {
  const { conv, codex, say } = await setup();
  await say("Je pars à Rome le 20 octobre");
  await say("Compare avec un départ de Lyon", { agent: "codex", model: "gpt-5.6-sol" });
  await t.app.runner.closeConversation(conv.id);

  const end = await say("Et le prix en classe affaires ?");
  expect(end).toMatchObject({ agent: "codex", model: "gpt-5.6-sol" });
  expect(codex.starts[1]).toMatchObject({ resumeId: "codex-s1", model: "gpt-5.6-sol" });
  expect(codex.prompts[1]!.text).toBe("Et le prix en classe affaires ?");
  expect(t.runtime.starts).toHaveLength(1);
});

test("switching agent without a model takes its default and drops the other agent's effort", async () => {
  const { conv, codex, say } = await setup();
  await say("Quels vols pour Rome ?", { model: "claude-sonnet-5", effort: "high" });
  await say("Compare avec Lyon", { agent: "codex" });
  expect(codex.starts[0]).toMatchObject({ model: "gpt-5.6-sol", effort: undefined });
  const c = (await t.api("GET", `/api/conversations/${conv.id}`)).data;
  expect(c.agent).toBe("codex");
  expect(c.model).toBeUndefined();
  expect(c.effort).toBeUndefined();
});

test("a failed turn on the new agent is handed over again", async () => {
  const { codex, say } = await setup();
  await say("Je pars à Rome le 20 octobre");
  codex.failNextPrompt = true;
  expect((await say("Compare avec Lyon", { agent: "codex", model: "gpt-5.6-sol" })).stopReason).toBe("error");

  await say("Réessaie avec Lyon");
  const retried = codex.prompts[1]!.text;
  expect(retried).toStartWith(HANDOFF_FULL_PREFIX);
  expect(retried).toContain("Utilisateur : Je pars à Rome le 20 octobre");
  expect(retried).toEndWith("Nouveau message :\nRéessaie avec Lyon");
});

test("an unknown agent is refused", async () => {
  const { conv, sock } = await setup();
  sock.send({ type: "prompt", conversationId: conv.id, text: "Bonjour", agent: "mistral" });
  expect((await sock.next("error")).message).toBe("unknown agent mistral");
  expect((await t.api("GET", `/api/conversations/${conv.id}/messages`)).data).toEqual([]);
});
