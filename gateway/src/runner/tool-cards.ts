const KV = /^\s*(?:[-•*]\s+)?\**([^:\n*]{1,40}?)\**\s*:\s+(\S.*)$/;
const TITLE = /^\s*\**([^:\n]{1,60}?)\**\s*:\s*$/;
const MIN_ITEMS = 2;

/**
 * Slash commands of type `tool` skip the agent, so nobody formats their output: a "Label : value" listing
 * becomes a ::facts card (title from a leading "Bilan aujourd'hui :" line), other lines stay as text around it.
 * Output that already has cards, or is not mostly a listing, is returned as is.
 */
export function cardsFromToolText(text: string): string {
  const lines = text.split("\n");
  if (lines.some((l) => l.trimStart().startsWith("::"))) return text;

  let title: string | undefined;
  const firstContent = lines.findIndex((l) => l.trim() !== "");
  const titleMatch = firstContent >= 0 ? TITLE.exec(lines[firstContent]!) : null;
  if (titleMatch) title = titleMatch[1]!.trim();

  const items: { label: string; value: string }[] = [];
  const before: string[] = [];
  const after: string[] = [];
  let content = 0;
  lines.forEach((line, i) => {
    if (titleMatch && i === firstContent) return;
    if (line.trim() === "") return;
    content++;
    const kv = KV.exec(line);
    if (kv && !/https?$/i.test(kv[1]!.trim())) {
      items.push({ label: kv[1]!.trim(), value: kv[2]!.replace(/\*\*/g, "").trim() });
    } else {
      (items.length ? after : before).push(line);
    }
  });
  if (items.length < MIN_ITEMS || items.length * 2 < content) return text;

  const card = `::facts ${JSON.stringify({ ...(title ? { title } : {}), items })}`;
  return [...before, card, ...after].join("\n");
}
