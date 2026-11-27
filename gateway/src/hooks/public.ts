import { timingSafeEqual } from "node:crypto";
import { sha256 } from "../auth/keys";
import { HttpError } from "../bots/service";
import { OWNER } from "../profiles/registry";
import { DEFAULT_AUTHSERV_ID, mailAddress, mailDomain, parseAuthResults, recentMail, sameMailbox, senderVerified } from "./mail";
import type { IncomingMail, WakeService } from "./service";

/**
 * Per window. Each kind of caller has its own budgets: a stranger's mails never use up what the owner's mails or the
 * webhooks may start, and a leaked webhook never blocks the owner's mail.
 */
export interface WakeLimits {
  /** Turns one webhook may start. */
  perHook: number;
  /** Turns all webhooks together may start. */
  global: number;
  /** Turns the owner's verified mails to one bot may start. */
  perBotMail: number;
  /** Turns the unverified mails of one sender to one bot may start. */
  unverifiedPerSender: number;
  /** Turns all unverified mails to one bot may start. */
  unverifiedPerBot: number;
  /** Turns all unverified mails together may start. */
  unverifiedGlobal: number;
  /** Refused calls (unknown token, wrong secret) one IP may make per window before every call of it is refused. */
  failuresPerIp: number;
  windowMs: number;
}

export const DEFAULT_WAKE_LIMITS: WakeLimits = {
  perHook: 30,
  global: 300,
  perBotMail: 30,
  unverifiedPerSender: 5,
  unverifiedPerBot: 20,
  unverifiedGlobal: 60,
  failuresPerIp: 30,
  windowMs: 3_600_000,
};

export interface WakeOptions {
  /** NUO_HOOKS_HOSTS: hostnames that serve the webhook and mail routes only, outside Cloudflare Access. */
  hosts?: Set<string>;
  /** NUO_MAIL_SECRET: shared with the mail Worker; without it `POST /mail` does not exist. */
  mailSecret?: string;
  /** NUO_MAIL_DOMAIN: the domain of the bots' addresses (a subdomain routed by Cloudflare Email Routing). */
  mailDomain?: string;
  /** NUO_OWNER_EMAILS: the owner's own addresses. */
  ownerEmails?: string[];
  /** NUO_MAIL_AUTHSERV_ID: the authserv-id of the receiving server's Authentication-Results header. */
  authservId?: string;
  limits?: Partial<WakeLimits>;
  now?: () => number;
}

const list = (v: string | undefined) =>
  (v ?? "")
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);

export function wakeOptionsFromEnv(env: Record<string, string | undefined> = process.env): WakeOptions {
  return {
    hosts: new Set(list(env.NUO_HOOKS_HOSTS)),
    mailSecret: env.NUO_MAIL_SECRET || undefined,
    mailDomain: env.NUO_MAIL_DOMAIN?.trim().toLowerCase() || undefined,
    ownerEmails: list(env.NUO_OWNER_EMAILS),
    authservId: env.NUO_MAIL_AUTHSERV_ID?.trim() || undefined,
  };
}

export const MAX_HOOK_BODY = 64 * 1024;
export const MAX_MAIL_BODY = 512 * 1024;
const EVENT_HEADERS = ["x-github-event", "linear-event", "x-gitlab-event", "x-event-type"];

/** Sliding window counters, in memory: a restart forgets them, which only ever lets a few more calls through. */
export class RateLimiter {
  private hits = new Map<string, number[]>();
  constructor(
    private windowMs: number,
    private now: () => number,
  ) {}

  private recent(key: string): number[] {
    const since = this.now() - this.windowMs;
    const kept = (this.hits.get(key) ?? []).filter((t) => t > since);
    if (kept.length) this.hits.set(key, kept);
    else this.hits.delete(key);
    return kept;
  }

  full(key: string, max: number): boolean {
    return this.recent(key).length >= max;
  }

  take(key: string, max: number): boolean {
    const kept = this.recent(key);
    if (kept.length >= max) return false;
    this.hits.set(key, [...kept, this.now()]);
    return true;
  }

  /** Takes one call in every window, or in none when one of them is full. */
  takeAll(windows: [key: string, max: number][]): boolean {
    const taken: string[] = [];
    for (const [key, max] of windows) {
      if (!this.take(key, max)) {
        for (const k of taken) this.give(k);
        return false;
      }
      taken.push(key);
    }
    return true;
  }

  give(key: string) {
    const kept = this.recent(key);
    kept.pop();
    if (kept.length) this.hits.set(key, kept);
    else this.hits.delete(key);
  }
}

const json = (data: unknown, status = 200) => Response.json(data, { status });
const fail = (status: number, error: string) => json({ error }, status);
const notFound = () => fail(404, "not found");

