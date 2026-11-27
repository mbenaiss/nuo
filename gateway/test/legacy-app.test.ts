import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { actionMessage, signedMessage } from "../src/auth/service";
import { acceptedAppNames, appNameFor, legacyAppPrefix } from "../src/compat/app-names";
import { apnsBodyFor, type PushPayload } from "../src/push/apns";
import type { Device } from "../src/store/store";
import type { SpeechToText, TranscriptionRequest } from "../src/transcription/service";
import { newDeviceKey, pairDevice, stepUp, type TestApp, type TestDevice } from "./helpers";
import { LOCAL, withRelay } from "./relay-setup";

/** A fictional earlier name: what the apps installed before a rename still put in shared identifiers. */
const LEGACY = "halo";
const ENV = "NUO_LEGACY_APP_PREFIX";
const BANK_ENV = "BANK_LOGIN=lumen-studio-4821\nBANK_SECRET_KEY=bank_fixture_k3y9Zt\n";
const PARCEL_LINK = "nuo://data/colis/colis-6A21894";
const CLIENT = { clientId: "client-123.apps.googleusercontent.com", clientSecret: "secret-du-client-oauth", redirectUri: "https://rdv.example.test/oauth/google/callback" };

class FakeStt implements SpeechToText {
  readonly provider = "fake-scribe";
  readonly model = "fake-model-1";
  async transcribe(_r: TranscriptionRequest) {
    return { text: "Ajoute acheter du pain et appeler Julie Martin demain à 9 h", language: "fr" };
  }
  async warm() {}
}

const saved = process.env[ENV];
let app: TestApp | undefined;
let dir: string | undefined;
afterEach(async () => {
  await app?.close();
  app = undefined;
  if (dir) rmSync(dir, { recursive: true, force: true });
  dir = undefined;
  if (saved === undefined) delete process.env[ENV];
  else process.env[ENV] = saved;
});

