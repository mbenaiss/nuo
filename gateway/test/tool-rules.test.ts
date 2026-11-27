import { afterEach, describe, expect, test } from "bun:test";
import { offeredRules, ruleFor, validateToolRules } from "../src/bots/tool-rules";
import { botConfig, Socket, startTestApp, type TestApp } from "./helpers";

let t: TestApp;
let sock: Socket | undefined;
afterEach(async () => {
  sock?.close();
  sock = undefined;
  await t?.close();
});

/** A published bot with a pending draft: a rule must land on both without publishing the draft. */
async function setup() {
  t = await startTestApp();
  const bot = (await t.api("POST", "/api/bots", { name: "Assistant" })).data;
  await t.api("PUT", `/api/bots/${bot.id}/draft`, botConfig({ name: "Assistant" }));
  await t.api("POST", `/api/bots/${bot.id}/publish`, {});
  await t.api("PUT", `/api/bots/${bot.id}/draft`, botConfig({ name: "Assistant", instructions: "Réponds en tutoyant." }));
  const conv = (await t.api("POST", "/api/conversations", { botId: bot.id })).data;
  sock = await Socket.open(t);
  return { botId: bot.id as string, conv, sock };
}

const rulesOf = async (botId: string) => {
  const bot = (await t.api("GET", `/api/bots/${botId}`)).data;
  return { published: bot.published?.config.toolRules, draft: bot.draft?.toolRules };
};

