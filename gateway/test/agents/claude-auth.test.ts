import { describe, expect, test } from "bun:test";
import { ClaudeAuthSession, claudeAuthFailure, claudeAuthMessage } from "../../src/agents/claude-auth";
import type { AgentSession, PromptResult, RunEvent } from "../../src/agents/types";

const LOCK_BUSY =
  "Failed to refresh OAuth token: another Claude Code process is refreshing it or exited mid-refresh. This is usually transient; retry in a minute, and if it persists close other Claude Code processes or sign in again";
const SESSION_EXPIRED = "Failed to authenticate: OAuth session expired and could not be refreshed";

type Reply = { chunks: RunEvent[]; result?: PromptResult };
const say = (...texts: string[]): Reply => ({ chunks: texts.map((text) => ({ type: "text", text })) });

class ScriptedSession implements AgentSession {
  readonly agentSessionId = "8f1c2d9e-cobot";
  readonly prompts: string[] = [];
  cancelled = false;
  constructor(private readonly replies: Reply[]) {}
  async prompt(text: string, _a: unknown[], onEvent: (e: RunEvent) => void): Promise<PromptResult> {
    this.prompts.push(text);
    const reply = this.replies.shift() ?? say("(no scripted reply)");
    for (const e of reply.chunks) onEvent(e);
    return reply.result ?? { stopReason: "end_turn" };
  }
  async cancel() {
    this.cancelled = true;
  }
  steered: string[] = [];
  onUnprompted?: AgentSession["onUnprompted"];
  awaitsBackground = true;
  async steer(text: string) {
    this.steered.push(text);
    return true;
  }
  async setModel() {}
  async close() {}
}

async function ask(session: AgentSession, text: string) {
  const events: RunEvent[] = [];
  const result = await session.prompt(text, [], (e) => events.push(e), async () => "allow");
  const reply = events.flatMap((e) => (e.type === "text" ? [e.text] : [])).join("");
  return { result, events, reply };
}

describe("claudeAuthFailure", () => {
  test("recognises Claude Code OAuth failures", () => {
    expect(claudeAuthFailure(LOCK_BUSY)).toBe("refresh_contended");
    expect(claudeAuthFailure(SESSION_EXPIRED)).toBe("login_required");
    expect(claudeAuthFailure("OAuth refresh token is no longer valid; run /login to re-authenticate")).toBe("login_required");
  });

  test("ignores ordinary answers, even about OAuth", () => {
    expect(claudeAuthFailure("Le vol AF1234 pour Lisbonne part à 7 h 45 du terminal 2F.")).toBeUndefined();
    expect(claudeAuthFailure("Failed to refresh OAuth token: the disk that holds the Claude Code config directory is full")).toBeUndefined();
  });
});

describe("ClaudeAuthSession", () => {
  test("hands « Envoyer maintenant » to the Claude session", async () => {
    const inner = new ScriptedSession([]);
    const session = new ClaudeAuthSession(inner, { retryDelaysMs: [] });
    expect(await session.steer("Ajoute aussi le budget 2027", [])).toBe(true);
    expect(inner.steered).toEqual(["Ajoute aussi le budget 2027"]);
  });

  test("lets the runner take Claude's follow-ups after a background command", async () => {
    const inner = new ScriptedSession([]);
    const session = new ClaudeAuthSession(inner, { retryDelaysMs: [] });
    const taken: string[] = [];
    session.onUnprompted = () => taken.push("compilation terminée");
    inner.onUnprompted?.({ run: async () => ({ stopReason: "end_turn" }) });
    expect(taken).toEqual(["compilation terminée"]);
    expect(session.awaitsBackground).toBe(true);
  });

  test("streams ordinary replies unchanged", async () => {
    const inner = new ScriptedSession([say("Ton prochain rendez-vous ", "est à 14 h avec Julie Martin.")]);
    const { result, events, reply } = await ask(new ClaudeAuthSession(inner, { retryDelaysMs: [5] }), "Qu'ai-je cet après-midi ?");
    expect(result).toEqual({ stopReason: "end_turn" });
    expect(reply).toBe("Ton prochain rendez-vous est à 14 h avec Julie Martin.");
    expect(events.filter((e) => e.type === "text").length).toBe(2);
  });

  test("a reply that only starts like an auth failure is released", async () => {
    const inner = new ScriptedSession([say("Failed", " deliveries this week: ORD-2026-104857 and ORD-2026-104902.")]);
    const { reply } = await ask(new ClaudeAuthSession(inner, { retryDelaysMs: [5] }), "Quelles livraisons ont échoué ?");
    expect(reply).toBe("Failed deliveries this week: ORD-2026-104857 and ORD-2026-104902.");
  });

  test("replays the prompt when the refresh lock was busy, without showing the raw error", async () => {
    const inner = new ScriptedSession([say(LOCK_BUSY), say("Il fera 18 °C à Lyon demain.")]);
    const { result, reply } = await ask(new ClaudeAuthSession(inner, { retryDelaysMs: [5, 5] }), "Quel temps demain à Lyon ?");
    expect(result).toEqual({ stopReason: "end_turn" });
    expect(reply).toBe("Il fera 18 °C à Lyon demain.");
    expect(inner.prompts).toEqual(["Quel temps demain à Lyon ?", "Quel temps demain à Lyon ?"]);
  });

  test("gives up with an actionable message once the retries are spent", async () => {
    const inner = new ScriptedSession([say(LOCK_BUSY), say(LOCK_BUSY), say(LOCK_BUSY)]);
    const { result, reply } = await ask(new ClaudeAuthSession(inner, { retryDelaysMs: [5, 5] }), "Résume mes mails non lus");
    expect(inner.prompts.length).toBe(3);
    expect(result.stopReason).toBe("error");
    expect(reply).toBe(claudeAuthMessage("refresh_contended"));
    expect(result.error).toBe(reply);
    expect(reply).not.toContain("Failed to refresh");
  });

  test("an expired session asks for a re-login right away, naming the profile's home", async () => {
    const inner = new ScriptedSession([say(SESSION_EXPIRED)]);
    const session = new ClaudeAuthSession(inner, { retryDelaysMs: [5], profileHome: "/srv/nuo/julie/home" });
    const { result, reply } = await ask(session, "Ajoute « acheter du pain » à ma liste");
    expect(inner.prompts.length).toBe(1);
    expect(result.stopReason).toBe("error");
    expect(reply).toContain("`/login`");
    expect(reply).toContain("/srv/nuo/julie/home");
  });

  test("cancelling during the wait ends the turn without replaying", async () => {
    const inner = new ScriptedSession([say(LOCK_BUSY), say("trop tard")]);
    const session = new ClaudeAuthSession(inner, { retryDelaysMs: [60_000] });
    const pending = ask(session, "Réserve une table chez Septime pour vendredi");
    await Bun.sleep(20);
    await session.cancel();
    const { result, reply } = await pending;
    expect(result).toEqual({ stopReason: "cancelled" });
    expect(reply).toBe("");
    expect(inner.prompts.length).toBe(1);
    expect(inner.cancelled).toBe(true);
  });
});
