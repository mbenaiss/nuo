import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, lstatSync, mkdirSync, readFileSync, readlinkSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { ChildProcess } from "node:child_process";
import { createPairCode } from "../src/auth/service";
import { base32Decode, totp } from "../src/auth/totp";
import { launcherArgs, profileHost, type AgentHost } from "../src/agents/host";
import { importDir } from "../src/data/importer";
import { Registry } from "../src/profiles/registry";
import { PAIR_FAILED } from "../src/profiles/set";
import { runtimesFrom } from "../src/runner/runtimes";
import { botConfig, FakeRuntime, newDeviceKey, pairDevice, Socket, startTestApp, stepUp, type TestApp, type TestDevice } from "./helpers";

const FIXTURE = join(import.meta.dir, "fixtures", "data-import", "databases");
let t: TestApp | undefined;
afterEach(async () => {
  await t?.close();
  t = undefined;
});

interface Other {
  device: TestDevice;
  token: string;
  totpSecret: string;
  runtime: FakeRuntime;
  api: (m: string, p: string, b?: unknown, token?: string) => Promise<{ status: number; data: any }>;
}

/** A host whose readiness the test controls; it never spawns anything (the fake runtime does not use it). */
function fakeHost(home: string, ready: { ok: boolean }): AgentHost {
  return {
    kind: "profile",
    home,
    env: () => undefined,
    which: () => null,
    spawn: () => {
      throw new Error("no spawn in tests");
    },
    scratch: () => home,
    ready: async () => (ready.ok ? { ok: true } : { ok: false, reason: "the Linux user nuo-alice is not set up" }),
  };
}

async function withAlice(o: { ready?: { ok: boolean }; browserMcp?: McpServerSpec } = {}): Promise<Other> {
  const ready = o.ready ?? { ok: true };
  const runtime = new FakeRuntime();
  t = await startTestApp({
    data: { autoStart: false },
    profileExecution: (_p, agentHome) => {
      const host = fakeHost(agentHome, ready);
      return {
        host,
        ...(o.browserMcp ? { browserMcp: o.browserMcp } : {}),
        runtimes: runtimesFrom([
          {
            id: runtime.id,
            name: runtime.name,
            status: async () => ((await host.ready()).ok ? runtime.status() : { available: false, authenticated: false }),
            models: () => runtime.models(),
            start: async (opts) => {
              const r = await host.ready();
              if (!r.ok) throw new Error(r.reason);
              return runtime.start(opts);
            },
          },
        ]),
      };
    },
  });
  t.app.profiles.registry.create("alice", "Alice");
  await t.app.profiles.sync();
  const stack = t.app.profiles.stack("alice")!;
  const totpSecret = stack.auth.enrollTotp("Alice").secret;
  const device = await pairDevice({ base: t.base, api: t.api, store: stack.store, totpSecret, now: Date.now(), name: "Alice iPhone", profile: "Alice" });
  const token = await stepUp(t.api, device);
  const api = t.api;
  return { device, token, totpSecret, runtime, api: (m, p, b, tok) => api(m, p, b, tok ?? token) };
}

