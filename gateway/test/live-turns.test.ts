import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { rfdState } from "../src/agents/acp";
import { subagentTitle } from "../src/agents/antigravity";
import { publishArtifacts } from "../src/runner/artifacts";
import { effectiveInstructions } from "../src/bots/instructions";
import { botConfig, Socket, startTestApp, type TestApp } from "./helpers";

let t: TestApp | undefined;
const sockets: Socket[] = [];
const dirs: string[] = [];
afterEach(async () => {
  for (const s of sockets.splice(0)) s.close();
  await t?.close();
  t = undefined;
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
});

async function setup() {
  t = await startTestApp();
  const bot = (await t.api("POST", "/api/bots", { name: "Cobot" })).data;
  await t.api("PUT", `/api/bots/${bot.id}/draft`, botConfig({ name: "Cobot" }));
  await t.api("POST", `/api/bots/${bot.id}/publish`, {});
  const conv = (await t.api("POST", "/api/conversations", { botId: bot.id })).data;
  const sock = await Socket.open(t);
  sockets.push(sock);
  return { bot, conv, sock };
}

async function waitFor(check: () => boolean, ms = 2000) {
  for (let i = 0; i < ms / 10 && !check(); i++) await Bun.sleep(10);
  expect(check()).toBe(true);
}

describe("« Envoyer maintenant »", () => {
  test("an agent that can steer gets the message inside the running turn, which goes on", async () => {
    const { conv, sock } = await setup();
    t!.runtime.steerable = true;
    sock.send({ type: "prompt", conversationId: conv.id, text: "slow: prépare le dossier de la réunion de lundi" });
    const start = await sock.next("message.start");
    await waitFor(() => t!.runtime.prompts.length === 1);
    sock.send({ type: "prompt", conversationId: conv.id, text: "Ajoute aussi le budget 2027", steer: true });
    await waitFor(() => t!.runtime.steered.length === 1);
    expect(t!.runtime.steered).toEqual(["Ajoute aussi le budget 2027"]);
    expect(sock.events.filter((e) => e.type === "message.start")).toHaveLength(1);
    expect(sock.events.some((e) => e.type === "message.end")).toBe(false);
    const texts = (await t!.api("GET", `/api/conversations/${conv.id}/messages`)).data.map((m: { role: string; text: string }) => `${m.role}:${m.text}`);
    expect(texts).toEqual(["user:slow: prépare le dossier de la réunion de lundi", "user:Ajoute aussi le budget 2027"]);
    sock.send({ type: "cancel", conversationId: conv.id });
    expect((await sock.next("message.end")).messageId).toBe(start.messageId);
  });

  test("an agent that cannot steer has its turn stopped, and the message runs right after", async () => {
    const { conv, sock } = await setup();
    sock.send({ type: "prompt", conversationId: conv.id, text: "slow: résume les 40 factures" });
    const first = await sock.next("message.start");
    await waitFor(() => t!.runtime.prompts.length === 1);
    sock.send({ type: "prompt", conversationId: conv.id, text: "Seulement celles de 2026", steer: true });
    expect(await sock.next("message.end")).toMatchObject({ messageId: first.messageId, stopReason: "cancelled" });
    const second = await sock.next("message.start");
    expect(second.messageId).not.toBe(first.messageId);
    expect(await sock.next("message.end")).toMatchObject({ messageId: second.messageId, stopReason: "end_turn" });
    expect(t!.runtime.prompts.at(-1)!.text).toContain("Seulement celles de 2026");
  });

  test("without a running turn it is a normal message", async () => {
    const { conv, sock } = await setup();
    t!.runtime.steerable = true;
    sock.send({ type: "prompt", conversationId: conv.id, text: "Bonjour", steer: true });
    expect(await sock.next("message.end")).toMatchObject({ stopReason: "end_turn" });
    expect(t!.runtime.steered).toEqual([]);
  });
});

