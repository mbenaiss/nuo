import { DEFAULT_UI_LANGUAGE, t, type UiLanguage } from "../i18n/language";
import { head } from "../text";

/**
 * A goal turn ("Goal" in the composer): the bot carries the request to its end without asking at each step.
 * The gateway answers its permission requests itself, except for what acts on other people or loses data, which the
 * user confirms in words (docs/security.md, "Goal mode").
 */

export const GOAL_PREFIX = `[Goal mode: this request is a goal to reach on your own.
- Carry the task through to the end without asking for my opinion along the way: choose yourself what is reasonable and note your assumptions.
- Check the result before concluding (read again what you wrote, make sure the action did take place, test what can be tested).
- Sending an email, inviting people or deleting something: Nuo has me confirm it at the time of the call, and that confirmation is my explicit consent. Prepare everything, then start the action without asking my permission in the conversation. For these actions, go only through Nuo's tools (gmail_send, calendar_create, calendar_delete, apple_event_delete…), never through a command such as gog.
- End with a short report: what is done, how you checked it, and what may be left for me to do.]

`;

/** How long a goal turn waits for a confirmation: the user is often away, a push tells them. */
export const GOAL_CONFIRMATION_TIMEOUT_MS = 30 * 60 * 1000;

/** Holds a tool route until the user confirms it during a goal turn; throws when refused. */
export type GoalGuard = (req: Request, name: string, input: Record<string, unknown>, draft?: () => Promise<string | undefined>) => Promise<void>;

export const GOAL_REFUSAL = "refused: the user did not allow this action. Do not try it again, mention it in your report.";

const said = (v: unknown, max = 80): string => {
  if (typeof v !== "string" && typeof v !== "number") return "";
  const t = String(v).replace(/\s+/g, " ").trim();
  return t.length > max ? `${head(t, max - 1).trimEnd()}…` : t;
};
function attendees(v: unknown): string[] {
  const list = Array.isArray(v) ? v : typeof v === "string" ? v.split(",") : [];
  return list.map((x) => said(x, 60)).filter(Boolean);
}

/**
 * What the user confirms during a goal turn, in words, for a tool of the `nuo` server; undefined when the call
 * needs no confirmation. `draft` describes a Gmail draft (recipients and subject) when the caller can read it.
 */
export function goalConfirmation(name: string, input: Record<string, unknown>, draft?: string, lang: UiLanguage = DEFAULT_UI_LANGUAGE): string | undefined {
  const quoted = (v: unknown) => (said(v) ? t("goal.quoted", { text: said(v) }, lang) : "");
  const say = (key: Parameters<typeof t>[0], params: Record<string, string> = {}) => t(key, params, lang).replace(/\s+/g, " ").trim();
  switch (name) {
    case "gmail_send":
      return draft ? say("goal.sendEmail", { draft }) : say("goal.sendDraft", { id: said(input.draft_id, 40) });
    case "calendar_create": {
      const people = attendees(input.attendees);
      if (!people.length) return undefined;
      return say("goal.invite", { people: people.join(", "), event: quoted(input.title) || t("goal.googleEvent", {}, lang) });
    }
    case "calendar_delete":
      return say("goal.deleteGoogleEvent", { id: said(input.event_id, 60) });
    case "apple_event_delete":
      return say("goal.deleteEvent", { event: quoted(input.title) || said(input.id, 60) });
    case "apple_calendar_delete":
      return say("goal.deleteCalendar", { calendar: quoted(input.title) || said(input.id, 60) });
    case "workout_cancel":
      return input.all === true ? say("goal.cancelAllWorkouts") : say("goal.cancelWorkout", { workout: quoted(input.name) });
    default:
      return undefined;
  }
}
