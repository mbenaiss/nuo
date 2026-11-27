import { HttpError } from "../bots/service";
import type { Interval } from "./availability";
import { isEmail } from "./validate";

/** A Google calendar the gateway writes to, written `account/calendarId` (`account` alone = primary). */
export interface GoogleTarget {
  account: string;
  calendarId: string;
}

export function parseTarget(s: string | undefined | null): GoogleTarget | undefined {
  const v = (s ?? "").trim();
  if (!v) return undefined;
  const i = v.indexOf("/");
  const account = (i < 0 ? v : v.slice(0, i)).trim();
  const calendarId = (i < 0 ? "primary" : v.slice(i + 1)).trim() || "primary";
  if (!isEmail(account) || !/^[^\s,]{1,300}$/.test(calendarId)) throw new HttpError(400, `invalid Google calendar "${v}": expected account[/calendarId]`);
  return { account, calendarId };
}

export const formatTarget = (t: GoogleTarget) => `${t.account}/${t.calendarId}`;

export interface GoogleEventInput {
  title: string;
  /** ISO instants, or YYYY-MM-DD with allDay (end exclusive). */
  start: string;
  end: string;
  allDay?: boolean;
  description?: string;
  location?: string;
  attendees?: string[];
  meet?: boolean;
  privateProps?: Record<string, string>;
}

export interface GoogleEventResult {
  id: string;
  htmlLink?: string;
  meetUrl?: string;
}

export interface GoogleCalendarInfo {
  target: string;
  account: string;
  id: string;
  title: string;
  primary: boolean;
  accessRole?: string;
}

export class GoogleError extends Error {}

export type CommandRunner = (args: string[], timeoutMs: number) => Promise<{ code: number; stdout: string; stderr: string }>;

