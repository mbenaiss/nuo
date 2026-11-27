import type { Database } from "bun:sqlite";
import { HttpError } from "../bots/service";
import { asApp } from "./db";
import { sqlite } from "./store";
import type { Area, Heading, Project } from "./types";

type Row = Record<string, string | number | null>;

const opt = (r: Row, k: string) => (r[k] === null || r[k] === undefined ? undefined : String(r[k]));

function text(b: Record<string, unknown>, k: string, required = false): string | null | undefined {
  if (!(k in b)) {
    if (required) throw new HttpError(400, `${k} is required`);
    return undefined;
  }
  const v = b[k];
  if (v === null || v === "") {
    if (required) throw new HttpError(400, `${k} must be a non-empty string`);
    return null;
  }
  if (typeof v !== "string" || (required && !v.trim())) throw new HttpError(400, `${k} must be a ${required ? "non-empty " : ""}string`);
  return required ? v.trim() : v;
}

function position(b: Record<string, unknown>): number | undefined {
  if (!("position" in b)) return undefined;
  if (typeof b.position !== "number" || !Number.isFinite(b.position)) throw new HttpError(400, "position must be a number");
  return b.position;
}

function toArea(r: Row): Area {
  return {
    id: String(r.id),
    title: String(r.title),
    ...(opt(r, "emoji") ? { emoji: opt(r, "emoji") } : {}),
    position: Number(r.position),
    createdAt: String(r.created_at),
    updatedAt: String(r.updated_at),
  };
}

function toHeading(r: Row): Heading {
  return { id: String(r.id), projectId: String(r.project_id), title: String(r.title), position: Number(r.position) };
}

/**
 * Areas, projects and project headings. Writes go through `asApp` so the history records them as the app's;
 * agents write the same tables with sqlite3 (docs/data.md).
 */
export class Projects {
  constructor(
    readonly db: Database,
    private clock: () => number = Date.now,
  ) {}

  private now = () => new Date(this.clock()).toISOString();

  private write(sql: string, ...params: (string | number | null)[]) {
    sqlite(() => asApp(this.db, () => this.db.query(sql).run(...params)));
  }

  private update(table: "areas" | "projects" | "project_headings", id: string, set: Record<string, string | number | null>) {
    const names = Object.keys(set);
    if (!names.length) return;
    this.write(`UPDATE ${table} SET ${names.map((n) => `"${n}" = ?`).join(", ")}, updated_at = ? WHERE id = ?`, ...names.map((n) => set[n]!), this.now(), id);
  }

  private nextPosition(table: string, where = "1", ...params: string[]): number {
    const r = this.db.query(`SELECT coalesce(max(position), 0) + 1 AS p FROM ${table} WHERE archived_at IS NULL AND ${where}`).get(...params) as { p: number };
    return r.p;
  }

  // MARK: Areas

  private areaRow(id: string): Row {
    const r = this.db.query("SELECT * FROM areas WHERE id = ? AND archived_at IS NULL").get(id) as Row | null;
    if (!r) throw new HttpError(404, "area not found");
    return r;
  }

  areas(): Area[] {
    return (this.db.query("SELECT * FROM areas WHERE archived_at IS NULL ORDER BY position, title").all() as Row[]).map(toArea);
  }

  createArea(b: Record<string, unknown>): Area {
    const id = crypto.randomUUID();
    const title = text(b, "title", true)!;
    this.write("INSERT INTO areas (id, title, emoji, position) VALUES (?, ?, ?, ?)", id, title, text(b, "emoji") ?? null, position(b) ?? this.nextPosition("areas"));
    return toArea(this.areaRow(id));
  }

  patchArea(id: string, b: Record<string, unknown>): Area {
    this.areaRow(id);
    const set: Record<string, string | number | null> = {};
    if ("title" in b) set.title = text(b, "title", true)!;
    if ("emoji" in b) set.emoji = text(b, "emoji") ?? null;
    const p = position(b);
    if (p !== undefined) set.position = p;
    this.update("areas", id, set);
    return toArea(this.areaRow(id));
  }

  /** Archives the area; its projects and reminders stay, without an area. */
  archiveArea(id: string): void {
    this.areaRow(id);
    this.db.transaction(() => {
      const now = this.now();
      this.write("UPDATE projects SET area_id = NULL, updated_at = ? WHERE area_id = ?", now, id);
      this.write("UPDATE reminders SET area_id = NULL, updated_at = ? WHERE area_id = ?", now, id);
      this.update("areas", id, { archived_at: now });
    })();
  }

