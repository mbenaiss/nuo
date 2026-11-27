# Data, docs, reminders and dashboards

Nuo replaces a notes app and a to-do app. Everything lives on the gateway host under `~/nuo/`, is written mostly
by agents and read/edited by you in the apps. There is no MCP for this: agents that have a shell work
directly on the files and the database; the app goes through the gateway REST API below.

```
~/nuo/
  data/data.db          SQLite, one real table per collection + reminders + history (WAL, foreign keys on)
  docs/                 git repository of Markdown files (notes, plans, santé, homelab, voyages…)
  dashboards/<slug>.json  dashboard definitions (SQL queries + display type)
```

`data.db` is separate from the gateway's own `nuo.db` (conversations, devices…). The calendar mirror, booking
types and bookings (`006_calendar.sql`, view `v_agenda`) are described in [calendar.md](calendar.md).

## Database rules (enforced by the schema, whoever writes)

- One table per collection, snake_case, with typed columns, `CHECK` constraints and foreign keys
  (`invoices.client_id → clients.id`). Every table has `id TEXT PRIMARY KEY` (random when omitted), `notion_id`
  (unique, set by the importer), `created_at`, `updated_at` (bumped by a trigger when a writer forgets it),
  `archived_at` (NULL = active). Nothing is hard-deleted by the app; agents archive too.
- Notion formulas become SQL views `v_<table>` (e.g. a `v_invoices` view adding `net`, `vat`, `total`, `year`, `month`).
  Reads for display always go through the view.
- `_history(id, at, table_name, row_id, op, old_json, new_json, source)` is filled by triggers on every
  table, so every change by an agent or the app is recorded and can be reverted. `source` is `app` when the
  gateway writes (it sets it through a `_context(id = 1, source, op)` single-row table inside the same transaction),
  `import` for the importer, else `agent`. `op` ∈ insert, update, archive, unarchive, delete (an agent ignoring the
  rule), revert. The triggers are generated from `_collections` (+ `reminders`) at every gateway start and by
  `bun run src/cli.ts data-triggers` (to run after adding a column or a collection by hand).
- Schema lives in `gateway/src/data/schema/NNN_*.sql`, each applied once (`_migrations`). The repository ships
  the generic tables (reminders, places, calendar, projects, parcels). Your own hand-written collections (finance,
  invoices, budgets...) go in extra `NNN_*.sql` files of your [private overlay](private-overlay.md)
  (`private/gateway/src/data/schema/`), with the same rules. Other Notion databases get a generated table at
  import (see Import).
- Many-to-many relations use a link table (e.g. `budget_expenses(budget_id,
  expense_id)`), described per side in `_links(collection_id, column_name, table_name, from_column, to_column,
  target_collection, notion_name)`. Link tables have history too; unlinking = deleting the link row. Views expose
  them as `refs` columns.
