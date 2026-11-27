import type { Database } from "bun:sqlite";

/**
 * Device-bound keys, short-lived access tokens, TOTP and the audit log. `devices` is rebuilt so that
 * `token_hash` (the long-lived token of builds before 2FA) becomes optional: rows that still have one are
 * legacy devices, refused with `reauth: true` until they pair again.
 */
export function authMigration(db: Database) {
  db.exec(`
  CREATE TABLE devices_v2 (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    platform TEXT,
    public_key TEXT,
    token_hash TEXT UNIQUE,
    apns_token TEXT,
    apns_env TEXT,
    created_at TEXT NOT NULL,
    last_seen_at TEXT
  );
  INSERT INTO devices_v2 (id, name, token_hash, apns_token, apns_env, created_at, last_seen_at)
    SELECT id, name, token_hash, apns_token, apns_env, created_at, last_seen_at FROM devices;
  DROP TABLE devices;
  ALTER TABLE devices_v2 RENAME TO devices;

  CREATE TABLE auth_tokens (
    token_hash TEXT PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    scope TEXT NOT NULL,
    step_up_at INTEGER,
    cnf TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
  );
  CREATE INDEX auth_tokens_device ON auth_tokens(device_id, scope);

  CREATE TABLE auth_totp (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    secret_enc TEXT NOT NULL,
    last_step INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
  );
  CREATE TABLE auth_recovery_codes (
    code_hash TEXT PRIMARY KEY,
    used_at TEXT
  );

  CREATE TABLE auth_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    at INTEGER NOT NULL,
    type TEXT NOT NULL,
    ok INTEGER NOT NULL,
    ip TEXT,
    device_id TEXT,
    device_name TEXT,
    detail TEXT
  );
  CREATE INDEX auth_events_at ON auth_events(at);
  CREATE INDEX auth_events_fail ON auth_events(type, ok, at);

  CREATE TABLE auth_requests (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    at INTEGER NOT NULL,
    ip TEXT NOT NULL,
    method TEXT NOT NULL,
    route TEXT NOT NULL,
    status INTEGER NOT NULL,
    device_id TEXT
  );
  CREATE INDEX auth_requests_at ON auth_requests(at);
  `);
}
