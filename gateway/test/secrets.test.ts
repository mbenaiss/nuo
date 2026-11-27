import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { actionMessage } from "../src/auth/service";
import { deleteEntry, parseEnv, quoteValue, renderEnv, setEntry } from "../src/secrets/envfile";
import { MASKED, SecretMask } from "../src/secrets/mask";
import { pairDevice, startTestApp, stepUp, type TestApp } from "./helpers";

const GLOBAL_ENV = `# Cloudflare
export CF_TOKEN=cf_fixture_5d1c7a0e9b
export GOG_KEYRING_PASSWORD='keyring fixture phrase'

POSTHOG_PERSONAL_API_KEY=phx_fixture_8Qm2Lr # rotated in october
MUSIC_ASSISTANT_USER=alex
`;
const BANK_ENV = "BANK_LOGIN=lumen-studio-4821\nBANK_SECRET_KEY=bank_fixture_k3y9Zt\n";
const NUO_ENV = 'NUO_PORT=8790\nNUO_BOOKING_OWNER="Alex Morgan"\nNUO_CF_ACCESS_CLIENT_ID=cfaccess_fixture_id.access\nNUO_CF_ACCESS_CLIENT_SECRET=cfaccess_fixture_secret_77\n';
const FITNESS_ENV = "WHOOP_CLIENT_ID=whoop_fixture_client\nWHOOP_CLIENT_SECRET=whoop_fixture_secret_19\n";
const README = `# Secrets de dev
| Fichier | Lien (ancien chemin) | Utilisé par |
|---|---|---|
| global.env | ~/.env | scripts, Cloudflare, PostHog |
| nuo.env | ~/nuo/config/env | nuo-gateway (EnvironmentFile) |
| projects/fitness*.env | fitness/.env | MCP fitness |
`;
const VALUES = ["cf_fixture_5d1c7a0e9b", "keyring fixture phrase", "phx_fixture_8Qm2Lr", "bank_fixture_k3y9Zt", "cfaccess_fixture_secret_77", "whoop_fixture_secret_19"];

let t: TestApp | undefined;
let dir: string | undefined;
afterEach(async () => {
  await t?.close();
  t = undefined;
  if (dir) rmSync(dir, { recursive: true, force: true });
  dir = undefined;
});

function secretsDir(): string {
  dir = mkdtempSync(join(tmpdir(), "nuo-secrets-"));
  const root = join(dir, ".secrets");
  mkdirSync(join(root, "projects"), { recursive: true, mode: 0o700 });
  const put = (name: string, text: string) => {
    writeFileSync(join(root, name), text);
    chmodSync(join(root, name), 0o600);
  };
  put("global.env", GLOBAL_ENV);
  put("lumen-bank.env", BANK_ENV);
  put("nuo.env", NUO_ENV);
  put("projects/fitness.env", FITNESS_ENV);
  put("README.md", README);
  put("hcloud-token", "hcloud_fixture_token\n");
  writeFileSync(join(dir, "outside.env"), "OUTSIDE_TOKEN=outside_fixture\n");
  symlinkSync(join(dir, "outside.env"), join(root, "linked.env"));
  return root;
}

async function newActionKey() {
  const keys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const spki = Buffer.from(await crypto.subtle.exportKey("spki", keys.publicKey)).toString("base64");
  const sign = async (message: string) => Buffer.from(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, keys.privateKey, new TextEncoder().encode(message))).toString("base64");
  return { spki, sign };
}

