/**
 * Reads and edits `KEY=value` files in place: comments, blank lines, `export`, spacing and quoting of the other
 * lines stay byte for byte, so the shells, systemd units and dotenv loaders that read the file keep working.
 */

export type Quote = "none" | "single" | "double";

export interface EnvEntry {
  key: string;
  exported: boolean;
  /** First line of the assignment and how many lines it covers (a quoted value may span several). */
  line: number;
  span: number;
  value: string;
  quote: Quote;
  /** Everything before the value: indentation, `export `, the key and `=`. */
  prefix: string;
  /** What follows the value on its last line (closing text after a quote, an inline comment). */
  suffix: string;
}

export interface EnvDoc {
  lines: string[];
  entries: EnvEntry[];
  eol: string;
  trailingNewline: boolean;
}

export const KEY_PATTERN = /^[A-Za-z_][A-Za-z0-9_]*$/;
const ASSIGN = /^(\s*(export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*)(.*)$/;
/** Characters every reader takes literally without quotes (`~` is not: a shell expands it). */
const BARE_SAFE = /^[A-Za-z0-9_@%+=:,./^-]*$/;

function closing(text: string, quote: string, from: number): number {
  for (let i = from; i < text.length; i++) {
    if (quote === '"' && text[i] === "\\") {
      i++;
      continue;
    }
    if (text[i] === quote) return i;
  }
  return -1;
}

const unescapeDouble = (s: string) => s.replace(/\\([\\"$`])/g, "$1");
const escapeDouble = (s: string) => s.replace(/[\\"$`]/g, (c) => `\\${c}`);

export function parseEnv(text: string): EnvDoc {
  const eol = text.includes("\r\n") ? "\r\n" : "\n";
  const trailingNewline = text.endsWith(eol);
  const lines = text === "" ? [] : (trailingNewline ? text.slice(0, -eol.length) : text).split(eol);
  const entries: EnvEntry[] = [];
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i]!.match(ASSIGN);
    if (!m) continue;
    const prefix = m[1]!;
    const rest = m[4]!;
    const entry = { key: m[3]!, exported: !!m[2], line: i, prefix };
    const q = rest[0];
    if (q === '"' || q === "'") {
      let joined = rest;
      let end = closing(joined, q, 1);
      let span = 1;
      while (end < 0 && i + span < lines.length) {
        joined += "\n" + lines[i + span];
        span++;
        end = closing(joined, q, 1);
      }
      if (end >= 0) {
        const inner = joined.slice(1, end);
        entries.push({ ...entry, span, value: q === '"' ? unescapeDouble(inner) : inner, quote: q === '"' ? "double" : "single", suffix: joined.slice(end + 1) });
        i += span - 1;
        continue;
      }
    }
    const bare = rest.match(/^(.*?)(\s+#.*|\s*)$/)!;
    entries.push({ ...entry, span: 1, value: bare[1]!, quote: "none", suffix: bare[2]! });
  }
  return { lines, entries, eol, trailingNewline };
}

export function renderEnv(doc: EnvDoc): string {
  if (!doc.lines.length) return "";
  return doc.lines.join(doc.eol) + (doc.trailingNewline ? doc.eol : "");
}

/** Keeps the quoting the line already had when the new value allows it. */
export function quoteValue(value: string, preferred: Quote = "none"): string {
  if (preferred === "none" && BARE_SAFE.test(value)) return value;
  if (preferred === "single" && !value.includes("'")) return `'${value}'`;
  if (preferred === "double") return `"${escapeDouble(value)}"`;
  if (BARE_SAFE.test(value)) return value;
  return value.includes("'") ? `"${escapeDouble(value)}"` : `'${value}'`;
}

/** The value a shell sourcing the file ends up with: the last assignment wins. */
export function lastEntry(doc: EnvDoc, key: string): EnvEntry | undefined {
  return doc.entries.findLast((e) => e.key === key);
}

export function setEntry(doc: EnvDoc, key: string, value: string): EnvDoc {
  const lines = [...doc.lines];
  const existing = lastEntry(doc, key);
  if (existing) {
    lines.splice(existing.line, existing.span, existing.prefix + quoteValue(value, existing.quote) + existing.suffix);
  } else {
    // A file whose every variable is exported is sourced by a shell that needs them in child processes.
    const exportAll = doc.entries.length > 0 && doc.entries.every((e) => e.exported);
    lines.push(`${exportAll ? "export " : ""}${key}=${quoteValue(value)}`);
  }
  return parseEnv(serialize(lines, doc));
}

export function deleteEntry(doc: EnvDoc, key: string): EnvDoc {
  const drop = new Set<number>();
  for (const e of doc.entries) if (e.key === key) for (let i = 0; i < e.span; i++) drop.add(e.line + i);
  return parseEnv(serialize(doc.lines.filter((_, i) => !drop.has(i)), doc));
}

function serialize(lines: string[], doc: EnvDoc): string {
  if (!lines.length) return "";
  // A file without a final newline keeps it that way; a new file gets one, like any editor writes it.
  const trailing = doc.trailingNewline || doc.lines.length === 0;
  return lines.join(doc.eol) + (trailing ? doc.eol : "");
}
