import { afterEach, describe, expect, test } from "bun:test";
import type { Server } from "bun";
import { spawn, type ChildProcess } from "node:child_process";
import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import type { AgentHost } from "../src/agents/host";
import { addressToUrl, BrowserManager } from "../src/browser/manager";
import { launcherBrowser, profileCdpPort } from "../src/browser/profile";
import { effectiveInstructions } from "../src/bots/instructions";
import { runtimesFrom } from "../src/runner/runtimes";
import { botConfig, pairDevice, startTestApp, stepUp, type TestApp } from "./helpers";

/** Just enough of Chrome's DevTools endpoint: one tab, a screencast that paints a new frame after each ack, input recorded. */
class FakeChrome {
  calls: { method: string; params: any; sessionId?: string }[] = [];
  running = false;
  /** What `document.activeElement` looks like to the viewer's focus probe. */
  focusKind = "";
  private frames = 0;
  server: Server<undefined>;

  constructor() {
    this.server = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch: (req, server) => {
        const path = new URL(req.url).pathname;
        if (!this.running) return new Response("down", { status: 503 });
        if (path === "/json/version") return Response.json({ Browser: "Fake/1", webSocketDebuggerUrl: `ws://127.0.0.1:${this.port}/devtools/browser/x` });
        if (path === "/json/list") return Response.json([{ type: "page", url: "https://example.com/" }]);
        if (server.upgrade(req)) return undefined;
        return new Response("not found", { status: 404 });
      },
      websocket: {
        message: (ws, raw) => {
          const { id, method, params, sessionId } = JSON.parse(String(raw));
          this.calls.push({ method, params, sessionId });
          const reply = (result: unknown) => ws.send(JSON.stringify({ id, result, ...(sessionId ? { sessionId } : {}) }));
          const frame = () =>
            ws.send(JSON.stringify({ method: "Page.screencastFrame", sessionId: "S1", params: { data: Buffer.from(`jpeg-${++this.frames}`).toString("base64"), sessionId: this.frames, metadata: { deviceWidth: 1280, deviceHeight: 800 } } }));
          switch (method) {
            case "Target.getTargets":
              return reply({ targetInfos: [{ targetId: "T1", type: "page", title: "Example Domain", url: "https://example.com/" }] });
            case "Target.attachToTarget":
              return reply({ sessionId: "S1" });
            case "Target.createTarget":
              return reply({ targetId: "T2" });
            case "Page.getFrameTree":
              return reply({ frameTree: { frame: { id: "F1" } } });
            case "Page.getNavigationHistory":
              return reply({ currentIndex: 0, entries: [{ id: 1, url: "https://example.com/", title: "Example Domain" }] });
            case "Runtime.evaluate":
              return reply({ result: { value: this.focusKind } });
            case "Page.startScreencast":
              reply({});
              return frame();
            case "Page.screencastFrameAck":
              reply({});
              return frame();
            default:
              return reply({});
          }
        },
      },
    });
  }

  get port() {
    return this.server.port!;
  }

  called(method: string) {
    return this.calls.filter((c) => c.method === method);
  }

  stop() {
    this.server.stop(true);
  }
}

/** The app's side of a binary frame (`encodeFrame` in src/browser/viewer.ts). */
function readFrame(raw: ArrayBuffer): { type: string; kind: number; width: number; height: number; data: string } {
  const b = Buffer.from(raw);
  return { type: "frame", kind: b.readUInt8(0), width: b.readUInt16LE(2), height: b.readUInt16LE(4), data: b.subarray(8).toString() };
}