/** The gateway with the owner's iPhone paired, a relay key, a Face ID action key and a secrets folder. */
async function gateway() {
  dir = mkdtempSync(join(tmpdir(), "nuo-legacy-"));
  const secrets = join(dir, ".secrets");
  mkdirSync(secrets, { mode: 0o700 });
  writeFileSync(join(secrets, "lumen-bank.env"), BANK_ENV);
  chmodSync(join(secrets, "lumen-bank.env"), 0o600);
  const r = await withRelay({ transcription: new FakeStt(), extra: { secrets: { dir: secrets, home: dir }, google: CLIENT } });
  app = r.app;
  const t = r.app;
  const actionKey = await newDeviceKey();
  expect((await t.api("POST", "/api/auth/action-key", { publicKey: actionKey.spki }, await stepUp(t.api, t.device))).status).toBe(200);

  const nonce = async () => (await t.api("GET", "/api/auth/challenge", undefined, "")).data.nonce as string;
  /** Token refresh as an app of `name` signs it. */
  const refresh = async (name: string, device: TestDevice = t.device, n?: string) => {
    const c = n ?? (await nonce());
    return t.api("POST", "/api/auth/refresh", { deviceId: device.id, nonce: c, signature: await device.sign(signedMessage("refresh", device.id, c, name)) }, "");
  };
  const stepUpAs = async (name: string) => {
    const c = await nonce();
    return t.api("POST", "/api/auth/step-up", { nonce: c, signature: await t.device.sign(signedMessage("step-up", t.device.id, c, name)) }, t.device.accessToken);
  };
  const relayToken = async (name: string) => {
    const c = await nonce();
    return t.api("POST", "/api/auth/relay-token", { deviceId: t.device.id, nonce: c, signature: await r.key.sign(signedMessage("relay", t.device.id, c, name)) }, "");
  };
  /** Reveals a secret as the app does: headers and signed message both in `name`. */
  const reveal = async (name: string, o: { headerName?: string; signer?: (m: string) => Promise<string> } = {}) => {
    const text = JSON.stringify({ source: "lumen-bank.env", key: "BANK_SECRET_KEY" });
    const c = await nonce();
    const signature = await (o.signer ?? actionKey.sign)(actionMessage(t.device.id, c, "POST", "/api/secrets/reveal", text, name));
    const h = o.headerName ?? name;
    const res = await fetch(t.base + "/api/secrets/reveal", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${t.device.accessToken}`, [`x-${h}-action-nonce`]: c, [`x-${h}-action-signature`]: signature },
      body: text,
    });
    return { status: res.status, data: await res.json() };
  };
  const notify = (url: string) => {
    t.pusher.sent.length = 0;
    return fetch(t.base + "/api/notify", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${LOCAL}` },
      body: JSON.stringify({ title: "Colis en livraison", body: "Le colis 6A21894 arrive aujourd'hui", url }),
    }).then((res) => res.status);
  };
  /** The APNs body each device of the profile was sent for the last notification. */
  const lastPushes = () => t.pusher.sent.map((s) => ({ device: s.device.id, body: apnsBodyFor(s.device, s.payload) }));
  /** A dictation passed on by the watch, through the relay, naming a job with the `name` header. */
  const relayDictation = async (name: string) => {
    const f = new FormData();
    f.set("audio", new Blob([new Uint8Array([0, 0, 0, 24, 102, 116, 121, 112])], { type: "audio/mp4" }), "watch-ask.m4a");
    f.set("language", "fr");
    f.set("seconds", "4.2");
    return (await fetch(t.base + "/api/transcriptions", { method: "POST", headers: { authorization: `Bearer ${r.relay}`, [`x-${name}-transcription-id`]: "3f6c2a1e-8d4b-4f0a-9c1e-5a7b2d9e4c10" }, body: f })).status;
  };
  /** Where the gateway sends the browser back once Google answers a connection started by this device. */
  const googleReturn = async () => {
    const begun = await t.api("POST", "/api/google/connect", { services: ["gmail"] }, t.device.accessToken);
    expect(begun.status).toBe(200);
    const state = new URL(begun.data.url).searchParams.get("state")!;
    const res = await fetch(`${t.base}/oauth/google/callback?state=${state}&error=access_denied`, { redirect: "manual" });
    return res.headers.get("location");
  };
  const naming = (id = t.device.id) => t.app.store.appNaming(id);
  /** As the migration leaves a device paired before the gateway kept track of the name. */
  const pairedBefore = (id = t.device.id) => t.app.store.db.query("UPDATE devices SET app_naming = NULL WHERE id = ?").run(id);
  return { t, refresh, stepUpAs, relayToken, reveal, notify, lastPushes, relayDictation, googleReturn, naming, pairedBefore, nonce };
}

describe("NUO_LEGACY_APP_PREFIX", () => {
  test("is read only when set, and only as a plain name other than the current one", () => {
    expect(legacyAppPrefix({})).toBeUndefined();
    expect(legacyAppPrefix({ [ENV]: "  " })).toBeUndefined();
    expect(legacyAppPrefix({ [ENV]: LEGACY })).toBe(LEGACY);
    expect(acceptedAppNames({ [ENV]: LEGACY })).toEqual(["nuo", LEGACY]);
    for (const bad of ["nuo", "Halo", "ha-lo", "halo:v1", "halo.answer", "h", "x".repeat(33)]) expect(() => legacyAppPrefix({ [ENV]: bad })).toThrow();
  });

  test("names a device only while it is set: a device of unknown age is an earlier app", () => {
    expect(appNameFor(undefined, {})).toBe("nuo");
    expect(appNameFor("legacy", {})).toBe("nuo");
    expect(appNameFor(undefined, { [ENV]: LEGACY })).toBe(LEGACY);
    expect(appNameFor("legacy", { [ENV]: LEGACY })).toBe(LEGACY);
    expect(appNameFor("current", { [ENV]: LEGACY })).toBe("nuo");
  });
});