describe("subagents", () => {
  test("each change is sent live, kept in the snapshot and saved with the answer", async () => {
    const { conv, sock } = await setup();
    sock.send({ type: "prompt", conversationId: conv.id, text: "delegate unfinished" });
    const start = await sock.next("message.start");
    await sock.next("message.end");
    const updates = sock.events.filter((e) => e.type === "subagent").map((e) => (e as { subagent: { id: string; state: string } }).subagent);
    expect(updates.filter((u) => u.id === "sub-1").map((u) => u.state)).toContain("running");
    const saved = (await t!.api("GET", `/api/conversations/${conv.id}/messages`)).data.find((m: { id: string }) => m.id === start.messageId);
    expect(saved.subagents).toHaveLength(2);
    expect(saved.subagents[0]).toMatchObject({
      id: "sub-1",
      title: "Explore",
      description: "Compter les fichiers de /etc/systemd",
      state: "completed",
      text: "12 fichiers",
      steps: [{ toolCallId: "b1", title: "find /etc/systemd -type f | wc -l", status: "completed" }],
    });
    expect(saved.subagents[0].endedAt).toBeString();
    // A subagent still running when the turn ends finished with it.
    expect(saved.subagents[1]).toMatchObject({ id: "sub-2", title: "Plan", state: "completed" });
  });

  test("a long subagent text or result never starts on half of an emoji", async () => {
    const { conv, sock } = await setup();
    sock.send({ type: "prompt", conversationId: conv.id, text: "compte rendu long" });
    const start = await sock.next("message.start");
    await sock.next("message.end");
    const sent = sock.events.filter((e) => e.type === "subagent").map((e) => (e as { subagent: { text?: string } }).subagent.text ?? "");
    expect(sent.every((text) => text.isWellFormed())).toBe(true);
    const saved = (await t!.api("GET", `/api/conversations/${conv.id}/messages`)).data.find((m: { id: string }) => m.id === start.messageId);
    for (const sub of saved.subagents) {
      expect(sub.text).toHaveLength(5999);
      expect(sub.text).toStartWith("Sortie Z2 de 45 min");
    }
  });

  test("Claude's states and Antigravity's titles map to the app's", () => {
    expect(rfdState({ state: "running" })).toBe("running");
    expect(rfdState({ state: "requires_action" })).toBe("waiting");
    expect(rfdState({ state: "idle", stopReason: "end_turn" })).toBe("completed");
    expect(rfdState({ state: "idle", stopReason: "cancelled" })).toBe("cancelled");
    expect(rfdState({ state: "idle", stopReason: "max_tokens" })).toBe("failed");
    expect(subagentTitle("invoke_subagent", { TaskName: "Analyser les relevés bancaires" })).toBe("Analyser les relevés bancaires");
    expect(subagentTitle("browser_subagent", {})).toBe("Navigateur");
  });
});

describe("files the bots publish", () => {
  const PAGE = "<!doctype html><title>Contrôle des charges Gecina</title>";
  const SIZE = Buffer.byteLength(PAGE);
  function workspace() {
    const root = mkdtempSync(join(tmpdir(), "nuo-artifacts-"));
    dirs.push(root);
    const bot = join(root, "bot");
    mkdirSync(join(bot, "artifacts"), { recursive: true });
    writeFileSync(join(bot, "artifacts", "charges-gecina.html"), PAGE);
    writeFileSync(join(root, "secret.txt"), "token");
    symlinkSync(join(root, "secret.txt"), join(bot, "artifacts", "lien.txt"));
    const saved: { mime: string; name: string; size: number }[] = [];
    const save = async (mime: string, bytes: Uint8Array, name: string) => {
      saved.push({ mime, name, size: bytes.length });
      return `m${saved.length}.html`;
    };
    return { bot, root, saved, save };
  }

  test("a file in the bot's folder becomes a media url with its type and size", async () => {
    const w = workspace();
    const text = 'Voici le contrôle.\n::artifact {"path":"artifacts/charges-gecina.html","title":"Contrôle des charges 2023-2025"}\nBonne lecture.';
    const out = await publishArtifacts(text, { bases: [w.root, w.bot], roots: [w.bot], save: w.save });
    const line = out.split("\n")[1]!;
    expect(JSON.parse(line.replace("::artifact ", ""))).toEqual({
      title: "Contrôle des charges 2023-2025",
      name: "charges-gecina.html",
      mime: "text/html",
      size: SIZE,
      url: "/api/media/m1.html",
    });
    expect(out.split("\n")[0]).toBe("Voici le contrôle.");
    expect(w.saved).toEqual([{ mime: "text/html", name: "charges-gecina.html", size: SIZE }]);
  });

  test("files outside the bot's folders, symlinks out of it and missing files are refused", async () => {
    const w = workspace();
    const text = [
      `::artifact {"path":"${join(w.root, "secret.txt")}"}`,
      '::artifact {"path":"artifacts/lien.txt"}',
      '::artifact {"path":"artifacts/budget.xlsx","title":"Budget"}',
      '::artifact {"url":"/api/media/deja.pdf","title":"Déjà publié"}',
    ].join("\n");
    const lines = (await publishArtifacts(text, { bases: [w.root, w.bot], roots: [w.bot], save: w.save })).split("\n").map((l) => JSON.parse(l.replace("::artifact ", "")));
    expect(lines[0].error).toBe("File outside the bot's workspace");
    expect(lines[1].error).toBe("File outside the bot's workspace");
    expect(lines[2]).toEqual({ title: "Budget", name: "budget.xlsx", error: "File not found" });
    expect(lines[3]).toEqual({ url: "/api/media/deja.pdf", title: "Déjà publié" });
    expect(w.saved).toEqual([]);
  });
});

