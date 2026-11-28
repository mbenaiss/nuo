import { isEmail } from "../calendar/validate";

/** Cloudflare Email Routing stamps its own verdict under this name (NUO_MAIL_AUTHSERV_ID overrides it). */
export const DEFAULT_AUTHSERV_ID = "mx.cloudflare.net";

/** The bare address of `Julie Martin <julie.martin@lumen.example>`, lowercased; undefined when it is not one. */
export function mailAddress(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const inside = raw.match(/<([^<>]*)>\s*$/)?.[1] ?? raw;
  const address = inside.trim().replace(/^mailto:/i, "").toLowerCase();
  return isEmail(address) ? address : undefined;
}

export const mailDomain = (address: string) => address.slice(address.lastIndexOf("@") + 1);

/** What the receiving server checked, as it wrote it in its Authentication-Results header (RFC 8601). */
export interface MailAuthentication {
  /** Signing domains (header.d) of the DKIM signatures that passed. */
  dkim: string[];
  /** Domain of the envelope sender (smtp.mailfrom) when SPF passed. */
  spf?: string;
  /** Domain of the From header (header.from) when DMARC passed. */
  dmarc?: string;
}

/**
 * The `;`-separated parts of an RFC 8601 header, each a list of words: comments dropped (nested and escaped ones
 * included), a quoted string kept whole inside its word. Undefined when quotes or parentheses do not balance.
 */
export function authResultParts(header: string): string[][] | undefined {
  const parts: string[][] = [[]];
  let word = "";
  let depth = 0;
  let quoted = false;
  const end = () => {
    if (word) parts.at(-1)!.push(word);
    word = "";
  };
  for (let i = 0; i < header.length; i++) {
    const c = header[i]!;
    if (quoted) {
      word += c === "\\" ? c + (header[++i] ?? "") : c;
      if (c === '"') quoted = false;
    } else if (depth > 0) {
      if (c === "\\") i++;
      else if (c === "(") depth++;
      else if (c === ")") depth--;
    } else if (c === '"') {
      quoted = true;
      word += c;
    } else if (c === "(") {
      end();
      depth = 1;
    } else if (c === ")") return undefined;
    else if (c === ";") {
      end();
      parts.push([]);
    } else if (/\s/.test(c)) end();
    else word += c;
  }
  if (quoted || depth > 0) return undefined;
  end();
  return parts;
}

const domainOf = (v: string | undefined) => {
  const s = (v ?? "").trim().toLowerCase();
  return (s.includes("@") ? mailDomain(s) : s) || undefined;
};

/**
 * Reads the Authentication-Results header the Worker passed on (the one Email Routing stamped under its own Received line). Only the
 * header stamped by our own receiving server counts: one with another authserv-id is ignored as a whole. A quoted
 * string stays inside its word, so an envelope sender like `"x;dmarc=pass"@evil.example` copied into smtp.mailfrom
 * adds no result, while Cloudflare's own `smtp.remote-ip="2a00:…"` is read as it should. Unbalanced syntax makes the
 * whole verdict unverified, and only the first result of each method is read.
 */
export function parseAuthResults(header: string | undefined, authservId = DEFAULT_AUTHSERV_ID): MailAuthentication {
  const out: MailAuthentication = { dkim: [] };
  if (!header) return out;
  const parts = authResultParts(header);
  if (!parts) return out;
  const [head, ...results] = parts;
  if (head?.[0]?.toLowerCase() !== authservId.toLowerCase()) return out;
  const seen = new Set<string>();
  const repeated = new Set<string>();
  for (const [verdict, ...props] of results) {
    const [method, value] = (verdict ?? "").toLowerCase().split("=");
    if (!method) continue;
    if (seen.has(method)) {
      repeated.add(method);
      continue;
    }
    seen.add(method);
    if (value !== "pass") continue;
    const prop = (name: string) => props.find((p) => p.toLowerCase().startsWith(`${name}=`))?.slice(name.length + 1);
    if (method === "dkim") {
      const d = domainOf(prop("header.d") ?? prop("header.i"));
      if (d) out.dkim.push(d);
    } else if (method === "spf") out.spf = domainOf(prop("smtp.mailfrom"));
    else if (method === "dmarc") out.dmarc = domainOf(prop("header.from"));
  }
  // One SPF and one DMARC check per mail: a second result is text that slipped into the header, so neither counts.
  if (repeated.has("spf")) delete out.spf;
  if (repeated.has("dmarc")) delete out.dmarc;
  return out;
}

/** Relaxed alignment without a public suffix list: the same domain, or the From domain under the verified one. */
const aligned = (verified: string, from: string) => verified === from || from.endsWith(`.${verified}`);

/** The From address is proven, not just written: DMARC, an aligned DKIM signature or an aligned SPF pass. */
export function senderVerified(from: string, auth: MailAuthentication): boolean {
  const domain = mailDomain(from);
  if (auth.dmarc === domain) return true;
  if (auth.dkim.some((d) => aligned(d, domain))) return true;
  return !!auth.spf && aligned(auth.spf, domain);
}

/** The same mailbox, a `+tag` aside: `work+devis@bots.example.com` is `work@bots.example.com`. */
export function sameMailbox(a: string, b: string): boolean {
  const bare = (s: string) => {
    const at = s.lastIndexOf("@");
    return `${s.slice(0, at).split("+")[0]}@${s.slice(at + 1)}`.toLowerCase();
  };
  return bare(a) === bare(b);
}

/** A genuine mail of the owner resent later stays signed: only a recent one counts as a request. */
export const TRUSTED_MAIL_MAX_AGE_MS = 2 * 86_400_000;
const CLOCK_SKEW_MS = 3_600_000;

export function recentMail(date: string | undefined, now: number): boolean {
  const at = date ? Date.parse(date) : Number.NaN;
  return Number.isFinite(at) && at <= now + CLOCK_SKEW_MS && now - at <= TRUSTED_MAIL_MAX_AGE_MS;
}

const QUOTE_LINES = [
  /^>/,
  /^-{2,}\s*(forwarded message|message transféré|original message|message d'origine)/i,
  /^(début du message réexpédié|begin forwarded message)\s*:?\s*$/i,
];

/**
 * The owner's own words, and from the first quoted or forwarded part on, what someone else wrote: a reply quoting a
 * stranger must not turn the stranger's words into the owner's request.
 */
export function splitOwnText(text: string): { own: string; quoted: string } {
  const lines = text.split(/\r?\n/);
  const at = lines.findIndex((line, i) => {
    const l = line.trim();
    const next = (lines[i + 1] ?? "").trim();
    if (QUOTE_LINES.some((re) => re.test(l))) return true;
    // "Le jeu. 26 nov. 2026 à 09:14, Julie Martin <…> a écrit :" (French clients), often wrapped over two lines.
    if (/^Le\s/.test(l) && (/a écrit\s*:$/.test(l) || /a écrit\s*:$/.test(next))) return true;
    if (/^On\s/.test(l) && (/wrote:$/.test(l) || /wrote:$/.test(next))) return true;
    // Outlook's header block: "From: … Sent: …" or, in French, "De : … Envoyé :".
    return /^(from|de)\s*:/i.test(l) && lines.slice(i + 1, i + 4).some((n) => /^(sent|envoyé|date)\s*:/i.test(n.trim()));
  });
  if (at < 0) return { own: text.trim(), quoted: "" };
  return { own: lines.slice(0, at).join("\n").trim(), quoted: lines.slice(at).join("\n").trim() };
}
