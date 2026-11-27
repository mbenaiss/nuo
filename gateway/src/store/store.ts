import type { Database } from "bun:sqlite";
import { uniqueSlug } from "./slug";
import type { PushDestination } from "../push/apns";
import type { Alert, Attachment, Bot, BotConfig, BotVersion, ContextUsage, Conversation, ConversationSearchHit, Message, MessageTask, ScheduledTask, SubagentInfo, TaskAction, TaskRun, TaskSchedule, ToolStep } from "../protocol";

export const now = () => new Date().toISOString();
export const newId = () => crypto.randomUUID();

const SEARCH_SCAN = 400;

/** Lowercase without accents, as the full-text index compares words. */
export function foldText(s: string): string {
  return s.normalize("NFD").replace(/\p{M}+/gu, "").toLowerCase();
}

/** Each word of the query as a prefix, all required: « factu edf » finds « la facture EDF de mars ». */
export function searchTerms(query: string): string[] {
  return foldText(query).match(/[\p{L}\p{N}]+/gu) ?? [];
}

export type StoredSearchHit = Omit<ConversationSearchHit, "conversation"> & { conversation: StoredConversation };

const ALERTED_META_PREFIX = "alerted.conversation.";
const ALERT_KEEP = 500;
const ALERT_MAX_AGE_DAYS = 60;

export function alertText(title: string, body: string): string {
  const head = title.trim() ? `🔔 **${title.trim()}**` : "🔔";
  return body.trim() ? `${head}\n\n${body.trim()}` : head;
}

export interface Device {
  id: string;
  name: string;
  apnsToken?: string;
  apnsEnv?: "development" | "production";
}

/** A native session of one agent for a conversation, and the last message it has seen. */
export interface NativeSession {
  sessionId: string;
  syncedTo?: string;
}

export interface StoredConversation extends Conversation {
  /** The agent whose session ran last, and that session. */
  agentId?: string;
  agentSessionId?: string;
  /** Per agent, so switching back resumes that agent's own session. */
  agentSessions?: Partial<Record<string, NativeSession>>;
}

/** Who started an agent turn: the user, a scheduled task, or the gateway resuming a turn cut by a restart. */
export type TurnOrigin = "user" | "scheduled" | "resumed";

/** The timings of one agent answer (turn_metrics). */
export interface TurnMetric {
  messageId: string;
  botId: string;
  conversationId: string;
  origin: TurnOrigin;
  startedAt: string;
  firstEventMs?: number;
  firstTextMs?: number;
  durationMs: number;
  toolMs: number;
  steps: number;
  stopReason: NonNullable<Message["stopReason"]>;
  agent: string;
  model?: string;
}

type Row = Record<string, any>;

const parse = <T>(s: string | null | undefined): T | undefined => (s ? (JSON.parse(s) as T) : undefined);
const opt = <T>(v: T | null | undefined): T | undefined => (v == null ? undefined : v);

export class Store {
  constructor(readonly db: Database) {}

  getMeta(key: string): string | undefined {
    return opt((this.db.query("SELECT value FROM meta WHERE key = ?").get(key) as Row | null)?.value);
  }

  setMeta(key: string, value: string) {
    this.db.query("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value").run(key, value);
  }

  /** Keeps a bot's alert in the conversation it came from: the notification alone leaves nothing to find. */
  recordAlert(conversationId: string, title: string, body: string): Message {
    const message: Message = { id: newId(), conversationId, role: "assistant", text: alertText(title, body), stopReason: "end_turn", createdAt: now() };
    this.addMessage(message);
    this.setMeta(ALERTED_META_PREFIX + conversationId, message.createdAt);
    return message;
  }

  // Alert history

  addAlert(a: { title: string; body: string; botId?: string; destination: PushDestination }, createdAt = now()): Alert {
    const alert: Alert = { id: newId(), title: a.title, body: a.body, ...(a.botId ? { botId: a.botId } : {}), destination: a.destination, createdAt };
    this.db.transaction(() => {
      this.db
        .query("INSERT INTO alerts (id, bot_id, title, body, destination, created_at) VALUES (?, ?, ?, ?, ?, ?)")
        .run(alert.id, alert.botId ?? null, alert.title, alert.body, JSON.stringify(alert.destination), alert.createdAt);
      const oldest = new Date(Date.parse(createdAt) - ALERT_MAX_AGE_DAYS * 86_400_000).toISOString();
      this.db.query("DELETE FROM alerts WHERE created_at < ?").run(oldest);
      this.db.query("DELETE FROM alerts WHERE id NOT IN (SELECT id FROM alerts ORDER BY created_at DESC, rowid DESC LIMIT ?)").run(ALERT_KEEP);
    })();
    return alert;
  }

