import type { AuthContext, AuthService } from "../auth/service";
import { HttpError, type BotService } from "../bots/service";
import { t } from "../i18n/language";
import { RelayRefusedError, type Runner } from "../runner/runner";
import type { Store } from "../store/store";
import { now as isoNow } from "../store/store";

/** The longest request the relay passes on: a spoken request, not a document. */
export const RELAY_MAX_PROMPT = 4000;
/** A relay request body is read only below this size (a 4,000-character prompt fits several times). */
export const RELAY_MAX_BODY = 16 * 1024;
/** Answers the relay may give to a confirmation: once, either way. */
const RELAY_ANSWERS = new Set(["allow_once", "reject_once"]);

export interface RelayDeps {
  store: Store;
  bots: BotService;
  runner: Runner;
  auth: AuthService;
}

const json = (data: unknown, status = 200) => Response.json(data, { status });

/** Conversations opened by this device's relay: the only ones its tokens may prompt, read or confirm in. */
export function relayOwns(store: Store, conversationId: string, deviceId: string): boolean {
  return !!store.db.query("SELECT 1 FROM relay_conversations WHERE conversation_id = ? AND device_id = ?").get(conversationId, deviceId);
}

/** The body as JSON, refused past `RELAY_MAX_BODY` before it is read (declared length) or while it is (chunked). */
async function cappedBody(req: Request): Promise<Record<string, unknown>> {
  const declared = req.headers.get("content-length");
  if (declared !== null && Number(declared) > RELAY_MAX_BODY) throw new HttpError(413, "request body too large for the relay");
  const reader = req.body?.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (let r = await reader?.read(); r && !r.done; r = await reader!.read()) {
    size += r.value.byteLength;
    if (size > RELAY_MAX_BODY) {
      await reader!.cancel().catch(() => {});
      throw new HttpError(413, "request body too large for the relay");
    }
    chunks.push(r.value);
  }
  try {
    const b = JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
    return b && typeof b === "object" && !Array.isArray(b) ? (b as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

/**
 * Every route a relay token reaches, written out one by one (docs/security.md, "Relay access"). The gate already
 * keeps the token to these paths; here each is narrowed to what the relay opened, and anything else is refused.
 */
export async function relayRoute(d: RelayDeps, path: string, req: Request, ctx: AuthContext, ip: string): Promise<Response> {
  const own = (id: string) => {
    if (!relayOwns(d.store, id, ctx.deviceId)) throw new HttpError(403, "the relay reaches only the conversations it opened");
    const c = d.store.conversation(id);
    if (!c) throw new HttpError(404, "conversation not found");
    return c;
  };
  const event = (type: "relay_permission", ok: boolean, detail: string) => d.auth.event(type, ok, { ip, deviceId: ctx.deviceId, deviceName: ctx.deviceName, detail });
  try {
    if (path === "/api/bots" && req.method === "GET") {
      // Who to ask, nothing of how a bot is set up.
      return json(
        d.store
          .bots()
          .filter((b) => b.published)
          .map((b) => ({ id: b.id, name: b.published!.config.name, emoji: b.published!.config.emoji, ...(b.published!.config.overview ? { overview: true } : {}) })),
      );
    }
    if (path === "/api/conversations" && req.method === "POST") {
      const b = await cappedBody(req);
      const bot = d.bots.get(String(b.botId ?? ""));
      if (!bot.published) throw new HttpError(400, "this bot has no published version");
      if (!d.auth.relayConversation(ctx, `${bot.published.config.name} · ${bot.id}`, ip)) {
        throw new HttpError(429, t("relay.tooManyConversations"));
      }
      const c = d.store.createConversation(bot.id, false, t("relay.conversationTitle"));
      d.store.db.query("INSERT INTO relay_conversations (conversation_id, device_id, created_at) VALUES (?, ?, ?)").run(c.id, ctx.deviceId, isoNow());
      return json({ id: c.id, botId: c.botId, title: c.title, createdAt: c.createdAt, updatedAt: c.updatedAt });
    }
    const m = path.match(/^\/api\/conversations\/([^/]+)(\/messages|\/prompt|\/permission)?$/);
    if (m) {
      let id: string;
      try {
        id = decodeURIComponent(m[1]!);
      } catch {
        throw new HttpError(400, "invalid conversation id");
      }
      const c = own(id);
      if (!m[2] && req.method === "GET") {
        const turn = d.runner.snapshots(c.id)[0];
        // A tool was refused: the iPhone sends the request again through the app once it is unlocked.
        return json({ id: c.id, botId: c.botId, title: c.title, ...(turn ? { turn } : {}), ...(d.runner.relayWaitsForUnlock(c.id) ? { waitsForUnlock: true } : {}) });
      }
      if (m[2] === "/messages" && req.method === "GET") return json(d.store.messages(c.id));
      if (m[2] === "/prompt" && req.method === "POST") {
        const b = await cappedBody(req);
        const text = typeof b.text === "string" ? b.text.trim() : "";
        if (!text) throw new HttpError(400, "empty prompt");
        if (text.length > RELAY_MAX_PROMPT) throw new HttpError(413, "prompt too long for the relay");
        if (Object.keys(b).some((k) => k !== "text")) throw new HttpError(400, "the relay sends text only");
        const bot = d.store.bot(c.botId);
        if (!d.auth.relayPrompt(ctx, `${bot?.published?.config.name ?? c.botId} · ${c.id}`, ip)) {
          throw new HttpError(429, t("relay.tooManyPrompts"));
        }
        const { messageId } = await d.runner.prompt({ conversationId: c.id, text }, { relay: { deviceId: ctx.deviceId, conversationId: c.id }, untrusted: true });
        return json({ messageId }, 202);
      }
      if (m[2] === "/permission" && req.method === "POST") {
        const b = await cappedBody(req);
        const requestId = typeof b.requestId === "string" ? b.requestId : "";
        const optionId = typeof b.optionId === "string" ? b.optionId : "";
        const pending = d.runner.pendingPermission(requestId);
        if (!pending || pending.conversationId !== c.id) throw new HttpError(404, "unknown or expired permission request");
        // Asked by the app's own turn in this conversation (unlocked since): answered in the app.
        if (!pending.relay) throw new HttpError(403, "this confirmation is answered in the app");
        const option = pending.options.find((o) => o.id === optionId);
        if (!option || !RELAY_ANSWERS.has(option.kind)) throw new HttpError(403, "the relay answers once, either way; anything else is decided in the app");
        if (!d.runner.answerPermission(requestId, optionId)) throw new HttpError(404, "unknown or expired permission request");
        event("relay_permission", true, `${option.kind} · ${pending.tool ?? "?"} · ${pending.title} · ${c.id}`);
        return json({ ok: true });
      }
    }
    return json({ error: "forbidden" }, 403);
  } catch (e) {
    if (e instanceof RelayRefusedError) return json({ error: e.message, ...(e.status === 409 ? { waitsForUnlock: true } : {}) }, e.status);
    if (e instanceof HttpError) return json({ error: e.message }, e.status);
    throw e;
  }
}
