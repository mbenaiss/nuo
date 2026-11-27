import { randomBytes } from "node:crypto";
import { chmodSync, existsSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { moveClaudeProject } from "../agents/claude";
import { findBinary, type AgentHost } from "../agents/host";
import { lightpandaMcp, type McpServerSpec } from "../agents/types";
import { AuthService, type NetworkInfo } from "../auth/service";
import { FINANCE_COLLECTIONS, type PolicyLookups } from "../auth/policy";
import { ToolCatalog } from "../bots/catalog";
import { BotService } from "../bots/service";
import { BrowserManager, type BrowserOptions } from "../browser/manager";
import { PROFILE_BROWSER_DIR, writeAgentGatewayEnv } from "../browser/profile";
import { createCalendarServices, type CalendarOptions, type CalendarServices } from "../calendar/service";
import { createDataServices, type DataOptions, type DataServices } from "../data/service";
import { DeviceBridge, type BridgeOptions } from "../device/bridge";
import { GoogleAccounts } from "../google/accounts";
import type { GoogleOAuth } from "../google/oauth";
import type { MachineToolSource } from "../machine/discovery";
import type { Layout } from "../paths";
import type { Pusher } from "../push/apns";
import { recordingPusher } from "../push/recording";
import { Hub } from "../runner/hub";
import { DEFAULT_RUNNER_OPTIONS, Runner, type NuoEndpoint, type RunnerOptions } from "../runner/runner";
import { AgentDirectory, type Runtimes } from "../runner/runtimes";
import type { CommandSpawner } from "../scheduler/command";
import { Scheduler, type SchedulerOptions } from "../scheduler/scheduler";
import { SecretMask } from "../secrets/mask";
import { SecretStore, type SecretsOptions } from "../secrets/store";
import { createScanServices, type ScanOptions, type ScanServices } from "../scan/service";
import { TrackerChain } from "../scan/tracking";
import { Muscu, type MuscuOptions } from "../muscu/service";
import type { ProfileTranscriptions, TranscriptionService } from "../transcription/service";
import { LatencyRecorder } from "../metrics/latency";
import { WakeService, type WakeConfig } from "../hooks/service";
import { openDb } from "../store/db";
import { MediaStore } from "../store/media";
import { Store } from "../store/store";
import { OWNER, type Profile } from "./registry";

export interface StackOptions {
  profile: Profile;
  runtimes: Runtimes;
  pusher: Pusher;
  nonces: Map<string, number>;
  authKey?: Buffer;
  authNow?: () => number;
  networkInfo?: NetworkInfo;
  /** The owner's comes from NUO_LOCAL_TOKEN; other profiles get a random one per start, only known to their agents. */
  localToken?: string;
  runner?: Partial<RunnerOptions>;
  machine?: MachineToolSource;
  scheduler?: SchedulerOptions;
  /** Owner only: where Claude Code keeps its sessions (bot folder moves). */
  claudeConfigDir?: string;
  data?: DataOptions;
  /** Owner only: Google calendars and the public booking host stay the owner's. */
  calendar?: CalendarOptions;
  /** The owner's browser always exists; another profile gets its own only with these (run as its Linux user). */
  browser?: BrowserOptions;
  /** Who runs this profile's agent processes and command tasks. */
  host?: AgentHost;
  commandSpawner?: CommandSpawner;
  commandsAllowed?: () => boolean;
  /** The gateway's Google client; each profile keeps its own accounts and tokens. */
  google?: { oauth: GoogleOAuth; sharedElsewhere?: (email: string, profileId: string) => boolean };
  device?: BridgeOptions;
  /** Owner only: the secret files of the gateway's machine user. */
  secrets?: SecretsOptions;
  /** Parcel tracking keys and product bases; every profile shares the gateway's tracking keys. */
  scan?: Partial<ScanOptions>;
  transcription?: TranscriptionService;
  /** Owner only: the fitness coach's database and chrono folder behind the Muscu screen. */
  muscu?: MuscuOptions;
  /** Webhook URLs, the bots' mail domain and the owner's own addresses (src/hooks/). */
  wake?: WakeConfig;
}

const NO_MACHINE_TOOLS: MachineToolSource = { list: async () => [] };

/** Folders the profile's agent user must never read: its own database, documents and secrets are reached through the gateway. */
const PRIVATE_DIRS = ["data", "docs", "dashboards", "memory", "browser", "config"] as const;

/**
 * Every service of one profile, on its own databases and folders: nothing here can reach another profile's
 * data, which is what makes the isolation hold by construction (no profile filter to forget in a query).
 */
export class ProfileStack {
  readonly id: string;
  readonly owner: boolean;
  readonly store: Store;
  readonly catalog: ToolCatalog;
  readonly agents: AgentDirectory;
  readonly bots: BotService;
  readonly media: MediaStore;
  readonly hub = new Hub();
  readonly latency: LatencyRecorder;
  readonly machine: MachineToolSource;
  readonly runner: Runner;
  readonly auth: AuthService;
  readonly scheduler: Scheduler;
  readonly data: DataServices;
  readonly calendar: CalendarServices;
  readonly browser?: BrowserManager;
  readonly google?: GoogleAccounts;
  readonly device: DeviceBridge;
  readonly secrets?: SecretStore;
  readonly scan: ScanServices;
  readonly muscu?: Muscu;
  readonly transcription?: ProfileTranscriptions;
  readonly wake: WakeService;
  readonly localToken: string;
  readonly lookups: PolicyLookups;
  readonly host?: AgentHost;
  readonly pusher: Pusher;
  profile: Profile;

  constructor(readonly layout: Layout, private o: StackOptions) {
    this.profile = o.profile;
    this.id = o.profile.id;
    this.owner = this.id === OWNER;
    this.host = o.host;
    prepareTree(layout, this.owner);
    this.store = new Store(openDb(layout.data));
    this.pusher = recordingPusher(o.pusher, this.store, this.hub);
    this.latency = new LatencyRecorder(this.store);
    this.latency.attach(this.hub);
    this.catalog = new ToolCatalog(join(layout.config, "tools.json"));
    this.agents = new AgentDirectory(o.runtimes);
    if (this.owner || o.browser) {
      this.browser = new BrowserManager(o.browser, (r) => {
        const title = `Connexion requise sur ${r.site}`;
        const body = "Un agent attend que tu te connectes dans le navigateur de Nuo. Touche pour l'ouvrir, puis « Terminé ».";
        this.hub.broadcast({ type: "notification", title, body, ...(r.botId ? { botId: r.botId } : {}) });
        for (const dev of this.store.devices()) void this.pusher.send(dev, { title, body, category: "nuo.browser", url: "nuo://browser", destination: { kind: "browser" } }).catch(() => {});
      });
    }
    // The owner's comes from the host; another profile's from /srv/nuo/runtime (src/profiles/runtime.ts), through o.runner.
    const browserMcp = o.runner && "browserMcp" in o.runner ? o.runner.browserMcp : this.owner ? ownerBrowserMcp() : undefined;
    const lightpanda = browserMcp ? { lightpanda: true } : {};
    const browserAccess = !this.browser
      ? undefined
      : this.owner
        ? { cli: `bun run ${layout.nuo}/app/src/cli.ts`, endpoint: this.browser.endpoint, profileDir: join(layout.browser, "profile"), ...lightpanda }
        : { cli: "nuo-browser", endpoint: this.browser.endpoint, profileDir: join(layout.agentHome, PROFILE_BROWSER_DIR, "profile"), ...lightpanda };
    this.bots = new BotService(this.store, this.catalog, this.agents, layout, !this.owner, browserAccess);
    if (this.owner) {
      this.bots.seed(join(layout.config, "bots.seed.json"));
      this.bots.migrateFolders((from, to) => moveClaudeProject(from, to, o.claudeConfigDir));
    }
    void this.bots.refreshInstructions();
    this.media = new MediaStore(join(layout.data, "media"));
    this.device = new DeviceBridge(this.store, this.hub, this.pusher, o.device);
    this.machine = this.owner ? (o.machine ?? NO_MACHINE_TOOLS) : NO_MACHINE_TOOLS;
    const secretFiles = this.owner && o.secrets ? new SecretStore(o.secrets) : undefined;
    const mask = secretFiles ? new SecretMask(() => secretFiles.allValues()) : undefined;
    this.runner = new Runner(this.store, this.bots, this.catalog, o.runtimes, this.media, this.hub, this.pusher, { ...DEFAULT_RUNNER_OPTIONS, mask, ...o.runner, browserMcp }, this.machine);
    this.localToken = o.localToken ?? randomBytes(32).toString("base64url");
    this.auth = new AuthService(this.store, {
      localToken: this.localToken,
      authKey: o.authKey,
      now: o.authNow,
      network: o.networkInfo,
      alert: (title, body, except) => this.alert(title, body, except),
      profileId: this.id,
      nonces: o.nonces,
      relayRevoked: (deviceId) => void this.runner.cancelRelay(deviceId),
    });
    this.runner.onRelayRefused = (origin, tool, conversationId) =>
      this.auth.event("relay_refused", false, {
        deviceId: origin.deviceId,
        deviceName: this.store.devices().find((d) => d.id === origin.deviceId)?.name,
        detail: `${tool} · ${conversationId}`,
      });
    this.scheduler = new Scheduler(this.store, this.runner, this.pusher, {
      ...o.scheduler,
      ...(this.owner ? {} : { commandsAllowed: o.commandsAllowed ?? (() => false), commandSpawner: o.commandSpawner, commandHome: o.host?.home }),
    });
    this.bots.onPublished = (botId) => this.scheduler.syncProactive(botId);
    this.data = createDataServices(layout, this.pusher, () => this.store.devices(), this.owner ? o.data : { ...o.data, starterDashboards: false, ownerCollections: false });
    this.calendar = createCalendarServices(
      this.data.db,
      (title, body, bookingId) => {
        this.hub.broadcast({ type: "notification", title, body });
        for (const dev of this.store.devices()) void this.pusher.send(dev, { title, body, category: "nuo.booking", bookingId, destination: { kind: "booking", id: bookingId } }).catch(() => {});
      },
      this.owner ? o.calendar : { gogRunner: null, clock: o.calendar?.clock },
    );
    if (o.google) {
      const g = o.google;
      this.google = new GoogleAccounts({
        db: this.store.db,
        oauth: g.oauth,
        authKey: o.authKey,
        profileId: this.id,
        audit: (type, ok, info) => this.auth.event(type, ok, info),
        sharedElsewhere: (email) => g.sharedElsewhere?.(email, this.id) ?? false,
      });
    }
    this.wake = new WakeService(
      { profileId: this.id, owner: this.owner, store: this.store, runner: this.runner, pusher: this.pusher, google: this.google, audit: (type, ok, info) => this.auth.event(type, ok, info) },
      o.wake ?? {},
    );
    if (this.owner && o.secrets) this.secrets = new SecretStore(o.secrets);
    this.transcription = o.transcription?.at(join(layout.data, "transcriptions"));
    const photographed = (code: string) => `cosmetic.photo.${code}`;
    this.scan = createScanServices(this.data.db, this.pusher, () => this.store.devices(), {
      tracker: new TrackerChain([]),
      ...o.scan,
      products: {
        ...o.scan?.products,
        memory: {
          get: (code) => {
            const raw = this.store.getMeta(photographed(code));
            return raw ? JSON.parse(raw) : undefined;
          },
          set: (code, entry) => this.store.setMeta(photographed(code), JSON.stringify(entry)),
        },
      },
    });
    if (this.owner && o.muscu) this.muscu = new Muscu(o.muscu);
    this.lookups = {
      isFinanceCollection: (id) => FINANCE_COLLECTIONS.has(id) || !!this.data.db.query("SELECT 1 FROM _columns WHERE collection_id = ? AND type = 'money' LIMIT 1").get(id),
      isCommandTask: (id) => this.store.task(id)?.action.type === "command",
      publishGrantsAuto: (id) => {
        const bot = this.store.bot(id);
        return bot?.draft?.permissionPolicy === "auto" && bot.published?.config.permissionPolicy !== "auto";
      },
    };
  }

  /** Pushes to this profile's devices only. */
  alert(title: string, body: string, exceptDeviceId?: string) {
    for (const dev of this.store.devices()) if (dev.id !== exceptDeviceId) void this.pusher.send(dev, { title, body, category: "nuo.security", destination: { kind: "settings" } }).catch(() => {});
  }

  start(endpoint: NuoEndpoint) {
    this.runner.setNuoEndpoint({ url: endpoint.url, token: this.localToken });
    const resumed = this.runner.resumeInterrupted();
    if (resumed.length) console.log(`[runner] ${this.id}: resuming ${resumed.length} interrupted turn(s)`);
    if (this.browser && !this.owner) writeAgentGatewayEnv(this.layout.home, { url: endpoint.url, token: this.localToken });
    this.scheduler.start();
    this.data.start();
    this.scan.start();
    this.browser?.start();
  }

  /** See Runner.noteInterrupted: before any profile starts stopping. */
  noteInterrupted() {
    this.runner.noteInterrupted();
  }

  async stop() {
    this.runner.noteInterrupted();
    this.browser?.close();
    // The owner's browser is a systemd unit that outlives the gateway; a profile's is a child of the gateway.
    if (!this.owner) await this.browser?.stop();
    await this.scheduler.stop();
    await this.runner.shutdown();
    this.device.close();
    this.hub.closeAll();
    this.scan.stop();
    this.muscu?.close();
    this.data.stop();
    this.store.db.close();
  }
}

function prepareTree(layout: Layout, owner: boolean) {
  const fresh = !existsSync(layout.home);
  mkdirSync(layout.home, { recursive: true, mode: 0o700 });
  if (fresh) chmodSync(layout.home, 0o700);
  if (owner) return;
  // The tree may be shared with the profile's Linux user (group of the top folder): keep the gateway's own parts private.
  for (const d of PRIVATE_DIRS) {
    const p = d === "data" ? layout.data : d === "config" ? layout.config : join(layout.home, d);
    if (!existsSync(p)) mkdirSync(p, { recursive: true, mode: 0o700 });
    chmodSync(p, 0o700);
  }
  for (const d of ["bots", "instructions", "inbox"]) mkdirSync(join(layout.home, d), { recursive: true, mode: 0o755 });
}

/** Every bot reads pages through lightpanda's MCP server, allowed even to read-only bots as one of their own tools. */
function ownerBrowserMcp(): McpServerSpec | undefined {
  const bin = findBinary("lightpanda");
  return bin ? lightpandaMcp(bin) : undefined;
}
