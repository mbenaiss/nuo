import { HttpError } from "../bots/service";
import type { Bot, BotConfig, CommandNotify, ScheduledTask, TaskAction, TaskRun, TaskSchedule } from "../protocol";
import type { Pusher } from "../push/apns";
import type { Runner } from "../runner/runner";
import { newId, preview, type Store } from "../store/store";
import { DEFAULT_COMMAND_TIMEOUT_SEC, MAX_COMMAND_TIMEOUT_SEC, runCommand, type CommandResult, type CommandSpawner, type RunningCommand } from "./command";
import { CronError, isValidTimeZone, nextRun, parseCron } from "./cron";
import { isNothingToPropose, isProactiveTask, NOTHING_PREVIEW, syncAllProactiveTasks, syncProactiveTask } from "./proactive";

export const DEFAULT_TIMEZONE = "Europe/Paris";
/** A once-task whose date passed less than this ago still runs (gateway restart, late creation). */
export const ONCE_GRACE_MS = 60 * 60 * 1000;
/** A cron run due this recently is still run after a restart; older ones are skipped. */
const CRON_RESTART_GRACE_MS = 60 * 1000;
const MAX_TIMER_MS = 30 * 1000;
const BUSY_RETRY_MS = 5 * 1000;
const PREVIEW_MAX = 160;
const PUSH_OUTPUT_LINES = 6;
const STOP_WAIT_MS = 6000;
const STOPPED_ERROR = "coupée par le redémarrage de la passerelle, reprise à son retour";
const PUSH_BODY_MAX = 600;
export const COMMAND_FORBIDDEN = "command tasks can only be created or changed from the paired app";

type CommandAction = Extract<TaskAction, { type: "command" }>;
const NOTIFY_ON: CommandNotify[] = ["failure", "always", "never"];

export interface TaskInput {
  botId?: unknown;
  title?: unknown;
  action?: unknown;
  prompt?: unknown;
  schedule?: unknown;
  conversation?: unknown;
  conversationId?: unknown;
  notify?: unknown;
  enabled?: unknown;
}

export interface SchedulerOptions {
  now?: () => number;
  /** Scheduled runs at the same time; defaults to 2, less when NUO_MAX_SESSIONS is small. */
  concurrency?: number;
  /** Command runs at the same time, apart from agent sessions; defaults to 4. */
  commandConcurrency?: number;
  /** HOME of the commands; defaults to the gateway user's. */
  commandHome?: string;
  /** Whether command tasks may be created and run (profiles other than the owner: only when turned on). */
  commandsAllowed?: () => boolean;
  commandSpawner?: CommandSpawner;
}

export const COMMANDS_DISABLED = "command tasks are not enabled for this profile";

export function botConfig(bot: Bot | undefined): BotConfig | undefined {
  return bot?.published?.config ?? bot?.draft;
}

/** Matches a bot by id, slug, or name (case and accents ignored) so a bot can target another one the user named. */
export function resolveBot(store: Store, ref: string): Bot | undefined {
  const byId = store.bot(ref);
  if (byId) return byId;
  const bySlug = store.botSlugs().find((b) => b.slug === ref.trim());
  if (bySlug) return store.bot(bySlug.id);
  const norm = (s: string) => s.normalize("NFD").replace(/\p{M}/gu, "").trim().toLowerCase();
  const wanted = norm(ref);
  if (!wanted) return undefined;
  return store.bots().find((b) => norm(botConfig(b)?.name ?? "") === wanted);
}