  alerts(limit = 200): Alert[] {
    const rows = this.db.query("SELECT * FROM alerts ORDER BY created_at DESC, rowid DESC LIMIT ?").all(limit) as Row[];
    return rows.map((r) => ({
      id: r.id,
      title: r.title,
      body: r.body,
      ...(r.bot_id ? { botId: r.bot_id } : {}),
      destination: JSON.parse(r.destination) as PushDestination,
      createdAt: r.created_at,
      ...(r.read_at ? { readAt: r.read_at } : {}),
    }));
  }

  /** Without `ids`, every unread alert. */
  markAlertsRead(ids?: string[], at = now()) {
    if (!ids) {
      this.db.query("UPDATE alerts SET read_at = ? WHERE read_at IS NULL").run(at);
      return;
    }
    const mark = this.db.query("UPDATE alerts SET read_at = ? WHERE id = ? AND read_at IS NULL");
    this.db.transaction(() => {
      for (const id of ids) mark.run(at, id);
    })();
  }

  deleteAlert(id: string): boolean {
    return this.db.query("DELETE FROM alerts WHERE id = ?").run(id).changes > 0;
  }

  /** `readOnly`: only the alerts already read, so the unread ones stay. */
  deleteAlerts(readOnly = false) {
    this.db.query(readOnly ? "DELETE FROM alerts WHERE read_at IS NOT NULL" : "DELETE FROM alerts").run();
  }

  // Devices & pairing

  addPairCode(codeHash: string, expiresAt: number) {
    this.db.transaction(() => {
      this.db.query("DELETE FROM pair_codes").run();
      this.db.query("INSERT INTO pair_codes (code_hash, expires_at) VALUES (?, ?)").run(codeHash, expiresAt);
    })();
  }

  consumePairCode(codeHash: string): boolean {
    this.db.query("DELETE FROM pair_codes WHERE expires_at < ?").run(Date.now());
    return this.db.query("DELETE FROM pair_codes WHERE code_hash = ?").run(codeHash).changes > 0;
  }

  addDevice(name: string, tokenHash: string): Device {
    const id = newId();
    this.db.query("INSERT INTO devices (id, name, token_hash, created_at) VALUES (?, ?, ?, ?)").run(id, name, tokenHash, now());
    return { id, name };
  }

  deviceByTokenHash(tokenHash: string): Device | undefined {
    const r = this.db.query("SELECT * FROM devices WHERE token_hash = ?").get(tokenHash) as Row | null;
    return r ? toDevice(r) : undefined;
  }

  devices(): Device[] {
    return (this.db.query("SELECT * FROM devices").all() as Row[]).map(toDevice);
  }

  setApnsToken(deviceId: string, token: string | null, env: string | null) {
    // A re-paired phone keeps its APNs token: clear it from the old row so pushes are not doubled.
    if (token) this.db.query("UPDATE devices SET apns_token = NULL, apns_env = NULL WHERE apns_token = ? AND id <> ?").run(token, deviceId);
    this.db.query("UPDATE devices SET apns_token = ?, apns_env = ? WHERE id = ?").run(token, env, deviceId);
  }

  touchDevice(deviceId: string) {
    this.db.query("UPDATE devices SET last_seen_at = ? WHERE id = ?").run(now(), deviceId);
  }

  // Bots

  botCount(): number {
    return (this.db.query("SELECT COUNT(*) AS n FROM bots").get() as Row).n;
  }

  /** The slug names the bot's folders and never changes, even when the bot is renamed. */
  createBot(draft: BotConfig | undefined, name: string): string {
    const id = newId();
    const t = now();
    const exists = this.db.query("SELECT 1 FROM bots WHERE slug = ?");
    const slug = uniqueSlug(name, (s) => exists.get(s) != null);
    this.db
      .query("INSERT INTO bots (id, slug, draft, created_at, updated_at) VALUES (?, ?, ?, ?, ?)")
      .run(id, slug, draft ? JSON.stringify(draft) : null, t, t);
    return id;
  }