describe("pairing with a profile", () => {
  test("the profile name is typed (slug or display name, any case); the grant says which profile", async () => {
    const alice = await withAlice();
    const me = await alice.api("GET", "/api/me");
    expect(me).toEqual({ status: 200, data: { deviceId: alice.device.id, profile: { id: "alice", name: "Alice" } } });
    expect((await t!.api("GET", "/api/me")).data.profile).toEqual({ id: "owner", name: "Propriétaire" });
    const stack = t!.app.profiles.stack("alice")!;
    const { spki } = await newDeviceKey();
    const r = await t!.api(
      "POST",
      "/api/pair",
      { profile: "  ALICE ", code: createPairCode(stack.store), totp: totp(base32Decode(alice.totpSecret), Date.now() + 30_000), deviceName: "Mac", publicKey: spki },
      "",
    );
    expect(r.status).toBe(200);
    expect(r.data.profile).toEqual({ id: "alice", name: "Alice" });
  });

  test("unknown profile, another profile's code, wrong code and a disabled profile get the same answer", async () => {
    const alice = await withAlice();
    const stack = t!.app.profiles.stack("alice")!;
    const body = async (profile: string, code: string, secret = alice.totpSecret) => ({ profile, code, totp: totp(base32Decode(secret), Date.now()), deviceName: "x", publicKey: (await newDeviceKey()).spki });
    const answers = [
      await t!.api("POST", "/api/pair", await body("bob", createPairCode(stack.store)), ""),
      await t!.api("POST", "/api/pair", await body("alice", createPairCode(t!.app.store)), ""),
      await t!.api("POST", "/api/pair", await body("alice", "000000"), ""),
      await t!.api("POST", "/api/pair", await body("owner", createPairCode(stack.store), t!.totpSecret), ""),
    ];
    t!.app.profiles.registry.setDisabled("alice", true);
    answers.push(await t!.api("POST", "/api/pair", await body("alice", createPairCode(stack.store)), ""));
    for (const a of answers) expect(a).toEqual({ status: 401, data: { error: PAIR_FAILED } });
  });

  test("every pairing answer takes the same minimum time", async () => {
    t = await startTestApp({ pairMinMs: 150 });
    const timed = async (profile: string) => {
      const started = performance.now();
      const r = await t!.api("POST", "/api/pair", { profile, code: createPairCode(t!.app.store), totp: "000000", publicKey: (await newDeviceKey()).spki }, "");
      return { status: r.status, ms: performance.now() - started };
    };
    for (const name of ["owner", "nobody"]) {
      const r = await timed(name);
      expect(r.status).toBe(401);
      expect(r.ms).toBeGreaterThanOrEqual(145);
    }
  });

  test("no route lists or reveals profiles", async () => {
    const alice = await withAlice();
    for (const path of ["/api/profiles", "/api/profiles/owner", "/api/admin/profiles"]) {
      expect((await alice.api("GET", path)).status).toBe(404);
      expect((await t!.api("GET", path)).status).toBe(404);
    }
    const devices = (await alice.api("GET", "/api/devices")).data as { id: string }[];
    expect(devices.map((d) => d.id)).toEqual([alice.device.id]);
  });
});