function normalizeSchedule(raw: unknown, now: number, errors: string[]): TaskSchedule | undefined {
  if (!raw || typeof raw !== "object") {
    errors.push("schedule is required");
    return undefined;
  }
  const s = raw as Record<string, unknown>;
  if (s.kind === "cron") {
    const expr = typeof s.expr === "string" ? s.expr.trim().replace(/\s+/g, " ") : "";
    const timezone = s.timezone === undefined || s.timezone === "" ? DEFAULT_TIMEZONE : s.timezone;
    if (typeof timezone !== "string" || !isValidTimeZone(timezone)) {
      errors.push(`unknown timezone "${String(timezone)}"`);
      return undefined;
    }
    try {
      if (nextRun(parseCron(expr), timezone, now) === undefined) {
        errors.push(`cron "${expr}" never runs`);
        return undefined;
      }
    } catch (e) {
      errors.push(`invalid cron "${expr}": ${e instanceof CronError ? e.message : String(e)}`);
      return undefined;
    }
    return { kind: "cron", expr, timezone };
  }
  if (s.kind === "once") {
    const at = typeof s.at === "string" ? Date.parse(s.at) : NaN;
    if (!Number.isFinite(at)) {
      errors.push("schedule.at must be an ISO date");
      return undefined;
    }
    if (at < now - ONCE_GRACE_MS) {
      errors.push("schedule.at is in the past");
      return undefined;
    }
    return { kind: "once", at: new Date(at).toISOString() };
  }
  errors.push('schedule.kind must be "cron" or "once"');
  return undefined;
}

/** When the task should run next, ignoring runs missed before `now`. */
export function computeNextRun(schedule: TaskSchedule, now: number): string | undefined {
  if (schedule.kind === "once") {
    const at = Date.parse(schedule.at);
    return at >= now - ONCE_GRACE_MS ? schedule.at : undefined;
  }
  const next = nextRun(parseCron(schedule.expr), schedule.timezone, now);
  return next === undefined ? undefined : new Date(next).toISOString();
}

const isAbsoluteish = (p: string) => p.startsWith("/") || p === "~" || p.startsWith("~/");

function normalizeAction(raw: unknown, errors: string[]): TaskAction | undefined {
  if (!raw || typeof raw !== "object") {
    errors.push("action must be an object");
    return undefined;
  }
  const a = raw as Record<string, unknown>;
  if (a.type === "prompt") return { type: "prompt" };
  if (a.type !== "command") {
    errors.push('action.type must be "prompt" or "command"');
    return undefined;
  }
  const before = errors.length;
  const command = typeof a.command === "string" ? a.command.trim() : "";
  if (command.length < 1 || command.length > 4000) errors.push("action.command must be 1 to 4000 characters");
  const out: CommandAction = { type: "command", command, timeoutSec: DEFAULT_COMMAND_TIMEOUT_SEC, notifyOn: "failure" };
  for (const k of ["cwd", "envFile"] as const) {
    const v = a[k];
    if (v === undefined || v === null || v === "") continue;
    if (typeof v !== "string" || !isAbsoluteish(v.trim())) errors.push(`action.${k} must be an absolute path or start with ~/`);
    else out[k] = v.trim();
  }
  if (a.env !== undefined && a.env !== null) {
    const env = a.env as Record<string, unknown>;
    if (typeof env !== "object" || Array.isArray(env)) errors.push("action.env must be an object of strings");
    else {
      const entries = Object.entries(env);
      if (entries.some(([k, v]) => !/^[A-Za-z_][A-Za-z0-9_]*$/.test(k) || typeof v !== "string") || entries.length > 50) {
        errors.push("action.env must map variable names to strings (50 at most)");
      } else if (entries.length) out.env = Object.fromEntries(entries) as Record<string, string>;
    }
  }
  if (a.timeoutSec !== undefined && a.timeoutSec !== null) {
    const n = a.timeoutSec;
    if (typeof n !== "number" || !Number.isInteger(n) || n < 1 || n > MAX_COMMAND_TIMEOUT_SEC) errors.push(`action.timeoutSec must be an integer from 1 to ${MAX_COMMAND_TIMEOUT_SEC}`);
    else out.timeoutSec = n;
  }
  if (a.notifyOn !== undefined && a.notifyOn !== null) {
    if (!NOTIFY_ON.includes(a.notifyOn as CommandNotify)) errors.push('action.notifyOn must be "failure", "always" or "never"');
    else out.notifyOn = a.notifyOn as CommandNotify;
  }
  return errors.length > before ? undefined : out;
}

export const isCommandInput = (input: TaskInput) => (input.action as { type?: unknown } | undefined)?.type === "command";