class Viewer {
  events: any[] = [];
  private waiters: { pred: (e: any) => boolean; resolve: (e: any) => void }[] = [];
  closed: Promise<number>;
  constructor(readonly ws: WebSocket) {
    ws.onmessage = (m) => {
      const e = typeof m.data === "string" ? JSON.parse(m.data) : readFrame(m.data as ArrayBuffer);
      this.events.push(e);
      this.waiters = this.waiters.filter((w) => (w.pred(e) ? (w.resolve(e), false) : true));
    };
    this.closed = new Promise((r) => (ws.onclose = (e) => r(e.code)));
  }
  static open(t: TestApp, token = t.token): Promise<Viewer> {
    const ws = new WebSocket(t.base.replace("http", "ws") + "/api/browser/ws", { headers: { authorization: `Bearer ${token}` } } as any);
    ws.binaryType = "arraybuffer";
    return new Promise((resolve, reject) => {
      ws.onopen = () => resolve(new Viewer(ws));
      ws.onerror = () => reject(new Error("upgrade refused"));
    });
  }
  next(pred: (e: any) => boolean, timeoutMs = 3000): Promise<any> {
    const seen = this.events.find(pred);
    if (seen) {
      this.events.splice(this.events.indexOf(seen), 1);
      return Promise.resolve(seen);
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("timeout")), timeoutMs);
      this.waiters.push({
        pred,
        resolve: (e) => {
          clearTimeout(timer);
          this.events.splice(this.events.indexOf(e), 1);
          resolve(e);
        },
      });
    });
  }
  send(e: unknown) {
    this.ws.send(JSON.stringify(e));
  }
}

let t: TestApp | undefined;
let chrome: FakeChrome | undefined;
let systemctl: string[] = [];

afterEach(async () => {
  await t?.close();
  chrome?.stop();
  t = undefined;
  chrome = undefined;
  systemctl = [];
});

async function setup(running = true) {
  chrome = new FakeChrome();
  chrome.running = running;
  const fake = chrome;
  t = await startTestApp({
    localToken: "local-secret",
    browser: {
      cdpPort: fake.port,
      systemctl: async (verb) => {
        systemctl.push(verb);
        fake.running = verb === "start";
      },
    },
  });
  return t;
}

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

describe("browser routes", () => {
  test("only the paired app reaches them: extension tokens are refused and the local token only gets the agent routes", async () => {
    const t = await setup();
    expect((await t.api("GET", "/api/browser")).data).toMatchObject({ running: true, viewers: 0, logins: [] });
    for (const scope of ["share", "widgets", "watch"]) {
      const token = t.device.extensionTokens[scope]!.token;
      expect((await t.api("GET", "/api/browser", undefined, token)).status).toBe(403);
      expect((await t.api("POST", "/api/browser/done", {}, token)).status).toBe(403);
      await expect(Viewer.open(t, token)).rejects.toThrow("upgrade refused");
    }
    expect((await t.api("GET", "/api/browser", undefined, "")).status).toBe(401);
    expect((await t.api("GET", "/api/browser", undefined, "local-secret")).status).toBe(200);
    expect((await t.api("POST", "/api/browser/stop", undefined, "local-secret")).status).toBe(404);
    expect((await t.api("POST", "/api/browser/done", {}, "local-secret")).status).toBe(404);
    await expect(Viewer.open(t, "local-secret")).rejects.toThrow("upgrade refused");
    // The agent routes are not app routes either.
    expect((await t.api("POST", "/api/browser/login-requests", { site: "LinkedIn" })).status).toBe(404);
  });

  test("the browser is started on demand and stopped from the app", async () => {
    const t = await setup(false);
    expect((await t.api("GET", "/api/browser")).data.running).toBe(false);
    expect((await t.api("POST", "/api/browser/start", undefined, "local-secret")).data).toEqual({ endpoint: `http://127.0.0.1:${chrome!.port}` });
    expect(systemctl).toEqual(["start"]);
    expect((await t.api("GET", "/api/browser")).data.running).toBe(true);
    expect((await t.api("POST", "/api/browser/stop")).status).toBe(204);
    expect(systemctl).toEqual(["start", "stop"]);
  });
});

