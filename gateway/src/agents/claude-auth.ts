import { DEFAULT_UI_LANGUAGE, t, type UiLanguage } from "../i18n/language";
import type { Attachment } from "../protocol";
import type { AgentSession, PermissionAsk, PromptResult, RunEvent, UnpromptedWork } from "./types";

/**
 * Claude Code reports an OAuth failure as the assistant's reply (a synthetic API error message), so without
 * this the raw CLI error becomes the bot's answer.
 */
export type ClaudeAuthFailure = "refresh_contended" | "login_required";

const REFRESH_CONTENDED = "Failed to refresh OAuth token: another Claude Code process";
const LOGIN_REQUIRED = ["Failed to authenticate: OAuth session expired", "OAuth refresh token is no longer valid", "Please run /login"];
const PREFIXES = [REFRESH_CONTENDED, ...LOGIN_REQUIRED];

export function claudeAuthFailure(text: string): ClaudeAuthFailure | undefined {
  const t = text.trim();
  if (t.startsWith(REFRESH_CONTENDED)) return "refresh_contended";
  if (LOGIN_REQUIRED.some((p) => t.startsWith(p)) || /^Failed to authenticate\b.*\/login/s.test(t)) return "login_required";
  return undefined;
}

/** Whether the reply so far may still turn out to be one of these failures. */
function mayBeAuthFailure(text: string): boolean {
  const t = text.trimStart();
  return PREFIXES.some((p) => p.startsWith(t) || t.startsWith(p)) || /^Failed to authenticate\b/.test(t);
}

export function claudeAuthMessage(kind: ClaudeAuthFailure, profileHome?: string, lang: UiLanguage = DEFAULT_UI_LANGUAGE): string {
  const where = profileHome ? t("agents.onServerProfile", { home: profileHome }, lang) : t("agents.onServer", {}, lang);
  return t(kind === "login_required" ? "agents.claudeLoginRequired" : "agents.claudeRefreshContended", { where }, lang);
}

export interface ClaudeAuthOptions {
  /**
   * Waits before replaying a prompt refused because the refresh lock was held. Claude Code already retried for a
   * few seconds; a lock left by a process killed mid-refresh only goes stale after 60 s.
   */
  retryDelaysMs: number[];
  profileHome?: string;
  /** The language of the message that replaces the CLI's error. */
  lang?: UiLanguage;
}

export const DEFAULT_RETRY_DELAYS_MS = [20_000, 45_000];

export class ClaudeAuthSession implements AgentSession {
  private cancelled = false;
  private wake?: () => void;

  constructor(
    private readonly inner: AgentSession,
    private readonly opts: ClaudeAuthOptions = { retryDelaysMs: DEFAULT_RETRY_DELAYS_MS },
  ) {}

  get agentSessionId(): string {
    return this.inner.agentSessionId;
  }

  get commands(): readonly string[] | undefined {
    return this.inner.commands;
  }

  get onUnprompted(): ((work: UnpromptedWork) => void) | undefined {
    return this.inner.onUnprompted;
  }

  set onUnprompted(fn: ((work: UnpromptedWork) => void) | undefined) {
    this.inner.onUnprompted = fn;
  }

  get awaitsBackground(): boolean {
    return this.inner.awaitsBackground ?? false;
  }

  async prompt(
    text: string,
    attachments: Attachment[],
    onEvent: (e: RunEvent) => void,
    askPermission: (ask: PermissionAsk) => Promise<string>,
  ): Promise<PromptResult> {
    this.cancelled = false;
    for (let attempt = 0; ; attempt++) {
      let held = "";
      let holding = true;
      const release = () => {
        if (!holding) return;
        holding = false;
        if (held) onEvent({ type: "text", text: held });
      };
      const result = await this.inner.prompt(
        text,
        attachments,
        (e) => {
          if (holding && e.type === "text") {
            held += e.text;
            if (!mayBeAuthFailure(held)) release();
            return;
          }
          if (e.type !== "usage") release();
          onEvent(e);
        },
        askPermission,
      );
      const failure = holding ? claudeAuthFailure(held) : undefined;
      if (!failure || this.cancelled || result.stopReason === "cancelled") {
        release();
        return result;
      }
      const delay = this.opts.retryDelaysMs[attempt];
      if (failure === "refresh_contended" && delay !== undefined) {
        console.warn(`[claude] OAuth refresh lock busy, retrying the prompt in ${Math.round(delay / 1000)}s`);
        await this.sleep(delay);
        if (this.cancelled) return { stopReason: "cancelled" };
        continue;
      }
      console.warn(`[claude] OAuth failure (${failure}): ${held.trim()}`);
      const message = claudeAuthMessage(failure, this.opts.profileHome, this.opts.lang);
      onEvent({ type: "text", text: message });
      return { stopReason: "error", error: message };
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      const timer = setTimeout(done, ms);
      function done() {
        clearTimeout(timer);
        resolve();
      }
      this.wake = done;
    }).finally(() => (this.wake = undefined));
  }

  async cancel(): Promise<void> {
    this.cancelled = true;
    this.wake?.();
    await this.inner.cancel();
  }

  async steer(text: string, attachments: Attachment[]): Promise<boolean> {
    return (await this.inner.steer?.(text, attachments)) ?? false;
  }

  setModel(model: string, effort?: string): Promise<void> {
    return this.inner.setModel(model, effort);
  }

  async close(): Promise<void> {
    this.cancelled = true;
    this.wake?.();
    await this.inner.close();
  }
}
