/** Wire types of docs/data.md. */

export type ColumnType = "text" | "longtext" | "number" | "money" | "percent" | "date" | "datetime" | "bool" | "select" | "multiselect" | "ref" | "refs" | "url" | "file";

export interface SelectOption {
  name: string;
  color?: string;
}

export interface DataColumn {
  name: string;
  label: string;
  type: ColumnType;
  options?: SelectOption[];
  ref?: string; // collection id, for `ref` and `refs`
  computed: boolean;
  hidden: boolean;
  order: number;
}

export interface DataCollection {
  id: string;
  label: string;
  emoji?: string;
  count: number;
  columns: DataColumn[];
  titleColumn: string;
  defaultSort?: string; // "column:asc|desc"
}

/** A `file` value item: `path` is relative to data/files (served by GET /api/data/files?path=), `url` when not downloaded. */
export interface DataFile {
  name: string;
  path?: string;
  url?: string;
}

export interface DataRow {
  id: string;
  values: Record<string, unknown>;
  title: string;
  /** Title of the row each `ref` column points to (titles joined by ", " for `refs`). */
  refs?: Record<string, string>;
  updatedAt: string;
  archivedAt?: string;
}

/** `GET …/groups`: `key` is the column value (`"2026"` for a year), `label` the title of a `ref` key. */
export interface DataGroup {
  key: string | number | boolean | null;
  label?: string;
  count: number;
  /** Sum of every money column of the group. */
  sums: Record<string, number>;
}

export interface DataGroups {
  by: string;
  groups: DataGroup[];
  total: { count: number; sums: Record<string, number> };
}

export type ChangeOp = "insert" | "update" | "archive" | "unarchive" | "delete" | "revert";

export interface DataChange {
  id: string;
  at: string;
  collection: string;
  rowId: string;
  op: ChangeOp;
  changes: Record<string, [unknown, unknown]>;
  source: "app" | "agent" | "import";
}

export interface Reminder {
  id: string;
  title: string;
  notes?: string;
  dueAt?: string;
  repeat?: string;
  list: string;
  priority: number;
  doneAt?: string;
  snoozedUntil?: string;
  place?: { id: string; name: string; lat: number; lon: number; radiusM: number };
  placeTrigger?: "arrive" | "leave";
  projectId?: string;
  project?: { id: string; title: string; emoji?: string };
  /** The reminder's own area, or its project's. */
  areaId?: string;
  area?: { id: string; title: string; emoji?: string };
  headingId?: string;
  someday: boolean;
  position: number;
  checklist?: { title: string; done: boolean }[];
  createdAt: string;
  updatedAt: string;
}

export interface Area {
  id: string;
  title: string;
  emoji?: string;
  position: number;
  createdAt: string;
  updatedAt: string;
}

export interface Project {
  id: string;
  title: string;
  notes?: string;
  emoji?: string;
  color?: string;
  areaId?: string;
  /** YYYY-MM-DD. */
  deadline?: string;
  someday: boolean;
  status: "open" | "done" | "cancelled";
  doneAt?: string;
  position: number;
  openCount: number;
  doneCount: number;
  /** Done reminders / all reminders, 0..1. */
  progress: number;
  createdAt: string;
  updatedAt: string;
}

export interface Heading {
  id: string;
  projectId: string;
  title: string;
  position: number;
}

export type BlockType = "number" | "line" | "bar" | "donut" | "table" | "list";

export interface DashboardSummary {
  slug: string;
  title: string;
  emoji?: string;
  description?: string;
}

export interface DashboardBlock {
  type: BlockType;
  title: string;
  format?: string;
  collection?: string;
  /** number */
  value?: number | string | null;
  /** line, bar, donut: one series per distinct `s` (a single series named after the block without it). */
  series?: { name: string; points: { x: string | number; y: number | null }[] }[];
  /** table */
  columns?: string[];
  rows?: unknown[][];
  /** list: from the columns title, subtitle, value, id */
  items?: { title: string; subtitle?: string; value?: unknown; id?: string }[];
  truncated?: boolean;
  error?: string;
}

export interface Dashboard extends DashboardSummary {
  blocks: DashboardBlock[];
}

export interface DocNode {
  path: string;
  name: string;
  kind: "dir" | "file";
  updatedAt: string;
  size: number;
}