describe("without NUO_LEGACY_APP_PREFIX, nothing of the earlier name is accepted or sent", () => {
  test("signatures, action headers, the transcription header and links in the earlier name are refused", async () => {
    delete process.env[ENV];
    const g = await gateway();
    expect(await g.refresh(LEGACY)).toMatchObject({ status: 401, data: { error: "invalid signature" } });
    expect(await g.stepUpAs(LEGACY)).toMatchObject({ status: 401, data: { error: "invalid signature" } });
    expect(await g.relayToken(LEGACY)).toMatchObject({ status: 401, data: { error: "invalid signature" } });
    expect(await g.reveal(LEGACY)).toMatchObject({ status: 403, data: { error: "unknown or expired nonce" } });
    expect(await g.notify("halo://data/colis/colis-6A21894")).toBe(400);
    // Unread, so it does not even count as naming a job: the dictation goes through like any other.
    expect(await g.relayDictation(LEGACY)).toBe(200);
    expect((await g.refresh("nuo")).status).toBe(200);
    expect(await g.reveal("nuo")).toEqual({ status: 200, data: { value: "bank_fixture_k3y9Zt" } });
  });

  test("a device paired before still gets the current category, links and Google return", async () => {
    delete process.env[ENV];
    const g = await gateway();
    g.pairedBefore();
    expect(g.naming()).toBeUndefined();
    expect(await g.notify(PARCEL_LINK)).toBe(204);
    expect(g.lastPushes()).toEqual([
      { device: g.t.device.id, body: expect.objectContaining({ aps: expect.objectContaining({ category: "nuo.alert" }), url: PARCEL_LINK, destination: { kind: "link", url: PARCEL_LINK } }) },
    ]);
    expect(await g.googleReturn()).toBe("nuo://google/connected?error=denied");
  });
});

describe("with NUO_LEGACY_APP_PREFIX, an app of the earlier name keeps working", () => {
  test("its token refresh, Face ID step-up and relay token are accepted, and the device is answered in its name", async () => {
    process.env[ENV] = LEGACY;
    const g = await gateway();
    expect(g.naming()).toBe("current");
    const refreshed = await g.refresh(LEGACY);
    expect(refreshed.status).toBe(200);
    expect(typeof refreshed.data.accessToken).toBe("string");
    expect(g.naming()).toBe("legacy");
    expect((await g.stepUpAs(LEGACY)).data.stepUpUntil).toBeDefined();
    expect((await g.relayToken(LEGACY)).status).toBe(200);
    expect(g.naming()).toBe("legacy");
    // Updated, the app signs in the current name and is answered in it from then on.
    expect((await g.refresh("nuo")).status).toBe(200);
    expect(g.naming()).toBe("current");
  });

  test("its Face ID confirmation of a secret is accepted with the earlier headers", async () => {
    process.env[ENV] = LEGACY;
    const g = await gateway();
    expect(await g.reveal(LEGACY)).toEqual({ status: 200, data: { value: "bank_fixture_k3y9Zt" } });
    expect(await g.reveal("nuo")).toEqual({ status: 200, data: { value: "bank_fixture_k3y9Zt" } });
    expect(g.naming()).toBe("current");
  });

  test("pushes carry the category and links each device's app knows", async () => {
    process.env[ENV] = LEGACY;
    const g = await gateway();
    const ipad = await pairDevice({ base: g.t.base, api: g.t.api, store: g.t.app.store, totpSecret: g.t.totpSecret, now: Date.now(), name: "iPad de Julie" });
    g.pairedBefore();
    expect(await g.notify("halo://data/colis/colis-6A21894")).toBe(204);
    const byDevice = Object.fromEntries(g.lastPushes().map((p) => [p.device, p.body]));
    expect(byDevice[g.t.device.id]).toMatchObject({ aps: { category: "halo.alert" }, url: "halo://data/colis/colis-6A21894", destination: { kind: "link", url: "halo://data/colis/colis-6A21894" } });
    expect(byDevice[ipad.id]).toMatchObject({ aps: { category: "nuo.alert" }, url: PARCEL_LINK, destination: { kind: "link", url: PARCEL_LINK } });
    // Stored in the current name: the alert history and the updated apps never see the earlier one.
    expect(g.t.app.store.alerts()[0]).toMatchObject({ destination: { kind: "link", url: PARCEL_LINK } });
  });

  test("the categories that decide a notification's buttons follow the device", async () => {
    process.env[ENV] = LEGACY;
    const payload = (over: Partial<PushPayload>): PushPayload => ({ title: "Coach", body: "Séance validée", destination: { kind: "home" }, ...over });
    const old: Device = { id: "iphone-2024", name: "iPhone de Julie" };
    const updated: Device = { ...old, appNaming: "current" };
    const answer = payload({ botId: "coach", conversationId: "conv-muscu-18", destination: { kind: "conversation", id: "conv-muscu-18", botId: "coach" } });
    expect((apnsBodyFor(old, answer).aps as any).category).toBe("halo.answer");
    expect((apnsBodyFor(updated, answer).aps as any).category).toBe("nuo.answer");
    for (const category of ["nuo.reminder", "nuo.browser", "nuo.booking", "nuo.security", "nuo.parcel"]) {
      expect((apnsBodyFor(old, payload({ category })).aps as any).category).toBe(category.replace("nuo.", "halo."));
      expect((apnsBodyFor(updated, payload({ category })).aps as any).category).toBe(category);
    }
    const browser = payload({ category: "nuo.browser", url: "nuo://browser", destination: { kind: "browser" } });
    expect(apnsBodyFor(old, browser)).toMatchObject({ url: "halo://browser", destination: { kind: "browser" } });
    expect(apnsBodyFor({ ...old, appNaming: "legacy" }, payload({ url: "https://www.laposte.fr/outils/suivre-vos-envois" })).url).toBe("https://www.laposte.fr/outils/suivre-vos-envois");
  });

  test("the Google sign-in sheet of an earlier app is closed with a link in its name", async () => {
    process.env[ENV] = LEGACY;
    const g = await gateway();
    expect(await g.googleReturn()).toBe("nuo://google/connected?error=denied");
    expect((await g.refresh(LEGACY)).status).toBe(200);
    expect(await g.googleReturn()).toBe("halo://google/connected?error=denied");
  });

  test("its transcription header is read, and the relay still cannot name a job with it", async () => {
    process.env[ENV] = LEGACY;
    const g = await gateway();
    expect(await g.relayDictation(LEGACY)).toBe(403);
    expect(await g.relayDictation("nuo")).toBe(403);
  });
});

