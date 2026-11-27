import { Database } from "bun:sqlite";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { defaultLayout } from "../paths";
import { uniqueSlug } from "./slug";
import { authMigration } from "../auth/schema";
import { googleMigration } from "../google/schema";
import { wakeMigration } from "../hooks/store";

export function defaultDataDir(): string {
  return defaultLayout().data;
}

type Migration = string | ((db: Database) => void);

function backfillSlugs(db: Database) {
  db.exec("ALTER TABLE bots ADD COLUMN slug TEXT");
  const rows = db
    .query(
      `SELECT b.id, b.draft,
         (SELECT v.config FROM bot_versions v WHERE v.bot_id = b.id ORDER BY v.version DESC LIMIT 1) AS config
       FROM bots b ORDER BY b.created_at, b.rowid`,
    )
    .all() as { id: string; draft: string | null; config: string | null }[];
  const taken = new Set<string>();
  const set = db.query("UPDATE bots SET slug = ? WHERE id = ?");
  for (const r of rows) {
    const name = (r.config ? JSON.parse(r.config).name : undefined) ?? (r.draft ? JSON.parse(r.draft).name : undefined) ?? "bot";
    const slug = uniqueSlug(String(name), (s) => taken.has(s));
    taken.add(slug);
    set.run(slug, r.id);
  }
  db.exec("CREATE UNIQUE INDEX bots_slug ON bots(slug)");
}

