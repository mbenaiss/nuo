import { head } from "../text";

/**
 * A goal turn (« Objectif » in the composer): the bot carries the request to its end without asking at each step.
 * The gateway answers its permission requests itself, except for what acts on other people or loses data, which the
 * user confirms in words (docs/security.md, « Mode objectif »).
 */

export const GOAL_PREFIX = `[Mode objectif : cette demande est un objectif à atteindre en autonomie.
- Mène la tâche jusqu'au bout sans me demander mon avis en chemin : choisis toi-même ce qui est raisonnable et note tes hypothèses.
- Vérifie le résultat avant de conclure (relis ce que tu as écrit, contrôle que l'action a bien eu lieu, teste ce qui peut l'être).
- Envoyer un e-mail, inviter des personnes ou supprimer quelque chose : Nuo me le fait confirmer au moment de l'appel, et cette confirmation vaut mon accord explicite. Prépare tout, puis lance l'action sans me demander la permission dans la conversation. Pour ces actions, passe uniquement par les outils de Nuo (gmail_send, calendar_create, calendar_delete, apple_event_delete…), jamais par une commande comme gog.
- Termine par un compte rendu court : ce qui est fait, comment tu l'as vérifié, et ce qui reste éventuellement à faire de mon côté.]

`;

/** How long a goal turn waits for a confirmation: the user is often away, a push tells them. */
export const GOAL_CONFIRMATION_TIMEOUT_MS = 30 * 60 * 1000;

/** Holds a tool route until the user confirms it during a goal turn; throws when refused. */
export type GoalGuard = (req: Request, name: string, input: Record<string, unknown>, draft?: () => Promise<string | undefined>) => Promise<void>;

export const GOAL_REFUSAL = "refusé : l'utilisateur n'a pas autorisé cette action. Ne la retente pas, signale-le dans ton compte rendu.";

const said = (v: unknown, max = 80): string => {
  if (typeof v !== "string" && typeof v !== "number") return "";
  const t = String(v).replace(/\s+/g, " ").trim();
  return t.length > max ? `${head(t, max - 1).trimEnd()}…` : t;
};
const quoted = (v: unknown) => (said(v) ? `« ${said(v)} »` : "");
const join = (...parts: string[]) => parts.filter(Boolean).join(" ");

function attendees(v: unknown): string[] {
  const list = Array.isArray(v) ? v : typeof v === "string" ? v.split(",") : [];
  return list.map((x) => said(x, 60)).filter(Boolean);
}

/**
 * What the user confirms during a goal turn, in words, for a tool of the `nuo` server; undefined when the call
 * needs no confirmation. `draft` describes a Gmail draft (recipients and subject) when the caller can read it.
 */
export function goalConfirmation(name: string, input: Record<string, unknown>, draft?: string): string | undefined {
  switch (name) {
    case "gmail_send":
      return join("Envoyer l'e-mail", draft ? `: ${draft}` : `(brouillon ${said(input.draft_id, 40)})`);
    case "calendar_create": {
      const people = attendees(input.attendees);
      if (!people.length) return undefined;
      return join(`Inviter ${people.join(", ")} à`, quoted(input.title) || "un évènement Google");
    }
    case "calendar_delete":
      return join("Supprimer l'évènement Google", said(input.event_id, 60));
    case "apple_event_delete":
      return join("Supprimer l'évènement", quoted(input.title) || said(input.id, 60));
    case "apple_calendar_delete":
      return join("Supprimer l'agenda", quoted(input.title) || said(input.id, 60));
    case "workout_cancel":
      return input.all === true ? "Retirer toutes les séances programmées sur la montre" : join("Retirer la séance", quoted(input.name), "de la montre");
    default:
      return undefined;
  }
}