describe("isolation between profiles", () => {
  test("another profile's ids are 404 everywhere, lists only show one's own", async () => {
    const alice = await withAlice();
    const owner = t!;
    importDir(owner.app.data.db, FIXTURE, { filesDir: join(owner.dataDir, "files") });
    const bot = (await owner.api("POST", "/api/bots", { name: "Secret" })).data;
    await owner.api("PUT", `/api/bots/${bot.id}/draft`, botConfig({ name: "Secret", toolServers: [] }));
    await owner.api("POST", `/api/bots/${bot.id}/publish`, {});
    await owner.api("PUT", `/api/bots/${bot.id}/memory`, { content: "- secret fact" });
    const conv = (await owner.api("POST", "/api/conversations", { botId: bot.id })).data;
    const task = (await owner.api("POST", "/api/schedules", { botId: bot.id, title: "T", prompt: "p", schedule: { kind: "cron", expr: "0 9 * * *" } })).data;
    const reminder = (await owner.api("POST", "/api/reminders", { title: "Secret reminder" })).data;
    const place = (await owner.api("POST", "/api/places", { name: "Maison", lat: 48.85, lon: 2.35 })).data;
    const area = (await owner.api("POST", "/api/areas", { title: "Pro" })).data;
    const project = (await owner.api("POST", "/api/projects", { title: "P" })).data;
    await owner.api("POST", "/api/docs/file", { path: "secret.md", content: "# Secret\n" });
    const bookingType = (await owner.api("POST", "/api/booking/types", { slug: "cafe", kind: "proposal", title: "Café", durationMin: 30, location: { kind: "address", value: "x" }, candidateSlots: [{ start: "2030-10-21T08:00:00Z" }] })).data;
    const ownerDevices = (await owner.api("GET", "/api/devices")).data as { id: string }[];

    const notFound: [string, string, unknown?][] = [
      ["GET", `/api/bots/${bot.id}`],
      ["PUT", `/api/bots/${bot.id}/draft`, botConfig({ toolServers: [] })],
      ["DELETE", `/api/bots/${bot.id}/draft`],
      ["POST", `/api/bots/${bot.id}/publish`, {}],
      ["GET", `/api/bots/${bot.id}/versions`],
      ["POST", `/api/bots/${bot.id}/rollback`, { version: 1 }],
      ["GET", `/api/bots/${bot.id}/memory`],
      ["PUT", `/api/bots/${bot.id}/memory`, { content: "x" }],
      ["POST", `/api/bots/${bot.id}/memory`, { fact: "x" }],
      ["DELETE", `/api/bots/${bot.id}`],
      ["GET", `/api/conversations/${conv.id}`],
      ["GET", `/api/conversations/${conv.id}/messages`],
      ["POST", `/api/conversations/${conv.id}/prompt`, { text: "hi" }],
      ["DELETE", `/api/conversations/${conv.id}`],
      ["POST", "/api/live-activities", { conversationId: conv.id, pushToken: "ab".repeat(32), environment: "development" }],
      ["PATCH", `/api/schedules/${task.id}`, { title: "x" }],
      ["DELETE", `/api/schedules/${task.id}`],
      ["POST", `/api/schedules/${task.id}/run`, {}],
      ["GET", `/api/schedules/${task.id}/runs`],
      ["PATCH", `/api/reminders/${reminder.id}`, { title: "x" }],
      ["POST", `/api/reminders/${reminder.id}/done`, {}],
      ["POST", `/api/reminders/${reminder.id}/snooze`, { until: "2030-01-01T00:00:00Z" }],
      ["PATCH", `/api/places/${place.id}`, { name: "x" }],
      ["PATCH", `/api/areas/${area.id}`, { title: "x" }],
      ["PATCH", `/api/projects/${project.id}`, { title: "x" }],
      ["POST", `/api/projects/${project.id}/done`, {}],
      ["GET", "/api/docs/file?path=secret.md"],
      ["GET", "/api/dashboards/budget"],
      ["GET", `/api/booking/types/${bookingType.id}`],
      ["PATCH", `/api/booking/types/${bookingType.id}`, { title: "x" }],
      ["DELETE", `/api/devices/${ownerDevices[0]!.id}`],
    ];
    for (const [m, p, b] of notFound) {
      const r = await alice.api(m, p, b);
      expect({ route: `${m} ${p}`, status: r.status }).toEqual({ route: `${m} ${p}`, status: 404 });
    }
    expect(((await alice.api("POST", "/api/conversations", { botId: bot.id })).status)).toBe(404);
    expect(((await alice.api("POST", "/api/schedules", { botId: bot.id, title: "T", prompt: "p", schedule: { kind: "cron", expr: "0 9 * * *" } })).status)).toBe(400);

    const empty: string[] = ["/api/bots", "/api/conversations", "/api/schedules", "/api/reminders", "/api/places", "/api/areas", "/api/projects", "/api/dashboards", "/api/booking/types", "/api/tools", "/api/machine/tools"];
    for (const p of empty) expect({ p, data: (await alice.api("GET", p)).data }).toEqual({ p, data: [] });
    const ownerRows = (await owner.api("GET", "/api/data/collections/factures/rows")).data;
    expect(ownerRows.total).toBe(3);
    const aliceRows = await alice.api("GET", "/api/data/collections/factures/rows");
    expect(aliceRows.status).toBe(404);
    // Only the collection every profile gets (its own parcels); none of the owner's.
    expect(((await alice.api("GET", "/api/data/collections")).data as { id: string }[]).map((c) => c.id)).toEqual(["colis"]);
    expect((await alice.api("GET", `/api/data/collections/factures/rows/${ownerRows.rows[0].id}`)).status).toBe(404);
    expect(JSON.stringify((await alice.api("GET", "/api/docs/tree")).data)).not.toContain("secret");
    expect(JSON.stringify((await alice.api("GET", "/api/data/search?q=Secret")).data)).not.toContain("Secret");
    // And the owner still sees everything.
    expect(((await owner.api("GET", "/api/bots")).data as { id: string }[]).map((b) => b.id)).toContain(bot.id);
    expect((await owner.api("GET", `/api/bots/${bot.id}/memory`)).data.content).toContain("secret fact");
  });

  test("the owner cannot reach a profile's data through the API either", async () => {
    const alice = await withAlice();
    const bot = (await alice.api("POST", "/api/bots", { name: "Mien" })).data;
    expect(bot.draft.permissionPolicy).toBe("auto");
    expect((await t!.api("POST", "/api/bots", { name: "À moi" })).data.draft.permissionPolicy).toBe("ask");
    const reminder = (await alice.api("POST", "/api/reminders", { title: "À moi" })).data;
    expect((await t!.api("GET", `/api/bots/${bot.id}`)).status).toBe(404);
    expect((await t!.api("PATCH", `/api/reminders/${reminder.id}`, { title: "x" })).status).toBe(404);
    expect(((await t!.api("GET", "/api/reminders")).data as { id: string }[]).some((r) => r.id === reminder.id)).toBe(false);
  });

  test("socket events, snapshots and pushes stay within the profile", async () => {
    const alice = await withAlice();
    const owner = t!;
    await owner.api("POST", "/api/devices", { apnsToken: "aa".repeat(32), environment: "development" });
    await alice.api("POST", "/api/devices", { apnsToken: "bb".repeat(32), environment: "development" });
    const bot = (await owner.api("POST", "/api/bots", { name: "B" })).data;
    await owner.api("PUT", `/api/bots/${bot.id}/draft`, botConfig({ name: "B", toolServers: [] }));
    await owner.api("POST", `/api/bots/${bot.id}/publish`, {});
    const conv = (await owner.api("POST", "/api/conversations", { botId: bot.id })).data;

    const aliceSocket = await Socket.open({ ...owner, token: alice.token });
    await aliceSocket.next("turns.snapshot");
    // A prompt for another profile's conversation is refused like an unknown one.
    aliceSocket.send({ type: "prompt", conversationId: conv.id, text: "hi" });
    expect((await aliceSocket.next("error")).message).toContain("not found");
    owner.pusher.sent = [];
    const r = await owner.api("POST", `/api/conversations/${conv.id}/prompt`, { text: "hello" });
    expect(r.status).toBe(202);
    await owner.app.runner.idle?.();
    for (let i = 0; i < 50 && !owner.pusher.sent.length; i++) await Bun.sleep(20);
    expect(owner.pusher.sent.map((s) => s.device.apnsToken)).toEqual(["aa".repeat(32)]);
    expect(aliceSocket.events.filter((e) => e.type !== "error")).toEqual([]);

    // Notifications from a profile's local token reach that profile only.
    owner.pusher.sent = [];
    const stack = owner.app.profiles.stack("alice")!;
    const local = await fetch(`${owner.base}/api/notify`, { method: "POST", headers: { authorization: `Bearer ${stack.localToken}`, "content-type": "application/json" }, body: JSON.stringify({ title: "Hi", body: "Alice" }) });
    expect(local.status).toBe(204);
    expect((await aliceSocket.next("notification")).body).toBe("Alice");
    expect(owner.pusher.sent.map((s) => s.device.apnsToken)).toEqual(["bb".repeat(32)]);
    aliceSocket.close();
  });

  test("a profile's local token only reaches that profile's schedules and memory", async () => {
    const alice = await withAlice();
    const owner = t!;
    const bot = (await owner.api("POST", "/api/bots", { name: "B" })).data;
    await owner.api("POST", "/api/schedules", { botId: bot.id, title: "Owner task", prompt: "p", schedule: { kind: "cron", expr: "0 9 * * *" } });
    const local = owner.app.profiles.stack("alice")!.localToken;
    const call = (m: string, p: string, b?: unknown) =>
      fetch(`${owner.base}${p}`, { method: m, headers: { authorization: `Bearer ${local}`, "content-type": "application/json" }, ...(b ? { body: JSON.stringify(b) } : {}) }).then(async (r) => ({ status: r.status, data: await r.json().catch(() => undefined) }));
    expect((await call("GET", "/api/schedules")).data).toEqual([]);
    expect((await call("GET", `/api/bots/${bot.id}/memory`)).status).toBe(404);
    expect((await call("GET", "/api/browser")).status).toBe(401);
    expect((await call("GET", "/api/bots")).status).toBe(401);
    expect(alice.device.id).toBeString();
  });

  test("a disabled profile's tokens stop working and its sockets close", async () => {
    const alice = await withAlice();
    const socket = await Socket.open({ ...t!, token: alice.token });
    const closed = new Promise<number>((r) => (socket.ws.onclose = (e) => r(e.code)));
    t!.app.profiles.registry.setDisabled("alice", true);
    await t!.app.profiles.sync();
    expect(await closed).toBe(1001);
    expect((await alice.api("GET", "/api/bots")).status).toBe(401);
    t!.app.profiles.registry.setDisabled("alice", false);
    await t!.app.profiles.sync();
    expect((await alice.api("GET", "/api/bots")).status).toBe(200);
  });
});

