-- Calendar mirror bridged by the apps from EventKit, booking types and bookings (docs/calendar.md).
-- Instants are normalized ISO 8601 UTC strings ("…T…:…:….000Z") so text comparison is chronological.

CREATE TABLE calendars (
  id TEXT PRIMARY KEY,
  key TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  account TEXT,
  type TEXT,
  device_color TEXT,
  color_override TEXT CHECK (color_override IS NULL OR color_override GLOB '#[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]'),
  allows_modifications INTEGER NOT NULL DEFAULT 1 CHECK (allows_modifications IN (0,1)),
  enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0,1)),
  privacy TEXT NOT NULL DEFAULT 'full' CHECK (privacy IN ('full','busy')),
  counts_for_availability INTEGER NOT NULL DEFAULT 1 CHECK (counts_for_availability IN (0,1)),
  needs_resync INTEGER NOT NULL DEFAULT 0 CHECK (needs_resync IN (0,1)),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TABLE calendar_sources (
  id TEXT PRIMARY KEY,
  calendar_id TEXT NOT NULL REFERENCES calendars(id),
  device_id TEXT NOT NULL,
  device_name TEXT,
  calendar_identifier TEXT NOT NULL,
  title TEXT NOT NULL,
  color TEXT,
  account TEXT,
  type TEXT,
  allows_modifications INTEGER NOT NULL DEFAULT 1,
  synced_at TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  UNIQUE (device_id, calendar_identifier)
);
CREATE INDEX calendar_sources_calendar ON calendar_sources(calendar_id, synced_at);

CREATE TABLE calendar_events (
  id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
  source_id TEXT NOT NULL REFERENCES calendar_sources(id) ON DELETE CASCADE,
  calendar_id TEXT NOT NULL,
  external_id TEXT NOT NULL,
  series_id TEXT,
  title TEXT,
  location TEXT,
  lat REAL,
  lon REAL,
  notes TEXT,
  url TEXT,
  conference_url TEXT,
  start_at TEXT NOT NULL,
  end_at TEXT NOT NULL,
  all_day INTEGER NOT NULL DEFAULT 0 CHECK (all_day IN (0,1)),
  availability TEXT NOT NULL DEFAULT 'busy' CHECK (availability IN ('busy','free','tentative','unavailable')),
  status TEXT CHECK (status IS NULL OR status IN ('confirmed','tentative','cancelled')),
  attendees_json TEXT CHECK (attendees_json IS NULL OR json_valid(attendees_json)),
  attendees_count INTEGER NOT NULL DEFAULT 0,
  organizer_json TEXT CHECK (organizer_json IS NULL OR json_valid(organizer_json)),
  travel_time_sec INTEGER,
  has_alarms INTEGER NOT NULL DEFAULT 0 CHECK (has_alarms IN (0,1)),
  sync_id TEXT,
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  UNIQUE (source_id, external_id)
);
CREATE INDEX calendar_events_range ON calendar_events(calendar_id, start_at, end_at);
CREATE INDEX calendar_events_source_range ON calendar_events(source_id, start_at);

CREATE TABLE booking_types (
  id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
  slug TEXT NOT NULL UNIQUE CHECK (slug GLOB '[a-z0-9]*' AND slug NOT GLOB '*[^a-z0-9-]*' AND length(slug) BETWEEN 1 AND 40),
  kind TEXT NOT NULL DEFAULT 'opening' CHECK (kind IN ('opening','proposal')),
  title TEXT NOT NULL CHECK (length(trim(title)) > 0),
  description TEXT,
  duration_min INTEGER NOT NULL CHECK (duration_min BETWEEN 5 AND 720),
  location_kind TEXT NOT NULL DEFAULT 'google_meet' CHECK (location_kind IN ('google_meet','phone','address','custom')),
  location_value TEXT,
  working_hours TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(working_hours)),
  buffer_before_min INTEGER NOT NULL DEFAULT 0 CHECK (buffer_before_min >= 0),
  buffer_after_min INTEGER NOT NULL DEFAULT 0 CHECK (buffer_after_min >= 0),
  min_notice_min INTEGER NOT NULL DEFAULT 240 CHECK (min_notice_min >= 0),
  max_days_ahead INTEGER NOT NULL DEFAULT 60 CHECK (max_days_ahead BETWEEN 1 AND 365),
  max_per_day INTEGER CHECK (max_per_day IS NULL OR max_per_day >= 1),
  slot_step_min INTEGER CHECK (slot_step_min IS NULL OR slot_step_min BETWEEN 5 AND 720),
  google_calendar TEXT,
  questions TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(questions)),
  candidate_slots TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(candidate_slots)),
  active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0,1)),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  archived_at TEXT
);

CREATE TABLE bookings (
  id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
  type_id TEXT NOT NULL REFERENCES booking_types(id),
  start_at TEXT NOT NULL,
  end_at TEXT NOT NULL CHECK (end_at > start_at),
  status TEXT NOT NULL CHECK (status IN ('pending','confirmed','cancelled','rescheduled','failed')),
  invitee_name TEXT NOT NULL,
  invitee_email TEXT NOT NULL,
  invitee_timezone TEXT,
  invitee_notes TEXT,
  answers TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(answers)),
  google_target TEXT,
  google_event_id TEXT,
  meet_url TEXT,
  manage_token_hash TEXT UNIQUE,
  rescheduled_from TEXT REFERENCES bookings(id),
  cancel_reason TEXT,
  ip TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX bookings_range ON bookings(status, start_at, end_at);
CREATE INDEX bookings_type ON bookings(type_id, start_at);

CREATE TRIGGER bookings_no_delete BEFORE DELETE ON bookings BEGIN
  SELECT RAISE(ABORT, 'bookings are never deleted: set status = cancelled');
END;

-- For agents: what is coming up, from the copy of each calendar whose last full sync is the most recent.
CREATE VIEW v_agenda AS
SELECT 'event' AS kind, e.id, c.title AS calendar,
       CASE WHEN c.privacy = 'busy' THEN 'Occupé' ELSE coalesce(e.title, '(sans titre)') END AS title,
       CASE WHEN c.privacy = 'busy' THEN NULL ELSE e.location END AS location,
       e.start_at, e.end_at, e.all_day, CASE WHEN c.privacy = 'busy' THEN 1 ELSE 0 END AS busy_only, NULL AS done
FROM calendar_events e
JOIN calendars c ON c.id = e.calendar_id AND c.enabled = 1
WHERE e.source_id = (SELECT s.id FROM calendar_sources s WHERE s.calendar_id = c.id ORDER BY s.synced_at DESC NULLS LAST, s.id LIMIT 1)
  AND coalesce(e.status, 'confirmed') <> 'cancelled'
  AND e.end_at >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-1 day')
  AND e.start_at <= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '+180 days')
UNION ALL
SELECT 'reminder', r.id, r.list, r.title, NULL, r.due_at, r.due_at, 0, 0, CASE WHEN r.done_at IS NULL THEN 0 ELSE 1 END
FROM reminders r
WHERE r.archived_at IS NULL AND r.done_at IS NULL AND r.due_at IS NOT NULL
  AND r.due_at >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-1 day')
  AND r.due_at <= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '+180 days');
