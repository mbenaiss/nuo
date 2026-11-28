import { existsSync } from "node:fs";
import { FINANCE_COLLECTIONS } from "../auth/policy";
import { HttpError } from "../bots/service";
import type { DataServices } from "../data/service";
import { REMINDER_TZ } from "../data/reminders";
import { zonedToUtc } from "../scheduler/cron";
import { relayRefusalText } from "./whitelist";

/**
 * The tools a relay session gets besides the calendars and `bot_ask`: each adds one thing and reads only what adding
 * it needs (a reminder's title to tick it, a collection's columns to fill it), never the rest of the data.
 */
export const RELAY_ADD_TOOLS = [
  {
    name: "reminder_add",
    description: "Adds a reminder for the user (Nuo app), its title in the user's language. `at`: local date and time in Paris, format YYYY-MM-DDTHH:MM; without `at`, a reminder with no due date.",
    inputSchema: {
      type: "object",
      properties: {
        title: { type: "string", description: "The reminder, short (e.g. \"Buy bread\")." },
        at: { type: "string", description: "Due date, Paris time: YYYY-MM-DDTHH:MM." },
        notes: { type: "string", description: "Optional details." },
      },
      required: ["title"],
    },
  },
  {
    name: "reminder_done",
    description: "Checks off the open reminder whose title contains `title` (3 characters at least). If several match, only their number is returned: ask for a more precise title.",
    inputSchema: { type: "object", properties: { title: { type: "string", description: "The reminder's title, or a precise enough part of it (3 characters at least)." } }, required: ["title"] },
  },
  {
    name: "note_add",
    description: "Adds a new note to the user's documents (notes/ folder). Never changes an existing note.",
    inputSchema: {
      type: "object",
      properties: { title: { type: "string" }, content: { type: "string", description: "The text of the note, in Markdown." } },
      required: ["title", "content"],
    },
  },
  {
    name: "collection_add",
    description: "Adds an item to one of the user's collections (e.g. Colis). `values`: column → value. An error gives the columns to fill. Finance collections cannot be reached this way.",
    inputSchema: {
      type: "object",
      properties: {
        collection: { type: "string", description: "Name or id of the collection." },
        values: { type: "object", description: "Values of the item, by column name." },
      },
      required: ["collection", "values"],
    },
  },
] as const;

export const RELAY_ADD_TOOL_NAMES: ReadonlySet<string> = new Set(RELAY_ADD_TOOLS.map((t) => t.name));

/** The fewest characters of a title `reminder_done` takes. */
export const REMINDER_DONE_MIN = 3;

type Args = Record<string, unknown>;

const text = (v: unknown) => (typeof v === "string" ? v.trim() : "");

function fold(s: string): string {
  return s.normalize("NFD").replace(/\p{M}+/gu, "").toLowerCase().trim();
}

function parisInstant(at: string): string {
  const m = at.match(/^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})$/);
  if (m) return new Date(zonedToUtc(+m[1]!, +m[2]!, +m[3]!, +m[4]!, +m[5]!, REMINDER_TZ)).toISOString();
  const t = Date.parse(at);
  if (!Number.isFinite(t)) throw new HttpError(400, `invalid date "${at}": use the format 2026-11-15T08:00`);
  return new Date(t).toISOString();
}

function slug(title: string): string {
  return fold(title).replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 60) || "note";
}

/** Runs one add tool for a relay session; the answer is the bot's tool result. */
export async function runRelayTool(d: DataServices, name: string, a: Args, now = Date.now()): Promise<string> {
  switch (name) {
    case "reminder_add": {
      const title = text(a.title);
      if (!title) throw new HttpError(400, "title is required");
      const at = text(a.at);
      const r = d.reminders.create({ title, ...(text(a.notes) ? { notes: text(a.notes) } : {}), ...(at ? { dueAt: parisInstant(at) } : {}) });
      const when = r.dueAt ? `, ${new Intl.DateTimeFormat("en-GB", { timeZone: REMINDER_TZ, dateStyle: "full", timeStyle: "short" }).format(new Date(r.dueAt))}` : "";
      return `Reminder added: "${r.title}"${when}.`;
    }
    case "reminder_done": {
      const want = fold(text(a.title));
      // A letter or two would match most reminders: probing them one by one would read their titles.
      if (want.length < REMINDER_DONE_MIN) throw new HttpError(400, `title: at least ${REMINDER_DONE_MIN} characters of the reminder's title`);
      const open = d.reminders.list("all").filter((r) => !r.doneAt && fold(r.title).includes(want));
      if (!open.length) return `No open reminder matches "${text(a.title)}".`;
      if (open.length > 1) return `${open.length} open reminders match "${text(a.title)}": ask the user for a more precise title.`;
      d.reminders.done(open[0]!.id);
      return `Reminder checked off: "${open[0]!.title}".`;
    }
    case "note_add": {
      const title = text(a.title);
      if (!title || typeof a.content !== "string") throw new HttpError(400, "title and content are required");
      const day = new Date(now).toISOString().slice(0, 10);
      const base = `notes/${day}-${slug(title)}`;
      let path = `${base}.md`;
      for (let n = 2; existsSync(d.docs.resolve(path).abs); n++) path = `${base}-${n}.md`;
      const created = await d.docs.create(path, `# ${title}\n\n${a.content.trim()}\n`);
      return `Note added: ${created.path}.`;
    }
    case "collection_add": {
      const ref = text(a.collection);
      if (!ref) throw new HttpError(400, "collection is required");
      const all = d.store.collections();
      const c = all.find((x) => x.id === ref) ?? all.find((x) => fold(x.label) === fold(ref));
      const finance = (id: string) => FINANCE_COLLECTIONS.has(id) || d.store.collection(id).columns.some((col) => col.type === "money");
      if (!c) {
        const names = all.filter((x) => !finance(x.id)).map((x) => x.label);
        throw new HttpError(404, `no collection "${ref}". Collections: ${names.join(", ") || "none"}.`);
      }
      if (finance(c.id)) throw new HttpError(403, relayRefusalText("collection_add"));
      const values = a.values && typeof a.values === "object" && !Array.isArray(a.values) ? (a.values as Args) : undefined;
      const columns = () => c.columns.map((col) => `${col.name} (${col.type})`).join(", ");
      if (!values || !Object.keys(values).length) throw new HttpError(400, `values is required. Columns of ${c.label}: ${columns()}.`);
      try {
        const row = d.store.insert(c.id, values);
        return `Added to ${c.label}: "${row.title || Object.values(values)[0]}".`;
      } catch (e) {
        if (e instanceof HttpError) throw new HttpError(400, `${e.message}. Columns of ${c.label}: ${columns()}.`);
        throw e;
      }
    }
    default:
      throw new HttpError(404, `unknown tool ${name}`);
  }
}