describe("live view", () => {
  test("streams frames paced by the app's acks and forwards input to the active tab", async () => {
    const t = await setup(false);
    const v = await Viewer.open(t);
    expect(await v.next((e) => e.type === "status")).toEqual({ type: "status", phase: "starting" });
    const state = await v.next((e) => e.type === "state");
    expect(systemctl).toEqual(["start"]);
    expect(state).toMatchObject({ activeTabId: "T1", url: "https://example.com/", title: "Example Domain", canGoBack: false, tabs: [{ id: "T1", title: "Example Domain" }], logins: [] });
    // Binary frames: the JPEG travels as bytes, with its CSS size in the header.
    expect(await v.next((e) => e.type === "frame")).toEqual({ type: "frame", kind: 1, width: 1280, height: 800, data: "jpeg-1" });
    expect((await v.next((e) => e.type === "frame")).data).toBe("jpeg-2");
    // Two frames stay in flight: Chrome has painted a third, which waits for the app to catch up.
    await wait(150);
    expect(v.events.some((e) => e.type === "frame")).toBe(false);
    v.send({ type: "ack" });
    expect((await v.next((e) => e.type === "frame")).data).toBe("jpeg-3");
    expect(t.app.hub.connected(t.device.id)).toBe(false);

    v.send({ type: "mouse", action: "click", x: 0.5, y: 0.25 });
    v.send({ type: "text", text: "pa$$wörd" });
    v.send({ type: "key", key: "Enter" });
    v.send({ type: "navigate", url: "example.org" });
    v.send({ type: "navigate", url: "file:///etc/passwd" });
    expect((await v.next((e) => e.type === "error")).message).toBe("Adresse invalide");
    v.send({ type: "viewport", width: 390, height: 900 });
    await v.next((e) => e.type === "state" && e.viewport);
    const pressed = chrome!.called("Input.dispatchMouseEvent").find((c) => c.params.type === "mousePressed")!;
    expect(pressed).toMatchObject({ sessionId: "S1", params: { x: 640, y: 200, button: "left", clickCount: 1 } });
    expect(chrome!.called("Input.insertText")[0]).toMatchObject({ sessionId: "S1", params: { text: "pa$$wörd" } });
    expect(chrome!.called("Input.dispatchKeyEvent")[0]!.params).toMatchObject({ type: "keyDown", key: "Enter", text: "\r", windowsVirtualKeyCode: 13 });
    expect(chrome!.called("Page.navigate").map((c) => c.params.url)).toEqual(["https://example.org/"]);
    expect(chrome!.called("Emulation.setDeviceMetricsOverride").at(-1)!.params).toEqual({ width: 390, height: 800, deviceScaleFactor: 1, mobile: false });
    expect((await t.api("GET", "/api/browser")).data.viewers).toBe(1);

    v.ws.close();
    await v.closed;
    await wait(50);
    expect((await t.api("GET", "/api/browser")).data.viewers).toBe(0);
    expect(chrome!.called("Target.detachFromTarget").length).toBeGreaterThan(0);
  });

  test("the app's surface sizes the capture, zoom is real, and the page reports which field has the keyboard", async () => {
    const t = await setup();
    const v = await Viewer.open(t);
    await v.next((e) => e.type === "frame");
    const screencasts = () => chrome!.called("Page.startScreencast");
    expect(screencasts().at(-1)!.params).toMatchObject({ format: "jpeg", quality: 60, maxWidth: 1600, maxHeight: 1600 });

    // A phone paints a far smaller area than the browser's window, and a taller one than Chrome will ever send.
    v.send({ type: "surface", width: 780, height: 1680 });
    await wait(400);
    expect(chrome!.called("Page.stopScreencast")).toHaveLength(1);
    expect(screencasts().at(-1)!.params).toMatchObject({ maxWidth: 780, maxHeight: 1600 });

    // Barely different: not worth dropping frames to restart the capture.
    v.send({ type: "surface", width: 800, height: 1680 });
    await wait(400);
    expect(chrome!.called("Page.stopScreencast")).toHaveLength(1);

    v.send({ type: "zoom", factor: 2.5 });
    await v.next((e) => e.type === "state" && e.pageScale === 2.5);
    expect(chrome!.called("Emulation.setPageScaleFactor").at(-1)!.params).toEqual({ pageScaleFactor: 2.5 });
    v.send({ type: "zoom", factor: 99 });
    await v.next((e) => e.type === "state" && e.pageScale === 5);

    // Only the kind of field, so the app can mask the input; the value stays in the page.
    chrome!.focusKind = "password";
    v.send({ type: "mouse", action: "click", x: 0.5, y: 0.5 });
    expect((await v.next((e) => e.type === "state" && e.focus)).focus).toBe("password");
    chrome!.focusKind = "";
    v.send({ type: "key", key: "Escape" });
    await v.next((e) => e.type === "state" && e.focus === null);
    expect(chrome!.called("Runtime.evaluate").every((c) => !/\.value/.test(String(c.params.expression)))).toBe(true);
  });

  test("revoking the device closes its live view", async () => {
    const t = await setup();
    const other = await pairDevice({ base: t.base, api: t.api, store: t.app.store, totpSecret: t.totpSecret, now: Date.now(), name: "Mac" });
    const v = await Viewer.open(t, other.accessToken);
    await v.next((e) => e.type === "frame");
    expect((await t.api("DELETE", `/api/devices/${other.id}`)).status).toBe(204);
    expect(await v.closed).toBe(4401);
  });
});