const TIMING_FIELDS = new Set(["schedule", "enabled", "title", "notify"]);
/** A bot may reschedule, pause or rename a command task, never change what it runs or where. */
const timingOnly = (input: TaskInput) => Object.keys(input).every((k) => TIMING_FIELDS.has(k));

/** What a bot (local token) sees of a command task: the shape, not the values of its environment. */
export function redactForBot(t: ScheduledTask): ScheduledTask {
  if (t.action.type !== "command" || !t.action.env) return t;
  return { ...t, action: { ...t.action, env: Object.fromEntries(Object.keys(t.action.env).map((k) => [k, "•••"])) } };
}

type Normalized = Partial<Pick<ScheduledTask, "botId" | "title" | "action" | "prompt" | "schedule" | "conversation" | "conversationId" | "notify" | "enabled">>;

/** Validates a create (no `existing`) or a partial update; throws a 400 listing every problem. */
export function validateTask(store: Store, input: TaskInput, existing: ScheduledTask | undefined, now: number): Normalized {
  const errors: string[] = [];
  const out: Normalized = {};
  const creating = !existing;

  if (creating || input.botId !== undefined) {
    const bot = typeof input.botId === "string" ? resolveBot(store, input.botId) : undefined;
    if (!bot) errors.push(`unknown bot "${String(input.botId ?? "")}"`);
    else if (!botConfig(bot)) errors.push("this bot has no configuration");
    else out.botId = bot.id;
  }
  if (creating || input.title !== undefined) {
    const title = typeof input.title === "string" ? input.title.trim() : "";
    if (title.length < 1 || title.length > 60) errors.push("title must be 1 to 60 characters");
    else out.title = title;
  }
  const given = input.action === undefined ? undefined : normalizeAction(input.action, errors);
  if (given || creating) out.action = given ?? { type: "prompt" };
  const action = out.action ?? existing?.action ?? { type: "prompt" };
  if (action.type === "command") {
    if (existing?.action.type !== "command") out.prompt = "";
  } else if (creating || input.prompt !== undefined || existing?.prompt === "") {
    const prompt = typeof input.prompt === "string" ? input.prompt.trim() : "";
    if (prompt.length < 1 || prompt.length > 4000) errors.push("prompt must be 1 to 4000 characters");
    else out.prompt = prompt;
  }
  if (creating || input.schedule !== undefined) {
    const schedule = normalizeSchedule(input.schedule, now, errors);
    if (schedule) out.schedule = schedule;
  }
  if (input.conversation !== undefined) {
    if (input.conversation !== "dedicated" && input.conversation !== "new") errors.push('conversation must be "dedicated" or "new"');
    else out.conversation = input.conversation;
  } else if (creating) out.conversation = "dedicated";
  for (const k of ["notify", "enabled"] as const) {
    if (input[k] === undefined) {
      if (creating) out[k] = true;
    } else if (typeof input[k] !== "boolean") errors.push(`${k} must be a boolean`);
    else out[k] = input[k] as boolean;
  }
  // `notify` is what older apps toggle; on a command task it maps onto notifyOn.
  if (action.type === "command") {
    let notifyOn = action.notifyOn;
    if (!given && typeof input.notify === "boolean") notifyOn = input.notify ? (notifyOn === "never" ? "failure" : notifyOn) : "never";
    if (notifyOn !== action.notifyOn) out.action = { ...action, notifyOn };
    out.notify = notifyOn !== "never";
  }
  // Not in the app's API: lets a bot schedule a follow-up in the conversation it is talking in.
  if (input.conversationId !== undefined && input.conversationId !== null && action.type === "prompt") {
    const conv = typeof input.conversationId === "string" ? store.conversation(input.conversationId) : undefined;
    const botId = out.botId ?? existing?.botId;
    if (!conv || conv.botId !== botId) errors.push("conversationId must be a conversation of this bot");
    else {
      out.conversationId = conv.id;
      out.conversation = "dedicated";
    }
  }
  const schedule = out.schedule ?? existing?.schedule;
  const enabled = out.enabled ?? existing?.enabled;
  if (!errors.length && enabled && schedule?.kind === "once" && !out.schedule && Date.parse(schedule.at) < now - ONCE_GRACE_MS) {
    errors.push("schedule.at is in the past");
  }
  if (errors.length) throw new HttpError(400, errors.join("; "));
  return out;
}

