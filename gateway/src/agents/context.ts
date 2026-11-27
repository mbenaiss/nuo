import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { AgentId, Attachment, Message } from "../protocol";
import type { UsageReport } from "./types";

/**
 * Context windows used when the agent does not report one (claude, codex and gemini send ACP
 * `usage_update` with `size`; grok does not). Assumptions:
 * - Claude: 200k, or 1M when the model id carries the `[1m]` suffix.
 * - Codex: `context_window * effective_context_window_percent` from ~/.codex/models_cache.json
 *   (what codex itself reports), else 272k at 95 %.
 * - Grok 4.x: 256k.
 * - Gemini, run by Antigravity (agy reports no window): by model family, Claude 200k, GPT-OSS 128k, Gemini 1M.
 */
export function contextWindow(agent: AgentId | string, model: string | undefined, codexHome = defaultCodexHome()): number | undefined {
  const m = (model ?? "").toLowerCase();
  switch (agent) {
    case "claude":
      return m.includes("[1m]") ? 1_000_000 : 200_000;
    case "codex":
      return codexWindow(m, codexHome) ?? Math.round(272_000 * 0.95);
    case "grok":
      return 256_000;
    case "gemini":
      return m.startsWith("claude") ? 200_000 : m.startsWith("gpt-oss") ? 128_000 : 1_000_000;
    default:
      return undefined;
  }
}

function defaultCodexHome(): string {
  return process.env.CODEX_HOME ?? join(homedir(), ".codex");
}

function codexWindow(model: string, codexHome: string): number | undefined {
  try {
    const cache = JSON.parse(readFileSync(join(codexHome, "models_cache.json"), "utf8")) as {
      models?: { slug: string; context_window?: number; effective_context_window_percent?: number }[];
    };
    const entry = cache.models?.find((x) => x.slug.toLowerCase() === model);
    if (!entry?.context_window) return undefined;
    return Math.round((entry.context_window * (entry.effective_context_window_percent ?? 100)) / 100);
  } catch {
    return undefined;
  }
}

const num = (v: unknown): number | undefined => (typeof v === "number" && Number.isFinite(v) && v >= 0 ? v : undefined);

/** ACP `usage_update` (claude-agent-acp, codex-acp, gemini --acp): `used` tokens in context out of `size`. */
export function usageFromUpdate(u: { used?: unknown; size?: unknown }): UsageReport | undefined {
  const used = num(u.used);
  if (used === undefined) return undefined;
  const size = num(u.size);
  return { usedTokens: used, ...(size ? { maxTokens: size } : {}) };
}

/**
 * Usage from a `session/prompt` response, for agents that send no `usage_update` (grok).
 * Grok puts the last model call's counts at the top of `_meta`; the standard (unstable) `usage`
 * is per turn and only a fallback. Zero totals (e.g. after a local command such as /compact) mean "unknown".
 */
export function usageFromPromptResponse(r: { usage?: unknown; _meta?: unknown } | null | undefined): UsageReport | undefined {
  const meta = r?._meta && typeof r._meta === "object" ? (r._meta as Record<string, unknown>) : undefined;
  if (meta && num(meta.totalTokens) && num(meta.inputTokens) !== undefined) {
    return { usedTokens: num(meta.inputTokens)! + (num(meta.outputTokens) ?? 0) };
  }
  const usage = r?.usage && typeof r.usage === "object" ? (r.usage as Record<string, unknown>) : undefined;
  const total = num(usage?.totalTokens);
  return total ? { usedTokens: total } : undefined;
}

/** Native compaction reports (claude-agent-acp's "Compact conversation" tool call carries pre/post token counts). */
export function compactionFromRawOutput(raw: unknown): { beforeTokens?: number; afterTokens?: number } | undefined {
  if (!raw || typeof raw !== "object") return undefined;
  const o = raw as Record<string, unknown>;
  const before = num(o.preTokens);
  const after = num(o.postTokens);
  if (before === undefined && after === undefined) return undefined;
  return { ...(before !== undefined ? { beforeTokens: before } : {}), ...(after !== undefined ? { afterTokens: after } : {}) };
}

