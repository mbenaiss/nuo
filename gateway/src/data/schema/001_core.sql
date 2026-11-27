-- Metadata, history and reminders shared by every collection (docs/data.md).

CREATE TABLE _collections (
  id TEXT PRIMARY KEY,
  label TEXT NOT NULL,
  emoji TEXT,
  table_name TEXT NOT NULL UNIQUE,
  view_name TEXT NOT NULL,
  title_column TEXT NOT NULL,
  default_sort TEXT,
  notion_slug TEXT UNIQUE,
  position INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE _columns (
  collection_id TEXT NOT NULL REFERENCES _collections(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  label TEXT NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('text','longtext','number','money','percent','date','datetime','bool','select','multiselect','ref','refs','url','file')),
  options TEXT CHECK (options IS NULL OR json_valid(options)),
  ref_collection TEXT,
  computed INTEGER NOT NULL DEFAULT 0 CHECK (computed IN (0,1)),
  hidden INTEGER NOT NULL DEFAULT 0 CHECK (hidden IN (0,1)),
  position INTEGER NOT NULL DEFAULT 0,
  notion_name TEXT,
  PRIMARY KEY (collection_id, name)
);

-- Many-to-many relations: one junction table per relation, one row here per side. The importer fills them
-- from the Notion relation named notion_name; views expose them as `refs` columns (JSON arrays of ids).
CREATE TABLE _links (
  collection_id TEXT NOT NULL REFERENCES _collections(id) ON DELETE CASCADE,
  column_name TEXT NOT NULL,
  table_name TEXT NOT NULL,
  from_column TEXT NOT NULL,
  to_column TEXT NOT NULL,
  target_collection TEXT NOT NULL,
  notion_name TEXT,
  PRIMARY KEY (collection_id, column_name)
);

CREATE TABLE _history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  table_name TEXT NOT NULL,
  row_id TEXT NOT NULL,
  op TEXT NOT NULL CHECK (op IN ('insert','update','archive','unarchive','delete','revert')),
  old_json TEXT,
  new_json TEXT,
  source TEXT NOT NULL DEFAULT 'agent'
);
CREATE INDEX _history_row ON _history(table_name, row_id, id);

-- One row. The gateway sets source/op inside its own write transactions, so other connections
-- (agents using sqlite3) always see NULL and their changes are recorded as 'agent'.
CREATE TABLE _context (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  source TEXT,
  op TEXT
);
INSERT INTO _context (id) VALUES (1);

CREATE TABLE reminders (
  id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
  title TEXT NOT NULL CHECK (length(trim(title)) > 0),
  notes TEXT,
  due_at TEXT CHECK (due_at IS NULL OR julianday(due_at) IS NOT NULL),
  repeat TEXT,
  list TEXT NOT NULL DEFAULT 'inbox',
  priority INTEGER NOT NULL DEFAULT 0 CHECK (priority BETWEEN 0 AND 3),
  done_at TEXT,
  snoozed_until TEXT CHECK (snoozed_until IS NULL OR julianday(snoozed_until) IS NOT NULL),
  notified_at TEXT,
  source_ref TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  archived_at TEXT
);
CREATE INDEX reminders_due ON reminders(done_at, archived_at, due_at);
