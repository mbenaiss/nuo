import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { decodeAttachments, filesNote, MAX_FILE_BYTES, MAX_IMAGE_BYTES, safeFileName, saveWorkspaceFile } from "../src/runner/attachments";
import { botConfig, Socket, startTestApp, type TestApp } from "./helpers";

const PNG_1PX = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
const b64 = (s: string) => Buffer.from(s).toString("base64");

describe("helpers", () => {
  test("safe file names", () => {
    expect(safeFileName("../../etc/passwd")).toBe("passwd");
    expect(safeFileName("a/b\\c.pdf")).toBe("c.pdf");
    expect(safeFileName(".env")).toBe("env");
    expect(safeFileName("  ..  ")).toBe("fichier");
    expect(safeFileName(undefined)).toBe("fichier");
    expect(safeFileName('rapport:\u0001final?.pdf')).toBe("rapport__final_.pdf");
    expect(safeFileName("Évaluation été.docx")).toBe("Évaluation été.docx");
    const long = safeFileName(`${"x".repeat(300)}.pdf`);
    expect(long).toHaveLength(120);
    expect(long).toEndWith(".pdf");
  });

  test("workspace files are dated, never collide and stay inside the workspace", async () => {
    const ws = mkdtempSync(join(tmpdir(), "nuo-ws-"));
    try {
      const at = new Date(2026, 9, 17, 12);
      const a = await saveWorkspaceFile(ws, "note.txt", Buffer.from("a"), at);
      const b = await saveWorkspaceFile(ws, "note.txt", Buffer.from("b"), at);
      const c = await saveWorkspaceFile(ws, "../../../note.txt", Buffer.from("c"), at);
      expect(a).toBe(join(ws, ".nuo/attachments/2026-10-17/note.txt"));
      expect(b).toBe(join(ws, ".nuo/attachments/2026-10-17/note (2).txt"));
      expect(c).toBe(join(ws, ".nuo/attachments/2026-10-17/note (3).txt"));
      expect(readFileSync(b, "utf8")).toBe("b");
    } finally {
      rmSync(ws, { recursive: true, force: true });
    }
  });

  test("limits and types are checked before anything is saved", () => {
    expect(decodeAttachments(undefined)).toEqual([]);
    expect(() => decodeAttachments("x")).toThrow("attachments must be an array");
    expect(() => decodeAttachments([{ kind: "image", mime: "image/svg+xml", dataBase64: b64("<svg/>") }])).toThrow("unsupported image type");
    expect(() => decodeAttachments([{ kind: "image", mime: "image/png", dataBase64: Buffer.alloc(MAX_IMAGE_BYTES + 1).toString("base64") }])).toThrow("10 MB");
    expect(() => decodeAttachments([{ kind: "file", mime: "video/mp4", dataBase64: Buffer.alloc(MAX_FILE_BYTES + 1).toString("base64") }])).toThrow("50 MB");
    const [f] = decodeAttachments([{ kind: "file", mime: "Application/PDF", name: "a.pdf", dataBase64: b64("%PDF") }]);
    expect(f).toMatchObject({ kind: "file", mime: "application/pdf", name: "a.pdf" });
    expect(decodeAttachments([{ kind: "file", mime: "not a mime", dataBase64: b64("x") }])[0]!.mime).toBe("application/octet-stream");
  });

  test("files note lists path, mime and size in French", () => {
    expect(filesNote([])).toBe("");
    const note = filesNote([{ path: "/w/.nuo/attachments/2026-10-17/a.pdf", mime: "application/pdf", size: 1536 }]);
    expect(note).toContain("Fichiers joints");
    expect(note).toContain("- /w/.nuo/attachments/2026-10-17/a.pdf (application/pdf, 1,5 Ko)");
  });
});

