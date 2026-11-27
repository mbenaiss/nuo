import { chmodSync, existsSync, lstatSync, mkdirSync, readdirSync, renameSync, symlinkSync } from "node:fs";
import { join } from "node:path";
import { moveClaudeProject } from "../agents/claude";
import { PROFILE_DIRS, type GlobalLayout } from "../paths";
import { OWNER } from "./registry";

export interface OwnerMigration {
  moved: string[];
  skipped: string[];
  claudeProjects: string[];
}

const isLink = (p: string) => {
  try {
    return lstatSync(p).isSymbolicLink();
  } catch {
    return false;
  }
};

/**
 * Moves the owner's folders of the layout before profiles (NUO_HOME/{data,docs,…}) to profiles/owner/ and
 * leaves a relative symlink at each old path, so scripts and units that use the old paths keep working.
 * Idempotent: a path that is already a link, or whose destination exists, is left alone. Must run before the
 * databases are opened. Claude Code sessions are keyed by folder: they follow the bot folders.
 */
export function migrateOwnerLayout(g: GlobalLayout, o: { dataOverride?: string; claudeConfigDir?: string } = {}): OwnerMigration {
  const report: OwnerMigration = { moved: [], skipped: [], claudeProjects: [] };
  const owner = join(g.profiles, OWNER);
  mkdirSync(g.profiles, { recursive: true, mode: 0o700 });
  if (!existsSync(owner)) {
    mkdirSync(owner, { mode: 0o700 });
    chmodSync(owner, 0o700);
  }
  for (const d of PROFILE_DIRS) {
    if (d === "data" && o.dataOverride) continue;
    const from = join(g.home, d);
    const to = join(owner, d);
    if (!existsSync(from) || isLink(from)) continue;
    if (existsSync(to)) {
      report.skipped.push(d);
      console.warn(`[profiles] both ${from} and ${to} exist: leaving ${from} in place`);
      continue;
    }
    renameSync(from, to);
    symlinkSync(join("profiles", OWNER, d), from);
    report.moved.push(d);
    if (d !== "bots") continue;
    for (const slug of readdirSync(to)) {
      try {
        moveClaudeProject(join(from, slug), join(to, slug), o.claudeConfigDir);
        report.claudeProjects.push(slug);
      } catch (e) {
        console.warn(`[profiles] Claude sessions of ${slug}: ${(e as Error)?.message ?? e}`);
      }
    }
  }
  if (report.moved.length) console.log(`[profiles] moved ${report.moved.join(", ")} to ${owner} (links left at the old paths)`);
  return report;
}
