-- Location reminders: saved places and the place a reminder fires at (on the iPhone, never pushed by the gateway).

CREATE TABLE places (
  id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
  name TEXT NOT NULL CHECK (length(trim(name)) > 0),
  address TEXT,
  lat REAL NOT NULL CHECK (lat BETWEEN -90 AND 90),
  lon REAL NOT NULL CHECK (lon BETWEEN -180 AND 180),
  radius_m REAL NOT NULL DEFAULT 150 CHECK (radius_m > 0),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  archived_at TEXT
);

ALTER TABLE reminders ADD COLUMN place_id TEXT REFERENCES places(id);
ALTER TABLE reminders ADD COLUMN place_trigger TEXT
  CHECK ((place_trigger IS NULL AND place_id IS NULL) OR (place_id IS NOT NULL AND place_trigger IN ('arrive', 'leave')));
CREATE INDEX reminders_place ON reminders(place_id);
