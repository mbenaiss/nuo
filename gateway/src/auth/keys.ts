import { createCipheriv, createDecipheriv, createHash, createPublicKey, randomBytes, verify, type KeyObject } from "node:crypto";
import { appendFileSync, chmodSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export const sha256 = (s: string) => createHash("sha256").update(s).digest("hex");

export function defaultSecretsFile(env: Record<string, string | undefined> = process.env): string {
  return env.NUO_SECRETS_FILE || join(homedir(), ".secrets", "nuo.env");
}

function parseKey(raw: string | undefined): Buffer | undefined {
  if (!raw) return undefined;
  const key = Buffer.from(raw.trim(), "base64");
  if (key.length !== 32) throw new Error("NUO_AUTH_KEY must be 32 bytes, base64-encoded");
  return key;
}

function readKeyFromFile(file: string): string | undefined {
  if (!existsSync(file)) return undefined;
  for (const line of readFileSync(file, "utf8").split("\n")) {
    const m = line.match(/^\s*(?:export\s+)?NUO_AUTH_KEY\s*=\s*["']?([^"'\s]+)["']?\s*$/);
    if (m) return m[1];
  }
  return undefined;
}

/**
 * The key that encrypts the TOTP secret at rest: NUO_AUTH_KEY from the environment, else from the secrets
 * file. With `create`, a missing key is generated and appended to the file (0600); the value is never printed.
 */
export function loadAuthKey(opts: { create?: boolean; env?: Record<string, string | undefined> } = {}): Buffer | undefined {
  const env = opts.env ?? process.env;
  const fromEnv = parseKey(env.NUO_AUTH_KEY);
  if (fromEnv) return fromEnv;
  const file = defaultSecretsFile(env);
  const fromFile = parseKey(readKeyFromFile(file));
  if (fromFile || !opts.create) return fromFile;
  const key = randomBytes(32);
  mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
  const prefix = existsSync(file) && !readFileSync(file, "utf8").endsWith("\n") && readFileSync(file, "utf8").length ? "\n" : "";
  appendFileSync(file, `${prefix}NUO_AUTH_KEY=${key.toString("base64")}\n`, { mode: 0o600 });
  chmodSync(file, 0o600);
  return key;
}

/** AES-256-GCM; output is base64(iv | tag | ciphertext). */
export function seal(key: Buffer, plain: Buffer): string {
  const iv = randomBytes(12);
  const c = createCipheriv("aes-256-gcm", key, iv);
  const body = Buffer.concat([c.update(plain), c.final()]);
  return Buffer.concat([iv, c.getAuthTag(), body]).toString("base64");
}

export function open(key: Buffer, sealed: string): Buffer {
  const raw = Buffer.from(sealed, "base64");
  const d = createDecipheriv("aes-256-gcm", key, raw.subarray(0, 12));
  d.setAuthTag(raw.subarray(12, 28));
  return Buffer.concat([d.update(raw.subarray(28)), d.final()]);
}

// DER prefix of a SubjectPublicKeyInfo for an uncompressed P-256 point (id-ecPublicKey, prime256v1).
const P256_SPKI_PREFIX = Buffer.from("3059301306072a8648ce3d020106082a8648ce3d030107034200", "hex");

/** Accepts a base64 SPKI DER key or a raw X9.63 uncompressed point (0x04 | X | Y), P-256 only. */
export function parseP256PublicKey(b64: string): KeyObject {
  const raw = Buffer.from(b64, "base64");
  const der = raw.length === 65 && raw[0] === 0x04 ? Buffer.concat([P256_SPKI_PREFIX, raw]) : raw;
  const key = createPublicKey({ key: der, format: "der", type: "spki" });
  if (key.asymmetricKeyType !== "ec" || key.asymmetricKeyDetails?.namedCurve !== "prime256v1") throw new Error("expected a P-256 key");
  return key;
}

/** ECDSA P-256 / SHA-256; the signature is DER (Apple CryptoKit, SecKey) or raw r|s (WebCrypto). */
export function verifyP256(publicKeyB64: string, message: string, signatureB64: string): boolean {
  try {
    const sig = Buffer.from(signatureB64, "base64");
    const key = parseP256PublicKey(publicKeyB64);
    return verify("sha256", Buffer.from(message), { key, dsaEncoding: sig.length === 64 ? "ieee-p1363" : "der" }, sig);
  } catch {
    return false;
  }
}

/** Canonical form stored for a device: SPKI DER, base64. */
export function normalizePublicKey(b64: string): string {
  return parseP256PublicKey(b64).export({ format: "der", type: "spki" }).toString("base64");
}