/** Builds and stores a new task; shared by the REST API and the gateway CLI. */
export function createTaskRecord(store: Store, input: TaskInput, createdBy: ScheduledTask["createdBy"], now: number): ScheduledTask {
  if (createdBy === "bot" && isCommandInput(input)) throw new HttpError(403, COMMAND_FORBIDDEN);
  const v = validateTask(store, input, undefined, now);
  return store.createTask({
    botId: v.botId!,
    title: v.title!,
    action: v.action!,
    prompt: v.prompt!,
    schedule: v.schedule!,
    enabled: v.enabled!,
    conversation: v.conversation!,
    conversationId: v.conversationId,
    notify: v.notify!,
    createdBy,
    nextRunAt: v.enabled ? computeNextRun(v.schedule!, now) : undefined,
  });
}

/** Applies a validated partial update; shared by the REST API and the gateway CLI. */
export function updateTaskRecord(store: Store, existing: ScheduledTask, input: TaskInput, now: number): ScheduledTask {
  const v = validateTask(store, input, existing, now);
  const fields: Parameters<Store["updateTask"]>[1] = { ...v };
  if (v.botId && v.botId !== existing.botId && v.conversationId === undefined) fields.conversationId = null;
  if (v.conversation === "new") fields.conversationId = null;
  if (v.schedule || v.enabled !== undefined) {
    const schedule = v.schedule ?? existing.schedule;
    const enabled = v.enabled ?? existing.enabled;
    fields.nextRunAt = enabled ? (computeNextRun(schedule, now) ?? null) : null;
  }
  return store.updateTask(existing.id, fields)!;
}

function lastLines(text: string, n: number): string {
  return text
    .split("\n")
    .map((l) => l.trimEnd())
    .filter((l) => l.trim())
    .slice(-n)
    .join("\n");
}

const clip = (s: string, max: number) => (s.length > max ? `…${s.slice(s.length - max + 1)}` : s);

export class Scheduler {
  private running = new Map<string, Promise<void>>();
  private commands = new Map<string, RunningCommand>();
  private queue: string[] = [];
  private timer?: ReturnType<typeof setTimeout>;
  private stopped = true;
  private readonly now: () => number;
  private readonly concurrency: number;
  private readonly commandConcurrency: number;
  private readonly commandHome?: string;
  private readonly commandsAllowed: () => boolean;
  private readonly commandSpawner?: CommandSpawner;

  constructor(
    private store: Store,
    private runner: Runner,
    private pusher: Pusher,
    opts: SchedulerOptions = {},
  ) {
    this.now = opts.now ?? Date.now;
    this.concurrency = opts.concurrency ?? Math.max(1, Math.min(2, runner.maxSessions - 1));
    this.commandConcurrency = opts.commandConcurrency ?? 4;
    this.commandHome = opts.commandHome;
    this.commandsAllowed = opts.commandsAllowed ?? (() => true);
    this.commandSpawner = opts.commandSpawner;
  }

  /** Forgets runs interrupted by a restart, skips missed cron runs, then starts the timer loop. */
  start() {
    this.stopped = false;
    this.store.failRunningTaskRuns("interrompue par un redémarrage de la passerelle");
    const now = this.now();
    syncAllProactiveTasks(this.store, now);
    for (const t of this.store.tasks()) {
      if (!t.enabled) continue;
      if (t.schedule.kind === "once") {
        const next = computeNextRun(t.schedule, now);
        this.store.updateTask(t.id, next ? { nextRunAt: next } : { enabled: false, nextRunAt: null });
      } else if (!t.nextRunAt || Date.parse(t.nextRunAt) < now - CRON_RESTART_GRACE_MS) {
        this.store.updateTask(t.id, { nextRunAt: computeNextRun(t.schedule, now) ?? null });
      }
    }
    this.tick();
  }

