-- History of one collection, newest first (GET /api/data/history?collection=) without sorting all its changes.
CREATE INDEX _history_table ON _history(table_name, id);
