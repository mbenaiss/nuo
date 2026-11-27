import type { Address, Email } from "postal-mime";

/** What `POST /mail` on the gateway's hooks host takes (docs/protocol.md, « Réveils »). */
export interface MailPayload {
  to: string;
  from: string;
  fromName?: string;
  subject: string;
  text: string;
  date?: string;
  messageId?: string;
  /** The Authentication-Results header Email Routing stamped under its own Received line (`stampedVerdict`). */
  authResults?: string;
  /** Addresses of the To and Cc headers: the owner's mail counts only when it names the bot there. */
  toHeader: string[];
  cc: string[];
  attachments: { filename: string; mimeType: string; size: number }[];
}

/** The gateway clips the text it shows the bot to 32 000 characters; nothing more needs to travel. */
export const MAX_TEXT = 32_000;

const htmlToText = (html: string) =>
  html
    .replace(/<(script|style)[^>]*>[\s\S]*?<\/\1>/gi, "")
    .replace(/<br\s*\/?>|<\/(p|div|li|tr|h[1-6])>/gi, "\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/g, " ")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, "&")
    .replace(/\n{3,}/g, "\n\n")
    .trim();

const sizeOf = (content: unknown) => (content instanceof ArrayBuffer ? content.byteLength : typeof content === "string" ? content.length : ArrayBuffer.isView(content) ? content.byteLength : 0);

const addresses = (list: Address[] | undefined): string[] =>
  (list ?? []).flatMap((a) => ("group" in a && a.group ? a.group : [a])).flatMap((m) => (m.address ? [m.address] : []));

/** What Email Routing writes right under its own Received line, before anything the mail brought with it. */
const STAMPS = new Set(["arc-seal", "arc-message-signature", "arc-authentication-results", "received-spf", "authentication-results"]);

/**
 * Email Routing's own verdict. Every server prepends its headers, so the mail starts with Cloudflare's Received line,
 * then its ARC, Received-SPF and Authentication-Results stamps, closed by its X-CF-* headers, and only then the
 * previous hop's Received line or, sent straight to Cloudflare, the sender's own headers. A verdict counts only inside
 * that closed block: one the mail brought with it comes after the X-CF-* close or in a block that never has one.
 */
export function stampedVerdict(headers: { key: string; value: string }[]): string | undefined {
  if (headers[0]?.key !== "received") return undefined;
  let verdict: string | undefined;
  for (const h of headers.slice(1)) {
    if (h.key.startsWith("x-cf-")) return verdict;
    if (!STAMPS.has(h.key)) return undefined;
    if (h.key === "authentication-results") verdict ??= h.value;
  }
  return undefined;
}

/** `envelopeTo` is the address Email Routing delivered to: the bot's, whatever the To header says. */
export function buildPayload(envelopeTo: string, email: Email): MailPayload {
  const from = email.from && "address" in email.from && email.from.address ? email.from : undefined;
  const text = (email.text?.trim() ? email.text : email.html ? htmlToText(email.html) : "").slice(0, MAX_TEXT);
  const authResults = stampedVerdict(email.headers);
  return {
    to: envelopeTo,
    from: from?.address ?? "",
    ...(from?.name ? { fromName: from.name } : {}),
    subject: email.subject ?? "",
    text,
    ...(email.date ? { date: email.date } : {}),
    ...(email.messageId ? { messageId: email.messageId } : {}),
    ...(authResults ? { authResults } : {}),
    toHeader: addresses(email.to),
    cc: addresses(email.cc),
    attachments: email.attachments.map((a) => ({ filename: a.filename ?? "(sans nom)", mimeType: a.mimeType, size: sizeOf(a.content) })),
  };
}