  async stop() {
    this.stopped = true;
    if (this.timer) clearTimeout(this.timer);
    this.timer = undefined;
    this.queue = [];
    const ending = [...this.commands.keys()].map((id) => this.running.get(id));
    for (const c of this.commands.values()) c.kill();
    if (ending.length) await Promise.race([Promise.all(ending), Bun.sleep(STOP_WAIT_MS)]);
  }

  isRunning(taskId: string) {
    return this.running.has(taskId);
  }

  /** Resolves once every run in flight has ended. */
  async idle() {
    while (this.running.size) await Promise.all([...this.running.values()]);
  }

  list(botId?: string): ScheduledTask[] {
    return this.store.tasks(botId);
  }

  get(id: string): ScheduledTask {
    const t = this.store.task(id);
    if (!t) throw new HttpError(404, "scheduled task not found");
    return t;
  }

  create(input: TaskInput, createdBy: ScheduledTask["createdBy"]): ScheduledTask {
    if (isCommandInput(input) && !this.commandsAllowed()) throw new HttpError(403, COMMANDS_DISABLED);
    const task = createTaskRecord(this.store, input, createdBy, this.now());
    this.tick();
    return this.store.task(task.id)!;
  }

  /** `local`: the caller is a bot (local token), which may not touch command tasks. */
  update(id: string, input: TaskInput, local = false): ScheduledTask {
    const existing = this.get(id);
    if (local && (isCommandInput(input) || (existing.action.type === "command" && !timingOnly(input)))) throw new HttpError(403, COMMAND_FORBIDDEN);
    if ((existing.action.type === "command" || isCommandInput(input)) && !this.commandsAllowed()) throw new HttpError(403, COMMANDS_DISABLED);
    updateTaskRecord(this.store, existing, input, this.now());
    this.queue = this.queue.filter((q) => q !== id);
    this.tick();
    return this.get(id);
  }

  remove(id: string, local = false) {
    const existing = this.get(id);
    if (local && existing.action.type === "command") throw new HttpError(403, COMMAND_FORBIDDEN);
    this.store.deleteTask(id);
    this.queue = this.queue.filter((q) => q !== id);
    this.arm();
  }

  /** Creates or removes the bot's proposals task after its published config changed. */
  syncProactive(botId: string) {
    syncProactiveTask(this.store, botId, this.now());
    this.queue = this.queue.filter((id) => this.store.task(id));
    this.arm();
  }

  runs(id: string): TaskRun[] {
    this.get(id);
    return this.store.taskRuns(id);
  }

  /** Runs the task right away, outside its schedule and the concurrency limit. */
  runNow(id: string, local = false): TaskRun {
    const task = this.get(id);
    if (local && task.action.type === "command") throw new HttpError(403, COMMAND_FORBIDDEN);
    if (task.action.type === "command" && !this.commandsAllowed()) throw new HttpError(403, COMMANDS_DISABLED);
    if (this.running.has(id)) throw new HttpError(409, "this task is already running");
    this.queue = this.queue.filter((q) => q !== id);
    return this.launch(task, false);
  }

  /** Queues due tasks and starts as many as the limits allow. Called by the timer; public for tests. */
  tick() {
    if (this.stopped) return;
    const now = this.now();
    for (const t of this.store.tasks()) {
      if (!t.enabled || !t.nextRunAt || Date.parse(t.nextRunAt) > now) continue;
      if (this.running.has(t.id) || this.queue.includes(t.id)) continue;
      this.queue.push(t.id);
    }
    this.drain();
    this.arm();
  }

  /** Commands do not use agent sessions, so they have their own limit and never wait for NUO_MAX_SESSIONS. */
  private hasRoom(task: ScheduledTask) {
    if (task.action.type === "command") return this.commands.size < this.commandConcurrency;
    return this.running.size - this.commands.size < this.concurrency && this.runner.busyCount < this.runner.maxSessions;
  }

