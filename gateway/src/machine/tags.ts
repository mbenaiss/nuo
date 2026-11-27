import type { MachineTool, PermissionPolicy } from "../protocol";

const blank = (s: string) => s.replace(/[^\n]/g, " ");

/** Removes regions where a "#" is never a tag: fenced code, inline code and URLs. */
function maskIgnored(text: string): string {
  return text
    .replace(/```[\s\S]*?(?:```|$)/g, blank)
    .replace(/`[^`\n]*`/g, blank)
    .replace(/\b[a-z][a-z0-9+.-]*:\/\/\S+/gi, blank)
    .replace(/\bwww\.\S+/gi, blank);
}

/** Tag ids found in `text` (lowercased, first occurrence order); `#` followed by a digit is never a tag. */
export function parseToolTags(text: string): string[] {
  const out: string[] = [];
  const re = /(^|[^\p{L}\p{N}_&#/-])#([a-z][a-z0-9_-]*)(?![a-z0-9_-])/giu;
  for (const m of maskIgnored(text).matchAll(re)) {
    const id = m[2]!.toLowerCase().replace(/[-_]+$/, "");
    if (id && !out.includes(id)) out.push(id);
  }
  return out;
}

export function taggedTools(text: string, tools: MachineTool[]): MachineTool[] {
  if (!text.includes("#")) return [];
  const byId = new Map(tools.filter((t) => t.available).map((t) => [t.id, t]));
  return parseToolTags(text).flatMap((id) => byId.get(id) ?? []);
}

const indent = (s: string) => s.trim().split(/\r?\n/).join("\n  ");

/** French hint prepended to the agent's prompt for this turn only; empty when nothing is tagged. */
export function toolHint(tools: MachineTool[], policy: PermissionPolicy): string {
  if (!tools.length) return "";
  let usable = 0;
  const lines = tools.map((t) => {
    if (t.needsShell && policy !== "auto") {
      return `- ${t.id} (${t.name}) : indisponible pour ce bot (pas d'accès au shell). Dis à l'utilisateur de le demander à Cobot.`;
    }
    usable++;
    return `- ${t.id} (${t.name}) : ${indent(t.usage || t.description)}`;
  });
  const footer = usable ? "\nUtilise-les en priorité." : "";
  return `Outils demandés par l'utilisateur pour ce message :\n${lines.join("\n")}${footer}\n\n`;
}
