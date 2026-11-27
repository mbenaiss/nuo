import type { ScheduledTask, TaskSchedule } from "../protocol";
import type { Store } from "../store/store";
import { nextRun, parseCron } from "./cron";

export const PROACTIVE_TITLE = "Propositions du jour";
export const PROACTIVE_SCHEDULE: Extract<TaskSchedule, { kind: "cron" }> = { kind: "cron", expr: "0 9 * * *", timezone: "Europe/Paris" };
/** The whole answer of a morning with nothing worth proposing: no push, and the turn leaves the conversation. */
export const NOTHING_TO_PROPOSE = "RIEN";
export const NOTHING_PREVIEW = "Rien à proposer aujourd'hui";

export const PROACTIVE_PROMPT = `Propositions du jour : avant que je te demande quoi que ce soit, cherche ce que tu pourrais prendre en charge pour moi aujourd'hui.

1. Regarde ta mémoire, nos conversations et tes données récentes, ainsi que mon agenda et mes rappels si tu y as accès. Utilise uniquement des outils de lecture : ne crée, n'envoie et ne modifie rien.
2. Propose-moi au plus 3 choses concrètes que tu pourrais faire maintenant pour moi : une relance, un rappel, une tâche planifiée, un suivi, la préparation d'un rendez-vous… Chacune tient en une phrase, suivie sur la ligne d'après d'une carte dont la question reprend la proposition en quelques mots, par exemple :
::question {"question":"Je relance Julie Martin pour le devis ?","options":["Oui, fais-le","Plus tard","Non merci"]}
3. Ne fais rien avant ma réponse : je choisis sur chaque carte.
4. Ne propose que ce qui m'est vraiment utile, sans répéter une proposition que j'ai déjà refusée. Si tu n'as rien d'utile à proposer, réponds exactement ${NOTHING_TO_PROPOSE}, sans aucun autre mot.`;

export const isProactiveTask = (t: Pick<ScheduledTask, "createdBy">) => t.createdBy === "gateway";

export const isNothingToPropose = (answer: string) => answer.trim() === NOTHING_TO_PROPOSE;

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
    title: PROACTIVE_TITLE,
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