describe("agents of a profile", () => {
  test("a profile that already exists at startup gets its agent host", async () => {
    let agentHome = "";
    t = await startTestApp({
      prepare: (home) => {
        mkdirSync(join(home, "profiles"), { recursive: true });
        const reg = new Registry(join(home, "profiles", "registry.db"));
        reg.create("alice", "Alice");
        reg.close();
      },
      profileExecution: (_p, home) => {
        agentHome = home;
        return { host: fakeHost(home, { ok: true }), runtimes: runtimesFrom([]) };
      },
    });
    expect(t.app.profiles.stack("alice")).toBeDefined();
    expect(agentHome).toContain("alice");
  });


  test("a profile's bots browse with the copy of lightpanda its user can run, never the owner's", async () => {
    const browserMcp = { name: "lightpanda", command: "/srv/nuo/runtime/bin/lightpanda", args: ["mcp"], env: {} };
    const alice = await withAlice({ browserMcp });
    const bot = (await alice.api("POST", "/api/bots", { name: "Aide" })).data;
    await alice.api("PUT", `/api/bots/${bot.id}/draft`, botConfig({ name: "Aide", toolServers: [], permissionPolicy: "readonly" }));
    await alice.api("POST", `/api/bots/${bot.id}/publish`, {});
    const conv = (await alice.api("POST", "/api/conversations", { botId: bot.id })).data;
    const socket = await Socket.open({ ...t!, token: alice.token });
    socket.send({ type: "prompt", conversationId: conv.id, text: "Quel temps à Lyon demain ?" });
    expect((await socket.next("message.end")).stopReason).toBe("end_turn");
    expect(alice.runtime.starts[0]!.mcpServers.find((s) => s.name === "lightpanda")).toEqual(browserMcp);
    socket.close();
  });

  test("no agent runs until the profile's Linux user is set up; then they run in the profile's tree", async () => {
    const ready = { ok: false };
    const alice = await withAlice({ ready });
    const agents = (await alice.api("GET", "/api/agents")).data;
    expect(agents[0]).toMatchObject({ available: false });
    const bot = (await alice.api("POST", "/api/bots", { name: "Aide" })).data;
    await alice.api("PUT", `/api/bots/${bot.id}/draft`, botConfig({ name: "Aide", toolServers: [] }));
    await alice.api("POST", `/api/bots/${bot.id}/publish`, {});
    const conv = (await alice.api("POST", "/api/conversations", { botId: bot.id })).data;
    const socket = await Socket.open({ ...t!, token: alice.token });
    socket.send({ type: "prompt", conversationId: conv.id, text: "hi" });
    const end = await socket.next("message.end");
    expect(end.stopReason).toBe("error");
    expect(alice.runtime.starts).toHaveLength(0);
    expect(t!.runtime.starts).toHaveLength(0);

    ready.ok = true;
    socket.send({ type: "prompt", conversationId: conv.id, text: "hi" });
    expect((await socket.next("message.end")).stopReason).toBe("end_turn");
    const opts = alice.runtime.starts[0]!;
    const tree = t!.app.profiles.stack("alice")!.layout.home;
    expect(opts.workdir).toBe(join(tree, "bots", bot.slug));
    expect(opts.workdir.startsWith(t!.profileHome)).toBe(false);
    expect((statSync(opts.workdir).mode & 0o7777).toString(8)).toBe("2777");
    expect(opts.attachmentsDir).toBe(join(tree, "inbox", bot.slug, ".nuo", "attachments"));
    // The profile's user runs the nuo MCP server: it reads the token from the tree, never from its command line.
    const nuo = opts.mcpServers.find((s) => s.name === "nuo")!;
    const stack = t!.app.profiles.stack("alice")!;
    expect(nuo.env.NUO_ENV_FILE).toBe(join(tree, "agent-env", "nuo.env"));
    expect(JSON.stringify(opts.mcpServers)).not.toContain(stack.localToken);
    expect(readFileSync(nuo.env.NUO_ENV_FILE!, "utf8")).toContain(`NUO_LOCAL_TOKEN=${stack.localToken}\n`);
    expect((statSync(nuo.env.NUO_ENV_FILE!).mode & 0o777).toString(8)).toBe("644");
    const instructions = readFileSync(join(tree, "instructions", `${bot.slug}.md`), "utf8");
    expect(instructions).not.toContain("data.db");
    expect(instructions).not.toContain("Navigateur partagé");
    expect(t!.runtime.starts).toHaveLength(0);
    socket.close();
  });

  test("the gateway's private folders of a profile tree are 0700", async () => {
    await withAlice();
    const tree = t!.app.profiles.stack("alice")!.layout.home;
    for (const d of ["data", "docs", "dashboards", "memory", "browser", "config"]) expect({ d, mode: (statSync(join(tree, d)).mode & 0o777).toString(8) }).toEqual({ d, mode: "700" });
    expect(existsSync(join(tree, "dashboards", "budget.json"))).toBe(false);
  });

  test("bots of a profile cannot use another folder, the owner's tools or command tasks", async () => {
    const alice = await withAlice();
    const r = await alice.api("POST", "/api/bots", { name: "X" });
    expect((await alice.api("PUT", `/api/bots/${r.data.id}/draft`, botConfig({ workdir: "/home", toolServers: [] }))).data.error).toContain("workdir is not available");
    expect((await alice.api("PUT", `/api/bots/${r.data.id}/draft`, botConfig({ toolServers: ["travel"] }))).data.error).toContain("unknown tool servers");
    await alice.api("PUT", `/api/bots/${r.data.id}/draft`, botConfig({ toolServers: [] }));
    await alice.api("POST", `/api/bots/${r.data.id}/publish`, {});
    const cmd = await alice.api("POST", "/api/schedules", { botId: r.data.id, title: "ls", action: { type: "command", command: "ls" }, schedule: { kind: "cron", expr: "0 9 * * *" } });
    expect(cmd).toEqual({ status: 403, data: { error: "command tasks are not enabled for this profile" } });
  });

  test("the launcher command line carries only allow-listed variables", () => {
    expect(launcherArgs("nuo-alice", "/usr/local/lib/nuo/nuo-agent", "/bin/codex-acp", ["--x"], { NO_BROWSER: "1", OPENAI_API_KEY: "sk-secret", TZ: "Europe/Paris" })).toEqual([
      "-n",
      "-u",
      "nuo-alice",
      "/usr/local/lib/nuo/nuo-agent",
      "NO_BROWSER=1",
      "TZ=Europe/Paris",
      "--",
      "/bin/codex-acp",
      "--x",
    ]);
    const spawned: { command: string; args: string[]; cwd?: string }[] = [];
    const host = profileHost({
      slug: "alice",
      home: "/srv/nuo/alice/home",
      check: async () => ({ ok: true }),
      spawner: (command, args, o) => {
        spawned.push({ command, args, cwd: o.cwd });
        return {} as ChildProcess;
      },
    });
    host.spawn("/x/claude-agent-acp", [], { cwd: "/srv/nuo/alice/bots/a", stdio: "pipe" });
    expect(spawned).toEqual([{ command: "/x/claude-agent-acp", args: [], cwd: "/srv/nuo/alice/bots/a" }]);
  });
});