  // MARK: Projects

  private projectRow(id: string): Row {
    const r = this.db.query("SELECT * FROM projects WHERE id = ? AND archived_at IS NULL").get(id) as Row | null;
    if (!r) throw new HttpError(404, "project not found");
    return r;
  }

  private toProjects(rows: Row[]): Project[] {
    if (!rows.length) return [];
    const ids = rows.map((r) => String(r.id));
    const counts = new Map<string, { open: number; done: number }>();
    for (const c of this.db
      .query(
        `SELECT project_id, sum(done_at IS NULL) AS open, sum(done_at IS NOT NULL) AS done FROM reminders
         WHERE archived_at IS NULL AND project_id IN (${ids.map(() => "?").join(", ")}) GROUP BY project_id`,
      )
      .all(...ids) as { project_id: string; open: number; done: number }[]) {
      counts.set(c.project_id, { open: Number(c.open), done: Number(c.done) });
    }
    return rows.map((r) => {
      const c = counts.get(String(r.id)) ?? { open: 0, done: 0 };
      const total = c.open + c.done;
      return {
        id: String(r.id),
        title: String(r.title),
        ...(opt(r, "notes") ? { notes: opt(r, "notes") } : {}),
        ...(opt(r, "emoji") ? { emoji: opt(r, "emoji") } : {}),
        ...(opt(r, "color") ? { color: opt(r, "color") } : {}),
        ...(opt(r, "area_id") ? { areaId: opt(r, "area_id") } : {}),
        ...(opt(r, "deadline") ? { deadline: opt(r, "deadline") } : {}),
        someday: Number(r.someday) === 1,
        status: String(r.status) as Project["status"],
        ...(opt(r, "done_at") ? { doneAt: opt(r, "done_at") } : {}),
        position: Number(r.position),
        openCount: c.open,
        doneCount: c.done,
        progress: total ? c.done / total : r.status === "done" ? 1 : 0,
        createdAt: String(r.created_at),
        updatedAt: String(r.updated_at),
      };
    });
  }

  project(id: string): Project {
    return this.toProjects([this.projectRow(id)])[0]!;
  }

  projects(o: { status?: string; area?: string } = {}): Project[] {
    const status = o.status ?? "open";
    if (!["open", "done", "cancelled", "all"].includes(status)) throw new HttpError(400, "status must be open, done, cancelled or all");
    const where = ["archived_at IS NULL"];
    const params: string[] = [];
    if (status !== "all") {
      where.push("status = ?");
      params.push(status);
    }
    if (o.area) {
      where.push("area_id = ?");
      params.push(o.area);
    }
    const order = status === "open" ? "someday, position, title" : "coalesce(done_at, updated_at) DESC";
    return this.toProjects(this.db.query(`SELECT * FROM projects WHERE ${where.join(" AND ")} ORDER BY ${order}`).all(...params) as Row[]);
  }

  private areaRef(b: Record<string, unknown>): string | null | undefined {
    if (!("areaId" in b)) return undefined;
    const v = b.areaId;
    if (v === null || v === "") return null;
    if (typeof v !== "string") throw new HttpError(400, "areaId must be a string");
    if (!this.db.query("SELECT 1 FROM areas WHERE id = ? AND archived_at IS NULL").get(v)) throw new HttpError(400, "areaId must be an existing area");
    return v;
  }

  private deadline(b: Record<string, unknown>): string | null | undefined {
    if (!("deadline" in b)) return undefined;
    const v = b.deadline;
    if (v === null || v === "") return null;
    if (typeof v !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(v) || Number.isNaN(Date.parse(`${v}T00:00:00Z`))) {
      throw new HttpError(400, "deadline must be a YYYY-MM-DD date");
    }
    return v;
  }

  private someday(b: Record<string, unknown>): number | undefined {
    if (!("someday" in b)) return undefined;
    if (typeof b.someday !== "boolean") throw new HttpError(400, "someday must be a boolean");
    return b.someday ? 1 : 0;
  }

