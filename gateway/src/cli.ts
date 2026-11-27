import { parseArgs } from "node:util";
import { defaultLayout } from "./paths";
import { openDataDb, regenerateTriggers } from "./data/db";
import { importDocsTree } from "./data/docs";
import { importDir } from "./data/importer";
import { prepareDataLayout } from "./data/service";
import { HttpError } from "./bots/service";
import { createTaskRecord, DEFAULT_TIMEZONE, resolveBot, updateTaskRecord, type TaskInput } from "./scheduler/scheduler";
import { openDb } from "./store/db";
import { Store } from "./store/store";
import { AUTH_USAGE, authCommand } from "./auth/cli";
import { formatTarget, parseTarget } from "./calendar/google";
import { googleEventInput } from "./calendar/routes";
import { googleFrom } from "./calendar/service";
import { BROWSER_USAGE, browserCommand } from "./browser/cli";
import { PROFILE_USAGE, profileCommand } from "./profiles/cli";

const USAGE = `usage:
  bun run src/cli.ts schedule-command --title <title> --cron "<expr>" --command "<shell command>"
      [--bot cobot] [--timezone Europe/Paris] [--cwd <dir>] [--env-file <file>] [--env KEY=VALUE]...
      [--timeout <seconds>] [--notify failure|always|never] [--disabled]
    Creates a command task, or updates the command task with the same title.
  bun run src/cli.ts bot-id <slug|name|id>
  bun run src/cli.ts schedules
  bun run src/cli.ts data-import <export dir> [--dry-run] [--files-root <dir>]
    Imports Notion exports (<dir>/databases/<slug>.json, or <dir>/<slug>.json; archive/ is ignored) into data/data.db, idempotently (upsert by notion_id);
    attachments are copied from <files-root> (default <export dir>/..) into data/files/. --dry-run prints the
    counts and the tables it would create, and changes nothing.
  bun run src/cli.ts data-import-docs <docs dir> [--dry-run]
    Copies an exported tree of Markdown pages and media into ~/nuo/docs (overwrites, never deletes) and commits
    "docs(import): Import Notion pages".
  bun run src/cli.ts data-triggers
    Recreates the history triggers of data.db (after adding a column or a collection by hand).
  bun run src/cli.ts calendar-create --title <title> --start <ISO|YYYY-MM-DD> --end <ISO|YYYY-MM-DD>
      [--target account[/calendarId]] [--attendee a@b.c]... [--meet] [--location <text>] [--notes <text>] [--all-day]
    Creates a Google Calendar event through gog (Google emails the attendees); --target defaults to NUO_GOOGLE_CALENDAR.
${PROFILE_USAGE}
${AUTH_USAGE}
${BROWSER_USAGE}

Writes straight to the gateway database (NUO_HOME, default ~/nuo); a running gateway picks changes up within 30 s.`;

function die(msg: string): never {
  console.error(msg);
  process.exit(1);
}

function scheduleCommand(store: Store, argv: string[]) {
  const { values } = parseArgs({
    args: argv,
    options: {
      title: { type: "string" },
      cron: { type: "string" },
      timezone: { type: "string" },
      command: { type: "string" },
      bot: { type: "string", default: "cobot" },
      cwd: { type: "string" },
      "env-file": { type: "string" },
      env: { type: "string", multiple: true },
      timeout: { type: "string" },
      notify: { type: "string" },
      disabled: { type: "boolean", default: false },
    },
    strict: true,
  });
  if (!values.title || !values.cron || !values.command) die(USAGE);
  const env: Record<string, string> = {};
  for (const kv of values.env ?? []) {
    const i = kv.indexOf("=");
    if (i < 1) die(`--env expects KEY=VALUE, got "${kv}"`);
    env[kv.slice(0, i)] = kv.slice(i + 1);
  }
  const input: TaskInput = {
    botId: values.bot,
    title: values.title,
    schedule: { kind: "cron", expr: values.cron, timezone: values.timezone || DEFAULT_TIMEZONE },
    enabled: !values.disabled,
    action: {
      type: "command",
      command: values.command,
      cwd: values.cwd,
      envFile: values["env-file"],
      env: Object.keys(env).length ? env : undefined,
      timeoutSec: values.timeout === undefined ? undefined : Number(values.timeout),
      notifyOn: values.notify ?? "failure",
    },
  };
  const title = values.title.trim();
  const existing = store.tasks().find((t) => t.action.type === "command" && t.title === title);
  const task = existing ? updateTaskRecord(store, existing, input, Date.now()) : createTaskRecord(store, input, "user", Date.now());
  console.log(`${existing ? "updated" : "created"} ${task.id}  ${task.title}  next run ${task.nextRunAt ?? "-"}`);
}

