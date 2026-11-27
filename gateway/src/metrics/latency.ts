import type { BotLatency, LatencyDay, LatencyReport, LatencyStats, ServerEvent } from "../protocol";
import type { Hub } from "../runner/hub";
import type { Store, TurnMetric, TurnOrigin } from "../store/store";

export const LATENCY_RETENTION_DAYS = 90;
const DAY_MS = 86_400_000;

/** What the agent itself sends; turn.phase, context and notices come from the gateway and say nothing of the agent's speed. */
const AGENT_EVENTS = new Set<ServerEvent["type"]>(["message.delta", "thought.delta", "tool.start", "tool.detail", "tool.end", "subagent", "permission.request"]);

interface OpenTurn {
  messageId: string;
  botId: string;
  conversationId: string;
  origin: TurnOrigin;
  at: string;
  startedAt: number;
  firstEventMs?: number;
  firstTextMs?: number;
  toolMs: number;
}

/**
 * Times every agent answer from the events the runner broadcasts, so it measures exactly what the app sees.
 * Answers the gateway writes by itself (slash commands, compaction) carry no agent on `message.end` and are left out.
 */
export class LatencyRecorder {
  private turns = new Map<string, OpenTurn>();
  private resuming = new Set<string>();
  private prunedAt = 0;

  constructor(
    private store: Store,
    private clock: () => number = Date.now,
  ) {}

  attach(hub: Hub): () => void {
    return hub.observe((e) => this.observe(e));
  }

  observe(e: ServerEvent) {
    if (e.type === "notice") {
      if (e.kind === "resumed") this.resuming.add(e.conversationId);
      return;
    }
    if (e.type === "message.start") {
      const resumed = this.resuming.delete(e.conversationId);
      const botId = e.botId ?? this.store.conversation(e.conversationId)?.botId;
      if (!botId) return;
      const origin: TurnOrigin = resumed ? "resumed" : this.store.hasRunningTaskRun(e.conversationId) ? "scheduled" : "user";
      this.turns.set(e.conversationId, { messageId: e.messageId, botId, conversationId: e.conversationId, origin, at: e.at, startedAt: this.clock(), toolMs: 0 });
      return;
    }
    if (!("conversationId" in e) || !e.conversationId) return;
    const t = this.turns.get(e.conversationId);
    if (!t || ("messageId" in e && e.messageId !== t.messageId)) return;
    if (e.type === "message.end") {
      this.turns.delete(e.conversationId);
      if (e.agent) this.save(t, e);
      return;
    }
    if (!AGENT_EVENTS.has(e.type)) return;
    const elapsed = this.clock() - t.startedAt;
    t.firstEventMs ??= elapsed;
    if (e.type === "message.delta" && e.text.trim()) t.firstTextMs ??= elapsed;
    if (e.type === "tool.end") t.toolMs += e.durationMs;
  }

  private save(t: OpenTurn, e: Extract<ServerEvent, { type: "message.end" }>) {
    this.store.addTurnMetric({
      messageId: t.messageId,
      botId: t.botId,
      conversationId: t.conversationId,
      origin: t.origin,
      startedAt: t.at,
      firstEventMs: t.firstEventMs,
      firstTextMs: t.firstTextMs,
      durationMs: e.durationMs,
      toolMs: t.toolMs,
      steps: e.steps,
      stopReason: e.stopReason,
      agent: e.agent!,
      model: e.model,
    });
    const now = this.clock();
    if (now - this.prunedAt < DAY_MS) return;
    this.prunedAt = now;
    this.store.pruneTurnMetrics(new Date(now - LATENCY_RETENTION_DAYS * DAY_MS).toISOString());
  }
}

/** Per bot over the last `days` local days (today included), most answers first. */
export function latencyReport(store: Store, opts: { days?: number; scheduled?: boolean; now?: number } = {}): LatencyReport {
  const days = Math.min(LATENCY_RETENTION_DAYS, Math.max(1, Math.floor(opts.days ?? 7)));
  const midnight = new Date(opts.now ?? Date.now());
  midnight.setHours(0, 0, 0, 0);
  midnight.setDate(midnight.getDate() - (days - 1));
  const since = midnight.toISOString();
  const scheduled = !!opts.scheduled;
  const rows = store.turnMetrics(since, scheduled ? ["user", "scheduled"] : ["user"]);
  const byBot = groupBy(rows, (r) => r.botId);
  const bots: BotLatency[] = [];
  for (const [botId, list] of byBot) {
    const bot = store.bot(botId);
    const config = bot?.published?.config ?? bot?.draft;
    if (!bot || !config) continue;
    const daily: LatencyDay[] = [...groupBy(list, (r) => localDay(r.startedAt))].map(([day, l]) => ({ day, ...stats(l) }));
    bots.push({ botId, name: config.name, emoji: config.emoji, ...(config.color ? { color: config.color } : {}), ...stats(list), daily });
  }
  bots.sort((a, b) => b.responses - a.responses || a.name.localeCompare(b.name));
  return { days, since, scheduled, bots };
}

function stats(rows: TurnMetric[]): LatencyStats {
  const pick = (f: (r: TurnMetric) => number | undefined) => rows.map(f).filter((v): v is number => v !== undefined);
  const firstText = pick((r) => r.firstTextMs);
  const completed = pick((r) => (r.stopReason === "end_turn" ? r.durationMs : undefined));
  // Absent percentiles stay undefined, which JSON leaves out.
  return {
    responses: rows.length,
    firstTextMedianMs: quantile(firstText, 0.5),
    firstTextP90Ms: quantile(firstText, 0.9),
    firstEventMedianMs: quantile(pick((r) => r.firstEventMs), 0.5),
    durationMedianMs: quantile(completed, 0.5),
    toolMedianMs: quantile(pick((r) => r.toolMs), 0.5),
    avgSteps: Math.round((rows.reduce((n, r) => n + r.steps, 0) / Math.max(1, rows.length)) * 10) / 10,
  };
}

/** Linear between the two closest ranks, so the median of two answers is their mean. */
export function quantile(values: number[], q: number): number | undefined {
  if (!values.length) return undefined;
  const sorted = [...values].sort((a, b) => a - b);
  const pos = (sorted.length - 1) * q;
  const lo = Math.floor(pos);
  const hi = Math.ceil(pos);
  return Math.round(sorted[lo]! + (sorted[hi]! - sorted[lo]!) * (pos - lo));
}

function localDay(iso: string): string {
  const d = new Date(iso);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

function groupBy<T>(items: T[], key: (item: T) => string): Map<string, T[]> {
  const out = new Map<string, T[]>();
  for (const item of items) {
    const k = key(item);
    const list = out.get(k);
    if (list) list.push(item);
    else out.set(k, [item]);
  }
  return out;
}