describe("login requests", () => {
  test("an agent asks, the user is notified with a link to the browser and « Terminé » answers it", async () => {
    const t = await setup();
    const local = (m: string, p: string, b?: unknown) => t.api(m, p, b, "local-secret");
    expect((await local("POST", "/api/browser/login-requests", { site: "LinkedIn", url: "javascript:alert(1)" })).status).toBe(400);
    expect((await local("POST", "/api/browser/login-requests", {})).status).toBe(400);
    const r = await local("POST", "/api/browser/login-requests", { site: "LinkedIn", url: "https://www.linkedin.com/login" });
    expect(r.status).toBe(201);
    expect(r.data).toMatchObject({ site: "LinkedIn", url: "https://www.linkedin.com/login", status: "pending" });
    expect(t.pusher.sent.at(-1)!.payload).toMatchObject({ title: "Connexion requise sur LinkedIn", category: "nuo.browser", url: "nuo://browser", destination: { kind: "browser" } });

    // The live view opens on the login page, in a new tab since none is on linkedin.com.
    const v = await Viewer.open(t);
    expect((await v.next((e) => e.type === "state")).logins).toMatchObject([{ id: r.data.id, site: "LinkedIn" }]);
    expect(chrome!.called("Target.createTarget")[0]!.params).toEqual({ url: "https://www.linkedin.com/login" });
    expect((await t.api("GET", "/api/browser")).data.logins).toHaveLength(1);

    v.send({ type: "done" });
    expect(await v.next((e) => e.type === "done")).toEqual({ type: "done", completed: 1 });
    expect((await local("GET", `/api/browser/login-requests/${r.data.id}`)).data).toMatchObject({ status: "done" });
    expect((await t.api("GET", "/api/browser")).data.logins).toEqual([]);
    expect((await t.api("POST", "/api/browser/done", {})).data).toEqual({ completed: 0 });
    expect((await local("GET", "/api/browser/login-requests/missing")).status).toBe(404);
  });
});

describe("idle stop", () => {
  test("stops after the idle delay with no viewer, and page changes count as activity", async () => {
    chrome = new FakeChrome();
    chrome.running = true;
    const stops: string[] = [];
    const m = new BrowserManager({ cdpPort: chrome.port, idleMs: 60_000, systemctl: async (verb) => void stops.push(verb) });
    const t0 = Date.now();
    await m.sweep(t0 + 120_000);
    // First sweep sees the open pages for the first time: that is activity.
    expect(stops).toEqual([]);
    await m.sweep(t0 + 150_000);
    expect(stops).toEqual([]);
    m.viewerOpened();
    await m.sweep(t0 + 10 * 60_000);
    expect(stops).toEqual([]);
    m.viewerClosed();
    await m.sweep(Date.now() + 61_000);
    expect(stops).toEqual(["stop"]);
  });
});

describe("addresses", () => {
  test("the address bar accepts URLs, bare hosts and searches, never local schemes", () => {
    expect(addressToUrl("linkedin.com")).toBe("https://linkedin.com/");
    expect(addressToUrl("https://www.linkedin.com/feed/")).toBe("https://www.linkedin.com/feed/");
    expect(addressToUrl("localhost:3000")).toBeUndefined();
    expect(addressToUrl("météo paris")).toBe("https://duckduckgo.com/?q=m%C3%A9t%C3%A9o%20paris");
    expect(addressToUrl("file:///etc/passwd")).toBeUndefined();
    expect(addressToUrl("chrome://settings")).toBeUndefined();
    expect(addressToUrl("javascript:alert(1)")).toBeUndefined();
    expect(addressToUrl("about:blank")).toBe("about:blank");
  });
});