/** Rough count (chars / 4) for agents that report nothing; tool outputs are not persisted, so it undercounts tool-heavy turns. */
export function estimateTokens(parts: (string | undefined)[]): number {
  let chars = 0;
  for (const p of parts) chars += p?.length ?? 0;
  return Math.ceil(chars / 4);
}

export function estimateConversationTokens(instructions: string | undefined, messages: Message[]): number {
  return estimateTokens([
    instructions,
    ...messages.flatMap((m) => [m.text, m.thoughts, ...(m.steps ?? []).map((s) => s.title)]),
  ]);
}

export const NOTICE_PREFIX = "::notice ";

export interface CompactedNotice {
  kind: "compacted";
  text: string;
  beforeTokens?: number;
  afterTokens?: number;
}

/** The conversation goes on with another agent or model from this point. */
export interface SwitchedNotice {
  kind: "switched";
  text: string;
  agent: AgentId;
  model?: string;
}

/** The gateway restarted during a turn and started it again from where the agent stopped. */
export interface ResumedNotice {
  kind: "resumed";
  text: string;
}

export type Notice = CompactedNotice | SwitchedNotice | ResumedNotice;

/** The persisted form of a notice: a single card line the app renders as a divider chip. */
export function noticeLine(n: Notice): string {
  return NOTICE_PREFIX + JSON.stringify(n);
}

export function isNotice(m: Message): boolean {
  return m.role === "assistant" && m.text.startsWith(NOTICE_PREFIX);
}

/** About 6k tokens: the last several exchanges, without crowding the smallest (128k) windows. */
export const HANDOFF_MAX_CHARS = 24_000;
export const HANDOFF_MESSAGE_MAX_CHARS = 4_000;

export const HANDOFF_FULL_PREFIX =
  "[Nuo] Cette conversation a commencé avec un autre agent. Voici les messages précédents, du plus ancien au plus récent, à garder comme contexte. Ne les rejoue pas : réponds seulement au nouveau message qui suit.";
export const HANDOFF_DELTA_PREFIX =
  "[Nuo] Depuis ton dernier message dans cette conversation, l'utilisateur a continué avec un autre agent. Voici ces messages, du plus ancien au plus récent, à garder comme contexte. Ne les rejoue pas : réponds seulement au nouveau message qui suit.";

/**
 * Transcript for an agent that did not see these turns (another agent answered them). `resumed`: the agent's own
 * session holds the turns before these. The oldest turns are dropped past `maxChars` and each message is cut at
 * HANDOFF_MESSAGE_MAX_CHARS; tool steps and thoughts stay out, they are the other agent's working notes.
 */
export function handoffTranscript(messages: Message[], resumed: boolean, maxChars = HANDOFF_MAX_CHARS): string {
  const lines = messages.filter((m) => !isNotice(m) && (m.text.trim() || m.attachments?.length)).map(transcriptLine);
  const kept: string[] = [];
  let used = 0;
  for (let i = lines.length - 1; i >= 0; i--) {
    if (kept.length && used + lines[i]!.length > maxChars) break;
    kept.unshift(lines[i]!);
    used += lines[i]!.length;
  }
  if (!kept.length) return "";
  const dropped = lines.length - kept.length;
  const omitted = dropped ? [`(${dropped} message${dropped > 1 ? "s plus anciens omis" : " plus ancien omis"})`] : [];
  return [resumed ? HANDOFF_DELTA_PREFIX : HANDOFF_FULL_PREFIX, "<historique>", ...omitted, ...kept, "</historique>", "", "Nouveau message :", ""].join("\n");
}

function transcriptLine(m: Message): string {
  const who = m.role === "user" ? "Utilisateur" : m.agent ? `Assistant (${[m.agent, m.model].filter(Boolean).join(" · ")})` : "Assistant";
  let text = m.text.trim();
  if (text.length > HANDOFF_MESSAGE_MAX_CHARS) text = `${text.slice(0, HANDOFF_MESSAGE_MAX_CHARS).trimEnd()} […]`;
  return `${who} : ${[text, ...(m.attachments ?? []).map(attachmentNote)].filter(Boolean).join(" ")}`;
}

function attachmentNote(a: Attachment): string {
  return a.kind === "image" ? "[image jointe]" : `[fichier joint : ${a.name ?? a.mime}]`;
}
