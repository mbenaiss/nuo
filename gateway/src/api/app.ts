import type { TranscriptionService } from "../transcription/service";
import { createPusher, type ApnsConfig, type Pusher } from "../push/apns";
import { join } from "node:path";
import { globalLayout } from "../paths";
import type { MachineToolSource } from "../machine/discovery";
import type { RunnerOptions } from "../runner/runner";
import type { Runtimes } from "../runner/runtimes";
import type { SchedulerOptions } from "../scheduler/scheduler";
import type { DataOptions } from "../data/service";
import type { CalendarOptions } from "../calendar/service";
import type { NetworkInfo } from "../auth/service";
import type { NetworkConfig } from "../auth/network";
import type { BrowserOptions } from "../browser/manager";
import type { AgentHost } from "../agents/host";
import type { McpServerSpec } from "../agents/types";
import type { CommandSpawner } from "../scheduler/command";
import { migrateOwnerLayout } from "../profiles/migrate";
import { OWNER, type Profile } from "../profiles/registry";
import { ProfileSet } from "../profiles/set";
import { startServer } from "./server";
import { GoogleOAuth, type GoogleOAuthOptions } from "../google/oauth";
import type { BridgeOptions } from "../device/bridge";
import type { SecretsOptions } from "../secrets/store";
import type { ScanOptions } from "../scan/service";

/** How a profile other than the owner runs its agents (its Linux user, see src/agents/host.ts). */
export interface ProfileExecution {
  runtimes: Runtimes;
  host: AgentHost;
  /** The built-in `nuo` MCP server as the profile's user can start it. */
  nuoMcp?: { command: string; args: string[] };
  commandSpawner?: CommandSpawner;
  /** The profile's own browser (src/browser/profile.ts); without it the profile has none. */
  browser?: BrowserOptions;
  /** The lightpanda MCP server as the profile's user can start it. */
  browserMcp?: McpServerSpec;
}

export interface AppOptions {
  /** NUO_HOME and the overrides of the owner's data and config (NUO_DATA_DIR, NUO_CONFIG_DIR). */
  layout: { home: string; config?: string; data?: string };
  port: number;
  hostname?: string;
  /** The owner's agents. */
  runtimes: Runtimes;
  /** Agents of the other profiles; without it they have none. */
  profileExecution?: (profile: Profile, agentHome: string) => ProfileExecution;
  localToken?: string;
  /** NUO_MACHINE_TOKEN: lets another host of the home network hold a conversation with a bot. */
  machineToken?: string;
  /** Seals the TOTP secret (NUO_AUTH_KEY); pairing is refused without it. */
  authKey?: Buffer;
  /** Clock of token expiry and TOTP checks (tests). */
  authNow?: () => number;
  /** Minimum duration of a pairing answer (tests). */
  pairMinMs?: number;
  /** Which peers are Caddy and cloudflared (zones, real client IP). */
  network?: NetworkConfig;
  /** Cloudflare Access token check for internet requests (NUO_CF_ACCESS_TEAM and NUO_CF_ACCESS_AUD). */
  cfAccess?: { verify(token: string | null | undefined): Promise<boolean> };
  /** Public URL and Cloudflare Access service token handed to the app at pairing. */
  networkInfo?: NetworkInfo;
  apns?: ApnsConfig;
  pusher?: Pusher;
  runner?: Partial<RunnerOptions>;
  machine?: MachineToolSource;
  scheduler?: SchedulerOptions;
  /** Where Claude Code keeps the owner's sessions; defaults to CLAUDE_CONFIG_DIR or ~/.claude. */
  claudeConfigDir?: string;
  data?: DataOptions;
  calendar?: CalendarOptions;
  browser?: BrowserOptions;
  /** Google OAuth client (GOOGLE_OAUTH_*); without a client id and secret, connecting an account is refused. */
  google?: GoogleOAuthOptions;
  /** Delays of bot requests to the user's iPhone and Mac (tests). */
  device?: BridgeOptions;
  /** The owner's secret files (NUO_SECRETS_DIR, default ~/.secrets); without it the secrets routes do not exist. */
  secrets?: SecretsOptions;
  /** Parcel trackers (NUO_LAPOSTE_OKAPI_KEY, NUO_SHIP24_API_KEY, NUO_SEVENTEENTRACK_API_KEY) and the product bases' fetch (tests). */
  scan?: Partial<ScanOptions>;
  /** Speech to text behind `POST /api/transcriptions` (NUO_TRANSCRIPTION_PROVIDER), shared by every profile. */
  transcription?: TranscriptionService;
}

