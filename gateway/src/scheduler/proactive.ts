import type { ScheduledTask, TaskSchedule } from "../protocol";
import { t } from "../i18n/language";
import type { Store } from "../store/store";
import { nextRun, parseCron } from "./cron";

export const PROACTIVE_SCHEDULE: Extract<TaskSchedule, { kind: "cron" }> = { kind: "cron", expr: "0 9 * * *", timezone: "Europe/Paris" };
/** The whole answer of a morning with nothing worth proposing: no push, and the turn leaves the conversation. */
export const NOTHING_TO_PROPOSE = "NOTHING";
/** The marker of the French prompt that proposals tasks created before keep in the database. */
const LEGACY_NOTHING_TO_PROPOSE = "RIEN";

export const PROACTIVE_PROMPT = `Today's proposals: before I ask you anything, look for what you could take care of for me today.

1. Look at your memory, our conversations and your recent data, as well as my calendar and my reminders if you have access to them. Use read-only tools only: create, send and change nothing.
2. Offer me at most 3 concrete things you could do for me now: a follow-up, a reminder, a scheduled task, a tracking, getting ready for an appointment… Each one fits in one sentence, followed on the next line by a card whose question sums up the proposal in a few words, for example:
::question {"question":"Shall I follow up with Julie Martin about the quote?","options":["Yes, do it","Later","No thanks"]}
3. Do nothing before my answer: I choose on each card.
4. Only offer what is really useful to me, without repeating a proposal I already turned down. If you have nothing useful to offer, answer exactly ${NOTHING_TO_PROPOSE}, without any other word.`;

export const isProactiveTask = (t: Pick<ScheduledTask, "createdBy">) => t.createdBy === "gateway";

export const isNothingToPropose = (answer: string) => [NOTHING_TO_PROPOSE, LEGACY_NOTHING_TO_PROPOSE].includes(answer.trim());

/**
 * Keeps exactly one proposals task for a published proactive bot and none otherwise. An existing task is left as
 * the user tuned it (time, pause, notification); only a missing one is created.
 */
export function syncProactiveTask(store: Store, botId: string, now: number): ScheduledTask | undefined {
  const wanted = store.bot(botId)?.published?.config.proactive === true;
  const [kept, ...extra] = store.tasks(botId).filter(isProactiveTask);
  for (const t of wanted ? extra : [kept, ...extra]) if (t) store.deleteTask(t.id);
  if (!wanted) return undefined;
  if (kept) return kept;
  const next = nextRun(parseCron(PROACTIVE_SCHEDULE.expr), PROACTIVE_SCHEDULE.timezone, now);
  return store.createTask({
    botId,
    title: t("schedule.proactiveTitle", {}, store.uiLanguage()),
    action: { type: "prompt" },
    prompt: PROACTIVE_PROMPT,
    schedule: PROACTIVE_SCHEDULE,
    enabled: true,
    conversation: "dedicated",
    notify: true,
    createdBy: "gateway",
    nextRunAt: next === undefined ? undefined : new Date(next).toISOString(),
  });
}

/** At start: also covers publishes that bypass BotService (seed sync, profile import). */
export function syncAllProactiveTasks(store: Store, now: number) {
  for (const { id } of store.botSlugs()) syncProactiveTask(store, id, now);
}