async function withSecrets(o: { registerKey?: boolean } = {}) {
  const root = secretsDir();
  t = await startTestApp({ secrets: { dir: root, home: dir, exclude: { names: ["nuo.env"] } }, localToken: "local-secret" });
  const app = t;
  const fresh = () => stepUp(app.api, app.device);
  const key = await newActionKey();
  const register = async () => app.api("POST", "/api/auth/action-key", { publicKey: key.spki }, await fresh());
  if (o.registerKey !== false) expect((await register()).status).toBe(200);
  /** One secret call as the app makes it: a nonce, then the Face ID key's signature of that exact request. */
  const call = async (method: string, path: string, body?: unknown, x: { headers?: Record<string, string>; tamper?: (b: string) => string; noSignature?: boolean } = {}) => {
    const text = body === undefined ? "" : JSON.stringify(body);
    const { data: c } = await app.api("GET", "/api/auth/challenge", undefined, "");
    const signature = await key.sign(actionMessage(app.device.id, c.nonce, method, path, text));
    const res = await fetch(app.base + path, {
      method,
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${app.device.accessToken}`,
        ...(x.noSignature ? {} : { "x-nuo-action-nonce": c.nonce, "x-nuo-action-signature": signature }),
        ...x.headers,
      },
      body: method === "DELETE" ? undefined : (x.tamper?.(text) ?? text),
    });
    const out = await res.text();
    return { status: res.status, data: out ? JSON.parse(out) : undefined };
  };
  return { root, t: app, fresh, register, call, read: (name: string) => readFileSync(join(root, name), "utf8") };
}

describe("env files", () => {
  test("reads export, quotes and inline comments; the last assignment wins", () => {
    const doc = parseEnv(GLOBAL_ENV + "MUSIC_ASSISTANT_USER=julie\n");
    const values = Object.fromEntries(doc.entries.map((e) => [e.key, e.value]));
    expect(values).toEqual({ CF_TOKEN: "cf_fixture_5d1c7a0e9b", GOG_KEYRING_PASSWORD: "keyring fixture phrase", POSTHOG_PERSONAL_API_KEY: "phx_fixture_8Qm2Lr", MUSIC_ASSISTANT_USER: "julie" });
    expect(doc.entries.filter((e) => e.exported).map((e) => e.key)).toEqual(["CF_TOKEN", "GOG_KEYRING_PASSWORD"]);
    expect(renderEnv(doc)).toBe(GLOBAL_ENV + "MUSIC_ASSISTANT_USER=julie\n");
  });

  test("an edit touches one line and keeps its export, quoting and comment", () => {
    let doc = setEntry(parseEnv(GLOBAL_ENV), "GOG_KEYRING_PASSWORD", "new keyring phrase");
    doc = setEntry(doc, "POSTHOG_PERSONAL_API_KEY", "phx_rotated_4Kd");
    expect(renderEnv(doc)).toBe(GLOBAL_ENV.replace("'keyring fixture phrase'", "'new keyring phrase'").replace("phx_fixture_8Qm2Lr", "phx_rotated_4Kd"));
  });

  test("values are quoted only when a shell would need it", () => {
    expect(quoteValue("bank_fixture_k3y9Zt")).toBe("bank_fixture_k3y9Zt");
    expect(quoteValue("Alex Morgan")).toBe("'Alex Morgan'");
    expect(quoteValue("l'atelier $HOME")).toBe('"l\'atelier \\$HOME"');
    expect(quoteValue("Julie Martin", "double")).toBe('"Julie Martin"');
    const doc = parseEnv(renderEnv(setEntry(parseEnv(""), "NUO_BOOKING_OWNER", 'say "bonjour" `now` \\ $X')));
    expect(doc.entries[0]!.value).toBe('say "bonjour" `now` \\ $X');
  });

  test("new keys follow the file's export habit; delete removes every line of a multi-line value", () => {
    const exported = setEntry(parseEnv("export CF_TOKEN=a\n"), "CF_ZONE_ID", "zone_42");
    expect(renderEnv(exported)).toBe("export CF_TOKEN=a\nexport CF_ZONE_ID=zone_42\n");
    expect(renderEnv(setEntry(parseEnv("A=1"), "B", "2"))).toBe("A=1\nB=2");
    const multi = parseEnv('# key\nAPNS_KEY="-----BEGIN\nabc\n-----END"\nAPNS_KEY_ID=K7Q2\n');
    expect(multi.entries.map((e) => [e.key, e.span])).toEqual([["APNS_KEY", 3], ["APNS_KEY_ID", 1]]);
    expect(renderEnv(deleteEntry(multi, "APNS_KEY"))).toBe("# key\nAPNS_KEY_ID=K7Q2\n");
  });
});

describe("secrets routes", () => {
  test("the list has files and names, never values, needs no Face ID, and leaves the gateway's own file out", async () => {
    const { t } = await withSecrets();
    const r = await t.api("GET", "/api/secrets", undefined, t.device.accessToken);
    expect(r.status).toBe(200);
    expect(r.data.configured).toBe(true);
    expect(r.data.root).toBe("~/.secrets");
    expect(r.data.sources.map((s: any) => s.id)).toEqual(["global.env", "lumen-bank.env", "projects/fitness.env"]);
    const global = r.data.sources[0];
    expect(global).toMatchObject({ path: "~/.secrets/global.env", mode: "600", insecure: false, link: "~/.env", usedBy: "scripts, Cloudflare, PostHog" });
    expect(global.entries).toEqual([
      { key: "CF_TOKEN", exported: true },
      { key: "GOG_KEYRING_PASSWORD", exported: true },
      { key: "POSTHOG_PERSONAL_API_KEY", exported: false },
      { key: "MUSIC_ASSISTANT_USER", exported: false },
    ]);
    expect(r.data.sources[2].usedBy).toBe("MCP fitness");
    const text = JSON.stringify(r.data);
    for (const v of [...VALUES, "outside_fixture", "hcloud_fixture_token", "NUO_CF_ACCESS_CLIENT_SECRET"]) expect(text).not.toContain(v);
  });

  test("a reveal needs the Face ID key's signature of that exact call, once, and is logged and pushed without the value", async () => {
    const { t, call } = await withSecrets();
    const body = { source: "lumen-bank.env", key: "BANK_SECRET_KEY" };
    expect(await call("POST", "/api/secrets/reveal", body, { noSignature: true })).toMatchObject({ status: 403, data: { action: true } });
    expect(await call("POST", "/api/secrets/reveal", body)).toEqual({ status: 200, data: { value: "bank_fixture_k3y9Zt" } });
    // Signed for one secret, sent for another: refused.
    const swapped = await call("POST", "/api/secrets/reveal", body, { tamper: (b) => b.replace("BANK_SECRET_KEY", "BANK_LOGIN") });
    expect(swapped).toMatchObject({ status: 403, data: { action: true } });
    // A generic step-up token is no longer enough on its own.
    expect((await t.api("POST", "/api/secrets/reveal", body, await stepUp(t.api, t.device))).status).toBe(403);
    const events = t.app.auth.events().filter((e) => e.type === "secret_reveal");
    expect(events.filter((e) => e.ok).map((e) => [e.detail, e.deviceName])).toEqual([["lumen-bank.env · BANK_SECRET_KEY", "Test iPhone"]]);
    expect(JSON.stringify(t.app.auth.events(500))).not.toContain("bank_fixture_k3y9Zt");
    const pushes = t.pusher.sent.map((p) => JSON.stringify(p.payload));
    expect(pushes.some((p) => p.includes("Secret affiché") && p.includes("lumen-bank.env › BANK_SECRET_KEY"))).toBe(true);
    expect(pushes.join("")).not.toContain("bank_fixture_k3y9Zt");
  });

  test("a signed call cannot be replayed, even by requests racing on its nonce", async () => {
    const { t, register } = await withSecrets({ registerKey: false });
    void register;
    const key = await newActionKey();
    expect((await t.api("POST", "/api/auth/action-key", { publicKey: key.spki }, await stepUp(t.api, t.device))).status).toBe(200);
    const text = JSON.stringify({ source: "global.env", key: "CF_TOKEN" });
    const { data: c } = await t.api("GET", "/api/auth/challenge", undefined, "");
    const signature = await key.sign(actionMessage(t.device.id, c.nonce, "POST", "/api/secrets/reveal", text));
    const send = () =>
      fetch(t.base + "/api/secrets/reveal", {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${t.device.accessToken}`, "x-nuo-action-nonce": c.nonce, "x-nuo-action-signature": signature },
        body: text,
      }).then((r) => r.status);
    expect((await Promise.all([send(), send(), send()])).sort()).toEqual([200, 403, 403]);
  });

  test("from the internet the list works, but nothing is shown or changed", async () => {
    const { call, t, read } = await withSecrets();
    const internet = { headers: { "cf-ray": "8a1b2c3d4e5f-CDG", "cf-connecting-ip": "203.0.113.24" } };
    expect((await t.api("GET", "/api/secrets", undefined, t.device.accessToken)).status).toBe(200);
    expect(await call("POST", "/api/secrets/reveal", { source: "lumen-bank.env", key: "BANK_SECRET_KEY" }, internet)).toMatchObject({ status: 403, data: { lanOnly: true } });
    expect(await call("PUT", "/api/secrets/entries", { source: "lumen-bank.env", key: "BANK_LOGIN", value: "other" }, internet)).toMatchObject({ status: 403, data: { lanOnly: true } });
    expect(read("lumen-bank.env")).toBe(BANK_ENV);
  });

  test("without a Face ID key the app is told to set one up, which needs a step-up and home", async () => {
    const { call, register, t } = await withSecrets({ registerKey: false });
    expect(await call("POST", "/api/secrets/reveal", { source: "lumen-bank.env", key: "BANK_SECRET_KEY" })).toMatchObject({ status: 403, data: { actionKey: true } });
    const key = await newActionKey();
    expect((await t.api("POST", "/api/auth/action-key", { publicKey: key.spki }, t.device.accessToken)).data).toMatchObject({ stepUp: true, reason: "secrets" });
    const viaInternet = await fetch(t.base + "/api/auth/action-key", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${await stepUp(t.api, t.device)}`, "cf-ray": "8a1b2c3d4e5f-CDG" },
      body: JSON.stringify({ publicKey: key.spki }),
    });
    expect(viaInternet.status).toBe(403);
    expect((await register()).status).toBe(200);
    expect(t.app.auth.events().filter((e) => e.type === "action_key" && e.ok).map((e) => e.detail)).toEqual(["registered"]);
    expect(t.pusher.sent.some((p) => JSON.stringify(p.payload).includes("Nouvelle clé Face ID"))).toBe(true);
  });

  test("unknown secrets, the gateway's file, files outside the folder and symlinks cannot be revealed", async () => {
    const { t, call } = await withSecrets();
    const reveal = async (source: string, key: string) => (await call("POST", "/api/secrets/reveal", { source, key })).status;
    expect(await reveal("lumen-bank.env", "BANK_IBAN")).toBe(404);
    expect(await reveal("nuo.env", "NUO_CF_ACCESS_CLIENT_SECRET")).toBe(404);
    expect(await reveal("../outside.env", "OUTSIDE_TOKEN")).toBe(404);
    expect(await reveal("linked.env", "OUTSIDE_TOKEN")).toBe(404);
    expect(await reveal("/etc/passwd", "root")).toBe(404);
    expect(await reveal("hcloud-token", "HCLOUD")).toBe(404);
    expect(await reveal("lumen-bank.env", "BANK;rm")).toBe(400);
    const failed = t.app.auth.events().filter((e) => e.type === "secret_reveal" && !e.ok);
    expect(failed.map((e) => e.detail)).toContain("lumen-bank.env · BANK_IBAN: secret not found");
  });

  test("create appends to the file, keeps it private and refuses duplicates, bad input and dangerous names", async () => {
    const { t, call, read, root } = await withSecrets();
    const create = (b: Record<string, unknown>) => call("POST", "/api/secrets/entries", b);
    const r = await create({ source: "lumen-bank.env", key: "BANK_ORGANIZATION_SLUG", value: "lumen-studio" });
    expect(r.status).toBe(201);
    expect(r.data.entries.map((e: any) => e.key)).toEqual(["BANK_LOGIN", "BANK_SECRET_KEY", "BANK_ORGANIZATION_SLUG"]);
    expect(JSON.stringify(r.data)).not.toContain("lumen-studio");
    expect(read("lumen-bank.env")).toBe(BANK_ENV + "BANK_ORGANIZATION_SLUG=lumen-studio\n");
    expect(statSync(join(root, "lumen-bank.env")).mode & 0o777).toBe(0o600);
    expect((await create({ source: "global.env", key: "CF_ZONE_ID", value: "zone 42" })).status).toBe(201);
    expect(read("global.env")).toBe(GLOBAL_ENV + "CF_ZONE_ID='zone 42'\n");
    expect((await create({ source: "lumen-bank.env", key: "BANK_LOGIN", value: "other" })).status).toBe(409);
    expect((await create({ source: "lumen-bank.env", key: "2FA_CODE", value: "1" })).status).toBe(400);
    expect((await create({ source: "lumen-bank.env", key: "BANK_NOTE", value: "line1\nline2" })).status).toBe(400);
    expect((await create({ source: "lumen-bank.env", key: "BANK_NOTE", value: "red \u001b[31mtext" })).status).toBe(400);
    expect((await create({ source: "lumen-bank.env", key: "BANK_NOTE", value: 42 })).status).toBe(400);
    expect((await create({ source: "missing.env", key: "BANK_NOTE", value: "a" })).status).toBe(404);
    for (const key of ["LD_PRELOAD", "NODE_OPTIONS", "BASH_ENV", "PATH", "NUO_PUBLIC_URL", "PYTHONSTARTUP", "GIT_SSH_COMMAND", "https_proxy"]) {
      expect((await create({ source: "global.env", key, value: "/tmp/evil.so" })).status).toBe(400);
    }
    expect(readdirSync(root).filter((f) => f.endsWith(".tmp"))).toEqual([]);
    const events = t.app.auth.events().filter((e) => e.type === "secret_create");
    expect(events.filter((e) => e.ok).map((e) => e.detail)).toEqual(["global.env · CF_ZONE_ID", "lumen-bank.env · BANK_ORGANIZATION_SLUG"]);
  });

  test("create can start a new file in the folder or an existing subfolder, never under the gateway's name", async () => {
    const { call, read, root } = await withSecrets();
    const create = (source: string) => call("POST", "/api/secrets/entries", { source, key: "STRIPE_SECRET_KEY", value: "sk_test_fixture_51Hq", createSource: true });
    const r = await create("projects/merci-maitresse.env");
    expect(r.status).toBe(201);
    expect(r.data).toMatchObject({ id: "projects/merci-maitresse.env", mode: "600", entries: [{ key: "STRIPE_SECRET_KEY", exported: false }] });
    expect(read("projects/merci-maitresse.env")).toBe("STRIPE_SECRET_KEY=sk_test_fixture_51Hq\n");
    expect((await create("../stripe.env")).status).toBe(400);
    expect((await create("billing/stripe.env")).status).toBe(400);
    expect((await create("stripe.txt")).status).toBe(400);
    expect((await create(".hidden.env")).status).toBe(400);
    expect((await create("projects/nuo.env")).status).toBe(400);
    expect(existsSync(join(root, "..", "stripe.env"))).toBe(false);
    expect((await create("projects/merci-maitresse.env")).status).toBe(409);
  });

  test("update rewrites one value and leaves every other line and the permissions as they were", async () => {
    const { t, call, read, root } = await withSecrets();
    chmodSync(join(root, "global.env"), 0o640);
    const update = (b: Record<string, unknown>) => call("PUT", "/api/secrets/entries", b);
    const r = await update({ source: "global.env", key: "CF_TOKEN", value: "cf_rotated_0b4e" });
    expect(r.status).toBe(200);
    expect(r.data).toMatchObject({ id: "global.env", mode: "640", insecure: true });
    expect(read("global.env")).toBe(GLOBAL_ENV.replace("cf_fixture_5d1c7a0e9b", "cf_rotated_0b4e"));
    expect(statSync(join(root, "global.env")).mode & 0o777).toBe(0o640);
    expect((await update({ source: "nuo.env", key: "NUO_BOOKING_OWNER", value: "Julie Martin" })).status).toBe(400);
    expect(read("nuo.env")).toBe(NUO_ENV);
    expect((await update({ source: "global.env", key: "CF_ACCOUNT_ID", value: "a" })).status).toBe(404);
    expect((await update({ source: "global.env", key: "CF_TOKEN" })).status).toBe(400);
    expect(t.app.auth.events().filter((e) => e.type === "secret_update" && e.ok).map((e) => e.detail)).toEqual(["global.env · CF_TOKEN"]);
    expect(JSON.stringify(t.app.auth.events(500))).not.toContain("cf_rotated_0b4e");
  });

  test("delete removes the line and is logged", async () => {
    const { t, call, read } = await withSecrets();
    const del = (q: string) => call("DELETE", `/api/secrets/entries?${q}`);
    const r = await del("source=projects%2Ffitness.env&key=WHOOP_CLIENT_SECRET");
    expect(r.status).toBe(200);
    expect(r.data.entries).toEqual([{ key: "WHOOP_CLIENT_ID", exported: false }]);
    expect(read("projects/fitness.env")).toBe("WHOOP_CLIENT_ID=whoop_fixture_client\n");
    expect((await del("source=projects%2Ffitness.env&key=WHOOP_CLIENT_SECRET")).status).toBe(404);
    expect((await del("source=..%2Foutside.env&key=OUTSIDE_TOKEN")).status).toBe(404);
    const events = t.app.auth.events().filter((e) => e.type === "secret_delete");
    expect(events.map((e) => [e.ok, e.detail])).toEqual([
      [false, "../outside.env · OUTSIDE_TOKEN: secret file not found"],
      [false, "projects/fitness.env · WHOOP_CLIENT_SECRET: secret not found"],
      [true, "projects/fitness.env · WHOOP_CLIENT_SECRET"],
    ]);
  });

  test("twenty operations in ten minutes, then the device waits", async () => {
    const { call } = await withSecrets();
    const body = { source: "global.env", key: "MUSIC_ASSISTANT_USER" };
    for (let i = 0; i < 20; i++) expect((await call("POST", "/api/secrets/reveal", body)).status).toBe(200);
    expect((await call("POST", "/api/secrets/reveal", body)).status).toBe(429);
  });

  test("extension tokens, the bots' local token and other profiles never reach the secrets", async () => {
    const { t, read } = await withSecrets();
    const before = read("lumen-bank.env");
    const routes: [string, string, unknown?][] = [
      ["GET", "/api/secrets"],
      ["POST", "/api/secrets/reveal", { source: "lumen-bank.env", key: "BANK_SECRET_KEY" }],
      ["POST", "/api/secrets/entries", { source: "lumen-bank.env", key: "BANK_IBAN", value: "FR76" }],
      ["PUT", "/api/secrets/entries", { source: "lumen-bank.env", key: "BANK_LOGIN", value: "other" }],
      ["DELETE", "/api/secrets/entries?source=lumen-bank.env&key=BANK_LOGIN"],
    ];
    for (const [m, p, b] of routes) {
      for (const scope of ["share", "widgets", "watch"]) expect((await t.api(m, p, b, t.device.extensionTokens[scope]!.token)).status).toBe(403);
      expect((await t.api(m, p, b, "local-secret")).status).toBe(401);
    }

    t.app.profiles.registry.create("alice", "Alice");
    await t.app.profiles.sync();
    const stack = t.app.profiles.stack("alice")!;
    const totpSecret = stack.auth.enrollTotp("Alice").secret;
    const alice = await pairDevice({ base: t.base, api: t.api, store: stack.store, totpSecret, now: Date.now(), name: "Alice iPhone", profile: "alice" });
    for (const [m, p, b] of routes) expect((await t.api(m, p, b, await stepUp(t.api, alice))).status).toBe(404);
    expect(read("lumen-bank.env")).toBe(before);
  });

  test("without a secrets folder configured the routes do not exist; a missing folder lists nothing", async () => {
    t = await startTestApp();
    expect((await t.api("GET", "/api/secrets")).status).toBe(404);
    await t.close();
    dir = mkdtempSync(join(tmpdir(), "nuo-secrets-"));
    t = await startTestApp({ secrets: { dir: join(dir, "absent") } });
    expect((await t.api("GET", "/api/secrets")).data).toMatchObject({ configured: false, sources: [] });
  });
});

describe("masking what the bots write", () => {
  const values = ["bank_fixture_k3y9Zt", "cfaccess_fixture_secret_77", "alex", "/home/alex/.secrets", "https://nuo.example.com"];

  test("known secret values are replaced, short words, paths and URLs are left alone", () => {
    const mask = new SecretMask(() => values);
    expect(mask.mask("La clé de la banque est bank_fixture_k3y9Zt, l'utilisateur alex.")).toBe(`La clé de la banque est ${MASKED}, l'utilisateur alex.`);
    expect(mask.mask("Voir https://nuo.example.com et /home/alex/.secrets")).toBe("Voir https://nuo.example.com et /home/alex/.secrets");
  });

  test("a value split across streamed chunks is still masked", () => {
    const stream = new SecretMask(() => values).stream();
    const out = ["Le secret est cfaccess_fix", "ture_secr", "et_77 voilà", " fin."].map((c) => stream.push(c)).join("") + stream.flush();
    expect(out).toBe(`Le secret est ${MASKED} voilà fin.`);
  });

  describe("streamed deltas never split an emoji", () => {
    const card =
      `::facts {"title":"Sortie Z2 45 min · aujourd'hui","items":[{"label":"Mise en route","value":"10 min · FC < 140"},` +
      `{"label":"Z2 facile","value":"30 min · FC < 145"},{"label":"Retour au calme","value":"5 min · FC < 140"},{"label":"Total","value":"45 min"}]}`;
    const answer = `La séance est envoyée sur ta montre 🏃\n\n${card}\n\nTu la trouves dans l'app Exercice, sous « Sortie Z2 45 min ».`;
    // The apps decode each event with JSONDecoder, which rejects a lone surrogate escape and drops the whole event.
    const shownByApp = (chunks: string[]) => {
      const stream = new SecretMask(() => values).stream();
      const deltas = [...chunks.map((c) => stream.push(c)), stream.flush()].filter(Boolean);
      return { deltas, shown: deltas.filter((d) => d.isWellFormed()).join("") };
    };

    test("the Apple Watch session answer keeps its card line", () => {
      // Chunk ends that put a delta boundary between the two halves of 🏃, given the 25 characters held back.
      const hold = "cfaccess_fixture_secret_77".length - 1;
      const ends = ["La séance est".length, answer.indexOf("🏃") + 1, answer.indexOf("Sortie")].map((at) => at + hold);
      const chunks = [0, ...ends].map((at, i) => answer.slice(at, ends[i] ?? answer.length));
      const { deltas, shown } = shownByApp(chunks);
      expect(deltas.every((d) => d.isWellFormed())).toBe(true);
      expect(shown).toBe(answer);
      expect(shown.split("\n")).toContain(card);
    });

    test("at every chunk size", () => {
      for (let size = 1; size <= 40; size++) {
        const chunks = Array.from({ length: Math.ceil(answer.length / size) }, (_, i) => answer.slice(i * size, (i + 1) * size));
        const { deltas, shown } = shownByApp(chunks);
        expect({ size, wellFormed: deltas.every((d) => d.isWellFormed()) }).toEqual({ size, wellFormed: true });
        expect(shown).toBe(answer);
      }
    });
  });
});
