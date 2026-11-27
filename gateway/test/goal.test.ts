import { afterEach, describe, expect, test } from "bun:test";
import { CALLER_HEADER } from "../src/mcp/overview-tools";
import { GOAL_PREFIX, GOAL_REFUSAL, goalConfirmation } from "../src/runner/goal";
import { botConfig, Socket, startTestApp, type TestApp } from "./helpers";

const LOCAL = "local-goal-test-token";

let t: TestApp;
let sock: Socket | undefined;
afterEach(async () => {
  sock?.close();
  sock = undefined;
  await t?.close();
});

async function setup() {
  t = await startTestApp({ localToken: LOCAL });
  const bot = (await t.api("POST", "/api/bots", { name: "Assistant" })).data;
  await t.api("PUT", `/api/bots/${bot.id}/draft`, botConfig());
  await t.api("POST", `/api/bots/${bot.id}/publish`, {});
  const conv = (await t.api("POST", "/api/conversations", { botId: bot.id })).data;
  sock = await Socket.open(t);
  return { conv, sock };
}

/** What the bot's `nuo` server does when it runs a device tool: it names its conversation. */
const deviceTool = (conversationId: string, tool: string, args: Record<string, unknown>) =>
  fetch(`${t.base}/api/device/tools/${tool}`, {
    method: "POST",
    headers: { authorization: `Bearer ${LOCAL}`, "content-type": "application/json", [CALLER_HEADER]: conversationId },
    body: JSON.stringify(args),
  }).then(async (r) => ({ status: r.status, data: (await r.json()) as { error?: string; text?: string } }));

describe("goal confirmations", () => {
  test("only what acts on other people or loses data is confirmed, said in words", () => {
    expect(goalConfirmation("gmail_send", { draft_id: "r-4821" }, "à julie.martin@lumen.example : « Devis cuisine, version 2 »")).toBe(
      "Envoyer l'e-mail : à julie.martin@lumen.example : « Devis cuisine, version 2 »",
    );
    expect(goalConfirmation("gmail_send", { draft_id: "r-4821" })).toBe("Envoyer l'e-mail (brouillon r-4821)");
    expect(goalConfirmation("calendar_create", { title: "Point chantier", attendees: ["julie.martin@lumen.example", "karim.haddad@lumen.example"] })).toBe(
      "Inviter julie.martin@lumen.example, karim.haddad@lumen.example à « Point chantier »",
    );
    expect(goalConfirmation("calendar_create", { title: "Bloc concentration" })).toBeUndefined();
    expect(goalConfirmation("calendar_create", { title: "Bloc concentration", attendees: [] })).toBeUndefined();
    expect(goalConfirmation("apple_event_delete", { id: "EV-31", title: "Dentiste" })).toBe("Supprimer l'évènement « Dentiste »");
    expect(goalConfirmation("calendar_delete", { event_id: "7hq2m" })).toBe("Supprimer l'évènement Google 7hq2m");
    expect(goalConfirmation("apple_calendar_delete", { id: "CAL-9" })).toBe("Supprimer l'agenda CAL-9");
    expect(goalConfirmation("workout_cancel", { name: "Fractionné 6 x 400 m" })).toBe("Retirer la séance « Fractionné 6 x 400 m » de la montre");
    expect(goalConfirmation("workout_cancel", { all: true })).toBe("Retirer toutes les séances programmées sur la montre");
    for (const name of ["gmail_draft", "gmail_search", "apple_event_create", "reminder_add", "mac_file_write"]) expect(goalConfirmation(name, {})).toBeUndefined();
  });
});

describe("goal turns", () => {
  test("the agent gets the goal instructions and works without asking", async () => {
    const { conv, sock } = await setup();
    sock.send({ type: "prompt", conversationId: conv.id, text: "Range mes fichiers de factures 2026 : perm", goal: true });
    await sock.next("message.end");
    expect(t.runtime.prompts.at(-1)!.text.startsWith(GOAL_PREFIX)).toBe(true);
    expect(sock.events.some((e) => e.type === "permission.request")).toBe(false);
    expect(sock.events.find((e) => e.type === "message.delta")).toMatchObject({ text: "chosen:allow_once" });
  });

  test("a goal ends with its turn: the next prompt asks again", async () => {
    const { conv, sock } = await setup();
    sock.send({ type: "prompt", conversationId: conv.id, text: "Prépare le dossier de remboursement : perm", goal: true });
    await sock.next("message.end");
    sock.send({ type: "prompt", conversationId: conv.id, text: "Supprime l'ancien dossier : perm" });
    const req = await sock.next("permission.request");
    expect(t.runtime.prompts.at(-1)!.text.startsWith(GOAL_PREFIX)).toBe(false);
    sock.send({ type: "permission", requestId: req.requestId, optionId: "reject_once" });
    await sock.next("message.end");
  });

  test("an extension cannot start a goal turn", async () => {
    const { conv, sock } = await setup();
    await t.app.runner.prompt({ conversationId: conv.id, text: "Commande les cartouches : perm", goal: true }, { untrusted: true });
    const req = await sock.next("permission.request");
    expect(t.runtime.prompts.at(-1)!.text.startsWith(GOAL_PREFIX)).toBe(false);
    sock.send({ type: "permission", requestId: req.requestId, optionId: "reject_once" });
    await sock.next("message.end");
  });

  test("deleting during a goal waits for the user, and a refusal reaches the bot", async () => {
    const { conv, sock } = await setup();
    sock.send({ type: "prompt", conversationId: conv.id, text: 'Libère mon jeudi : call:nuo/apple_event_delete{"id":"EV-31"} hold', goal: true });
    await sock.next("message.delta");
    const call = deviceTool(conv.id, "apple_event_delete", { id: "EV-31", title: "Dentiste" });
    const req = await sock.next("permission.request");
    expect(req).toMatchObject({ conversationId: conv.id, title: "Supprimer l'évènement « Dentiste »" });
    expect(req.options.map((o) => o.kind)).toEqual(["allow_once", "reject_once"]);
    sock.send({ type: "permission", requestId: req.requestId, optionId: "reject" });
    expect(await call).toEqual({ status: 403, data: { error: GOAL_REFUSAL } });
    sock.send({ type: "cancel", conversationId: conv.id });
    await sock.next("message.end");
  });

  test("an allowed deletion goes on to the device", async () => {
    const { conv, sock } = await setup();
    sock.send({ type: "prompt", conversationId: conv.id, text: 'Libère mon jeudi : call:nuo/apple_event_delete{"id":"EV-31"} hold', goal: true });
    await sock.next("message.delta");
    const call = deviceTool(conv.id, "apple_event_delete", { id: "EV-31", title: "Dentiste" });
    const req = await sock.next("permission.request");
    sock.send({ type: "permission", requestId: req.requestId, optionId: "allow" });
    const r = await call;
    expect(r.data.error).not.toBe(GOAL_REFUSAL);
    sock.send({ type: "cancel", conversationId: conv.id });
    await sock.next("message.end");
  });

  test("outside a goal turn, a device tool is not held", async () => {
    const { conv, sock } = await setup();
    const r = await deviceTool(conv.id, "apple_event_delete", { id: "EV-31", title: "Dentiste" });
    expect(r.data.error).not.toBe(GOAL_REFUSAL);
    expect(sock.events.some((e) => e.type === "permission.request")).toBe(false);
  });
});
