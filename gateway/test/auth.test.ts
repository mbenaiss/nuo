import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadAuthKey, open, seal, verifyP256 } from "../src/auth/keys";
import { classify } from "../src/auth/network";
import { loadFinanceCollections, stepUpRequired } from "../src/auth/policy";
import { createPairCode, signedMessage } from "../src/auth/service";
import { base32Decode, base32Encode, hotp, totp, verifyTotp } from "../src/auth/totp";
import { newDeviceKey, pairDevice, refresh, startTestApp, stepUp, type TestApp } from "./helpers";

let t: TestApp | undefined;
afterEach(async () => {
  await t?.close();
  t = undefined;
});

describe("TOTP (RFC 6238 appendix B)", () => {
  const seeds = {
    sha1: Buffer.from("12345678901234567890"),
    sha256: Buffer.from("12345678901234567890123456789012"),
    sha512: Buffer.from("1234567890".repeat(6) + "1234"),
  } as const;
  const vectors: [number, string, string, string][] = [
    [59, "94287082", "46119246", "90693936"],
    [1111111109, "07081804", "68084774", "25091201"],
    [1111111111, "14050471", "67062674", "99943326"],
    [1234567890, "89005924", "91819424", "93441116"],
    [2000000000, "69279037", "90698825", "38618901"],
    [20000000000, "65353130", "77737706", "47863826"],
  ];
  for (const [time, sha1, sha256, sha512] of vectors) {
    test(`T = ${time}`, () => {
      expect(totp(seeds.sha1, time * 1000, 8, "sha1")).toBe(sha1);
      expect(totp(seeds.sha256, time * 1000, 8, "sha256")).toBe(sha256);
      expect(totp(seeds.sha512, time * 1000, 8, "sha512")).toBe(sha512);
    });
  }

  test("RFC 4226 HOTP vectors and base32 round trip", () => {
    expect([0, 1, 2, 9].map((c) => hotp(seeds.sha1, c))).toEqual(["755224", "287082", "359152", "520489"]);
    expect(base32Encode(seeds.sha1)).toBe("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ");
    expect(base32Decode("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")).toEqual(seeds.sha1);
  });

  test("±1 step window and replay protection", () => {
    const now = 1_700_000_000_000;
    const step = Math.floor(now / 30_000);
    const code = (s: number) => hotp(seeds.sha1, s);
    expect(verifyTotp(seeds.sha1, code(step - 1), now, 0)).toBe(step - 1);
    expect(verifyTotp(seeds.sha1, code(step + 1), now, 0)).toBe(step + 1);
    expect(verifyTotp(seeds.sha1, code(step + 2), now, 0)).toBeUndefined();
    expect(verifyTotp(seeds.sha1, code(step), now, step)).toBeUndefined();
    expect(verifyTotp(seeds.sha1, code(step - 1), now, step)).toBeUndefined();
    expect(verifyTotp(seeds.sha1, "12345", now, 0)).toBeUndefined();
  });
});

