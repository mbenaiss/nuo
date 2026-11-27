-- Things-like organisation of reminders: areas hold projects, projects hold headings and reminders (docs/data.md).

CREATE TABLE areas (
  id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
  title TEXT NOT NULL CHECK (length(trim(title)) > 0),
  emoji TEXT,
  position REAL NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  archived_at TEXT
);

CREATE TABLE projects (
  id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
  title TEXT NOT NULL CHECK (length(trim(title)) > 0),
  notes TEXT,
  emoji TEXT,
  color TEXT,
  area_id TEXT REFERENCES areas(id),
  deadline TEXT CHECK (deadline IS NULL OR date(deadline) = deadline),
  someday INTEGER NOT NULL DEFAULT 0 CHECK (someday IN (0, 1)),
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'done', 'cancelled')),
  done_at TEXT,
  position REAL NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  archived_at TEXT
);
CREATE INDEX projects_area ON projects(area_id, status, archived_at);

CREATE TABLE project_headings (
  id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
  project_id TEXT NOT NULL REFERENCES projects(id),
  title TEXT NOT NULL CHECK (length(trim(title)) > 0),
  position REAL NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  archived_at TEXT
);
CREATE INDEX project_headings_project ON project_headings(project_id);

ALTER TABLE reminders ADD COLUMN project_id TEXT REFERENCES projects(id);
ALTER TABLE reminders ADD COLUMN area_id TEXT REFERENCES areas(id);
ALTER TABLE reminders ADD COLUMN heading_id TEXT REFERENCES project_headings(id);
ALTER TABLE reminders ADD COLUMN someday INTEGER NOT NULL DEFAULT 0 CHECK (someday IN (0, 1));
ALTER TABLE reminders ADD COLUMN position REAL NOT NULL DEFAULT 0;
-- JSON array of {title, done}.
ALTER TABLE reminders ADD COLUMN checklist TEXT CHECK (checklist IS NULL OR json_type(checklist) = 'array');
CREATE INDEX reminders_project ON reminders(project_id, done_at, archived_at);
CREATE INDEX reminders_area ON reminders(area_id, done_at, archived_at);

-- Free-text lists become areas, so nothing filed before is lost.
INSERT INTO areas (title, position)
  SELECT upper(substr(list, 1, 1)) || substr(list, 2), row_number() OVER (ORDER BY list)
  FROM (SELECT DISTINCT list FROM reminders WHERE list <> 'inbox' AND archived_at IS NULL);
UPDATE reminders SET area_id = (SELECT a.id FROM areas a WHERE lower(a.title) = lower(reminders.list))
  WHERE list <> 'inbox';
