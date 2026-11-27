import type { ToolRule } from "../protocol";
import type { RelayToolCall } from "../relay/whitelist";
import { goalConfirmation } from "../runner/goal";

export const TOOL_RULES_MAX = 100;
const RULES: ToolRule[] = ["allow", "block"];
const KEY = /^(?:[A-Za-z0-9_.-]{1,64}\/)?[A-Za-z0-9_-]{1,64}$/;

export function isToolRuleKey(key: string): boolean {
  return KEY.test(key);
}

export function isToolRule(v: unknown): v is ToolRule {
  return RULES.includes(v as ToolRule);
}

/** `server/name` for an MCP tool, the bare name of a built-in one; undefined for a name no rule could be kept under. */
export function toolRuleKey(tool: RelayToolCall): string | undefined {
  const key = tool.server ? `${tool.server}/${tool.name}` : tool.name;
  return isToolRuleKey(key) ? key : undefined;
}

/**
 * Sending, inviting and deleting through Nuo's own tools: what a goal turn has the user confirm (src/runner/goal.ts)
 * is never allowed for good. Without `input`, whether the tool can do so at all (calendar_create only invites with
 * attendees, so it can still be allowed: the rule then skips only the calls without any).
 */
export function alwaysConfirmed(tool: RelayToolCall): boolean {
  return tool.server === "nuo" && goalConfirmation(tool.name, tool.input ?? {}) !== undefined;
}

function confirmedKey(key: string): boolean {
  const [server, name] = key.split("/");
  return !!name && alwaysConfirmed({ server, name });
}

/** The rules a permission card may offer to remember for this call. */
export function offeredRules(tool: RelayToolCall): ToolRule[] {
  return alwaysConfirmed(tool) ? ["block"] : ["allow", "block"];
}

/** The rule that decides this call, if any: an `allow` never covers a call that sends, invites or deletes. */
export function ruleFor(rules: Record<string, ToolRule> | undefined, tool: RelayToolCall): ToolRule | undefined {
  const key = toolRuleKey(tool);
  const rule = key ? rules?.[key] : undefined;
  return rule === "allow" && alwaysConfirmed(tool) ? undefined : rule;
}

/** Why this rule cannot be kept for this key, or undefined when it can. */
export function toolRuleError(key: string, rule: unknown): string | undefined {
  if (!isToolRuleKey(key)) return `invalid tool rule key "${key.slice(0, 80)}"`;
  if (!isToolRule(rule)) return `tool rule for ${key} must be one of ${RULES.join(", ")}`;
  if (rule === "allow" && confirmedKey(key)) return `${key} sends, invites or deletes: it is always confirmed`;
  return undefined;
}

export function validateToolRules(v: unknown, errors: string[]): Record<string, ToolRule> | undefined {
  if (v === undefined || v === null) return undefined;
  if (typeof v !== "object" || Array.isArray(v)) {
    errors.push("toolRules must be an object");
    return undefined;
  }
  const entries = Object.entries(v as Record<string, unknown>);
  if (entries.length > TOOL_RULES_MAX) errors.push(`toolRules holds at most ${TOOL_RULES_MAX} tools`);
  for (const [key, rule] of entries) {
    const error = toolRuleError(key, rule);
    if (error) errors.push(error);
  }
  return entries.length ? (Object.fromEntries(entries) as Record<string, ToolRule>) : undefined;
}