describe("instructions", () => {
  test("bots publish files as artifacts, draw diagrams in mermaid and link the documents they write", () => {
    const paths = { home: "/home/julie/nuo", db: "/home/julie/nuo/data/data.db", docs: "/home/julie/nuo/docs", dashboards: "/home/julie/nuo/dashboards" };
    const text = effectiveInstructions({ name: "Cobot", instructions: "Assistant de Julie.", permissionPolicy: "auto" } as never, undefined, "", paths);
    expect(text).toContain('::artifact {"path":"artifacts/report.html","title":"Report"}');
    expect(text).toContain("nuo://docs/Family/Association/Service%20charge%20review.html");
    expect(text).toContain("```mermaid");
  });

  test("bots are told to answer fast, write memory after answering and get the data schema up front", () => {
    const paths = { home: "/home/julie/nuo", db: "/home/julie/nuo/data/data.db", docs: "/home/julie/nuo/docs", dashboards: "/home/julie/nuo/dashboards" };
    const schema = "colis : id, numero, transporteur, statut\nv_colis = colis + jours_restants";
    const text = effectiveInstructions({ name: "Cobot", instructions: "Assistant de Julie.", permissionPolicy: "auto" } as never, undefined, "", paths, undefined, schema);
    expect(text.indexOf("## Speed")).toBeLessThan(text.indexOf("## Memory"));
    expect(text).toContain("run it in the background");
    expect(text).toContain("run it directly the next time");
    expect(text).toContain('::question {"question":"Which one do we start with?"');
    expect(text).toContain("## Proposals");
    expect(text).toContain("after writing your answer");
    expect(text).toContain(schema);
    expect(text.indexOf("## Language")).toBeLessThan(text.indexOf("## Speed"));
    expect(text).toContain("Write everything the user can read in the user's language");
    expect(text).toContain("the short messages between two\nactions");
    expect(text).toContain("which the gateway gives at the top of that turn");
    const french = effectiveInstructions({ name: "Cobot", instructions: "Assistant de Julie.", permissionPolicy: "auto" } as never, undefined, "", paths, undefined, "", "French");
    expect(french).toContain("is in their preferred language, French.");
    const tutor = effectiveInstructions({ name: "Tutor", instructions: "Professeur d'anglais de Julie.", permissionPolicy: "auto", language: "English" } as never, undefined, "", paths, undefined, "", "French");
    expect(tutor).toContain("Write everything the user can read in English");
    expect(tutor).not.toContain("French");
    const ask = effectiveInstructions({ name: "Coach", instructions: "Coach de Julie.", permissionPolicy: "ask" } as never, undefined, "", paths, undefined, schema);
    expect(ask).toContain("## Speed");
    expect(ask).not.toContain(schema);
  });
});