  private drain() {
    const waiting: string[] = [];
    for (const id of this.queue) {
      const task = this.store.task(id);
      if (!task || !task.enabled || !task.nextRunAt || Date.parse(task.nextRunAt) > this.now() || this.running.has(task.id)) continue;
      if (this.hasRoom(task)) this.launch(task, true);
      else waiting.push(id);
    }
    this.queue = waiting;
  }

  private arm() {
    if (this.timer) clearTimeout(this.timer);
    this.timer = undefined;
    if (this.stopped) return;
    const now = this.now();
    let delay = MAX_TIMER_MS;
    for (const t of this.store.tasks()) {
      if (!t.enabled || !t.nextRunAt || this.running.has(t.id)) continue;
      delay = Math.min(delay, Math.max(0, Date.parse(t.nextRunAt) - now));
    }
    if (this.queue.length) delay = Math.max(delay, BUSY_RETRY_MS);
    this.timer = setTimeout(() => this.tick(), delay);
    this.timer.unref?.();
  }

  private launch(task: ScheduledTask, scheduled: boolean): TaskRun {
    const now = this.now();
    const startedAt = new Date(now).toISOString();
    if (scheduled) {
      // Advance the schedule first so the task is not picked up again while it runs.
      this.store.updateTask(
        task.id,
        task.schedule.kind === "once" ? { enabled: false, nextRunAt: null } : { nextRunAt: computeNextRun(task.schedule, now) ?? null },
      );
    }
    if (task.action.type === "command") return this.launchCommand(task, task.action, startedAt);

    const bot = this.store.bot(task.botId);
    const config = botConfig(bot);
    if (!bot || !config) {
      const run: TaskRun = { id: newId(), taskId: task.id, conversationId: "", startedAt, endedAt: startedAt, status: "error", error: "ce bot n'a pas de configuration" };
      this.store.addTaskRun(run);
      this.store.updateTask(task.id, { lastRunAt: startedAt, lastStatus: "error" });
      return run;
    }

    let conversationId = task.conversation === "dedicated" && task.conversationId && this.store.conversation(task.conversationId) ? task.conversationId : undefined;
    if (!conversationId) {
      conversationId = this.store.createConversation(bot.id, !bot.published, task.title).id;
      if (task.conversation === "dedicated") this.store.updateTask(task.id, { conversationId });
    }
    const run: TaskRun = { id: newId(), taskId: task.id, conversationId, startedAt, status: "running" };
    this.store.addTaskRun(run);
    this.store.updateTask(task.id, { lastRunAt: startedAt, lastStatus: "running" });
    this.track(task.id, this.execute(task, config, run));
    return run;
  }

  private launchCommand(task: ScheduledTask, action: CommandAction, startedAt: string): TaskRun {
    const run: TaskRun = { id: newId(), taskId: task.id, conversationId: "", startedAt, status: "running" };
    this.store.addTaskRun(run);
    this.store.updateTask(task.id, { lastRunAt: startedAt, lastStatus: "running" });
    const cmd = this.commandsAllowed()
      ? runCommand(action, this.commandHome, this.commandSpawner)
      : { done: Promise.resolve<CommandResult>({ ok: false, output: "", durationMs: 0, error: COMMANDS_DISABLED }), kill() {} };
    this.commands.set(task.id, cmd);
    this.track(
      task.id,
      cmd.done.then((r) => this.finishCommand(task.id, run, r)),
    );
    return run;
  }

  private track(taskId: string, work: Promise<void>) {
    const p = work
      .catch((e) => console.error(`[scheduler] task ${taskId}:`, e))
      .finally(() => {
        this.running.delete(taskId);
        this.commands.delete(taskId);
        const t = this.store.task(taskId);
        // A run longer than the interval skips the runs it overlapped instead of chaining them.
        if (t?.enabled && t.schedule.kind === "cron" && t.nextRunAt && Date.parse(t.nextRunAt) < this.now()) {
          this.store.updateTask(t.id, { nextRunAt: computeNextRun(t.schedule, this.now()) ?? null });
        }
        this.tick();
      });
    this.running.set(taskId, p);
  }

