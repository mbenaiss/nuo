-- Event alarms as the bridge reads them, and travel times the apps compute (MapKit, from a place the user chose).
-- Travel times live apart from the mirror rows: a sync rewrites those rows and the copy served may change device.
ALTER TABLE calendar_events ADD COLUMN alarms_json TEXT CHECK (alarms_json IS NULL OR json_valid(alarms_json));

CREATE TABLE calendar_event_travel (
  calendar_id TEXT NOT NULL,
  external_id TEXT NOT NULL,
  travel_time_sec INTEGER NOT NULL CHECK (travel_time_sec BETWEEN 0 AND 86400),
  mode TEXT CHECK (mode IS NULL OR mode IN ('driving','transit','walking','cycling')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  PRIMARY KEY (calendar_id, external_id)
);