describe("language of a bot", () => {
  test("a bot follows the language the apps send, and is told it on a turn the user did not write", async () => {
    const { bot, conv, sock } = await setup();
    sock.send({ type: "prompt", conversationId: conv.id, text: "Où en est la candidature chez KPMG ?" });
    await sock.next("message.end");
    expect(t!.runtime.starts[0]!.language).toBeUndefined();

    await fetch(`${t!.base}/api/bots`, { headers: { authorization: `Bearer ${t!.token}`, "accept-language": "fr-FR, en-US;q=0.9" } });
    expect(t!.app.store.userLanguages()).toEqual(["fr-FR", "en-US"]);
    const next = (await t!.api("POST", "/api/conversations", { botId: bot.id })).data;
    sock.send({ type: "prompt", conversationId: next.id, text: "Et chez Deloitte ?" });
    await sock.next("message.end");
    expect(t!.runtime.starts.at(-1)!.language).toBe("French");
    expect(readFileSync(join(t!.profileHome, "instructions", `${bot.slug}.md`), "utf8")).toContain("is in their preferred language, French.");
    expect(t!.runtime.prompts.at(-1)!.text).toBe("Et chez Deloitte ?");

    const { done } = await t!.app.runner.prompt({ conversationId: next.id, text: "Point du matin sur les candidatures" }, { scheduled: true });
    await done;
    expect(t!.runtime.prompts.at(-1)!.text).toStartWith("[Nuo: no message from the user in this turn. Write in French, their preferred language.]\n\n");
  });

  test("a bot writes in the user's language unless its config names another language", async () => {
    const { conv, sock } = await setup();
    sock.send({ type: "prompt", conversationId: conv.id, text: "Où en est la candidature chez KPMG ?" });
    await sock.next("message.end");
    expect(t!.runtime.starts[0]!.language).toBeUndefined();

    const tutor = (await t!.api("POST", "/api/bots", { name: "Tutor" })).data;
    await t!.api("PUT", `/api/bots/${tutor.id}/draft`, botConfig({ name: "Tutor", language: "  English " }));
    await t!.api("POST", `/api/bots/${tutor.id}/publish`, {});
    expect((await t!.api("GET", `/api/bots/${tutor.id}`)).data.published.config.language).toBe("English");
    const lesson = (await t!.api("POST", "/api/conversations", { botId: tutor.id })).data;
    sock.send({ type: "prompt", conversationId: lesson.id, text: "Let's practise a job interview for a KYC analyst role" });
    await sock.next("message.end");
    expect(t!.runtime.starts.at(-1)!.language).toBe("English");
  });

  test("a language must be a short name", async () => {
    const { bot } = await setup();
    const bad = await t!.api("PUT", `/api/bots/${bot.id}/draft`, botConfig({ name: "Cobot", language: 7 }));
    expect(bad.status).toBe(400);
    expect(bad.data.error).toContain("language must be a language name");
  });
});

describe("restart of the gateway", () => {
  test("a turn running at shutdown is noted, then resumed without a new user message", async () => {
    const { conv, sock } = await setup();
    sock.send({ type: "prompt", conversationId: conv.id, text: "slow: analyse les 3 ans de charges" });
    await sock.next("message.start");
    await waitFor(() => t!.runtime.prompts.length === 1);
    await t!.app.runner.shutdown();
    expect(JSON.parse(t!.app.store.getMeta("runner.interrupted")!)).toEqual([conv.id]);
    const before = (await t!.api("GET", `/api/conversations/${conv.id}/messages`)).data.length;

    expect(t!.app.runner.resumeInterrupted()).toEqual([conv.id]);
    await waitFor(() => t!.runtime.prompts.length === 2);
    expect(t!.runtime.prompts[1]!.text).toContain("The gateway restarted during your answer");
    await waitFor(() => !t!.app.runner.activeTurn(conv.id));
    const messages = (await t!.api("GET", `/api/conversations/${conv.id}/messages`)).data as { role: string; text: string }[];
    expect(messages.slice(before).map((m) => m.role)).toEqual(["assistant", "assistant"]);
    expect(messages[before]!.text).toContain("Resumed after the gateway restarted");
    expect(t!.app.runner.resumeInterrupted()).toEqual([]);
  });

  test("the notice of a resumed turn is in the language the user's device sent, and the bot is told it", async () => {
    const { conv, sock } = await setup();
    await fetch(`${t!.base}/api/bots`, { headers: { authorization: `Bearer ${t!.token}`, "accept-language": "fr-FR, en;q=0.5" } });
    sock.send({ type: "prompt", conversationId: conv.id, text: "slow: compare les devis des trois menuisiers" });
    await sock.next("message.start");
    await waitFor(() => t!.runtime.prompts.length === 1);
    await t!.app.runner.shutdown();
    const before = (await t!.api("GET", `/api/conversations/${conv.id}/messages`)).data.length;
    expect(t!.app.runner.resumeInterrupted()).toEqual([conv.id]);
    await waitFor(() => t!.runtime.prompts.length === 2);
    expect(t!.runtime.prompts[1]!.text).toStartWith("[Nuo: no message from the user in this turn. Write in French, their preferred language.]\n\n[Nuo] The gateway restarted");
    await waitFor(() => !t!.app.runner.activeTurn(conv.id));
    const messages = (await t!.api("GET", `/api/conversations/${conv.id}/messages`)).data as { text: string }[];
    expect(messages[before]!.text).toContain("Reprise après le redémarrage de la passerelle");
  });

  test("a turn its agent ends before the gateway gets to stop is still resumed", async () => {
    const { conv, sock } = await setup();
    sock.send({ type: "prompt", conversationId: conv.id, text: "slow: recherche d'emploi du jour, LinkedIn et Apec" });
    await sock.next("message.start");
    await waitFor(() => t!.runtime.prompts.length === 1);
    // SIGTERM reached every profile: the agent of a profile stopped later answers « cancelled » before its runner stops.
    t!.app.runner.noteInterrupted();
    sock.send({ type: "cancel", conversationId: conv.id });
    await sock.next("message.end");
    await waitFor(() => !t!.app.runner.activeTurn(conv.id));
    await t!.app.runner.shutdown();
    expect(JSON.parse(t!.app.store.getMeta("runner.interrupted")!)).toEqual([conv.id]);
  });

  test("background work still running after its turn is resumed, with what it was doing", async () => {
    const { conv, sock } = await setup();
    sock.send({ type: "prompt", conversationId: conv.id, text: "Lance les trois recherches d'offres de 16 h" });
    await sock.next("message.end");
    (t!.runtime.sessions[0] as { awaitsBackground?: boolean }).awaitsBackground = true;
    await t!.app.runner.shutdown();
    expect(JSON.parse(t!.app.store.getMeta("runner.interrupted")!)).toEqual([conv.id]);
    expect(t!.app.runner.resumeInterrupted()).toEqual([conv.id]);
    await waitFor(() => t!.runtime.prompts.length === 2);
    expect(t!.runtime.prompts[1]!.text).toContain("your background work (subagents, commands)");
  });

  test("background work that ends before the stop is not resumed", async () => {
    const { conv, sock } = await setup();
    sock.send({ type: "prompt", conversationId: conv.id, text: "Lance les trois recherches d'offres de 9 h" });
    await sock.next("message.end");
    const session = t!.runtime.sessions[0] as { awaitsBackground?: boolean };
    session.awaitsBackground = true;
    t!.app.runner.noteInterrupted();
    session.awaitsBackground = false;
    sock.send({ type: "prompt", conversationId: conv.id, text: "Fais-moi le bilan des offres retenues" });
    await sock.next("message.start");
    await sock.next("message.end");
    await t!.app.runner.shutdown();
    expect(JSON.parse(t!.app.store.getMeta("runner.interrupted") ?? "[]")).toEqual([]);
  });
});

