import { dropFromEnv } from "./data/drop";
import { transcriptionFromEnv } from "./transcription/service";
import { join } from "node:path";
import { allRuntimes, getRuntime, runtimesFor } from "./agents/registry";
import { LAUNCHER, profileHost } from "./agents/host";
import { lightpandaMcp } from "./agents/types";
import { launcherSpawner } from "./scheduler/command";
import { prepareProfileRuntime } from "./profiles/runtime";
import type { AgentId } from "./protocol";
import { createApp } from "./api/app";
import { apnsConfigFromEnv } from "./push/apns";
import { loadAuthKey } from "./auth/keys";
import { CfAccessVerifier, cfAccessFromEnv } from "./auth/cfaccess";
import { networkConfigFromEnv } from "./auth/network";
import { networkInfoFromEnv } from "./auth/service";
import { defaultLayout, REPO_CONFIG_DIR, seedConfig } from "./paths";
import { calendarOptionsFromEnv } from "./calendar/service";
import { browserOptionsFromEnv } from "./browser/manager";
import { googleOAuthOptionsFromEnv } from "./google/oauth";
import { secretsOptionsFromEnv } from "./secrets/store";
import { trackerFromEnv } from "./scan/tracking";
import { launcherBrowser, PROFILE_BROWSER_DIR, profileCdpPort, userUid } from "./browser/profile";

const browserEnv = browserOptionsFromEnv();

const KNOWN = new Set<string>(["claude", "codex", "grok", "gemini"]);

const layout = defaultLayout();
for (const f of seedConfig(layout.config, REPO_CONFIG_DIR)) console.log(`[nuo] ${f} copied to ${layout.config}`);
console.log(`[nuo] home ${layout.home}, data ${layout.data}, config ${layout.config}`);

const profileRuntime = await prepareProfileRuntime().catch((e) => {
  console.warn(`[profiles] runtime for profile users not prepared: ${e?.message ?? e}`);
  return undefined;
});

const app = createApp({
  layout: { home: layout.nuo, config: process.env.NUO_CONFIG_DIR || undefined, data: process.env.NUO_DATA_DIR || undefined },
  port: Number(process.env.NUO_PORT) || 8790,
  hostname: process.env.NUO_HOST || undefined,
  runtimes: {
    get: (id) => (KNOWN.has(id) ? getRuntime(id as AgentId) : undefined),
    all: allRuntimes,
  },
  profileExecution: (profile, agentHome) => {
    const host = profileHost({ slug: profile.id, home: agentHome });
    const uid = userUid(`nuo-${profile.id}`);
    const cdpPort = uid === undefined ? undefined : profileCdpPort(uid);
    return {
      host,
      runtimes: runtimesFor(host),
      nuoMcp: profileRuntime?.nuoMcp,
      ...(profileRuntime?.lightpanda ? { browserMcp: lightpandaMcp(profileRuntime.lightpanda) } : {}),
      commandSpawner: launcherSpawner(`nuo-${profile.id}`, LAUNCHER),
      ...(cdpPort && profileRuntime ? { browser: { cdpPort, idleMs: browserEnv.idleMs, backend: launcherBrowser(host, { port: cdpPort, dir: join(agentHome, PROFILE_BROWSER_DIR) }) } } : {}),
    };
  },
  localToken: process.env.NUO_LOCAL_TOKEN || undefined,
  machineToken: process.env.NUO_MACHINE_TOKEN || undefined,
  authKey: loadAuthKey(),
  network: networkConfigFromEnv(),
  cfAccess: (() => {
    const cfg = cfAccessFromEnv();
    if (!cfg) console.warn("[nuo] NUO_CF_ACCESS_TEAM/AUD not set: internet requests are not checked for a Cloudflare Access token");
    return cfg ? new CfAccessVerifier(cfg) : undefined;
  })(),
  networkInfo: networkInfoFromEnv(),
  apns: apnsConfigFromEnv(),
  runner: { maxSessions: Number(process.env.NUO_MAX_SESSIONS) || 3 },
  calendar: calendarOptionsFromEnv(),
  browser: browserEnv,
  google: googleOAuthOptionsFromEnv(),
  secrets: secretsOptionsFromEnv(process.env, join(layout.config, "env")),
  scan: { tracker: trackerFromEnv(), products: { inciApiKey: process.env.NUO_INCIAPI_KEY || undefined } },
  transcription: transcriptionFromEnv(),
  data: { drop: dropFromEnv() },
});

if (!process.env.NUO_SHIP24_API_KEY && !process.env.NUO_SEVENTEENTRACK_API_KEY) console.warn("[scan] NUO_SHIP24_API_KEY and NUO_SEVENTEENTRACK_API_KEY not set: only La Poste parcels get an automatic status");
if (!app.auth.totpConfigured()) console.warn("[auth] 2FA is not set up: pairing is refused until `bun run src/cli.ts auth-totp-setup` runs");

void app.machine.list().catch((e) => console.warn(`[machine] discovery failed: ${e?.message ?? e}`));

console.log(`[nuo] listening on ${app.server.hostname}:${app.server.port}`);

let stopping = false;
for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, async () => {
    if (stopping) return;
    stopping = true;
    await app.stop().catch((e) => console.error(e));
    process.exit(0);
  });
}