/** In the profile's tree: the owner's is the gateway user's alone, another profile's is shared with its Linux user only. */
const AGENT_ENV_DIR = "agent-env";

const NO_AGENTS: Runtimes = { get: () => undefined, all: () => [] };

export function createApp(o: AppOptions) {
  const global = globalLayout(o.layout.home, o.layout.config);
  const dataOverride = o.layout.data && o.layout.data !== `${o.layout.home}/data` ? o.layout.data : undefined;
  migrateOwnerLayout(global, { dataOverride, claudeConfigDir: o.claudeConfigDir });
  let profiles: ProfileSet;
  const googleOAuth = new GoogleOAuth(o.google);
  const google = {
    oauth: googleOAuth,
    sharedElsewhere: (email: string, self: string) => profiles.all().some((s) => s.id !== self && !!s.google?.has(email)),
  };
  const pusher =
    o.pusher ??
    createPusher(o.apns, (deviceId) => {
      for (const s of profiles.all()) s.store.setApnsToken(deviceId, null, null);
    });
  profiles = new ProfileSet({
    global,
    ownerOver: { data: dataOverride, config: o.layout.config },
    authNow: o.authNow,
    pairMinMs: o.pairMinMs,
    machineToken: o.machineToken,
    // Called while the set is being built: the layout comes as an argument, `profiles` is not assigned yet.
    stack: (p, layout) => {
      const shared = { pusher, authKey: o.authKey, authNow: o.authNow, networkInfo: o.networkInfo, scheduler: o.scheduler, data: o.data, google, device: o.device, scan: o.scan, transcription: o.transcription };
      if (p.id === OWNER) {
        return { ...shared, runtimes: o.runtimes, localToken: o.localToken, runner: { ...o.runner, agentEnv: { dir: join(layout.home, AGENT_ENV_DIR) } }, machine: o.machine, claudeConfigDir: o.claudeConfigDir, calendar: o.calendar, browser: o.browser, secrets: o.secrets };
      }
      const exec = o.profileExecution?.(p, layout.agentHome);
      return {
        ...shared,
        runtimes: exec?.runtimes ?? NO_AGENTS,
        host: exec?.host,
        runner: { ...o.runner, ...(exec?.nuoMcp ? { nuoMcp: { ...exec.nuoMcp, home: exec.host.home } } : {}), ...(exec ? { codexHome: `${exec.host.home}/.codex` } : {}), browserMcp: exec?.browserMcp, agentEnv: { dir: join(layout.home, AGENT_ENV_DIR), shared: true } },
        commandSpawner: exec?.commandSpawner,
        browser: exec?.browser,
        commandsAllowed: () => !!exec?.commandSpawner && !!profiles.registry.get(p.id)?.allowCommands,
        calendar: { clock: o.calendar?.clock },
      };
    },
  });
  const server = startServer({ port: o.port, hostname: o.hostname, profiles, network: o.network, cfAccess: o.cfAccess, google: googleOAuth });
  profiles.start({ url: `http://127.0.0.1:${server.port}`, token: "" });
  const owner = profiles.owner;

  const stop = async () => {
    await profiles.stop();
    await server.stop(true);
    pusher.close();
  };
  return {
    server,
    profiles,
    store: owner.store,
    bots: owner.bots,
    runner: owner.runner,
    hub: owner.hub,
    auth: owner.auth,
    machine: owner.machine,
    scheduler: owner.scheduler,
    data: owner.data,
    calendar: owner.calendar,
    browser: owner.browser,
    scan: owner.scan,
    stop,
  };
}