- `_collections` and `_columns` describe each collection for the app (label, emoji, table, view, title column,
  default sort; per column: name, label, type, options, ref collection, computed, hidden, order).
  Column types: `text`, `longtext`, `number`, `money` (EUR, 2 decimals), `percent` (a fraction: 0.2 = 20 %), `date` (`YYYY-MM-DD`),
  `datetime` (ISO 8601, UTC), `bool` (0/1 in SQL, JSON booleans in the API), `select`, `multiselect` (JSON array),
  `ref`, `refs` (JSON array of row ids of `ref` collection, read-only, from a link table), `url`, `file` (JSON array of `{name, path?, url?}`; `path` is relative to `data/files/`, `url` is kept
  when Notion's file could not be downloaded). `_columns.notion_name` maps a column to its Notion property.
- `reminders(id, title, notes, due_at, repeat, list, priority, done_at, snoozed_until, notified_at, source_ref,
  created_at, updated_at, archived_at)`. `list` defaults to `inbox`. `repeat` is NULL or a 5-field cron in Europe/Paris
  (or `daily|weekly|monthly|yearly` shortcuts, which keep the Paris time/day of `due_at`). A done repeating
  reminder is not closed: it gets its next `due_at` (first occurrence after max(due_at, now)). `notified_at` is set
  when the push leaves and cleared when `due_at` changes, on snooze and on undone.
- Things-like organisation (migration 007): `areas(id, title, emoji, position, …)`, `projects(id, title, notes, emoji,
  color, area_id, deadline YYYY-MM-DD, someday 0/1, status open|done|cancelled, done_at, position, …)`,
  `project_headings(id, project_id, title, position, …)`. `reminders` gains `project_id`, `area_id`, `heading_id`,
  `someday` (0/1), `position` and `checklist` (JSON `[{title, done}]`). A reminder is in a project (optionally under a
  heading), or directly in an area, or in the inbox (neither); setting one side clears the other and a heading implies
  its project. `list` is legacy: migration 007 turned every non-inbox list into an area. All three tables have history.

## REST (all under the paired-device token)

Writes to finance collections, history reverts, `DELETE /api/docs/file` and `DELETE /api/docs/folder` need a recent biometric step-up
(403 `{stepUp: true, reason}` otherwise); see [protocol.md](protocol.md#step-up-scope).

| Method & path | Body | Response |
|---|---|---|
| `GET /api/data/collections` | | `DataCollection[]` (`{id, label, emoji, count, columns: DataColumn[], titleColumn, defaultSort}`) |
| `GET /api/data/collections/:id/rows?q=&sort=col:asc&filter=col:op:value&limit=50&cursor=` | | `{rows: DataRow[], nextCursor?, total}`; `op` ∈ eq, ne, lt, lte, gt, gte, contains, in, empty, notempty; archived rows excluded unless `archived=1`. `filter` and `sort` repeat (AND / successive keys); default sort = `defaultSort`; `in` takes comma-separated values (the whole `filter` parameter URL-encoded, e.g. `filter=client%3Ain%3AClient%20A%2CClient%20B`; a value cannot contain a comma); bool values are `true`/`false`/`1`/`0`; `contains` on a multiselect matches one option; `q` searches the text columns; `limit` ≤ 200; `cursor` is opaque. Unknown column, operator or malformed value → 400 |
| `GET /api/data/collections/:id/groups?by=col[:year\|month\|day]&q=&filter=` | | `{by, groups: {key, label?, count, sums}[], total: {count, sums}}`: rows matching `q`/`filter` (as for `rows`) grouped by a text, select, bool, ref, number or date column (`year` by default for dates); `sums` totals every money column; `label` is the title of a `ref` key; dates newest first, refs by title, other keys ascending, empty key (`null`) last |
| `GET /api/data/collections/:id/rows/:rowId` | | `{row: DataRow, history: DataChange[]}` (last 50) |
| `POST /api/data/collections/:id/rows` | `{values}` | `DataRow` |
| `PATCH /api/data/collections/:id/rows/:rowId` | `{values}` (partial) | `DataRow` |
| `POST /api/data/collections/:id/rows/:rowId/archive` / `unarchive` | | `DataRow` |
| `GET /api/data/history?collection=&rowId=&limit=` | | `DataChange[]` newest first |
| `POST /api/data/history/:changeId/revert` | | `DataChange` (the revert itself) |
| `GET /api/data/search?q=` | | `{collection, row}[]` across title columns (max 30) |
| `GET /api/data/files?path=` | | the file (`path` from a `file` value) |
| `POST /api/data/collections/:id/rows/:rowId/files/:column?name=` | raw bytes (≤ 50 MB) | `201 DataRow`: the file lands in `data/files/<id>/<rowId>/<name>` (a free name like `devis-2.pdf` when taken) and is appended to the `file` column |
| `GET /api/reminders?scope=today\|upcoming\|overdue\|done\|all\|inbox\|anytime\|someday&project=&area=&list=` | | `Reminder[]` (with `project`, ordered by position) |
| `GET /api/reminders/overview` | | `{counts: {inbox, today, overdue, upcoming, anytime, someday}, areas: (Area & {projects: Project[]})[], projects: Project[]}` (open projects; `projects` = those without an area) |
| `GET /api/areas` · `POST /api/areas` · `PATCH /api/areas/:id` · `DELETE /api/areas/:id` | `{title, emoji?, position?}` | `Area[]` / `Area` / `204` (archives; its projects and reminders lose their area) |
| `GET /api/projects?status=open\|done\|cancelled\|all&area=` | | `Project[]` (open: by someday, position) |
| `POST /api/projects` · `PATCH /api/projects/:id` | `{title, notes?, emoji?, color?, areaId?, deadline?, someday?, position?}` | `Project` |
| `GET /api/projects/:id` | | `{project, headings: Heading[], reminders: Reminder[]}` (open by position, then done newest first) |
| `POST /api/projects/:id/done` · `/cancel` | `{openReminders?: "done"\|"keep"}` (default done: completes its open reminders) | `Project` |
| `POST /api/projects/:id/reopen` · `DELETE /api/projects/:id` | | `Project` / `204` (archives it with its headings and reminders) |
| `POST /api/projects/:id/headings` · `PATCH /api/headings/:id` · `DELETE /api/headings/:id` | `{title, position?}` | `Heading` / `204` (its reminders stay in the project) |
| `GET /api/reminders/lists` | | `{id, label, count}[]` (open reminders per list; `inbox`, labelled « Boîte de réception », always first; other labels = the id capitalised) |
| `POST /api/reminders` | `{title, notes?, dueAt?, repeat?, list?, priority?}` | `Reminder` |
| `PATCH /api/reminders/:id` | partial | `Reminder` |
| `POST /api/reminders/:id/done` / `undone` | | `Reminder` |
| `POST /api/reminders/:id/snooze` | `{minutes}` or `{until}` | `Reminder` (also reopens a done one) |
| `DELETE /api/reminders/:id` | | `204` (archives) |
| `GET /api/dashboards` | | `{slug, title, emoji, description}[]` |
| `GET /api/dashboards/:slug` | | `{slug, title, emoji, blocks: DashboardBlock[]}` with computed data |
| `GET /api/docs/tree` | | `DocNode[]` (`{path, name, kind: "dir"\|"file", updatedAt, size}`), flat, depth-first, sorted by name |
| `GET /api/docs/file?path=` | | `{path, content, sha, updatedAt}` |
| `PUT /api/docs/file` | `{path, content, baseSha?}` | `{path, sha, updatedAt}`; 409 if `baseSha` is stale; commits `docs(app): Update <path>` |
| `POST /api/docs/file` / `DELETE /api/docs/file?path=` | `{path, content}` | `201 {path, sha, updatedAt}` (409 if it exists) / `204`, moved to `docs/.trash/` (git-ignored; the deletion is committed) |
| `POST /api/docs/move` | `{from, to}` | `{path, kind}`; moves or renames a file or a folder (missing parent folders are created), commits `docs(app): Move <from> → <to>`; 404 if `from` is missing, 409 if `to` exists (never overwrites), 400 for a folder moved into itself. Contents are moved as is: relative links and media paths inside moved documents are not rewritten, so media referenced relatively should move with their document (move the folder) |
| `POST /api/docs/folder` / `DELETE /api/docs/folder?path=` | `{path}` | `201 {path}` (409 if it exists); the folder holds a hidden `.keep` so git tracks it while empty / `204`, the whole folder goes to `docs/.trash/` (the deletion is committed). A folder emptied by a move or a folder deletion gets a `.keep` and stays listed; `.keep` files never appear in the tree |
| `GET /api/docs/pins` / `PUT /api/docs/pins` | `{paths}` (ordered, max 200) | `{paths}`: pinned files and folders of the profile, shared by its devices; stored in `data/docs-pins.json` (not in the docs repo). A move or rename updates the pins of the item and of everything inside it, a deletion drops them; paths that no longer exist are left out of the answer |
| `POST /api/docs/upload?path=` | raw bytes (any content type, 50 MB max) | `201 {path, size}`: stores an image, a PDF or any file; a taken path gets a free name (`photo-2.png`, never overwrites), `.md` is refused (use `/api/docs/file`); commits `docs(app): Add <path>`. The apps upload next to the document, in `<folder>/_fichiers/` (docs/documents.md) |
| `GET /api/docs/search?q=` | | `{path, line, snippet}[]` (max 50) |
| `GET /api/docs/raw?path=` | | the file as is (images referenced by Markdown: the app resolves a relative link against the document's folder), with its content type, `etag` (304 on `if-none-match`) and `cache-control: private, max-age=300, must-revalidate` |
| `POST /api/docs/drop` | `{path, ttl}`, `ttl` in minutes: `60`, `1440`, `10080` or `0` (permanent) | `{url, expiresAt}` (`expiresAt` null when permanent): publishes the file as a public link on drop (`NUO_DROP_URL`, `NUO_DROP_API_KEY`; the key never leaves the gateway). 25 MB max (drop's limit). A Markdown document is rendered by drop, without its `_fichiers/` images. 404 when drop is not configured |

`DataCollection.defaultSort` uses the `sort` syntax (`numero:desc`).
`DataColumn = {name, label, type, options?: {name, color?}[] (select/multiselect), ref?: collectionId, computed, hidden, order}`.
`DataRow = {id, values: {[column]: value}, title, refs?: {[refColumn]: title of the referenced row}, updatedAt, archivedAt?}`
(values come from the view, so computed columns are included). `DataChange = {id, at, collection, rowId,
op: "insert"|"update"|"archive"|"unarchive"|"delete"|"revert", changes: {column: [old, new]}, source: "app"|"agent"|"import"}`
(`collection` is `reminders` for reminder changes). Reverting an insert archives the row, a delete re-inserts it,
anything else restores the old values; 409 when the row is gone or nothing changes.
`Reminder = {id, title, notes?, dueAt?, repeat?, list, priority: 0..3, doneAt?, snoozedUntil?, projectId?, project?: {id, title,
emoji?}, areaId?, area?: {id, title, emoji?} (its own or its project's), headingId?, someday, position, checklist?, createdAt, updatedAt}`.
`Area = {id, title, emoji?, position}`; `Project = {id, title, notes?, emoji?, color?, areaId?, deadline?, someday, status,
doneAt?, position, openCount, doneCount, progress (0..1)}`; `Heading = {id, projectId, title, position}`.
Scopes (Paris day): `today` = not done, due (or snoozed until) before tomorrow 00:00, overdue included; `upcoming` =
due from tomorrow; `overdue` = due before now; `done` = done, newest first; `all` (default) = not done; `inbox` = not
done, no project, no area, no date, no place, not someday; `anytime` = not done and not someday (nor in a someday project);
`someday` = the others.
POST/PATCH accept title, notes, dueAt, repeat, list, priority, snoozedUntil, projectId, areaId, headingId, someday, position, checklist; a `dueAt` in the body clears `snoozedUntil` and
`notified_at`, so the reminder is pushed again at its new time.

PATCH/POST `values` are validated against `_columns`: unknown, computed or system columns (`id`, `notion_id`,
`created_at`, `updated_at`, `archived_at`) → 400; `money` is rounded to 2 decimals; `date` must be a real
`YYYY-MM-DD`; `select`/`multiselect` values must be among the options (when the column has some); `ref` must point to
an existing row; CHECK/NOT NULL/foreign key failures → 400.

## Reminder pushes

The gateway checks due reminders every 30 s. A due reminder (`due_at` or `snoozed_until` reached, not done)
is pushed once with category `nuo.reminder` and actions `Fait`, `+1 h`, `Demain 9 h`
(`{reminderId}` in the payload, `apns-collapse-id: reminder-<id>`); the app also schedules a local notification for reminders due in the next
48 h as a fallback when the gateway is unreachable.

## Location reminders

A reminder can trigger when you arrive at or leave a place, instead of (or as well as) at a time.

- `places(id, name, address, lat, lon, radius_m DEFAULT 150, created_at, updated_at, archived_at)` — places that
  you define yourself in the app (« Maison », « Bureau », « Salle de sport »…). They live only in `data.db`
  (source of truth); agents may reference an existing place by name but never create, move or delete one.
- `reminders` gains `place_id` (ref `places`, nullable) and `place_trigger` (`arrive` | `leave`, NULL when no place).
  A reminder with a place and no `due_at` fires only on location; with both, the time push fires as usual and the
  location trigger is an extra one.
- REST: `GET /api/places`, `POST /api/places` `{name, address?, lat, lon, radiusM?}`, `PATCH /api/places/:id`,
  `DELETE /api/places/:id` (archives; reminders keep working until changed). `POST/PATCH /api/reminders` accept
  `placeId` and `placeTrigger`; `Reminder` gains `place?: {id, name, lat, lon, radiusM}` and `placeTrigger?`.
- Firing is done on the iPhone, not by the gateway: the app registers a local notification with a
  `UNLocationNotificationTrigger` (`CLCircularRegion`, `notifyOnEntry` or `notifyOnExit`, `repeats` = the reminder has
  a `repeat`) for open location reminders, identifier `reminder-loc-<id>`, category `nuo.reminder`. iOS limits
  monitored regions (~20 per app): the app keeps the 20 most relevant by priority then due date (never by the
  user's position) and refreshes the set when reminders change or the app comes to the foreground. The app never
  reads, stores or sends the user's position: iOS only matches the registered regions itself. When such a reminder is
  marked done the app removes its trigger. The gateway does not push location reminders (a place and no `due_at`);
  once snoozed (`+1 h` from the location notification) such a reminder is pushed when the snooze ends.
- `placeId` must be an active place (an archived place stays valid for the reminders already using it);
  `placeTrigger` defaults to `arrive`, needs a place, and `placeId: null` clears both. `Place = {id, name, address?,
  lat, lon, radiusM, createdAt, updatedAt}`; `GET /api/places` lists active places by name. Places changes are in
  `_history` (`GET /api/data/history?collection=places`), so a place written by an agent despite the rule shows with source `agent` and can be
  reverted with `POST /api/data/history/:changeId/revert`.
- Agents create location reminders with SQL using an existing place (`SELECT id FROM places WHERE name = …`); if
  the place does not exist they ask you to create it in the app instead of inserting one.

## Dashboards

`dashboards/<slug>.json`:

```json
{"title": "Lumen Studio 2026", "emoji": "💼", "description": "Revenue and invoices",
 "blocks": [
   {"type": "number", "title": "Revenue 2026", "sql": "SELECT sum(net) AS value FROM v_invoices WHERE year = 2026", "format": "money"},
   {"type": "bar", "title": "Revenue by month", "sql": "SELECT month AS x, sum(net) AS y FROM v_invoices WHERE year = 2026 GROUP BY month ORDER BY month", "format": "money"},
   {"type": "table", "title": "Latest invoices", "sql": "SELECT title, client, total, issued_on FROM v_invoices ORDER BY issued_on DESC LIMIT 10", "collection": "invoices"}
 ]}
```

Block types: `number`, `line`, `bar`, `donut`, `table`, `list`. Queries run read-only (`PRAGMA query_only`,
2 s timeout, 500 rows max); a series column `s` makes multi-series charts. Agents create or edit dashboards by
writing these files. Starter dashboards in `gateway/config/dashboards/` (none in the repository; add yours
through the [private overlay](private-overlay.md)) are copied on the first run only.

A query is a single `SELECT` or `WITH … SELECT` (anything else is an error), run on a read-only connection in a
separate long-lived process (started on demand, stopped after 1 min idle; queries one after another) and killed
with it after 2 s; the next queries go on in a new process. A computed dashboard is served again as is until
data.db (any writer) or its file changes, for 5 minutes at most (queries may use `now`); results with a failing
block are not kept. Computed blocks (`GET /api/dashboards/:slug`):

```
DashboardBlock = {type, title, format?, collection?, truncated?, error?,
  value?,                                  // number: column `value` (or the first) of the first row
  series?: [{name, points: [{x, y}]}],      // line, bar, donut: columns x, y, s (one series named after the block without s)
  columns?: string[], rows?: unknown[][],   // table (an `id` column lets the app open the row in `collection`)
  items?: [{title, subtitle?, value?, id?}]}// list: columns title, subtitle, value, id
```
A failing block carries `error` and the others are still computed. `format` ∈ money, number, percent, integer, text.

## Docs

`~/nuo/docs` is a git repository. Agents edit Markdown with their usual tools and commit
(`docs(<bot>): …`); the gateway commits app edits (author `Nuo <nuo@dev>`). Front matter is optional (`title`, `tags`).
`sha` is the git blob id of the content (`git hash-object`). Paths are relative to `docs/`; absolute paths, `..`, `.git/`,
`.trash/` and symlinks leading outside are rejected with 400. Search uses ripgrep when installed (case-insensitive,
5 hits per file).

## Import (Notion → data.db)

`bun run src/cli.ts data-import <dir> [--dry-run] [--files-root <dir>]` reads `<dir>/<slug>.json` in the homebase
export format (`{slug, name, icon, properties: [{name, type, config}], rows: [{notion_id, created_at, updated_at,
properties: {<name>: value}}]}`):
- `<dir>` is the export root (`databases/`, `files/`; `archive/` is ignored) or its `databases/` folder;
- a file whose `slug` matches `_collections.notion_slug` fills that table through `_columns.notion_name`; Notion
  properties without a column or link are listed as ignored (inverse relations stored as a foreign key on the other
  side); `notion_name` `"<property>#end"` takes the end of a date range; relations listed in `_links` fill the link
  table from every side present (union) and remove the links of imported rows that no side lists any more;
- any other file gets a generated table `snake(slug)` with `v_<table> = SELECT *`, typed columns and metadata;
  its formulas and rollups are stored as snapshots (`computed = 1`, not editable from the app);
- rows are upserted by `notion_id` in one transaction (history source `import`); relations become foreign keys
  (first related row); numbers go to `percent` columns as fractions (Notion already stores percent-formatted numbers
  as fractions; a plain Notion number mapped to a percent column is divided by 100); select options are merged from Notion and from the values found; files with a `path`
  (relative to `--files-root`, default `<dir>/..`) are copied to `data/files/<path without files/>`;
- when the export carries Notion's computed values, the views are checked against them and differences are printed;
- a relation stored in a single foreign key keeps the first row and the count of truncated values is printed;
- `--dry-run` runs everything in a rolled-back transaction and prints the counts and generated SQL.

`bun run src/cli.ts data-import-docs <dir> [--dry-run]` copies an exported tree of Markdown pages and media into
`docs/` (overwrites changed files, never deletes) and commits `docs(import): Import Notion pages`.