  createProject(b: Record<string, unknown>): Project {
    const id = crypto.randomUUID();
    const title = text(b, "title", true)!;
    this.write(
      "INSERT INTO projects (id, title, notes, emoji, color, area_id, deadline, someday, position) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      id,
      title,
      text(b, "notes") ?? null,
      text(b, "emoji") ?? null,
      text(b, "color") ?? null,
      this.areaRef(b) ?? null,
      this.deadline(b) ?? null,
      this.someday(b) ?? 0,
      position(b) ?? this.nextPosition("projects"),
    );
    return this.project(id);
  }

  patchProject(id: string, b: Record<string, unknown>): Project {
    this.projectRow(id);
    const set: Record<string, string | number | null> = {};
    if ("title" in b) set.title = text(b, "title", true)!;
    for (const k of ["notes", "emoji", "color"]) if (k in b) set[k] = text(b, k) ?? null;
    const area = this.areaRef(b);
    if (area !== undefined) set.area_id = area;
    const deadline = this.deadline(b);
    if (deadline !== undefined) set.deadline = deadline;
    const someday = this.someday(b);
    if (someday !== undefined) set.someday = someday;
    const p = position(b);
    if (p !== undefined) set.position = p;
    this.update("projects", id, set);
    return this.project(id);
  }

  /**
   * Completes (or cancels) a project. Its open reminders are completed with it, like in Things, unless
   * `openReminders: "keep"`; repeating ones are closed too, since their project is over.
   */
  finishProject(id: string, b: Record<string, unknown>, status: "done" | "cancelled" = "done"): Project {
    this.projectRow(id);
    const keep = b.openReminders === "keep";
    if (b.openReminders !== undefined && b.openReminders !== "keep" && b.openReminders !== "done") throw new HttpError(400, "openReminders must be done or keep");
    this.db.transaction(() => {
      const now = this.now();
      if (!keep) this.write("UPDATE reminders SET done_at = ?, snoozed_until = NULL, updated_at = ? WHERE project_id = ? AND done_at IS NULL AND archived_at IS NULL", now, now, id);
      this.update("projects", id, { status, done_at: now });
    })();
    return this.project(id);
  }

  reopenProject(id: string): Project {
    this.projectRow(id);
    this.update("projects", id, { status: "open", done_at: null });
    return this.project(id);
  }

  /** Archives the project with its headings and its reminders. */
  archiveProject(id: string): void {
    this.projectRow(id);
    this.db.transaction(() => {
      const now = this.now();
      this.write("UPDATE reminders SET archived_at = ?, updated_at = ? WHERE project_id = ? AND archived_at IS NULL", now, now, id);
      this.write("UPDATE project_headings SET archived_at = ?, updated_at = ? WHERE project_id = ? AND archived_at IS NULL", now, now, id);
      this.update("projects", id, { archived_at: now });
    })();
  }

  // MARK: Headings

  private headingRow(id: string): Row {
    const r = this.db.query("SELECT * FROM project_headings WHERE id = ? AND archived_at IS NULL").get(id) as Row | null;
    if (!r) throw new HttpError(404, "heading not found");
    return r;
  }

  headings(projectId: string): Heading[] {
    return (this.db.query("SELECT * FROM project_headings WHERE project_id = ? AND archived_at IS NULL ORDER BY position, created_at").all(projectId) as Row[]).map(toHeading);
  }

  createHeading(projectId: string, b: Record<string, unknown>): Heading {
    this.projectRow(projectId);
    const id = crypto.randomUUID();
    this.write(
      "INSERT INTO project_headings (id, project_id, title, position) VALUES (?, ?, ?, ?)",
      id,
      projectId,
      text(b, "title", true)!,
      position(b) ?? this.nextPosition("project_headings", "project_id = ?", projectId),
    );
    return toHeading(this.headingRow(id));
  }

  patchHeading(id: string, b: Record<string, unknown>): Heading {
    this.headingRow(id);
    const set: Record<string, string | number | null> = {};
    if ("title" in b) set.title = text(b, "title", true)!;
    const p = position(b);
    if (p !== undefined) set.position = p;
    this.update("project_headings", id, set);
    return toHeading(this.headingRow(id));
  }

  /** Archives the heading; its reminders stay in the project, without a heading. */
  archiveHeading(id: string): void {
    this.headingRow(id);
    this.db.transaction(() => {
      const now = this.now();
      this.write("UPDATE reminders SET heading_id = NULL, updated_at = ? WHERE heading_id = ?", now, id);
      this.update("project_headings", id, { archived_at: now });
    })();
  }
}