  private async finishCommand(taskId: string, run: TaskRun, r: CommandResult) {
    const status: TaskRun["status"] = r.ok ? "ok" : "error";
    const last = lastLines(r.output, 1);
    this.store.finishTaskRun(run.id, {
      status,
      endedAt: new Date(this.now()).toISOString(),
      preview: last ? clip(last, PREVIEW_MAX) : undefined,
      error: r.error,
      exitCode: r.exitCode,
      output: r.output || undefined,
      durationMs: r.durationMs,
    });
    const current = this.store.task(taskId);
    if (!current) return;
    this.store.updateTask(taskId, { lastStatus: status });
    if (this.stopped) return;
    const notifyOn = current.action.type === "command" ? current.action.notifyOn : "never";
    const wasOpen = this.store.taskAlertOpen(taskId);
    const isOpen = status === "error" && notifyOn !== "never";
    if (isOpen !== wasOpen) this.store.setTaskAlertOpen(taskId, isOpen);

    const tail = lastLines(r.output, PUSH_OUTPUT_LINES);
    let push: { title: string; body: string } | undefined;
    if (status === "error") {
      if (notifyOn === "always" || (notifyOn === "failure" && !wasOpen)) {
        push = { title: `⚠️ ${current.title}`, body: [r.error ?? "échec", tail].filter(Boolean).join("\n") };
      }
    } else if (wasOpen && notifyOn !== "never") {
      push = { title: `✅ ${current.title} rétabli`, body: tail || "La commande fonctionne à nouveau." };
    } else if (notifyOn === "always") {
      push = { title: current.title, body: tail || "Terminé" };
    }
    if (!push) return;
    const body = clip(push.body, PUSH_BODY_MAX);
    await Promise.all(
      this.store
        .devices()
        .filter((d) => d.apnsToken)
        .map((d) => this.pusher.send(d, { title: push.title, body, botId: current.botId, taskId: current.id, runId: run.id, destination: { kind: "task", id: current.id, botId: current.botId, runId: run.id } })),
    );
  }

  private async execute(task: ScheduledTask, config: BotConfig, run: TaskRun) {
    let status: TaskRun["status"] = "error";
    let text = "";
    let error: string | undefined;
    let quiet = false;
    try {
      const { messageId, done } = await this.runner.prompt({ conversationId: run.conversationId, text: task.prompt }, { scheduled: true, task: { id: task.id, title: task.title } });
      const outcome = await done;
      text = outcome.text;
      if (outcome.stopReason === "end_turn") status = "ok";
      else if (this.stopped) error = STOPPED_ERROR;
      else error = outcome.stopReason === "cancelled" ? "annulée" : outcome.error || text || "erreur inconnue";
      quiet = status === "ok" && isProactiveTask(task) && isNothingToPropose(text);
      // The agent session keeps the turn; only the transcript the user reads loses it.
      if (quiet) this.store.deleteMessages(run.conversationId, [messageId, ...(outcome.messageId ? [outcome.messageId] : [])]);
    } catch (e) {
      error = (e as Error)?.message ?? String(e);
    }
    const endedAt = new Date(this.now()).toISOString();
    const shown = quiet ? NOTHING_PREVIEW : preview(text, PREVIEW_MAX) || undefined;
    this.store.finishTaskRun(run.id, { status, endedAt, preview: shown, error });
    const current = this.store.task(task.id);
    if (!current) return;
    this.store.updateTask(task.id, { lastStatus: status });
    // The runner resumes the turn once the gateway is back: an error push would announce a failure that is not one.
    if (!current.notify || quiet || (this.stopped && status !== "ok")) return;
    const body = status === "ok" ? (shown ?? "Terminé") : `Erreur : ${preview(error ?? "", PREVIEW_MAX) || "échec"}`;
    const title = `${config.emoji} ${current.title}`.trim();
    await Promise.all(
      this.store
        .devices()
        .filter((d) => d.apnsToken)
        .map((d) =>
          this.pusher.send(d, {
            title,
            body,
            botId: current.botId,
            conversationId: run.conversationId,
            taskId: current.id,
            destination: { kind: "conversation", id: run.conversationId, botId: current.botId },
          }),
        ),
    );
  }
}