/** The body as text, or undefined once it passes `max` bytes (the stream is read no further). */
async function readCapped(req: Request, max: number): Promise<string | undefined> {
  const length = Number(req.headers.get("content-length") ?? Number.NaN);
  if (Number.isFinite(length) && length > max) return undefined;
  if (!req.body) return "";
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > max) {
      await reader.cancel().catch(() => {});
      return undefined;
    }
    chunks.push(value);
  }
  return new TextDecoder().decode(Buffer.concat(chunks));
}

/** A webhook body as the bot reads it; undefined when it is not text, JSON or a form. */
export function hookBody(contentType: string, raw: string): string | undefined {
  const type = contentType.split(";")[0]!.trim().toLowerCase();
  if (type === "application/json" || type.endsWith("+json")) {
    try {
      return JSON.stringify(JSON.parse(raw), null, 2);
    } catch {
      throw new HttpError(400, "invalid JSON body");
    }
  }
  if (type === "application/x-www-form-urlencoded") return [...new URLSearchParams(raw)].map(([k, v]) => `${k}: ${v}`).join("\n");
  if (type === "" || type.startsWith("text/")) return raw;
  return undefined;
}

interface WakeProfile {
  id: string;
  wake: WakeService;
}

/**
 * The hooks hostname (NUO_HOOKS_HOSTS): public, outside Cloudflare Access, it serves `POST /hooks/<token>` and
 * `POST /mail` and nothing else. No route of the app is ever reached from it.
 */
export class WakeSite {
  readonly hosts: Set<string>;
  private limits: WakeLimits;
  private limiter: RateLimiter;
  private secretHash?: Buffer;
  private now: () => number;

  constructor(
    private o: WakeOptions,
    private profiles: () => WakeProfile[],
  ) {
    this.hosts = o.hosts ?? new Set();
    this.limits = { ...DEFAULT_WAKE_LIMITS, ...o.limits };
    this.now = o.now ?? Date.now;
    this.limiter = new RateLimiter(this.limits.windowMs, this.now);
    if (o.mailSecret) this.secretHash = Buffer.from(sha256(o.mailSecret), "hex");
  }

  async handle(req: Request, path: string, ip: string): Promise<Response> {
    try {
      if (req.method !== "POST") return notFound();
      const hook = path.match(/^\/hooks\/([^/]+)$/);
      if (hook) return await this.hook(req, decodeURIComponent(hook[1]!), ip);
      if (path === "/mail" && this.secretHash) return await this.mail(req, ip);
      return notFound();
    } catch (e) {
      if (e instanceof HttpError) return fail(e.status, e.message);
      console.error(`[wake] ${req.method} ${path}:`, e);
      return fail(500, "internal error");
    }
  }

  private refused(ip: string, res: Response): Response {
    this.limiter.take(`fail:${ip}`, Number.MAX_SAFE_INTEGER);
    return res;
  }

  private blocked(ip: string) {
    return this.limiter.full(`fail:${ip}`, this.limits.failuresPerIp);
  }

  private async hook(req: Request, token: string, ip: string): Promise<Response> {
    if (this.blocked(ip)) return fail(429, "too many requests");
    let found: { p: WakeProfile; hook: NonNullable<ReturnType<WakeService["hookByToken"]>> } | undefined;
    for (const p of this.profiles()) {
      const hook = p.wake.hookByToken(token);
      if (hook) {
        found = { p, hook };
        break;
      }
    }
    if (!found) return this.refused(ip, notFound());
    const contentType = req.headers.get("content-type") ?? "";
    const raw = await readCapped(req, MAX_HOOK_BODY);
    if (raw === undefined) return fail(413, `body too large (${MAX_HOOK_BODY / 1024} KB at most)`);
    const body = hookBody(contentType, raw);
    if (body === undefined) return fail(415, "send JSON, text or a form");
    const { p, hook } = found;
    if (
      !this.limiter.takeAll([
        [`hook:${p.id}:${hook.id}`, this.limits.perHook],
        ["hooks", this.limits.global],
      ])
    ) {
      return fail(429, "too many calls");
    }
    const event = EVENT_HEADERS.map((h) => req.headers.get(h)).find(Boolean)?.slice(0, 100);
    await p.wake.runHook(hook, { body, contentType: contentType.split(";")[0]!.trim(), event });
    p.wake.audit("hook_call", true, { ip, detail: `${hook.name}${event ? ` · ${event}` : ""}` });
    return json({ accepted: true }, 202);
  }

  private secretMatches(req: Request): boolean {
    const given = (req.headers.get("authorization") ?? "").match(/^Bearer\s+(.+)$/i)?.[1]?.trim();
    if (!given || !this.secretHash) return false;
    return timingSafeEqual(Buffer.from(sha256(given), "hex"), this.secretHash);
  }