describe("bot instructions", () => {
  test("shell bots learn the shared browser and its rules, the others do not", () => {
    const paths = { home: "/r", db: "/r/data/data.db", docs: "/r/docs", dashboards: "/r/dashboards" };
    const browser = { cli: "bun run /r/app/src/cli.ts", endpoint: "http://127.0.0.1:9222", profileDir: "/r/browser/profile" };
    const auto = effectiveInstructions(botConfig({ permissionPolicy: "auto" }) as any, undefined, "", paths, browser);
    expect(auto).toContain("## Shared browser");
    expect(auto).toContain("bun run /r/app/src/cli.ts browser-login-needed");
    expect(auto).toContain("playwright-cli attach --cdp=http://127.0.0.1:9222");
    expect(auto).toContain("never solve a captcha");
    expect(auto).toContain("prefer WebFetch");
    const ask = effectiveInstructions(botConfig({ permissionPolicy: "ask" }) as any, undefined, "", paths, browser);
    expect(ask).not.toContain("Shared browser");
  });

  test("with lightpanda on the host, shell bots read public pages with its tools instead of Chrome", () => {
    const browser = { cli: "bun run /r/app/src/cli.ts", endpoint: "http://127.0.0.1:9222", profileDir: "/r/browser/profile", lightpanda: true };
    const text = effectiveInstructions(botConfig({ permissionPolicy: "auto" }) as any, undefined, "", undefined, browser);
    expect(text).toContain("use the lightpanda tools (`goto` then `markdown`");
    expect(text).not.toContain("prefer WebFetch");
  });
});

/** A profile user that is always ready; spawns go through `spawner` (the launcher in production). */
function fakeHost(home: string, spawner: (command: string, args: string[]) => ChildProcess = () => spawn("sleep", ["30"]), ready = { ok: true }): AgentHost {
  return {
    kind: "profile",
    home,
    env: () => undefined,
    which: () => null,
    spawn: (command, args) => spawner(command, args),
    scratch: () => home,
    ready: async () => (ready.ok ? { ok: true } : { ok: false, reason: "the Linux user nuo-alice is not set up" }),
  };
}

