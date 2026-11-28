import type { Database } from "bun:sqlite";
import { newId, now } from "../store/store";

/**
 * What wakes a bot from outside (docs/protocol.md, "Wake-ups from outside"): webhooks, its mail alias, the conversation each
 * sender's mails go to, and the Message-IDs already handled.
 */
export const wakeMigration = `
  CREATE TABLE hooks (
    id TEXT PRIMARY KEY,
    bot_id TEXT NOT NULL REFERENCES bots(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    token_hash TEXT NOT NULL UNIQUE,
    notify INTEGER NOT NULL DEFAULT 1,
    conversation_id TEXT REFERENCES conversations(id) ON DELETE SET NULL,
    calls INTEGER NOT NULL DEFAULT 0,
    last_called_at TEXT,
    created_at TEXT NOT NULL
  );
  CREATE INDEX hooks_bot ON hooks(bot_id);
  CREATE TABLE mail_aliases (
    bot_id TEXT PRIMARY KEY REFERENCES bots(id) ON DELETE CASCADE,
    alias TEXT NOT NULL UNIQUE
  );
  CREATE TABLE mail_threads (
    bot_id TEXT NOT NULL REFERENCES bots(id) ON DELETE CASCADE,
    thread TEXT NOT NULL,
    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    PRIMARY KEY (bot_id, thread)
  );
  CREATE TABLE mail_seen (
    message_id TEXT PRIMARY KEY,
    seen_at TEXT NOT NULL
  );
`;

export interface Hook {
  id: string;
  botId: string;
  name: string;
  notify: boolean;
  conversationId?: string;
  calls: number;
  lastCalledAt?: string;
  createdAt: string;
}

type Row = Record<string, any>;

const toHook = (r: Row): Hook => ({
  id: r.id,
  botId: r.bot_id,
  name: r.name,
  notify: !!r.notify,
  ...(r.conversation_id ? { conversationId: r.conversation_id } : {}),
  calls: r.calls,
  ...(r.last_called_at ? { lastCalledAt: r.last_called_at } : {}),
  createdAt: r.created_at,
});

/** Message-IDs are kept this long: a mail server retries for days, not months. */
const SEEN_DAYS = 30;

export class WakeStore {
  constructor(private db: Database) {}

  hooks(botId: string): Hook[] {
    return (this.db.query("SELECT * FROM hooks WHERE bot_id = ? ORDER BY created_at, rowid").all(botId) as Row[]).map(toHook);
  }

  hook(id: string): Hook | undefined {
    const r = this.db.query("SELECT * FROM hooks WHERE id = ?").get(id) as Row | null;
    return r ? toHook(r) : undefined;
  }

  hookByTokenHash(hash: string): Hook | undefined {
    const r = this.db.query("SELECT * FROM hooks WHERE token_hash = ?").get(hash) as Row | null;
    return r ? toHook(r) : undefined;
  }

  addHook(botId: string, name: string, tokenHash: string, notify: boolean): Hook {
    const id = newId();
    this.db.query("INSERT INTO hooks (id, bot_id, name, token_hash, notify, created_at) VALUES (?, ?, ?, ?, ?, ?)").run(id, botId, name, tokenHash, notify ? 1 : 0, now());
    return this.hook(id)!;
  }

  setHookNotify(id: string, notify: boolean) {
    this.db.query("UPDATE hooks SET notify = ? WHERE id = ?").run(notify ? 1 : 0, id);
  }

  setHookConversation(id: string, conversationId: string) {
    this.db.query("UPDATE hooks SET conversation_id = ? WHERE id = ?").run(conversationId, id);
  }

  countHookCall(id: string) {
    this.db.query("UPDATE hooks SET calls = calls + 1, last_called_at = ? WHERE id = ?").run(now(), id);
  }

  deleteHook(id: string): boolean {
    return this.db.query("DELETE FROM hooks WHERE id = ?").run(id).changes > 0;
  }

  mailAlias(botId: string): string | undefined {
    return (this.db.query("SELECT alias FROM mail_aliases WHERE bot_id = ?").get(botId) as Row | null)?.alias ?? undefined;
  }

  botByAlias(alias: string): string | undefined {
    return (this.db.query("SELECT bot_id FROM mail_aliases WHERE alias = ?").get(alias) as Row | null)?.bot_id ?? undefined;
  }

  setMailAlias(botId: string, alias: string | undefined) {
    if (alias) this.db.query("INSERT INTO mail_aliases (bot_id, alias) VALUES (?, ?) ON CONFLICT(bot_id) DO UPDATE SET alias = excluded.alias").run(botId, alias);
    else this.db.query("DELETE FROM mail_aliases WHERE bot_id = ?").run(botId);
  }

  mailThread(botId: string, thread: string): string | undefined {
    return (this.db.query("SELECT conversation_id FROM mail_threads WHERE bot_id = ? AND thread = ?").get(botId, thread) as Row | null)?.conversation_id ?? undefined;
  }

  setMailThread(botId: string, thread: string, conversationId: string) {
    this.db
      .query("INSERT INTO mail_threads (bot_id, thread, conversation_id) VALUES (?, ?, ?) ON CONFLICT(bot_id, thread) DO UPDATE SET conversation_id = excluded.conversation_id")
      .run(botId, thread, conversationId);
  }

  /** False when this bot already handled this Message-ID: the Worker or the mail server tried again. */
  markMailSeen(key: string, at = new Date()): boolean {
    this.db.query("DELETE FROM mail_seen WHERE seen_at < ?").run(new Date(at.getTime() - SEEN_DAYS * 86_400_000).toISOString());
    return this.db.query("INSERT OR IGNORE INTO mail_seen (message_id, seen_at) VALUES (?, ?)").run(key, at.toISOString()).changes > 0;
  }

  forgetMail(key: string) {
    this.db.query("DELETE FROM mail_seen WHERE message_id = ?").run(key);
  }
}