/** Runs gog with an argv array: nothing goes through a shell, so titles and notes cannot inject arguments. */
export function spawnRunner(bin: string, env: Record<string, string | undefined> = process.env): CommandRunner {
  return async (args, timeoutMs) => {
    const proc = Bun.spawn([bin, ...args], { stdin: "ignore", stdout: "pipe", stderr: "pipe", env });
    const timer = setTimeout(() => proc.kill(), timeoutMs);
    try {
      const [stdout, stderr, code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
      return { code, stdout, stderr };
    } finally {
      clearTimeout(timer);
    }
  };
}

const flag = (name: string, value: string) => `--${name}=${value}`;

function meetUrlOf(e: Record<string, any>): string | undefined {
  if (typeof e.hangoutLink === "string") return e.hangoutLink;
  const video = e.conferenceData?.entryPoints?.find?.((p: any) => p?.entryPointType === "video");
  return typeof video?.uri === "string" ? video.uri : undefined;
}

/** Thin wrapper over `gog calendar …` (gogcli), whose JSON output wraps the Google API objects. */
export class GoogleCalendar {
  private sendUpdatesOnEdit?: Promise<boolean>;

  constructor(
    private run: CommandRunner,
    private timeoutMs = 30_000,
  ) {}

  private async gog(target: { account: string }, args: string[]): Promise<any> {
    const r = await this.run(["calendar", ...args, flag("account", target.account), "--json", "--no-input"], this.timeoutMs).catch((e) => {
      throw new GoogleError(`gog could not run: ${(e as Error)?.message ?? e}`);
    });
    if (r.code !== 0) throw new GoogleError(`gog calendar ${args[0]} failed (${r.code}): ${(r.stderr || r.stdout).trim().slice(0, 300)}`);
    try {
      return r.stdout.trim() ? JSON.parse(r.stdout) : {};
    } catch {
      throw new GoogleError(`gog calendar ${args[0]} returned invalid JSON`);
    }
  }

  /** gog v0.9.0 only has --send-updates on create; later versions also on update/delete. */
  private canNotifyEdits(): Promise<boolean> {
    this.sendUpdatesOnEdit ??= this.run(["calendar", "update", "--help"], this.timeoutMs)
      .then((r) => /--send-updates/.test(r.stdout + r.stderr))
      .catch(() => false);
    return this.sendUpdatesOnEdit;
  }

  private eventArgs(e: Partial<GoogleEventInput>): string[] {
    const a: string[] = [];
    if (e.title !== undefined) a.push(flag("summary", e.title));
    if (e.start !== undefined) a.push(flag("from", e.start));
    if (e.end !== undefined) a.push(flag("to", e.end));
    if (e.allDay) a.push("--all-day");
    if (e.description !== undefined) a.push(flag("description", e.description));
    if (e.location !== undefined) a.push(flag("location", e.location));
    if (e.attendees?.length) {
      for (const m of e.attendees) if (!isEmail(m)) throw new GoogleError(`invalid attendee email "${m}"`);
      a.push(flag("attendees", e.attendees.join(",")));
    }
    for (const [k, v] of Object.entries(e.privateProps ?? {})) a.push(flag("private-prop", `${k}=${v}`));
    return a;
  }

  async createEvent(t: GoogleTarget, e: GoogleEventInput): Promise<GoogleEventResult> {
    const args = ["create", t.calendarId, ...this.eventArgs(e), flag("send-updates", "all")];
    if (e.meet) args.push("--with-meet");
    const out = await this.gog(t, args);
    const ev = out?.event ?? out;
    if (typeof ev?.id !== "string") throw new GoogleError("gog calendar create returned no event id");
    return { id: ev.id, ...(typeof ev.htmlLink === "string" ? { htmlLink: ev.htmlLink } : {}), ...(meetUrlOf(ev) ? { meetUrl: meetUrlOf(ev) } : {}) };
  }

  async updateEvent(t: GoogleTarget, id: string, e: Partial<GoogleEventInput>): Promise<GoogleEventResult> {
    const args = ["update", t.calendarId, id, ...this.eventArgs(e)];
    if (await this.canNotifyEdits()) args.push(flag("send-updates", "all"));
    const out = await this.gog(t, args);
    const ev = out?.event ?? out;
    return { id: typeof ev?.id === "string" ? ev.id : id, ...(typeof ev?.htmlLink === "string" ? { htmlLink: ev.htmlLink } : {}), ...(ev && meetUrlOf(ev) ? { meetUrl: meetUrlOf(ev) } : {}) };
  }

  async deleteEvent(t: GoogleTarget, id: string): Promise<void> {
    const args = ["delete", t.calendarId, id, "--force"];
    if (await this.canNotifyEdits()) args.push(flag("send-updates", "all"));
    await this.gog(t, args);
  }

  async freeBusy(t: GoogleTarget, from: number, to: number): Promise<Interval[]> {
    const out = await this.gog(t, ["freebusy", t.calendarId, flag("from", new Date(from).toISOString()), flag("to", new Date(to).toISOString())]);
    const cals = out?.calendars ?? {};
    const entry = cals[t.calendarId] ?? (t.calendarId === "primary" ? cals[t.account] : undefined) ?? Object.values(cals)[0];
    if (!entry) return [];
    if (Array.isArray(entry.errors) && entry.errors.length) throw new GoogleError(`free/busy error: ${entry.errors.map((e: any) => e?.reason).join(", ")}`);
    return (entry.busy ?? [])
      .map((b: any) => ({ start: Date.parse(b.start), end: Date.parse(b.end) }))
      .filter((b: Interval) => Number.isFinite(b.start) && Number.isFinite(b.end));
  }

  async calendars(account: string): Promise<GoogleCalendarInfo[]> {
    const out = await this.gog({ account }, ["calendars", flag("max", "250")]);
    return (out?.calendars ?? [])
      .filter((c: any) => typeof c?.id === "string")
      .map((c: any) => ({
        target: `${account}/${c.primary ? "primary" : c.id}`,
        account,
        id: c.id,
        title: c.summaryOverride ?? c.summary ?? c.id,
        primary: c.primary === true,
        ...(c.accessRole ? { accessRole: c.accessRole } : {}),
      }));
  }
}