describe("with NUO_LEGACY_APP_PREFIX, the checks stay as strict", () => {
  test("a nonce serves once whatever the name: a signature in the other name cannot replay it", async () => {
    process.env[ENV] = LEGACY;
    const g = await gateway();
    const c = await g.nonce();
    expect((await g.refresh(LEGACY, g.t.device, c)).status).toBe(200);
    expect(await g.refresh("nuo", g.t.device, c)).toMatchObject({ status: 401, data: { error: "unknown or expired nonce" } });
    expect(await g.refresh(LEGACY, g.t.device, c)).toMatchObject({ status: 401, data: { error: "unknown or expired nonce" } });
  });

  test("a signature for another purpose, another key or another name is refused", async () => {
    process.env[ENV] = LEGACY;
    const g = await gateway();
    const t = g.t;
    const step = await g.nonce();
    const stepUpSigned = await t.device.sign(signedMessage("step-up", t.device.id, step, LEGACY));
    expect(await t.api("POST", "/api/auth/refresh", { deviceId: t.device.id, nonce: step, signature: stepUpSigned }, "")).toMatchObject({ status: 401, data: { error: "invalid signature" } });
    const c = await g.nonce();
    const otherName = await t.device.sign(signedMessage("refresh", t.device.id, c, "aura"));
    expect(await t.api("POST", "/api/auth/refresh", { deviceId: t.device.id, nonce: c, signature: otherName }, "")).toMatchObject({ status: 401, data: { error: "invalid signature" } });
    const stranger = await newDeviceKey();
    const c2 = await g.nonce();
    expect(await t.api("POST", "/api/auth/refresh", { deviceId: t.device.id, nonce: c2, signature: await stranger.sign(signedMessage("refresh", t.device.id, c2, LEGACY)) }, "")).toMatchObject({
      status: 401,
      data: { error: "invalid signature" },
    });
    // The device key signing an action in the earlier name is not the Face ID key.
    expect(await g.reveal(LEGACY, { signer: t.device.sign })).toMatchObject({ status: 403, data: { error: "invalid action signature" } });
    expect(await g.reveal(LEGACY, { headerName: "aura" })).toMatchObject({ status: 403, data: { error: "unknown or expired nonce" } });
    expect(g.naming()).toBe("current");
  });
});