describe("follow-ups the agent starts by itself", () => {
  test("Claude's word after a background command reaches the conversation as an answer of its own", async () => {
    const { conv, sock } = await setup();
    sock.send({ type: "prompt", conversationId: conv.id, text: "Lance la compilation de Nuo en arrière-plan" });
    const first = await sock.next("message.start");
    await sock.next("message.end");
    t!.runtime.comeBack("La compilation est terminée : 0 erreur, 2 avertissements.");
    const second = await sock.next("message.start");
    expect(second.messageId).not.toBe(first.messageId);
    expect(await sock.next("message.end")).toMatchObject({ messageId: second.messageId, stopReason: "end_turn", steps: 1 });
    const messages = (await t!.api("GET", `/api/conversations/${conv.id}/messages`)).data as { role: string; text: string }[];
    expect(messages.map((m) => m.role)).toEqual(["user", "assistant", "assistant"]);
    expect(messages.at(-1)!.text).toBe("La compilation est terminée : 0 erreur, 2 avertissements.");
    // Nothing was sent to the agent for it.
    expect(t!.runtime.prompts).toHaveLength(1);
  });

  test("a follow-up arriving during a turn waits for it", async () => {
    const { conv, sock } = await setup();
    sock.send({ type: "prompt", conversationId: conv.id, text: "Bonjour" });
    await sock.next("message.start");
    await sock.next("message.end");
    sock.send({ type: "prompt", conversationId: conv.id, text: "slow: résume les relevés bancaires" });
    const running = await sock.next("message.start");
    await waitFor(() => t!.runtime.prompts.length === 2);
    t!.runtime.comeBack("Les tests sont passés.");
    await Bun.sleep(50);
    expect(sock.events.filter((e) => e.type === "message.start")).toHaveLength(2);
    sock.send({ type: "cancel", conversationId: conv.id });
    expect((await sock.next("message.end")).messageId).toBe(running.messageId);
    const followUp = await sock.next("message.start");
    expect(followUp.messageId).not.toBe(running.messageId);
    await sock.next("message.end");
  });
});