describe("profile browsers", () => {
  let alice: FakeChrome | undefined;
  afterEach(() => {
    alice?.stop();
    alice = undefined;
  });

  async function withAlice() {
    chrome = new FakeChrome();
    chrome.running = true;
    const aliceChrome = (alice = new FakeChrome());
    const backend: string[] = [];
    const app = (t = await startTestApp({
      localToken: "local-secret",
      browser: { cdpPort: chrome.port, systemctl: async (verb) => void systemctl.push(verb) },
      profileExecution: (_p, agentHome) => ({
        host: fakeHost(agentHome),
        runtimes: runtimesFrom([]),
        browser: {
          cdpPort: aliceChrome.port,
          backend: {
            start: async () => void (backend.push("start"), (aliceChrome.running = true)),
            stop: async () => void (backend.push("stop"), (aliceChrome.running = false)),
          },
        },
      }),
    }));
    app.app.profiles.registry.create("alice", "Alice");
    await app.app.profiles.sync();
    const stack = app.app.profiles.stack("alice")!;
    const totpSecret = stack.auth.enrollTotp("Alice").secret;
    const device = await pairDevice({ base: app.base, api: app.api, store: stack.store, totpSecret, now: Date.now(), name: "Alice Mac", profile: "Alice" });
    const token = await stepUp(app.api, device);
    return { t: app, stack, device, token, backend, aliceChrome };
  }

  test("each profile reaches its own browser: status, start, live view and login requests", async () => {
    const { t, stack, device, token, backend, aliceChrome } = await withAlice();
    const aliceLocal = (m: string, p: string, b?: unknown) => t.api(m, p, b, stack.localToken);
    expect((await t.api("GET", "/api/browser", undefined, token)).data).toMatchObject({ running: false, endpoint: `http://127.0.0.1:${aliceChrome.port}` });
    expect((await t.api("GET", "/api/browser")).data).toMatchObject({ running: true, endpoint: `http://127.0.0.1:${chrome!.port}` });

    expect((await aliceLocal("POST", "/api/browser/start")).data).toEqual({ endpoint: `http://127.0.0.1:${aliceChrome.port}` });
    expect(backend).toEqual(["start"]);
    expect(systemctl).toEqual([]);

    const r = await aliceLocal("POST", "/api/browser/login-requests", { site: "LinkedIn" });
    expect(r.status).toBe(201);
    expect(t.pusher.sent.at(-1)).toMatchObject({ device: { id: device.id }, payload: { title: "Connexion requise sur LinkedIn", url: "nuo://browser" } });
    expect((await t.api("GET", "/api/browser")).data.logins).toEqual([]);
    expect((await t.api("GET", "/api/browser", undefined, token)).data.logins).toHaveLength(1);
    expect((await t.api("GET", `/api/browser/login-requests/${r.data.id}`, undefined, "local-secret")).status).toBe(404);

    const v = await Viewer.open(t, token);
    await v.next((e) => e.type === "frame");
    expect(aliceChrome.called("Page.startScreencast").length).toBe(1);
    expect(chrome!.called("Page.startScreencast")).toEqual([]);
    v.send({ type: "done" });
    expect(await v.next((e) => e.type === "done")).toEqual({ type: "done", completed: 1 });
    v.ws.close();
    await v.closed;

    // A disabled profile's browser is stopped with its stack; the owner's unit is left alone.
    t.app.profiles.registry.setDisabled("alice", true);
    await t.app.profiles.sync();
    expect(backend).toEqual(["start", "stop"]);
    expect(systemctl).toEqual([]);
  });

  test("the profile's agents get their endpoint, `nuo-browser` and a token file only their user can read", async () => {
    const { t, stack, aliceChrome } = await withAlice();
    const env = join(stack.layout.home, "gateway.env");
    expect(readFileSync(env, "utf8")).toBe(`NUO_URL=${t.base}\nNUO_LOCAL_TOKEN=${stack.localToken}\n`);
    expect((statSync(env).mode & 0o777).toString(8)).toBe("644");
    const bot = await stack.bots.create("Aide");
    const browser = stack.bots.workspace(bot.id).browser!;
    expect(browser).toEqual({ cli: "nuo-browser", endpoint: `http://127.0.0.1:${aliceChrome.port}`, profileDir: join(stack.layout.agentHome, ".browser", "profile") });
    const text = effectiveInstructions(botConfig({ permissionPolicy: "auto" }) as any, undefined, "", undefined, browser);
    expect(text).toContain("`nuo-browser browser-start`");
    expect(text).toContain(`playwright-cli attach --cdp=http://127.0.0.1:${aliceChrome.port}`);
    expect(text).not.toContain("9222");
    const ownerBot = await t.app.profiles.owner.bots.create("O");
    expect(t.app.profiles.owner.bots.workspace(ownerBot.id).browser).toMatchObject({ endpoint: `http://127.0.0.1:${chrome!.port}` });
  });
});

describe("profile browser process", () => {
  test("ports come from the profile user's uid: distinct users, distinct ports", () => {
    expect(profileCdpPort(999)).toBe(29999);
    expect(profileCdpPort(998)).toBe(29998);
    expect(profileCdpPort(0)).toBeUndefined();
    expect(profileCdpPort(40000)).toBeUndefined();
  });

  test("runs the browser script through the profile's host, once, and stops its process group", async () => {
    const spawned: { command: string; args: string[]; child: ChildProcess }[] = [];
    const ready = { ok: false };
    const host = fakeHost(
      "/srv/nuo/alice/home",
      (command, args) => {
        const child = spawn("sleep", ["30"]);
        spawned.push({ command, args, child });
        return child;
      },
      ready,
    );
    const b = launcherBrowser(host, { port: 29999, dir: "/srv/nuo/alice/home/.browser" });
    await expect(b.start()).rejects.toThrow("nuo-alice is not set up");
    ready.ok = true;
    await b.start();
    await b.start();
    expect(spawned.map(({ command, args }) => ({ command, args }))).toEqual([
      { command: "/srv/nuo/runtime/bin/nuo-chrome", args: ["--port", "29999", "--dir", "/srv/nuo/alice/home/.browser"] },
    ]);
    await b.stop();
    expect(spawned[0]!.child.signalCode).toBe("SIGTERM");
    await b.start();
    expect(spawned).toHaveLength(2);
    await b.stop();
  });
});
