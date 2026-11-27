import type { Database } from "bun:sqlite";

/** One profile's Google accounts; the refresh token is sealed (src/google/accounts.ts). */
export function googleMigration(db: Database) {
  db.exec(`
  CREATE TABLE google_accounts (
    email TEXT PRIMARY KEY,
    sub TEXT,
    scopes TEXT NOT NULL,
    token_enc TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'ok' CHECK (status IN ('ok', 'error')),
    last_error TEXT,
    connected_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    last_used_at TEXT
  );
  `);
}