describe("secrets", () => {
  test("auth key is generated once into a 0600 file and never changes", () => {
    const dir = mkdtempSync(join(tmpdir(), "nuo-key-"));
    const file = join(dir, "sub", "nuo.env");
    try {
      const env = { NUO_SECRETS_FILE: file };
      expect(loadAuthKey({ env })).toBeUndefined();
      const k = loadAuthKey({ env, create: true })!;
      expect(k).toHaveLength(32);
      expect(statSync(file).mode & 0o777).toBe(0o600);
      expect(loadAuthKey({ env, create: true })).toEqual(k);
      writeFileSync(file, `OTHER=1\n${readFileSync(file, "utf8")}`);
      expect(loadAuthKey({ env })).toEqual(k);
      expect(open(k, seal(k, Buffer.from("secret")))).toEqual(Buffer.from("secret"));
      expect(() => open(Buffer.alloc(32, 1), seal(k, Buffer.from("secret")))).toThrow();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("the TOTP secret is sealed in nuo.db and recovery codes are hashed", async () => {
    t = await startTestApp();
    const row = t.app.store.db.query("SELECT secret_enc FROM auth_totp").get() as { secret_enc: string };
    expect(row.secret_enc).not.toContain(t.totpSecret);
    expect(Buffer.from(row.secret_enc, "base64").toString("latin1")).not.toContain(base32Decode(t.totpSecret).toString("latin1"));
    const { recoveryCodes } = t.app.auth.enrollTotp("test", true);
    const hashes = (t.app.store.db.query("SELECT code_hash FROM auth_recovery_codes").all() as { code_hash: string }[]).map((r) => r.code_hash);
    expect(hashes).toHaveLength(10);
    for (const c of recoveryCodes) expect(hashes).not.toContain(c);
  });
});

describe("pairing", () => {
  const pairBody = async (app: TestApp, second: string, profile = "owner") => ({
    profile,
    code: createPairCode(app.app.store),
    totp: second,
    deviceName: "iPad",
    platform: "iPadOS",
    publicKey: (await newDeviceKey()).spki,
  });

  test("a TOTP code is accepted once", async () => {
    t = await startTestApp();
    const second = totp(base32Decode(t.totpSecret), Date.now() + 30_000);
    expect((await t.api("POST", "/api/pair", await pairBody(t, second), "")).status).toBe(200);
    const replay = await t.api("POST", "/api/pair", await pairBody(t, second), "");
    expect(replay.status).toBe(401);
  });

  test("a recovery code works once instead of TOTP", async () => {
    t = await startTestApp();
    const { recoveryCodes } = t.app.auth.enrollTotp("test", true);
    expect((await t.api("POST", "/api/pair", await pairBody(t, recoveryCodes[0]!.toUpperCase()), "")).status).toBe(200);
    expect((await t.api("POST", "/api/pair", await pairBody(t, recoveryCodes[0]!), "")).status).toBe(401);
    expect(t.app.auth.recoveryCodesLeft()).toBe(9);
  });

  test("without 2FA set up, pairing is refused with the generic answer", async () => {
    t = await startTestApp();
    t.app.store.db.query("DELETE FROM auth_totp").run();
    const r = await t.api("POST", "/api/pair", await pairBody(t, "123456"), "");
    expect(r).toEqual({ status: 401, data: { error: "invalid profile, pairing code or 2FA code" } });
  });

  test("5 failures per address, 10 per profile name, 20 in total lock pairing for 15 minutes", async () => {
    let clock = Date.now();
    t = await startTestApp({ authNow: () => clock });
    const from = (ip: string, body: unknown) => fetch(`${t!.base}/api/pair`, { method: "POST", headers: { "content-type": "application/json", "x-forwarded-for": ip }, body: JSON.stringify(body) });
    for (let i = 0; i < 5; i++) expect((await from("10.20.0.20", await pairBody(t, "000000"))).status).toBe(401);
    const good = await pairBody(t, totp(base32Decode(t.totpSecret), clock + 30_000));
    const locked = await from("10.20.0.20", good);
    expect(locked.status).toBe(429);
    expect((await locked.json()).retryAt).toBeString();
    for (let i = 0; i < 5; i++) expect((await from(`10.20.0.${30 + i}`, await pairBody(t, "000000"))).status).toBe(401);
    // The owner's name is locked now, from any address; other names are not (yet).
    expect((await from("10.20.0.98", good)).status).toBe(429);
    for (let i = 0; i < 10; i++) expect((await from(`10.20.0.${40 + i}`, await pairBody(t, "000000", `nobody-${i}`))).status).toBe(401);
    expect((await from("10.20.0.99", await pairBody(t, "000000", "someone-else"))).status).toBe(429);
    clock += 15 * 60_000 + 1000;
    const later = await pairBody(t, totp(base32Decode(t.totpSecret), clock));
    expect((await from("10.20.0.99", later)).status).toBe(200);
    const fails = t.app.auth.events(100).filter((e) => e.type === "pair" && !e.ok);
    expect(fails[0]).toMatchObject({ ip: "10.20.0.99", detail: "locked" });
    expect(fails.some((e) => e.detail === 'unknown profile (profile "nobody-3")')).toBe(true);
    expect(t.pusher.sent.map((s) => s.payload.title)).toContain("Nuo · failed pairings");
  });

  test("pairing alerts the other devices and is audited", async () => {
    t = await startTestApp();
    await t.api("POST", "/api/devices", { apnsToken: "ab".repeat(32), environment: "development" });
    await pairDevice({ base: t.base, api: t.api, store: t.app.store, totpSecret: t.totpSecret, now: Date.now(), name: "Mac" });
    expect(t.pusher.sent.map((s) => s.payload.body)).toEqual([expect.stringContaining('"Mac" was just paired from')]);
    expect(t.pusher.sent[0]!.payload).toMatchObject({ category: "nuo.security", destination: { kind: "settings" } });
    expect(t.app.auth.events().find((e) => e.type === "pair" && e.ok)).toMatchObject({ deviceName: "Mac", ip: "127.0.0.1" });
  });

  test("pairing is not reachable from the internet", async () => {
    t = await startTestApp();
    const r = await fetch(`${t.base}/api/pair`, { method: "POST", headers: { "cf-connecting-ip": "203.0.113.9", "content-type": "application/json" }, body: "{}" });
    expect(r.status).toBe(404);
  });
});

describe("device keys and tokens", () => {
  test("refresh needs a signature of a fresh nonce by the device key", async () => {
    t = await startTestApp();
    const ok = await refresh(t.api, t.device);
    expect(ok.status).toBe(200);
    expect(ok.data.accessToken).not.toBe(t.device.accessToken);
    expect((await t.api("GET", "/api/bots", undefined, ok.data.accessToken)).status).toBe(200);

    const { data: c } = await t.api("GET", "/api/auth/challenge", undefined, "");
    const other = await newDeviceKey();
    const forged = await t.api("POST", "/api/auth/refresh", { deviceId: t.device.id, nonce: c.nonce, signature: await other.sign(signedMessage("refresh", t.device.id, c.nonce)) }, "");
    expect(forged.status).toBe(401);
    expect(forged.data.reauth).toBe(false);
    // The nonce was spent by the failed attempt.
    const reuse = await t.api("POST", "/api/auth/refresh", { deviceId: t.device.id, nonce: c.nonce, signature: await t.device.sign(signedMessage("refresh", t.device.id, c.nonce)) }, "");
    expect(reuse.status).toBe(401);
    const { data: c2 } = await t.api("GET", "/api/auth/challenge", undefined, "");
    const wrongPurpose = await t.api("POST", "/api/auth/refresh", { deviceId: t.device.id, nonce: c2.nonce, signature: await t.device.sign(signedMessage("step-up", t.device.id, c2.nonce)) }, "");
    expect(wrongPurpose.status).toBe(401);
    expect(t.app.auth.events().filter((e) => e.type === "refresh").map((e) => e.ok)).toEqual([false, false, false, true]);
  });

  test("DER signatures (CryptoKit) verify too", async () => {
    const { generateKeyPairSync, sign } = await import("node:crypto");
    const { publicKey, privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
    const spki = publicKey.export({ format: "der", type: "spki" }).toString("base64");
    const der = sign("sha256", Buffer.from("m"), privateKey).toString("base64");
    expect(verifyP256(spki, "m", der)).toBe(true);
    expect(verifyP256(spki, "n", der)).toBe(false);
    const raw = publicKey.export({ format: "jwk" });
    const x963 = Buffer.concat([Buffer.from([4]), Buffer.from(raw.x!, "base64url"), Buffer.from(raw.y!, "base64url")]).toString("base64");
    expect(verifyP256(x963, "m", der)).toBe(true);
  });

  test("access tokens expire after 15 minutes and are bound to the device key", async () => {
    let clock = Date.now();
    t = await startTestApp({ authNow: () => clock });
    clock += 15 * 60_000 + 1;
    const expired = await t.api("GET", "/api/bots");
    expect(expired).toMatchObject({ status: 401, data: { reauth: false } });
    const r = await refresh(t.api, t.device);
    expect(r.data.cnf).toBeString();
    expect((await t.api("GET", "/api/bots", undefined, r.data.accessToken)).status).toBe(200);
    t.app.store.db.query("UPDATE devices SET public_key = ? WHERE id = ?").run((await newDeviceKey()).spki, t.device.id);
    expect((await t.api("GET", "/api/bots", undefined, r.data.accessToken)).data.reauth).toBe(true);
  });

  test("legacy long-lived tokens are refused with reauth", async () => {
    t = await startTestApp();
    const { createHash } = await import("node:crypto");
    const old = "legacy-token-value";
    t.app.store.db.query("INSERT INTO devices (id, name, token_hash, created_at) VALUES ('old', 'iPhone', ?, '2026-01-01')").run(createHash("sha256").update(old).digest("hex"));
    const r = await t.api("GET", "/api/bots", undefined, old);
    expect(r).toMatchObject({ status: 401, data: { reauth: true } });
    const list = await t.api("GET", "/api/devices");
    expect(list.data.find((d: { id: string }) => d.id === "old")).toMatchObject({ legacy: true, current: false });
  });

  test("revoking a device rejects its tokens immediately and closes its sockets", async () => {
    t = await startTestApp();
    const other = await pairDevice({ base: t.base, api: t.api, store: t.app.store, totpSecret: t.totpSecret, now: Date.now(), name: "Watch phone" });
    const ws = new WebSocket(t.base.replace("http", "ws") + "/api/ws", { headers: { authorization: `Bearer ${other.accessToken}` } } as any);
    await new Promise((r) => (ws.onopen = r));
    const closed = new Promise<number>((r) => (ws.onclose = (e) => r(e.code)));
    const list = await t.api("GET", "/api/devices");
    expect(list.data.map((d: { name: string; current: boolean }) => [d.name, d.current])).toEqual([
      ["Test iPhone", true],
      ["Watch phone", false],
    ]);
    expect((await t.api("DELETE", `/api/devices/${other.id}`, undefined, t.device.accessToken)).data.stepUp).toBe(true);
    expect((await t.api("DELETE", `/api/devices/${other.id}`)).status).toBe(204);
    expect(await closed).toBe(4401);
    expect((await t.api("GET", "/api/bots", undefined, other.accessToken)).status).toBe(401);
    expect((await t.api("GET", "/api/bots", undefined, other.extensionTokens.widgets!.token)).status).toBe(401);
    expect((await refresh(t.api, other)).data.reauth).toBe(true);
    expect(t.app.auth.events().find((e) => e.type === "revoke")).toMatchObject({ deviceName: "Watch phone" });
  });

  test("extension tokens only reach their routes", async () => {
    t = await startTestApp();
    const ext = t.device.extensionTokens;
    const bot = (await t.api("POST", "/api/bots", { name: "Voyages" })).data;
    const call = (scope: string, m: string, p: string, b?: unknown) => t!.api(m, p, b, ext[scope]!.token).then((r) => r.status);
    expect(await call("widgets", "GET", "/api/bots")).toBe(200);
    expect(await call("widgets", "GET", "/api/reminders")).toBe(200);
    expect(await call("widgets", "POST", "/api/conversations", { botId: bot.id })).toBe(403);
    expect(await call("widgets", "GET", "/api/devices")).toBe(403);
    expect(await call("widgets", "POST", "/api/reminders/missing/done")).toBe(404);
    expect(await call("widgets", "POST", "/api/reminders", { title: "x" })).toBe(403);
    expect(await call("share", "GET", "/api/bots")).toBe(200);
    expect(await call("share", "GET", "/api/reminders")).toBe(403);
    expect(await call("share", "GET", `/api/bots/${bot.id}`)).toBe(403);
    expect(await call("watch", "GET", "/api/conversations")).toBe(200);
    expect(await call("watch", "DELETE", `/api/bots/${bot.id}`)).toBe(403);
    expect(await call("watch", "POST", "/api/auth/step-up", {})).toBe(403);
    expect(await call("share", "GET", "/api/data/collections")).toBe(403);
  });
});

describe("step-up", () => {
  test("sensitive routes need a step-up younger than 60 s", async () => {
    let clock = Date.now();
    t = await startTestApp({ authNow: () => clock });
    const plain = t.device.accessToken;
    const finance = { values: { titre: "F-1" } };
    const r1 = await t.api("POST", "/api/data/collections/factures/rows", finance, plain);
    expect(r1).toMatchObject({ status: 403, data: { stepUp: true, reason: "finance" } });
    expect((await t.api("POST", "/api/data/collections/factures/rows", finance)).status).not.toBe(403);
    expect((await t.api("DELETE", "/api/docs/file?path=a.md", undefined, plain)).data.reason).toBe("docs");
    expect((await t.api("DELETE", "/api/docs/folder?path=a", undefined, plain)).data.reason).toBe("docs");
    expect((await t.api("GET", "/api/data/collections/factures/rows", undefined, plain)).status).toBe(200);
    expect((await t.api("POST", "/api/reminders", { title: "pain" }, plain)).status).not.toBe(403);
    clock += 61_000;
    expect((await t.api("POST", "/api/data/collections/factures/rows", finance)).data.reason).toBe("finance");
    const fresh = await stepUp(t.api, t.device);
    expect((await t.api("POST", "/api/data/collections/factures/rows", finance, fresh)).status).not.toBe(403);
    expect(t.app.auth.events().filter((e) => e.type === "step_up" && e.ok)).toHaveLength(2);
  });

  test("step-up needs the device key", async () => {
    t = await startTestApp();
    const { data: c } = await t.api("GET", "/api/auth/challenge", undefined, "");
    const other = await newDeviceKey();
    const r = await t.api("POST", "/api/auth/step-up", { nonce: c.nonce, signature: await other.sign(signedMessage("step-up", t.device.id, c.nonce)) }, t.device.accessToken);
    expect(r.status).toBe(401);
  });

  test("finance collections: an optional private list, none without the file, a malformed one refused", () => {
    const dir = mkdtempSync(join(tmpdir(), "nuo-finance-"));
    expect(loadFinanceCollections(join(dir, "finance-collections.json"))).toEqual(new Set());
    writeFileSync(join(dir, "finance-collections.json"), JSON.stringify(["releves_bancaires", "placements"]));
    expect(loadFinanceCollections(join(dir, "finance-collections.json"))).toEqual(new Set(["releves_bancaires", "placements"]));
    writeFileSync(join(dir, "finance-collections.json"), JSON.stringify({ releves_bancaires: true }));
    expect(() => loadFinanceCollections(join(dir, "finance-collections.json"))).toThrow("expected an array of collection ids");
    rmSync(dir, { recursive: true, force: true });
  });

  test("policy: command tasks, finance by money column, revert", () => {
    const l = { isFinanceCollection: (id: string) => id === "factures", isCommandTask: (id: string) => id === "cmd" };
    expect(stepUpRequired("POST", "/api/schedules", { action: { type: "command" } }, l)).toBe("commands");
    expect(stepUpRequired("POST", "/api/schedules", { action: { type: "prompt" } }, l)).toBeUndefined();
    expect(stepUpRequired("PATCH", "/api/schedules/cmd", { enabled: false }, l)).toBe("commands");
    expect(stepUpRequired("PATCH", "/api/schedules/p1", { action: { type: "command" } }, l)).toBe("commands");
    expect(stepUpRequired("PATCH", "/api/schedules/p1", { title: "x" }, l)).toBeUndefined();
    expect(stepUpRequired("POST", "/api/data/collections/factures/rows/r1/archive", undefined, l)).toBe("finance");
    expect(stepUpRequired("PATCH", "/api/data/collections/notes/rows/r1", undefined, l)).toBeUndefined();
    expect(stepUpRequired("POST", "/api/data/history/h1/revert", undefined, l)).toBe("finance");
  });
});

describe("network zones and the local token", () => {
  const cfg = { tunnelSources: new Set(["10.0.0.5"]), proxySources: new Set(["127.0.0.1", "10.20.0.54"]) };
  const h = (o: Record<string, string>) => new Headers(o);

  test("classify", () => {
    expect(classify("127.0.0.1", h({}), cfg)).toEqual({ zone: "local", ip: "127.0.0.1" });
    expect(classify("10.20.0.54", h({ "x-forwarded-for": "10.20.0.12" }), cfg)).toEqual({ zone: "lan", ip: "10.20.0.12" });
    expect(classify("10.0.0.5", h({ "cf-connecting-ip": "203.0.113.9" }), cfg)).toEqual({ zone: "internet", ip: "203.0.113.9" });
    // Cloudflare headers from anywhere else are not believed, but still make the request internet.
    expect(classify("10.20.0.12", h({ "cf-connecting-ip": "1.2.3.4" }), cfg)).toEqual({ zone: "internet", ip: "10.20.0.12" });
    expect(classify("127.0.0.1", h({ "cf-connecting-ip": "1.2.3.4" }), cfg)).toEqual({ zone: "internet", ip: "127.0.0.1" });
    expect(classify("10.20.0.77", h({ "x-forwarded-for": "10.9.9.9" }), cfg)).toEqual({ zone: "lan", ip: "10.20.0.77" });
    expect(classify("10.0.0.5", h({}), cfg).zone).toBe("internet");
    expect(classify("10.20.0.54", h({ "x-forwarded-for": "8.8.8.8" }), cfg)).toEqual({ zone: "internet", ip: "8.8.8.8" });
  });

  test("the local token only works from a direct loopback connection", async () => {
    t = await startTestApp({ localToken: "local-secret" });
    const notify = (headers: Record<string, string>) =>
      fetch(`${t!.base}/api/notify`, { method: "POST", headers: { authorization: "Bearer local-secret", "content-type": "application/json", ...headers }, body: JSON.stringify({ title: "a", body: "b" }) });
    expect((await notify({})).status).toBe(204);
    expect((await notify({ "x-forwarded-for": "10.20.0.12" })).status).toBe(401);
    expect((await notify({ "cf-connecting-ip": "203.0.113.9" })).status).toBe(401);
    expect(t.app.auth.events().filter((e) => e.type === "local_token_rejected")).toHaveLength(2);
  });

  test("internet requests: generic errors, no hints, logged, security headers", async () => {
    t = await startTestApp({ network: { tunnelSources: new Set(["127.0.0.1"]), proxySources: new Set() } });
    const inet = (path: string, init: RequestInit = {}) => fetch(`${t!.base}${path}`, { ...init, headers: { "cf-connecting-ip": "203.0.113.9", ...(init.headers as Record<string, string>) } });
    const health = await inet("/api/health");
    expect(await health.json()).toEqual({ ok: true });
    expect(health.headers.get("x-content-type-options")).toBe("nosniff");
    expect(health.headers.get("access-control-allow-origin")).toBeNull();
    const bad = await inet("/api/bots", { headers: { authorization: "Bearer nope" } });
    expect(await bad.json()).toEqual({ error: "unauthorized", reauth: false });
    const wrongMethod = await inet("/api/agents", { method: "DELETE", headers: { authorization: `Bearer ${t.token}` } });
    expect(wrongMethod.status).toBe(404);
    const big = await inet("/api/bots", { method: "POST", headers: { authorization: `Bearer ${t.token}`, "content-type": "application/json" }, body: JSON.stringify({ name: "x".repeat(300 * 1024) }) });
    expect(big.status).toBe(413);
    const activity = await t.api("GET", "/api/auth/activity");
    const rows = activity.data.internet as { ip: string; requests: number; deviceName?: string }[];
    expect(rows.every((r) => r.ip === "203.0.113.9")).toBe(true);
    expect(rows.reduce((n, r) => n + r.requests, 0)).toBe(4);
    expect(rows.find((r) => r.deviceName)?.deviceName).toBe("Test iPhone");
  });

  test("pairing returns the public URL and the Cloudflare Access service token", async () => {
    t = await startTestApp({ networkInfo: { publicURL: "https://nuo.example.dev", cfAccess: { clientId: "id.access", clientSecret: "s3cret" } } });
    const r = await t.api("POST", "/api/pair", {
      profile: "owner",
      code: createPairCode(t.app.store),
      totp: totp(base32Decode(t.totpSecret), Date.now() + 30_000),
      deviceName: "iPad",
      publicKey: (await newDeviceKey()).spki,
    }, "");
    expect(r.data.network).toEqual({ publicURL: "https://nuo.example.dev", cfAccess: { clientId: "id.access", clientSecret: "s3cret" } });
    expect((await t.api("GET", "/api/auth/network")).data.publicURL).toBe("https://nuo.example.dev");
  });
});
