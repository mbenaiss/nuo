/**
 * Claude Code attaches to the turn, without a tool call or a permission request, any file a prompt names as `@path`
 * or `@"path"`: a text the owner did not type (a share, a watch, a machine token) could read any file the gateway
 * user can. Removing the tools does not stop it. A deny rule on every read (`Read(//**)`) does, but it also keeps
 * Claude Code from loading the bot's CLAUDE.md, its instructions: the text is neutralized instead.
 */

/** FULLWIDTH COMMERCIAL AT: reads as "@" to the model and to the user, never starts a mention. */
const NEUTRAL_AT = "\uFF20";

/**
 * Claude Code only takes an `@` at the start of the text or after a blank (no-break space included) for a mention.
 * With a margin, every `@` is neutralized but one right after a letter, a digit or a slash: an address
 * (julie.martin@example.fr) and a shared link (youtube.com/@fireship, maps/place/Lyon/@45.75,4.83) stay as they are.
 * A word that only starts with `@` changes too, `@media` or `npm i @scope/pkg` from a machine token included: the
 * model still reads it.
 */
const MENTION_AT = /(?<![\p{L}\p{N}\p{M}/])@/gu;

/** The text with no `@` that Claude Code would take for a file mention; anything else is left as it was. */
export function neutralizeMentions(text: string): string {
  return text.replace(MENTION_AT, NEUTRAL_AT);
}

/** FULLWIDTH SOLIDUS: still reads as "/", never starts a command. */
const NEUTRAL_SLASH = "／";

/**
 * Claude Code runs a prompt that starts with `/` as one of the host's commands or skills, whose body may run a
 * command or name a file. For a text the owner did not type, once the bot's own commands are ruled out.
 */
export function neutralizeCommand(text: string): string {
  return text.replace(/^(\s*)\//, `$1${NEUTRAL_SLASH}`);
}
