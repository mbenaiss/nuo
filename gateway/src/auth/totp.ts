import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";

/** RFC 6238 time-based one-time passwords (RFC 4226 HOTP over a 30 s counter). */
export const TOTP_PERIOD_S = 30;
export const TOTP_DIGITS = 6;
/** Accepted clock drift, in steps on each side. */
export const TOTP_WINDOW = 1;

export type TotpAlgorithm = "sha1" | "sha256" | "sha512";

const B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

export function base32Encode(buf: Uint8Array): string {
  let bits = 0;
  let value = 0;
  let out = "";
  for (const byte of buf) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += B32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += B32[(value << (5 - bits)) & 31];
  return out;
}

export function base32Decode(s: string): Buffer {
  const clean = s.toUpperCase().replace(/[\s=-]/g, "");
  let bits = 0;
  let value = 0;
  const out: number[] = [];
  for (const c of clean) {
    const i = B32.indexOf(c);
    if (i < 0) throw new Error("invalid base32");
    value = (value << 5) | i;
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return Buffer.from(out);
}

export function generateTotpSecret(): Buffer {
  return randomBytes(20);
}

export function hotp(secret: Uint8Array, counter: number, digits = TOTP_DIGITS, algorithm: TotpAlgorithm = "sha1"): string {
  const msg = Buffer.alloc(8);
  msg.writeBigUInt64BE(BigInt(counter));
  const mac = createHmac(algorithm, secret).update(msg).digest();
  const offset = mac[mac.length - 1]! & 0x0f;
  const bin = ((mac[offset]! & 0x7f) << 24) | (mac[offset + 1]! << 16) | (mac[offset + 2]! << 8) | mac[offset + 3]!;
  return (bin % 10 ** digits).toString().padStart(digits, "0");
}

export const totpStep = (nowMs: number) => Math.floor(nowMs / 1000 / TOTP_PERIOD_S);

export function totp(secret: Uint8Array, nowMs: number, digits = TOTP_DIGITS, algorithm: TotpAlgorithm = "sha1"): string {
  return hotp(secret, totpStep(nowMs), digits, algorithm);
}

/**
 * Returns the matched step, or undefined. Steps at or before `lastUsedStep` are refused so that a code
 * (or an older one inside the drift window) can only be used once.
 */
export function verifyTotp(secret: Uint8Array, code: string, nowMs: number, lastUsedStep: number): number | undefined {
  if (!/^\d{6}$/.test(code)) return undefined;
  const current = totpStep(nowMs);
  let matched: number | undefined;
  // Check every candidate so the timing does not reveal which step matched.
  for (let s = current - TOTP_WINDOW; s <= current + TOTP_WINDOW; s++) {
    if (timingSafeEqual(Buffer.from(hotp(secret, s)), Buffer.from(code)) && s > lastUsedStep && matched === undefined) matched = s;
  }
  return matched;
}

export function otpauthUri(secret: Uint8Array, account: string, issuer = "Nuo"): string {
  const label = `${encodeURIComponent(issuer)}:${encodeURIComponent(account)}`;
  const q = new URLSearchParams({ secret: base32Encode(secret), issuer, algorithm: "SHA1", digits: String(TOTP_DIGITS), period: String(TOTP_PERIOD_S) });
  return `otpauth://totp/${label}?${q}`;
}