export const MIGRATIONS: Migration[] = [
  `
  CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
  CREATE TABLE devices (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    token_hash TEXT NOT NULL UNIQUE,
    apns_token TEXT,
    apns_env TEXT,
    created_at TEXT NOT NULL,
    last_seen_at TEXT
  );
  CREATE TABLE pair_codes (
    code_hash TEXT PRIMARY KEY,
    expires_at INTEGER NOT NULL
  );
  CREATE TABLE bots (
    id TEXT PRIMARY KEY,
    draft TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );
  CREATE TABLE bot_versions (
    bot_id TEXT NOT NULL REFERENCES bots(id) ON DELETE CASCADE,
    version INTEGER NOT NULL,
    config TEXT NOT NULL,
    note TEXT,
    published_at TEXT NOT NULL,
    PRIMARY KEY (bot_id, version)
  );
  CREATE TRIGGER bot_versions_immutable BEFORE UPDATE ON bot_versions
    BEGIN SELECT RAISE(ABORT, 'bot versions are immutable'); END;
  CREATE TABLE conversations (
    id TEXT PRIMARY KEY,
    bot_id TEXT NOT NULL REFERENCES bots(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    use_draft INTEGER NOT NULL DEFAULT 0,
    model TEXT,
    effort TEXT,
    agent_id TEXT,
    agent_session_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );
  CREATE INDEX conversations_bot ON conversations(bot_id, updated_at);
  CREATE TABLE messages (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    role TEXT NOT NULL,
    text TEXT NOT NULL,
    thoughts TEXT,
    attachments TEXT,
    steps TEXT,
    duration_ms INTEGER,
    stop_reason TEXT,
    created_at TEXT NOT NULL
  );
  CREATE INDEX messages_conversation ON messages(conversation_id);
  `,
  `ALTER TABLE conversations ADD COLUMN context TEXT;`,
  `
  CREATE TABLE schedules (
    id TEXT PRIMARY KEY,
    bot_id TEXT NOT NULL REFERENCES bots(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    prompt TEXT NOT NULL,
    schedule TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    conversation TEXT NOT NULL DEFAULT 'dedicated',
    conversation_id TEXT REFERENCES conversations(id) ON DELETE SET NULL,
    notify INTEGER NOT NULL DEFAULT 1,
    created_by TEXT NOT NULL DEFAULT 'user',
    next_run_at TEXT,
    last_run_at TEXT,
    last_status TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );
  CREATE INDEX schedules_bot ON schedules(bot_id);
  CREATE TABLE task_runs (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL REFERENCES schedules(id) ON DELETE CASCADE,
    conversation_id TEXT NOT NULL,
    started_at TEXT NOT NULL,
    ended_at TEXT,
    status TEXT NOT NULL,
    preview TEXT,
    error TEXT
  );
  CREATE INDEX task_runs_task ON task_runs(task_id, started_at);
  `,
  backfillSlugs,
  `
  ALTER TABLE schedules ADD COLUMN action TEXT;
  ALTER TABLE schedules ADD COLUMN alert_open INTEGER NOT NULL DEFAULT 0;
  ALTER TABLE task_runs ADD COLUMN exit_code INTEGER;
  ALTER TABLE task_runs ADD COLUMN output TEXT;
  ALTER TABLE task_runs ADD COLUMN duration_ms INTEGER;
  `,
  authMigration,
  googleMigration,
  `
  ALTER TABLE conversations ADD COLUMN agent TEXT;
  ALTER TABLE conversations ADD COLUMN agent_sessions TEXT;
  ALTER TABLE messages ADD COLUMN agent TEXT;
  ALTER TABLE messages ADD COLUMN model TEXT;
  `,
  `ALTER TABLE messages ADD COLUMN subagents TEXT;`,
  // A second device key, used only to sign one sensitive action each time, behind Face ID.
  `ALTER TABLE devices ADD COLUMN action_key TEXT;`,
  `ALTER TABLE messages ADD COLUMN task TEXT;`,
  // How fast each agent answer came (src/metrics/latency.ts); kept apart from messages, which a deleted conversation takes away.
  `
  CREATE TABLE turn_metrics (
    message_id TEXT PRIMARY KEY,
    bot_id TEXT NOT NULL REFERENCES bots(id) ON DELETE CASCADE,
    conversation_id TEXT NOT NULL,
    origin TEXT NOT NULL,
    started_at TEXT NOT NULL,
    first_event_ms INTEGER,
    first_text_ms INTEGER,
    duration_ms INTEGER NOT NULL,
    tool_ms INTEGER NOT NULL,
    steps INTEGER NOT NULL,
    stop_reason TEXT NOT NULL,
    agent TEXT NOT NULL,
    model TEXT
  );
  CREATE INDEX turn_metrics_started ON turn_metrics(started_at);
  `,
  // Every alert pushed to the devices, so one that leaves no message anywhere can still be found in the app.
  `
  CREATE TABLE alerts (
    id TEXT PRIMARY KEY,
    bot_id TEXT,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    destination TEXT NOT NULL,
    created_at TEXT NOT NULL,
    read_at TEXT
  );
  CREATE INDEX alerts_created ON alerts(created_at);
  `,
  // Full-text index of every message, to find a conversation across all bots by what was said in it.
  `
  CREATE VIRTUAL TABLE message_search USING fts5(text, content='messages', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2');
  INSERT INTO message_search(rowid, text) SELECT rowid, text FROM messages;
  CREATE TRIGGER messages_search_insert AFTER INSERT ON messages BEGIN
    INSERT INTO message_search(rowid, text) VALUES (new.rowid, new.text);
  END;
  CREATE TRIGGER messages_search_delete AFTER DELETE ON messages BEGIN
    INSERT INTO message_search(message_search, rowid, text) VALUES ('delete', old.rowid, old.text);
  END;
  CREATE TRIGGER messages_search_update AFTER UPDATE OF text ON messages BEGIN
    INSERT INTO message_search(message_search, rowid, text) VALUES ('delete', old.rowid, old.text);
    INSERT INTO message_search(rowid, text) VALUES (new.rowid, new.text);
  END;
  `,
  // The relay key (the watch's requests while the iPhone is locked) and the conversations its tokens opened: they
  // may prompt, read and confirm in those only.
  `
  ALTER TABLE devices ADD COLUMN relay_key TEXT;
  ALTER TABLE devices ADD COLUMN relay_key_at TEXT;
  ALTER TABLE auth_tokens ADD COLUMN step_up_reason TEXT;
  CREATE TABLE relay_conversations (
    conversation_id TEXT PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,
    device_id TEXT NOT NULL,
    created_at TEXT NOT NULL
  );
  `,
  // Webhooks and mail that wake a bot from outside (src/hooks/).
  wakeMigration,
  `ALTER TABLE messages ADD COLUMN wake TEXT;`,
  // NULL for the devices paired before it: their apps used the earlier name (src/compat/app-names.ts).
  `ALTER TABLE devices ADD COLUMN app_naming TEXT;`,
];

export function openDb(dataDir: string): Database {
  mkdirSync(dataDir, { recursive: true });
  const db = new Database(join(dataDir, "nuo.db"), { create: true, strict: true });
  // NORMAL in WAL mode only syncs at checkpoints: a power cut can lose the last commits, never corrupt the file.
  db.exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;");
  const current = (db.query("PRAGMA user_version").get() as { user_version: number }).user_version;
  for (let v = current; v < MIGRATIONS.length; v++) {
    db.transaction(() => {
      const m = MIGRATIONS[v]!;
      if (typeof m === "string") db.exec(m);
      else m(db);
      db.exec(`PRAGMA user_version = ${v + 1}`);
    })();
  }
  return db;
}