describe("REST prompt", () => {
  let t: TestApp;
  let sock: Socket | undefined;
  afterEach(async () => {
    sock?.close();
    sock = undefined;
    await t?.close();
  });

  async function setup(over: Record<string, unknown> = {}) {
    t = await startTestApp();
    const bot = (await t.api("POST", "/api/bots", { name: "Voyages" })).data;
    await t.api("PUT", `/api/bots/${bot.id}/draft`, botConfig(over));
    await t.api("POST", `/api/bots/${bot.id}/publish`, {});
    const conv = (await t.api("POST", "/api/conversations", { botId: bot.id })).data;
    return { bot, conv };
  }

  async function waitMessages(convId: string, n: number) {
    for (let i = 0; i < 100; i++) {
      const msgs = (await t.api("GET", `/api/conversations/${convId}/messages`)).data;
      if (msgs.length >= n) return msgs;
      await Bun.sleep(20);
    }
    throw new Error("timeout waiting for messages");
  }

  test("saves files in the workspace, tells the agent and persists the attachments", async () => {
    const { bot, conv } = await setup({ permissionPolicy: "readonly" });
    const r = await t.api("POST", `/api/conversations/${conv.id}/prompt`, {
      text: "Résume ce rapport",
      attachments: [
        { kind: "file", mime: "application/pdf", name: "rapport.pdf", dataBase64: b64("%PDF-1.7 rapport") },
        { kind: "image", mime: "image/png", dataBase64: PNG_1PX },
      ],
    });
    expect(r.status).toBe(202);
    const msgs = await waitMessages(conv.id, 2);
    expect(msgs[0].id).toBe(r.data.messageId);
    expect(msgs[0].text).toBe("Résume ce rapport");
    const [file, image] = msgs[0].attachments;
    expect(file).toMatchObject({ kind: "file", mime: "application/pdf", name: "rapport.pdf", size: 16 });
    expect(image).toMatchObject({ kind: "image", mime: "image/png", size: 70 });
    const media = await fetch(t.base + file.url, { headers: { authorization: `Bearer ${t.token}` } });
    expect(await media.text()).toBe("%PDF-1.7 rapport");

    const sent = t.runtime.prompts[0]!;
    expect(sent.text).toStartWith("Résume ce rapport\n\n[Nuo] Fichiers joints");
    const path = sent.text.match(/- (\S+\/rapport\.pdf) \(application\/pdf, 16 o\)/)![1]!;
    expect(dirname(dirname(path))).toBe(join(t.profileHome, "bots", bot.slug, ".nuo/attachments"));
    expect(readFileSync(path, "utf8")).toBe("%PDF-1.7 rapport");
    expect(sent.attachments.map((a) => a.kind)).toEqual(["image"]);
    expect(sent.attachments[0]!.dataBase64).toBe(PNG_1PX);

    await t.api("POST", `/api/conversations/${conv.id}/prompt`, {
      text: "",
      attachments: [{ kind: "file", mime: "application/pdf", name: "rapport.pdf", dataBase64: b64("v2") }],
    });
    const again = await waitMessages(conv.id, 4);
    expect(again[2].attachments[0].name).toBe("rapport (2).pdf");
  });

  test("answers stream to sockets; devices without a socket get a push", async () => {
    const { conv } = await setup();
    await t.api("POST", "/api/devices", { apnsToken: "ab".repeat(32), environment: "development" });
    const r = await t.api("POST", `/api/conversations/${conv.id}/prompt`, { text: "Bonjour" });
    expect(r.status).toBe(202);
    await waitMessages(conv.id, 2);
    expect(t.pusher.sent.map((s) => s.payload)).toEqual([{
        title: "✈️ Voyages",
        body: "Hello world",
        botId: conv.botId,
        conversationId: conv.id,
        messageId: expect.any(String),
        destination: { kind: "conversation", id: conv.id, botId: conv.botId },
      },
    ]);

    sock = await Socket.open(t);
    await t.api("POST", `/api/conversations/${conv.id}/prompt`, { text: "Encore" });
    const end = await sock.next("message.end");
    expect(end.stopReason).toBe("end_turn");
    expect(end.scheduled).toBeUndefined();
    expect(t.pusher.sent).toHaveLength(1);
  });

  test("a running command's description reaches the lock screen right after the command starts", async () => {
    const { conv } = await setup();
    await t.api("POST", "/api/devices", { apnsToken: "ab".repeat(32), environment: "development" });
    await t.api("POST", "/api/live-activities", { conversationId: conv.id, pushToken: "CD".repeat(40), environment: "development" });
    await t.api("POST", `/api/conversations/${conv.id}/prompt`, { text: "Surveille le deploy de main" });
    await waitMessages(conv.id, 2);
    const updates = t.pusher.live.filter((p) => p.payload.event === "update").map((p) => p.payload.contentState.currentTool);
    expect(updates).toEqual(["Terminal", "Wait for the deploy workflow on main"]);
  });

  test("a registered Live Activity is ended by push with an alert instead of a regular push", async () => {
    const { conv } = await setup();
    await t.api("POST", "/api/devices", { apnsToken: "ab".repeat(32), environment: "development" });
    const reg = await t.api("POST", "/api/live-activities", { conversationId: conv.id, pushToken: "CD".repeat(40), environment: "development" });
    expect(reg.status).toBe(204);
    await t.api("POST", `/api/conversations/${conv.id}/prompt`, { text: "Bonjour" });
    await waitMessages(conv.id, 2);
    expect(t.pusher.sent).toHaveLength(0);
    expect(t.pusher.live).toHaveLength(1);
    const { target, payload } = t.pusher.live[0]!;
    expect(target).toMatchObject({ pushToken: "cd".repeat(40), environment: "development" });
    expect(payload).toMatchObject({ event: "end", alert: { title: "✈️ Voyages", body: "Hello world" } });
    expect(payload.contentState).toMatchObject({ phase: "done", steps: 0, answer: "Hello world" });
    // Seconds since 2001-01-01, as Swift decodes Date.
    expect(payload.contentState.startedAt as number).toBeGreaterThan(800_000_000);
    expect(payload.contentState.startedAt as number).toBeLessThan(Date.now() / 1000 - 900_000_000);
    expect((await t.api("POST", "/api/live-activities", { conversationId: "nope", pushToken: "ab".repeat(32), environment: "development" })).status).toBe(404);
  });

  test("errors", async () => {
    const { conv } = await setup();
    expect((await t.api("POST", "/api/conversations/missing/prompt", { text: "x" })).status).toBe(404);
    expect((await t.api("POST", `/api/conversations/${conv.id}/prompt`, { text: "  " })).data).toEqual({ error: "empty prompt" });
    const bad = await t.api("POST", `/api/conversations/${conv.id}/prompt`, { text: "x", attachments: [{ kind: "image", mime: "image/tiff", dataBase64: b64("x") }] });
    expect(bad).toEqual({ status: 400, data: { error: "unsupported image type image/tiff" } });
    expect((await t.api("POST", `/api/conversations/${conv.id}/prompt`, { text: "x" }, "wrong")).status).toBe(401);
    expect((await t.api("GET", `/api/conversations/${conv.id}/messages`)).data).toEqual([]);
  });
});