  /** The bot a recipient names: `<alias or slug>@<domain>` for the owner, `<…>.<profile>@<domain>` for another profile. */
  private recipient(to: string): { p: WakeProfile; bot: NonNullable<ReturnType<WakeService["botForMail"]>> } | undefined {
    if (!this.o.mailDomain || mailDomain(to) !== this.o.mailDomain) return undefined;
    const local = to.slice(0, to.lastIndexOf("@")).split("+")[0]!;
    const profiles = this.profiles();
    const dot = local.lastIndexOf(".");
    const named = dot > 0 ? profiles.find((p) => p.id !== OWNER && p.id === local.slice(dot + 1)) : undefined;
    const p = named ?? profiles.find((x) => x.id === OWNER);
    const bot = p?.wake.botForMail(named ? local.slice(0, dot) : local);
    return p && bot ? { p, bot } : undefined;
  }

  private async mail(req: Request, ip: string): Promise<Response> {
    if (this.blocked(ip)) return fail(429, "too many requests");
    if (!this.secretMatches(req)) return this.refused(ip, fail(401, "unauthorized"));
    const raw = await readCapped(req, MAX_MAIL_BODY);
    if (raw === undefined) return fail(413, "mail too large");
    let b: Record<string, unknown>;
    try {
      const parsed = JSON.parse(raw) as unknown;
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error();
      b = parsed as Record<string, unknown>;
    } catch {
      return fail(400, "invalid JSON body");
    }
    const to = mailAddress(b.to);
    const from = mailAddress(b.from);
    if (!to || !from) return fail(400, "to and from must be mail addresses");
    const str = (v: unknown) => (typeof v === "string" ? v : "");
    const target = this.recipient(to);
    if (!target) return notFound();
    const { p, bot } = target;
    const messageId = str(b.messageId).trim().slice(0, 500);
    const seenKey = messageId ? `${bot.id}:${messageId}` : undefined;
    if (seenKey && !p.wake.store.markMailSeen(seenKey)) return json({ duplicate: true });
    const listed = [b.toHeader, b.cc].flatMap((v) => (Array.isArray(v) ? v : [])).map(mailAddress);
    // The From header alone proves nothing: the receiving server must also have verified it (DMARC, DKIM or SPF).
    // A genuine signed mail of the owner resent by someone else stays signed: it must also be addressed to this bot
    // (To or Cc) and recent.
    const doubt = !p.wake.ownAddress(from)
      ? "expéditeur inconnu"
      : !senderVerified(from, parseAuthResults(str(b.authResults) || undefined, this.o.authservId ?? DEFAULT_AUTHSERV_ID))
        ? str(b.authResults)
          ? "authentification non concluante"
          : "aucun verdict d'authentification"
        : !listed.some((a) => !!a && sameMailbox(a, to))
          ? "bot absent de To et Cc"
          : !recentMail(str(b.date) || undefined, this.now())
            ? "date absente ou trop ancienne"
            : undefined;
    const trusted = !doubt;
    const trust = trusted ? "vérifié" : `non vérifié (${doubt})`;
    const windows: [string, number][] = trusted
      ? [[`mail:${p.id}:${bot.id}`, this.limits.perBotMail]]
      : [
          [`stranger:${p.id}:${bot.id}:${from}`, this.limits.unverifiedPerSender],
          [`strangers:${p.id}:${bot.id}`, this.limits.unverifiedPerBot],
          ["strangers", this.limits.unverifiedGlobal],
        ];
    if (!this.limiter.takeAll(windows)) {
      if (seenKey) p.wake.store.forgetMail(seenKey);
      return fail(429, "too many mails");
    }
    const attachments = (Array.isArray(b.attachments) ? b.attachments : [])
      .map((a) => (typeof a === "string" ? a : str((a as { filename?: unknown } | null)?.filename)))
      .map((n) => n.replace(/[\r\n]+/g, " ").trim().slice(0, 200))
      .filter(Boolean)
      .slice(0, 50);
    const mail: IncomingMail = {
      to,
      from,
      fromName: (str(b.fromName) || str(b.from).replace(/<[^<>]*>\s*$/, "")).replace(/[\r\n"]+/g, " ").trim().slice(0, 200) || undefined,
      subject: str(b.subject).replace(/[\r\n]+/g, " ").trim(),
      text: str(b.text),
      date: str(b.date).trim().slice(0, 100) || undefined,
      attachments,
    };
    try {
      await p.wake.runMail(bot, mail, trusted);
    } catch (e) {
      if (seenKey) p.wake.store.forgetMail(seenKey);
      p.wake.audit("mail_wake", false, { ip, detail: `${bot.slug} · ${from} · ${trust} · ${(e as Error)?.message ?? e}` });
      throw e;
    }
    p.wake.audit("mail_wake", true, { ip, detail: `${bot.slug} · ${from} · ${trust}` });
    return json({ accepted: true, trusted }, 202);
  }
}