  botSlug(botId: string): string | undefined {
    return opt((this.db.query("SELECT slug FROM bots WHERE id = ?").get(botId) as Row | null)?.slug);
  }

  botSlugs(): { id: string; slug: string }[] {
    return this.db.query("SELECT id, slug FROM bots").all() as { id: string; slug: string }[];
  }

  setDraft(botId: string, draft: BotConfig | undefined) {
    this.db.query("UPDATE bots SET draft = ?, updated_at = ? WHERE id = ?").run(draft ? JSON.stringify(draft) : null, now(), botId);
  }

  publish(botId: string, config: BotConfig, note: string | undefined, clearDraft: boolean): number {
    return this.db.transaction(() => {
      const last = (this.db.query("SELECT MAX(version) AS v FROM bot_versions WHERE bot_id = ?").get(botId) as Row).v ?? 0;
      const version = last + 1;
      this.db
        .query("INSERT INTO bot_versions (bot_id, version, config, note, published_at) VALUES (?, ?, ?, ?, ?)")
        .run(botId, version, JSON.stringify(config), note ?? null, now());
      this.db.query(`UPDATE bots SET updated_at = ?${clearDraft ? ", draft = NULL" : ""} WHERE id = ?`).run(now(), botId);
      return version;
    })();
  }

  versions(botId: string): BotVersion[] {
    return (this.db.query("SELECT * FROM bot_versions WHERE bot_id = ? ORDER BY version DESC").all(botId) as Row[]).map(toVersion);
  }

  version(botId: string, version: number): BotVersion | undefined {
    const r = this.db.query("SELECT * FROM bot_versions WHERE bot_id = ? AND version = ?").get(botId, version) as Row | null;
    return r ? toVersion(r) : undefined;
  }

  deleteBot(botId: string): boolean {
    return this.db.query("DELETE FROM bots WHERE id = ?").run(botId).changes > 0;
  }

  bot(botId: string): Bot | undefined {
    return this.queryBots("WHERE b.id = ?", botId)[0];
  }

  bots(): Bot[] {
    return this.queryBots("");
  }

  private queryBots(where: string, ...args: string[]): Bot[] {
    // The last message is found per conversation through messages_conversation instead of sorting every message of the bot.
    // A scheduled task's prompt is skipped: the bot list would show the instructions instead of an answer while it runs.
    const rows = this.db
      .query(
        `SELECT b.*, v.version, v.config, v.note, v.published_at, lm.created_at AS last_at, lm.text AS last_text
         FROM bots b
         LEFT JOIN bot_versions v ON v.bot_id = b.id AND v.version = (SELECT MAX(version) FROM bot_versions WHERE bot_id = b.id)
         LEFT JOIN messages lm ON lm.rowid = (SELECT max((SELECT max(m.rowid) FROM messages m WHERE m.conversation_id = c.id AND m.task IS NULL)) FROM conversations c WHERE c.bot_id = b.id)
         ${where}
         ORDER BY COALESCE(last_at, b.updated_at) DESC`,
      )
      .all(...args) as Row[];
    return rows.map((r) => ({
      id: r.id,
      slug: r.slug,
      published: r.version != null ? toVersion(r) : undefined,
      draft: parse<BotConfig>(r.draft),
      createdAt: r.created_at,
      updatedAt: r.updated_at,
      lastMessageAt: opt(r.last_at),
      lastMessagePreview: r.last_text != null ? preview(r.last_text) : undefined,
    }));
  }

  // Conversations

  createConversation(botId: string, useDraft: boolean, title: string): StoredConversation {
    const id = newId();
    const t = now();
    this.db
      .query("INSERT INTO conversations (id, bot_id, title, use_draft, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)")
      .run(id, botId, title, useDraft ? 1 : 0, t, t);
    return this.conversation(id)!;
  }

  conversation(id: string): StoredConversation | undefined {
    const r = this.db.query("SELECT * FROM conversations WHERE id = ?").get(id) as Row | null;
    return r ? toConversation(r) : undefined;
  }