describe("tool rules", () => {
  test("a card offers to remember its tool, and « Toujours » spares the next card", async () => {
    const { botId, conv, sock } = await setup();
    sock.send({ type: "prompt", conversationId: conv.id, text: 'Trouve la facture EDF : call:nuo/gmail_search{"query":"from:edf.fr facture"}' });
    const req = await sock.next("permission.request");
    expect(req).toMatchObject({ tool: "nuo/gmail_search", rules: ["allow", "block"] });
    expect(t.app.runner.snapshots(conv.id)[0]?.permission).toMatchObject({ requestId: req.requestId, tool: "nuo/gmail_search", rules: ["allow", "block"] });
    sock.send({ type: "permission", requestId: req.requestId, optionId: "allow_always", rule: "allow" });
    await sock.next("message.end");
    // The agent's own « always » would only last its session: the call is allowed once, the rule does the rest.
    expect(sock.events.filter((e) => e.type === "message.delta").map((e) => (e as { text: string }).text).join("")).toBe("gmail_search:allow_once ");
    expect(await rulesOf(botId)).toEqual({ published: { "nuo/gmail_search": "allow" }, draft: { "nuo/gmail_search": "allow" } });
    expect((await t.api("GET", `/api/bots/${botId}`)).data.draft.instructions).toBe("Réponds en tutoyant.");

    sock.events.length = 0;
    sock.send({ type: "prompt", conversationId: conv.id, text: 'Et celle de Free : call:nuo/gmail_search{"query":"from:free.fr facture"}' });
    await sock.next("message.end");
    expect(sock.events.some((e) => e.type === "permission.request")).toBe(false);
    expect(sock.events.find((e) => e.type === "message.delta")).toMatchObject({ text: "gmail_search:allow_once " });
  });

  test("a blocked tool is refused without a card, in a goal turn too", async () => {
    const { botId, conv, sock } = await setup();
    sock.send({ type: "prompt", conversationId: conv.id, text: "Vide le dossier Téléchargements : call:nuo/mac_file_write" });
    const req = await sock.next("permission.request");
    sock.send({ type: "permission", requestId: req.requestId, optionId: "allow_once", rule: "block" });
    await sock.next("message.end");
    expect(sock.events.find((e) => e.type === "message.delta")).toMatchObject({ text: "mac_file_write:reject_once " });
    expect((await rulesOf(botId)).published).toEqual({ "nuo/mac_file_write": "block" });

    sock.events.length = 0;
    sock.send({ type: "prompt", conversationId: conv.id, text: "Range mon bureau : call:nuo/mac_file_write", goal: true });
    await sock.next("message.end");
    expect(sock.events.some((e) => e.type === "permission.request")).toBe(false);
    expect(sock.events.find((e) => e.type === "message.delta")).toMatchObject({ text: "mac_file_write:reject_once " });
  });

  test("what sends, invites or deletes is never allowed for good", async () => {
    const { botId, conv, sock } = await setup();
    sock.send({ type: "prompt", conversationId: conv.id, text: 'Envoie le devis à Julie : call:nuo/gmail_send{"draft_id":"r-4821"} hold' });
    const req = await sock.next("permission.request");
    expect(req).toMatchObject({ tool: "nuo/gmail_send", rules: ["block"] });
    sock.send({ type: "permission", requestId: req.requestId, optionId: "allow_once", rule: "allow" });
    expect((await sock.next("error")).message).toContain("does not offer");
    expect(await rulesOf(botId)).toEqual({ published: undefined, draft: undefined });
    sock.send({ type: "permission", requestId: req.requestId, optionId: "reject_once" });
    await sock.next("message.delta");
    sock.send({ type: "cancel", conversationId: conv.id });
    await sock.next("message.end");
    expect(offeredRules({ server: "nuo", name: "calendar_create", input: { title: "Point chantier", attendees: ["julie.martin@lumen.example"] } })).toEqual(["block"]);
    expect(offeredRules({ server: "nuo", name: "calendar_create", input: { title: "Bloc concentration" } })).toEqual(["allow", "block"]);
    // An allow kept for creating events never covers one that invites people.
    const rules = { "nuo/calendar_create": "allow" } as const;
    expect(ruleFor(rules, { server: "nuo", name: "calendar_create", input: { title: "Bloc concentration" } })).toBe("allow");
    expect(ruleFor(rules, { server: "nuo", name: "calendar_create", input: { title: "Point chantier", attendees: ["karim.haddad@lumen.example"] } })).toBeUndefined();
  });

  test("rules are listed and removed from the bot's settings, and a saved draft does not touch them", async () => {
    const { botId, conv, sock } = await setup();
    sock.send({ type: "prompt", conversationId: conv.id, text: "Cherche le billet Rome : call:nuo/gmail_search" });
    let req = await sock.next("permission.request");
    sock.send({ type: "permission", requestId: req.requestId, optionId: "allow_once", rule: "allow" });
    await sock.next("message.end");
    expect((await t.api("GET", `/api/bots/${botId}/tool-rules`)).data).toEqual({ toolRules: { "nuo/gmail_search": "allow" } });

    // An editor opened before the rule existed saves without it, or with a rule of its own: neither counts.
    const draft = botConfig({ name: "Assistant", toolRules: { "nuo/gmail_send": "allow", Bash: "allow" } });
    expect((await t.api("PUT", `/api/bots/${botId}/draft`, draft)).data.draft.toolRules).toEqual({ "nuo/gmail_search": "allow" });

    expect((await t.api("DELETE", `/api/bots/${botId}/tool-rules/nuo%2Fmac_folders!`)).status).toBe(400);
    const removed = (await t.api("DELETE", `/api/bots/${botId}/tool-rules/nuo/gmail_search`)).data;
    expect(removed.published.config.toolRules).toBeUndefined();
    expect(removed.draft.toolRules).toBeUndefined();
    expect(removed.published.note).toBe("Règle d'outil : nuo/gmail_search retirée");

    sock.events.length = 0;
    sock.send({ type: "prompt", conversationId: conv.id, text: "Et le billet retour : call:nuo/gmail_search" });
    req = await sock.next("permission.request");
    expect(req.tool).toBe("nuo/gmail_search");
    sock.send({ type: "permission", requestId: req.requestId, optionId: "reject_once" });
    await sock.next("message.end");
  });

  test("a relay session ignores the rules and cannot keep one", async () => {
    const { botId, conv, sock } = await setup();
    sock.send({ type: "prompt", conversationId: conv.id, text: "Ajoute le dentiste : call:nuo/apple_event_create" });
    let req = await sock.next("permission.request");
    sock.send({ type: "permission", requestId: req.requestId, optionId: "allow_once", rule: "allow" });
    await sock.next("message.end");
    expect((await rulesOf(botId)).published).toEqual({ "nuo/apple_event_create": "allow" });

    sock.events.length = 0;
    const input = JSON.stringify({ title: "Dentiste", start: "2026-12-03T09:00", end: "2026-12-03T09:30" });
    await t.app.runner.prompt({ conversationId: conv.id, text: `Ajoute le dentiste jeudi : call:nuo/apple_event_create${input}` }, { relay: { deviceId: t.device.id, conversationId: conv.id } });
    req = await sock.next("permission.request");
    expect(req.tool).toBeUndefined();
    expect(req.rules).toBeUndefined();
    sock.send({ type: "permission", requestId: req.requestId, optionId: "reject_once", rule: "block" });
    expect((await sock.next("error")).message).toContain("does not offer");
    sock.send({ type: "permission", requestId: req.requestId, optionId: "reject_once" });
    await sock.next("message.end");
    expect((await rulesOf(botId)).published).toEqual({ "nuo/apple_event_create": "allow" });
  });

  test("the validator keeps well-formed rules only", () => {
    const errors: string[] = [];
    expect(validateToolRules({ "nuo/gmail_search": "allow", Bash: "block", "notion/pages_search": "allow" }, errors)).toEqual({
      "nuo/gmail_search": "allow",
      Bash: "block",
      "notion/pages_search": "allow",
    });
    expect(errors).toEqual([]);
    validateToolRules({ "nuo/apple_event_delete": "allow", "rm -rf": "block", Edit: "always" }, errors);
    expect(errors).toEqual([
      "nuo/apple_event_delete sends, invites or deletes: it is always confirmed",
      'invalid tool rule key "rm -rf"',
      "tool rule for Edit must be one of allow, block",
    ]);
    const many = Object.fromEntries(Array.from({ length: 101 }, (_, i) => [`notion/outil_${i}`, "block"]));
    const tooMany: string[] = [];
    validateToolRules(many, tooMany);
    expect(tooMany).toEqual(["toolRules holds at most 100 tools"]);
    expect(validateToolRules(["Bash"], errors)).toBeUndefined();
  });
});