async function calendarCreate(argv: string[]) {
  const { values } = parseArgs({
    args: argv,
    options: {
      title: { type: "string" },
      start: { type: "string" },
      end: { type: "string" },
      target: { type: "string" },
      attendee: { type: "string", multiple: true },
      meet: { type: "boolean", default: false },
      location: { type: "string" },
      notes: { type: "string" },
      "all-day": { type: "boolean", default: false },
    },
    strict: true,
  });
  if (!values.title || !values.start || !values.end) die(USAGE);
  const target = parseTarget(values.target ?? process.env.NUO_GOOGLE_CALENDAR);
  if (!target) die("error: --target is required (NUO_GOOGLE_CALENDAR is not set)");
  const input = googleEventInput({
    title: values.title,
    start: values.start,
    end: values.end,
    allDay: values["all-day"],
    attendees: values.attendee,
    meet: values.meet,
    location: values.location,
    notes: values.notes,
  });
  const ev = await googleFrom({ gogBin: process.env.NUO_GOG_BIN })!.createEvent(target, input);
  console.log(JSON.stringify({ googleEventId: ev.id, target: formatTarget(target), ...ev }, null, 2));
}

function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  if (cmd === "data-import" || cmd === "data-triggers" || cmd === "data-import-docs") return dataCommand(cmd, rest);
  if (cmd === "calendar-create") {
    void calendarCreate(rest).catch((e) => die(e instanceof HttpError ? `error: ${e.message}` : String((e as Error)?.message ?? e)));
    return;
  }
  if (cmd?.startsWith("browser-")) {
    const resolve = (ref: string) => {
      const db = openDb(defaultLayout().data);
      try {
        return resolveBot(new Store(db), ref)?.id;
      } finally {
        db.close();
      }
    };
    void browserCommand(cmd, rest, resolve)
      .then((code) => process.exit(code))
      .catch((e) => die(`error: ${(e as Error)?.message ?? e}`));
    return;
  }
  if (cmd?.startsWith("profile-") || cmd === "pair-code" || cmd === "bot-import") {
    void profileCommand(cmd, rest).catch((e) => die(String((e as Error)?.message ?? e)));
    return;
  }
  if (cmd?.startsWith("auth-")) {
    void authCommand(cmd, rest).catch((e) => die(String((e as Error)?.message ?? e)));
    return;
  }
  const db = openDb(defaultLayout().data);
  const store = new Store(db);
  try {
    switch (cmd) {
      case "schedule-command":
        scheduleCommand(store, rest);
        break;
      case "bot-id": {
        const bot = rest[0] ? resolveBot(store, rest[0]) : undefined;
        if (!bot) die(`unknown bot "${rest[0] ?? ""}"`);
        console.log(bot.id);
        break;
      }
      case "schedules":
        for (const t of store.tasks()) {
          const what = t.action.type === "command" ? `$ ${t.action.command}` : `prompt: ${t.prompt.slice(0, 60)}`;
          const when = t.schedule.kind === "cron" ? t.schedule.expr : t.schedule.at;
          console.log(`${t.id}  ${t.enabled ? "on " : "off"}  ${when.padEnd(14)}  ${t.title}  (${store.botSlug(t.botId) ?? t.botId})  ${what}`);
        }
        break;
      default:
        die(USAGE);
    }
  } catch (e) {
    die(e instanceof HttpError ? `error: ${e.message}` : String((e as Error)?.stack ?? e));
  } finally {
    db.close();
  }
}

function dataCommand(cmd: string, argv: string[]) {
  const layout = defaultLayout();
  prepareDataLayout(layout);
  const db = openDataDb(layout.dataDb);
  try {
    if (cmd === "data-import-docs") {
      const { values, positionals } = parseArgs({ args: argv, options: { "dry-run": { type: "boolean", default: false } }, allowPositionals: true, strict: true });
      if (positionals.length !== 1) die(USAGE);
      const r = importDocsTree(positionals[0]!, layout.docs, { dryRun: values["dry-run"] });
      console.log(`${r.added} added, ${r.changed} changed, ${r.unchanged} unchanged${values["dry-run"] ? " (dry run: nothing was written)" : r.committed ? `, committed in ${layout.docs}` : ""}`);
      return;
    }
    if (cmd === "data-triggers") {
      regenerateTriggers(db);
      console.log(`history triggers regenerated in ${layout.dataDb}`);
      return;
    }
    const { values, positionals } = parseArgs({
      args: argv,
      options: { "dry-run": { type: "boolean", default: false }, "files-root": { type: "string" } },
      allowPositionals: true,
      strict: true,
    });
    if (positionals.length !== 1) die(USAGE);
    const report = importDir(db, positionals[0]!, {
      filesDir: layout.dataFiles,
      filesRoot: values["files-root"],
      dryRun: values["dry-run"],
      log: (l) => console.log(l),
    });
    for (const sql of report.ddl) console.log(`\n${sql}`);
    console.log(values["dry-run"] ? "dry run: nothing was written" : `imported into ${layout.dataDb}`);
  } catch (e) {
    die(String((e as Error)?.stack ?? e));
  } finally {
    db.close();
  }
}

main();