  /**
   * Conversations of scheduled tasks that run in the background (no notification), or left empty by a run that
   * found nothing to say: only their runs show them.
   */
  backgroundConversationIds(): Set<string> {
    // A conversation that alerted the user stays listed: the alert sends them looking for it.
    const rows = this.db
      .query(
        `SELECT conversation_id AS id FROM schedules s WHERE conversation = 'dedicated' AND conversation_id IS NOT NULL
           AND (notify = 0 OR NOT EXISTS (SELECT 1 FROM messages m WHERE m.conversation_id = s.conversation_id))
           AND NOT EXISTS (SELECT 1 FROM meta WHERE key = '${ALERTED_META_PREFIX}' || s.conversation_id)`,
      )
      .all() as { id: string }[];
    return new Set(rows.map((r) => r.id));
  }

  conversations(botId?: string): StoredConversation[] {
    const rows = botId
      ? this.db.query("SELECT * FROM conversations WHERE bot_id = ? ORDER BY updated_at DESC, rowid DESC").all(botId)
      : this.db.query("SELECT * FROM conversations ORDER BY updated_at DESC, rowid DESC").all();
    return (rows as Row[]).map(toConversation);
  }

  /**
   * Conversations whose title holds every word of the query, most recent first, then those where a message does, best
   * match first, each with that message cut around the words found.
   */
  searchConversations(query: string, opts: { botId?: string; limit?: number } = {}): StoredSearchHit[] {
    const terms = searchTerms(query);
    if (!terms.length) return [];
    const limit = Math.max(1, Math.min(opts.limit ?? 30, 100));
    const hits = new Map<string, StoredSearchHit>();
    for (const c of this.conversations(opts.botId)) {
      const title = foldText(c.title);
      if (terms.every((t) => title.includes(t))) hits.set(c.id, { conversation: c });
      if (hits.size >= limit) return [...hits.values()];
    }
    const match = terms.map((t) => `"${t}"*`).join(" ");
    const rows = this.db
      .query(
        `SELECT m.id AS message_id, m.role, snippet(message_search, 0, '', '', '…', 18) AS snippet, c.*
         FROM message_search JOIN messages m ON m.rowid = message_search.rowid JOIN conversations c ON c.id = m.conversation_id
         WHERE message_search MATCH ? ${opts.botId ? "AND c.bot_id = ?" : ""}
         ORDER BY bm25(message_search) LIMIT ${SEARCH_SCAN}`,
      )
      .all(...(opts.botId ? [match, opts.botId] : [match])) as Row[];
    for (const r of rows) {
      if (hits.size >= limit) break;
      const hit = hits.get(r.id);
      if (hit) {
        if (!hit.snippet) Object.assign(hit, { messageId: r.message_id, role: r.role, snippet: r.snippet });
        continue;
      }
      hits.set(r.id, { conversation: toConversation(r), messageId: r.message_id, role: r.role, snippet: r.snippet });
    }
    return [...hits.values()];
  }

  /** `undefined` keeps a column, `null` clears it. */
  updateConversation(
    id: string,
    fields: { [K in "title" | "agent" | "model" | "effort" | "agentId" | "agentSessionId"]?: StoredConversation[K] | null },
  ) {
    const cols: Record<string, string> = {
      title: "title",
      agent: "agent",
      model: "model",
      effort: "effort",
      agentId: "agent_id",
      agentSessionId: "agent_session_id",
    };
    const sets: string[] = ["updated_at = ?"];
    const vals: (string | null)[] = [now()];
    for (const [k, v] of Object.entries(fields)) {
      if (v === undefined) continue;
      sets.push(`${cols[k]} = ?`);
      vals.push(v);
    }
    this.db.query(`UPDATE conversations SET ${sets.join(", ")} WHERE id = ?`).run(...vals, id);
  }

  setContext(id: string, context: ContextUsage) {
    this.db.query("UPDATE conversations SET context = ? WHERE id = ?").run(JSON.stringify(context), id);
  }

  /** Forgets the agent session so the next turn starts a fresh one instead of resuming. */
  clearAgentSession(id: string, agent?: string) {
    this.db.query("UPDATE conversations SET agent_id = NULL, agent_session_id = NULL WHERE id = ?").run(id);
    if (agent) this.setNativeSession(id, agent, undefined);
  }