describe("owner layout migration", () => {
  test("the old layout moves under profiles/owner with links left behind, once, and data survives", async () => {
    t = await startTestApp({
      prepare: (home) => {
        for (const d of ["data", "docs", "bots/coach", "instructions", "memory/coach", "dashboards", "browser/profile"]) mkdirSync(join(home, d), { recursive: true });
        writeFileSync(join(home, "memory/coach/MEMORY.md"), "- old fact\n");
        writeFileSync(join(home, "browser/profile/Cookies"), "c");
        mkdirSync(join(home, "claude", "projects", join(home, "bots", "coach").replace(/[^a-zA-Z0-9]/g, "-")), { recursive: true });
      },
    });
    const home = t.home;
    for (const d of ["data", "docs", "bots", "instructions", "memory", "dashboards", "browser"]) {
      expect(lstatSync(join(home, d)).isSymbolicLink()).toBe(true);
      expect(readlinkSync(join(home, d))).toBe(`profiles/owner/${d}`);
    }
    expect(readFileSync(join(home, "memory/coach/MEMORY.md"), "utf8")).toBe("- old fact\n");
    expect(readFileSync(join(t.profileHome, "browser/profile/Cookies"), "utf8")).toBe("c");
    expect(existsSync(join(home, "claude", "projects", join(t.profileHome, "bots", "coach").replace(/[^a-zA-Z0-9]/g, "-")))).toBe(true);
    expect((statSync(t.profileHome).mode & 0o777).toString(8)).toBe("700");
    // The paired device and its data are the owner's: nothing to redo after the migration.
    expect((await t.api("GET", "/api/me")).data.profile.id).toBe("owner");
  });
});