  /** `undefined` forgets that agent's session. */
  setNativeSession(id: string, agent: string, session: NativeSession | undefined) {
    this.db.transaction(() => {
      const r = this.db.query("SELECT agent_sessions FROM conversations WHERE id = ?").get(id) as Row | null;
      if (!r) return;
      const sessions = parse<Record<string, NativeSession>>(r.agent_sessions) ?? {};
      if (session) sessions[agent] = session;
      else delete sessions[agent];
      this.db.query("UPDATE conversations SET agent_sessions = ? WHERE id = ?").run(JSON.stringify(sessions), id);
    })();
  }

  deleteConversation(id: string): boolean {
    return this.db.query("DELETE FROM conversations WHERE id = ?").run(id).changes > 0;
  }

  // Messages

  messageCount(conversationId: string): number {
    return (this.db.query("SELECT COUNT(*) AS n FROM messages WHERE conversation_id = ?").get(conversationId) as Row).n;
  }

  addMessage(m: Message) {
    this.db
      .query(
        `INSERT INTO messages (id, conversation_id, role, text, thoughts, attachments, steps, subagents, duration_ms, stop_reason, agent, model, task, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        m.id,
        m.conversationId,
        m.role,
        m.text,
        m.thoughts ?? null,
        m.attachments?.length ? JSON.stringify(m.attachments) : null,
        m.steps?.length ? JSON.stringify(m.steps) : null,
        m.subagents?.length ? JSON.stringify(m.subagents) : null,
        m.durationMs ?? null,
        m.stopReason ?? null,
        m.agent ?? null,
        m.model ?? null,
        m.task ? JSON.stringify(m.task) : null,
        m.createdAt,
      );
    this.db.query("UPDATE conversations SET updated_at = ? WHERE id = ?").run(now(), m.conversationId);
  }

  /** Removes exactly these messages: a message the user sent meanwhile, and its answer, stay. */
  deleteMessages(conversationId: string, ids: string[]) {
    const del = this.db.query("DELETE FROM messages WHERE conversation_id = ? AND id = ?");
    this.db.transaction(() => {
      for (const id of ids) del.run(conversationId, id);
    })();
  }

  messages(conversationId: string): Message[] {
    const rows = this.db.query("SELECT * FROM messages WHERE conversation_id = ? ORDER BY rowid").all(conversationId) as Row[];
    return rows.map((r) => ({
      id: r.id,
      conversationId: r.conversation_id,
      role: r.role,
      text: r.text,
      thoughts: opt(r.thoughts),
      attachments: parse<Attachment[]>(r.attachments),
      steps: parse<ToolStep[]>(r.steps),
      subagents: parse<SubagentInfo[]>(r.subagents),
      durationMs: opt(r.duration_ms),
      stopReason: opt(r.stop_reason),
      agent: opt(r.agent),
      model: opt(r.model),
      task: parse<MessageTask>(r.task),
      createdAt: r.created_at,
    }));
  }

  // Scheduled tasks

  createTask(t: Omit<ScheduledTask, "id" | "createdAt" | "updatedAt" | "action"> & { action?: TaskAction }): ScheduledTask {
    const id = newId();
    const at = now();
    this.db
      .query(
        `INSERT INTO schedules (id, bot_id, title, action, prompt, schedule, enabled, conversation, conversation_id, notify, created_by,
           next_run_at, last_run_at, last_status, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        id,
        t.botId,
        t.title,
        !t.action || t.action.type === "prompt" ? null : JSON.stringify(t.action),
        t.prompt,
        JSON.stringify(t.schedule),
        t.enabled ? 1 : 0,
        t.conversation,
        t.conversationId ?? null,
        t.notify ? 1 : 0,
        t.createdBy,
        t.nextRunAt ?? null,
        t.lastRunAt ?? null,
        t.lastStatus ?? null,
        at,
        at,
      );
    return this.task(id)!;
  }

  task(id: string): ScheduledTask | undefined {
    const r = this.db.query("SELECT * FROM schedules WHERE id = ?").get(id) as Row | null;
    return r ? toTask(r) : undefined;
  }

  tasks(botId?: string): ScheduledTask[] {
    const rows = botId
      ? this.db.query("SELECT * FROM schedules WHERE bot_id = ? ORDER BY created_at, rowid").all(botId)
      : this.db.query("SELECT * FROM schedules ORDER BY created_at, rowid").all();
    return (rows as Row[]).map(toTask);
  }

  /** `null` clears an optional column. */
  updateTask(
    id: string,
    fields: {
      [K in "botId" | "title" | "action" | "prompt" | "schedule" | "enabled" | "conversation" | "conversationId" | "notify" | "nextRunAt" | "lastRunAt" | "lastStatus"]?:
        | ScheduledTask[K]
        | null;
    },
  ): ScheduledTask | undefined {
    const cols: Record<string, string> = {
      botId: "bot_id",
      title: "title",
      action: "action",
      prompt: "prompt",
      schedule: "schedule",
      enabled: "enabled",
      conversation: "conversation",
      conversationId: "conversation_id",
      notify: "notify",
      nextRunAt: "next_run_at",
      lastRunAt: "last_run_at",
      lastStatus: "last_status",
    };
    const sets: string[] = ["updated_at = ?"];
    const vals: (string | number | null)[] = [now()];
    for (const [k, v] of Object.entries(fields)) {
      if (v === undefined || !cols[k]) continue;
      sets.push(`${cols[k]} = ?`);
      if (k === "action") {
        vals.push((v as TaskAction).type === "prompt" ? null : JSON.stringify(v));
        continue;
      }
      vals.push(v === null ? null : typeof v === "boolean" ? (v ? 1 : 0) : typeof v === "object" ? JSON.stringify(v) : (v as string));
    }
    this.db.query(`UPDATE schedules SET ${sets.join(", ")} WHERE id = ?`).run(...vals, id);
    return this.task(id);
  }

  /** Whether a failure of this command task was already pushed and its recovery not yet. */
  taskAlertOpen(id: string): boolean {
    return !!(this.db.query("SELECT alert_open FROM schedules WHERE id = ?").get(id) as Row | null)?.alert_open;
  }

  setTaskAlertOpen(id: string, open: boolean) {
    this.db.query("UPDATE schedules SET alert_open = ? WHERE id = ?").run(open ? 1 : 0, id);
  }

  deleteTask(id: string): boolean {
    return this.db.query("DELETE FROM schedules WHERE id = ?").run(id).changes > 0;
  }

  addTaskRun(run: TaskRun, keep = 50) {
    this.db
      .query("INSERT INTO task_runs (id, task_id, conversation_id, started_at, ended_at, status, preview, error) VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
      .run(run.id, run.taskId, run.conversationId, run.startedAt, run.endedAt ?? null, run.status, run.preview ?? null, run.error ?? null);
    this.db
      .query(
        `DELETE FROM task_runs WHERE task_id = ? AND id NOT IN
           (SELECT id FROM task_runs WHERE task_id = ? ORDER BY started_at DESC, rowid DESC LIMIT ?)`,
      )
      .run(run.taskId, run.taskId, keep);
  }

  finishTaskRun(id: string, f: Pick<TaskRun, "status" | "endedAt" | "preview" | "error" | "exitCode" | "output" | "durationMs">) {
    this.db
      .query("UPDATE task_runs SET status = ?, ended_at = ?, preview = ?, error = ?, exit_code = ?, output = ?, duration_ms = ? WHERE id = ?")
      .run(f.status, f.endedAt ?? null, f.preview ?? null, f.error ?? null, f.exitCode ?? null, f.output ?? null, f.durationMs ?? null, id);
  }

  taskRun(id: string): TaskRun | undefined {
    const r = this.db.query("SELECT * FROM task_runs WHERE id = ?").get(id) as Row | null;
    return r ? toTaskRun(r) : undefined;
  }

  taskRuns(taskId: string, limit = 50): TaskRun[] {
    return (this.db.query("SELECT * FROM task_runs WHERE task_id = ? ORDER BY started_at DESC, rowid DESC LIMIT ?").all(taskId, limit) as Row[]).map(
      toTaskRun,
    );
  }

  /** A scheduled task is running in this conversation right now. */
  hasRunningTaskRun(conversationId: string): boolean {
    return !!this.db.query("SELECT 1 FROM task_runs WHERE conversation_id = ? AND status = 'running' LIMIT 1").get(conversationId);
  }

  addTurnMetric(m: TurnMetric) {
    this.db
      .query(
        `INSERT OR REPLACE INTO turn_metrics (message_id, bot_id, conversation_id, origin, started_at, first_event_ms, first_text_ms, duration_ms, tool_ms, steps, stop_reason, agent, model)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(m.messageId, m.botId, m.conversationId, m.origin, m.startedAt, m.firstEventMs ?? null, m.firstTextMs ?? null, m.durationMs, m.toolMs, m.steps, m.stopReason, m.agent, m.model ?? null);
  }

  /** Answers started at or after `since` (ISO), oldest first. */
  turnMetrics(since: string, origins: TurnOrigin[]): TurnMetric[] {
    const marks = origins.map(() => "?").join(", ");
    return (this.db.query(`SELECT * FROM turn_metrics WHERE started_at >= ? AND origin IN (${marks}) ORDER BY started_at`).all(since, ...origins) as Row[]).map(toTurnMetric);
  }

  pruneTurnMetrics(before: string) {
    this.db.query("DELETE FROM turn_metrics WHERE started_at < ?").run(before);
  }

  /** Runs left "running" by a gateway that stopped mid-run. */
  failRunningTaskRuns(error: string) {
    const t = now();
    this.db.query("UPDATE task_runs SET status = 'error', ended_at = ?, error = ? WHERE status = 'running'").run(t, error);
    this.db.query("UPDATE schedules SET last_status = 'error' WHERE last_status = 'running'").run();
  }
}

// Card lines are rendered as rich content by the app; a preview only wants prose.
export function preview(text: string, max = 120): string {
  const prose = text
    .split("\n")
    .filter((l) => !l.trimStart().startsWith("::"))
    .join(" ")
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/[*_`#>]/g, "")
    .replace(/\s+/g, " ")
    .trim();
  return prose.length > max ? `${prose.slice(0, max - 1)}…` : prose;
}

const toDevice = (r: Row): Device => ({ id: r.id, name: r.name, apnsToken: opt(r.apns_token), apnsEnv: opt(r.apns_env) });

const toVersion = (r: Row): BotVersion => ({
  version: r.version,
  config: JSON.parse(r.config),
  note: opt(r.note),
  publishedAt: r.published_at,
});

const toConversation = (r: Row): StoredConversation => ({
  id: r.id,
  botId: r.bot_id,
  title: r.title,
  useDraft: !!r.use_draft,
  agent: opt(r.agent),
  model: opt(r.model),
  effort: opt(r.effort),
  context: parse<ContextUsage>(r.context),
  createdAt: r.created_at,
  updatedAt: r.updated_at,
  agentId: opt(r.agent_id),
  agentSessionId: opt(r.agent_session_id),
  agentSessions: parse<Record<string, NativeSession>>(r.agent_sessions),
});

const toTask = (r: Row): ScheduledTask => ({
  id: r.id,
  botId: r.bot_id,
  title: r.title,
  action: parse<TaskAction>(r.action) ?? { type: "prompt" },
  prompt: r.prompt,
  schedule: JSON.parse(r.schedule) as TaskSchedule,
  enabled: !!r.enabled,
  conversation: r.conversation === "new" ? "new" : "dedicated",
  conversationId: opt(r.conversation_id),
  notify: !!r.notify,
  createdBy: r.created_by === "bot" || r.created_by === "gateway" ? r.created_by : "user",
  nextRunAt: opt(r.next_run_at),
  lastRunAt: opt(r.last_run_at),
  lastStatus: opt(r.last_status),
  createdAt: r.created_at,
  updatedAt: r.updated_at,
});

const toTaskRun = (r: Row): TaskRun => ({
  id: r.id,
  taskId: r.task_id,
  conversationId: r.conversation_id,
  startedAt: r.started_at,
  endedAt: opt(r.ended_at),
  status: r.status,
  preview: opt(r.preview),
  error: opt(r.error),
  exitCode: opt(r.exit_code),
  output: opt(r.output),
  durationMs: opt(r.duration_ms),
});

const toTurnMetric = (r: Row): TurnMetric => ({
  messageId: r.message_id,
  botId: r.bot_id,
  conversationId: r.conversation_id,
  origin: r.origin,
  startedAt: r.started_at,
  firstEventMs: opt(r.first_event_ms),
  firstTextMs: opt(r.first_text_ms),
  durationMs: r.duration_ms,
  toolMs: r.tool_ms,
  steps: r.steps,
  stopReason: r.stop_reason,
  agent: r.agent,
  model: opt(r.model),
});
