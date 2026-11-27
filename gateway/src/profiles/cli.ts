import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, realpathSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import QRCode from "qrcode";
import { agentsEnvFile, LAUNCHER, readEnvFile } from "../agents/host";
import { loadAuthKey } from "../auth/keys";
import { AuthService, createPairCode, PAIR_CODE_TTL_MS } from "../auth/service";
import type { BotConfig } from "../protocol";
import { defaultGlobal, profileLayout, treeLayout, type Layout } from "../paths";
import { openDb } from "../store/db";
import { Store } from "../store/store";
import { OWNER, PROFILE_SLUG, Registry } from "./registry";

export const PROFILE_USAGE = `  bun run src/cli.ts profile-create <slug> --name "<name>"
    Creates a profile (its own databases, documents, bots…) and prints, once, the 2FA enrolment (QR code, URI,
    recovery codes) to hand to that person. The app pairs with the profile name, a pair code and that 2FA code.
  bun run src/cli.ts profile-list
  bun run src/cli.ts profile-disable <slug> | profile-enable <slug>
    A disabled profile cannot pair, its devices are refused and its agents and tasks stop (within 5 s).
  bun run src/cli.ts profile-rename <slug> "<name>"
  bun run src/cli.ts profile-commands <slug> on|off
    Lets the profile create command tasks (they run as its Linux user nuo-<slug>). Off by default.
  bun run src/cli.ts profile-delete <slug> --yes
    Disables the profile and moves its whole tree to ~/nuo/archive/profiles/<slug>-<date> (nothing is erased).
  bun run src/cli.ts pair-code [<slug>]
    One-time pairing code for that profile (default: owner), valid 10 minutes.
  bun run src/cli.ts profile-login <slug> claude|codex|gemini|grok
    Runs the agent CLI's login as nuo-<slug> in this terminal: the person signs in with their own account.
  bun run src/cli.ts profile-env <slug> <VARIABLE>
    Reads a value on stdin (not echoed) and stores it in the profile's agents.env (e.g. ANTHROPIC_API_KEY).
  bun run src/cli.ts bot-import <slug> <bot.json>
    Creates and publishes a bot in that profile from a config file (name, agent, model, instructions…), so a
    profile can start with its bots before its device is paired.
  Devices, 2FA and audit of a profile: the auth-* commands with --profile <slug>.`;

function die(msg: string): never {
  console.error(msg);
  process.exit(1);
}

/** The layout of a profile as the gateway resolves it (real path once moved to /srv/nuo by the OS setup). */
export function profileLayoutFor(slug: string): Layout {
  const g = defaultGlobal();
  const layout = profileLayout(g, slug, slug === OWNER ? { data: process.env.NUO_DATA_DIR, config: process.env.NUO_CONFIG_DIR } : {});
  if (slug === OWNER || !existsSync(layout.home)) return layout;
  const real = realpathSync(layout.home);
  return treeLayout(real, layout.nuo, join(real, "config"));
}

function registry(): Registry {
  return new Registry(defaultGlobal().registry);
}

function withStore<T>(slug: string, fn: (store: Store) => T): T {
  const layout = profileLayoutFor(slug);
  if (!existsSync(layout.data)) mkdirSync(layout.data, { recursive: true, mode: 0o700 });
  const db = openDb(layout.data);
  try {
    return fn(new Store(db));
  } finally {
    db.close();
  }
}

const osUserReady = (slug: string) => spawnSync("getent", ["passwd", `nuo-${slug}`]).status === 0;

async function create(argv: string[]) {
  const slug = argv[0] ?? "";
  const i = argv.indexOf("--name");
  const name = i >= 0 ? argv[i + 1] : undefined;
  if (!PROFILE_SLUG.test(slug) || !name) die(PROFILE_USAGE);
  const reg = registry();
  try {
    reg.create(slug, name);
  } catch (e) {
    die(`error: ${(e as Error).message}`);
  } finally {
    reg.close();
  }
  const layout = profileLayoutFor(slug);
  mkdirSync(layout.home, { recursive: true, mode: 0o700 });
  for (const d of [layout.data, layout.config, layout.docs, layout.dashboards, layout.memory, layout.browser]) mkdirSync(d, { recursive: true, mode: 0o700 });
  const authKey = loadAuthKey({ create: true });
  const r = withStore(slug, (store) => new AuthService(store, { authKey, profileId: slug }).enrollTotp(`Nuo ${name}`));
  console.log(`Profile "${slug}" (${name}) created in ${layout.home}.\n`);
  console.log(await QRCode.toString(r.uri, { type: "terminal", small: true, errorCorrectionLevel: "M" }));
  console.log(`2FA for ${name}: scan the QR code with their authenticator app, or add it by hand:\n  ${r.uri}\n`);
  console.log("Recovery codes (each works once instead of a 2FA code; give them to that person, they are not shown again):");
  for (const c of r.recoveryCodes) console.log(`  ${c}`);
  console.log(`\nNext steps (docs/profiles.md):
  1. sudo bash ~/nuo/os/profile-os-setup.sh ${slug}      (Linux user nuo-${slug}; without it the profile has no agent)
  2. systemctl --user restart nuo-gateway
  3. bun run src/cli.ts profile-login ${slug} claude        (the person signs in with their own account)
  4. bun run src/cli.ts pair-code ${slug}                   (then they pair with the profile name "${slug}")`);
}

function list() {
  const reg = registry();
  try {
    for (const p of reg.list()) {
      const devices = existsSync(join(profileLayoutFor(p.id).data, "nuo.db")) ? withStore(p.id, (s) => s.devices().length) : 0;
      const os = p.id === OWNER ? "gateway user" : osUserReady(p.id) ? `nuo-${p.id}` : "no Linux user";
      console.log(`${p.id.padEnd(16)} ${p.name.padEnd(20)} ${p.disabledAt ? "DISABLED" : "enabled "}  ${String(devices).padStart(2)} device(s)  ${os}${p.allowCommands ? "  commands on" : ""}  created ${p.createdAt}`);
    }
  } finally {
    reg.close();
  }
}

function edit(slug: string | undefined, fn: (reg: Registry, slug: string) => void) {
  const reg = registry();
  try {
    if (!slug || !reg.get(slug)) die(`unknown profile "${slug ?? ""}"`);
    fn(reg, slug);
  } catch (e) {
    die(`error: ${(e as Error).message}`);
  } finally {
    reg.close();
  }
}

async function remove(argv: string[]) {
  const slug = argv[0];
  if (!argv.includes("--yes")) die("profile-delete moves the whole profile to the archive: add --yes to confirm");
  if (slug === OWNER) die("the owner profile cannot be deleted");
  edit(slug, (reg, s) => reg.setDisabled(s, true));
  console.log("profile disabled; waiting for the gateway to close it…");
  await Bun.sleep(7000);
  const g = defaultGlobal();
  const link = join(g.profiles, slug!);
  const dest = join(g.archive, "profiles", `${slug}-${new Date().toISOString().replace(/[:.]/g, "-")}`);
  mkdirSync(dest, { recursive: true, mode: 0o700 });
  chmodSync(dest, 0o700);
  if (existsSync(link)) {
    const isLink = lstatSync(link).isSymbolicLink();
    const tree = realpathSync(link);
    // A tree moved to /srv/nuo by the OS setup is emptied into the archive; /srv/nuo/<slug> goes with the OS user.
    for (const entry of readdirSync(tree)) renameSync(join(tree, entry), join(dest, entry));
    if (isLink) rmSync(link);
    else rmSync(tree, { recursive: false, force: true });
  }
  edit(slug, (reg, s) => reg.remove(s));
  console.log(`archived in ${dest}`);
  if (osUserReady(slug!)) console.log(`Remove the Linux user too: sudo bash ~/nuo/os/profile-os-remove.sh ${slug}`);
}

function login(argv: string[]) {
  const [slug, agent] = argv;
  if (!slug || slug === OWNER || !agent) die(PROFILE_USAGE);
  const commands: Record<string, string[]> = {
    claude: ["claude"],
    codex: ["codex", "login", "--device-auth"],
    gemini: ["agy"],
    grok: ["grok", "login"],
  };
  const cmd = commands[agent];
  if (!cmd) die(`unknown agent "${agent}" (claude, codex, gemini or grok)`);
  if (!osUserReady(slug)) die(`nuo-${slug} does not exist: run sudo bash ~/nuo/os/profile-os-setup.sh ${slug} first`);
  if (agent === "claude") console.log("In Claude Code, type /login and follow the link with that person's account, then /exit.");
  if (agent === "gemini") console.log("Choose the Google sign-in, open the link with that person's account and paste the code back, then /quit.");
  const r = spawnSync("/usr/bin/sudo", ["-u", `nuo-${slug}`, LAUNCHER, "NO_BROWSER=true", `TERM=${process.env.TERM ?? "xterm-256color"}`, "--", ...cmd], { stdio: "inherit", cwd: "/" });
  process.exit(r.status ?? 1);
}

async function setEnv(argv: string[]) {
  const [slug, name] = argv;
  if (!slug || slug === OWNER || !name || !/^[A-Z_][A-Z0-9_]*$/.test(name)) die(PROFILE_USAGE);
  const home = profileLayoutFor(slug).agentHome;
  if (!existsSync(home)) die(`${home} is missing: run sudo bash ~/nuo/os/profile-os-setup.sh ${slug} first`);
  process.stderr.write(`${name} (input hidden, Enter to finish): `);
  spawnSync("stty", ["-echo"], { stdio: "inherit" });
  const value = (await new Response(Bun.stdin.stream()).text()).split("\n")[0]!.trim();
  spawnSync("stty", ["echo"], { stdio: "inherit" });
  process.stderr.write("\n");
  if (!value) die("empty value: nothing changed");
  const file = agentsEnvFile(home);
  mkdirSync(join(home, ".config", "nuo"), { recursive: true, mode: 0o755 });
  const vars = { ...readEnvFile(file), [name]: value };
  // The profile's home is only reachable by its user and the gateway: the file must be readable by that user.
  writeFileSync(file, Object.entries(vars).map(([k, v]) => `${k}=${v}\n`).join(""), { mode: 0o644 });
  chmodSync(file, 0o644);
  console.log(`${name} saved for ${slug} (value not shown)`);
}

function importBot(argv: string[]) {
  const [slug, file] = argv;
  if (!file || !existsSync(file)) die(PROFILE_USAGE);
  edit(slug, () => {});
  const c = JSON.parse(readFileSync(file, "utf8")) as Partial<BotConfig>;
  const name = c.name?.trim() ?? "";
  if (name.length < 1 || name.length > 40 || !c.agent || !c.model || typeof c.instructions !== "string") {
    die("the file needs name (1-40 characters), agent, model and instructions");
  }
  if (slug !== OWNER && c.workdir) die("workdir is not available for this profile");
  const config: BotConfig = {
    emoji: "🤖",
    color: "#E0EEFF",
    description: "",
    permissionPolicy: "ask",
    ...c,
    name,
    agent: c.agent,
    model: c.model,
    instructions: c.instructions,
    toolServers: c.toolServers ?? [],
  };
  const version = withStore(slug!, (store) => store.publish(store.createBot(undefined, name), config, "Import", true));
  console.log(`Bot "${name}" published in ${slug} (v${version})`);
}

export async function profileCommand(cmd: string, argv: string[]): Promise<void> {
  switch (cmd) {
    case "profile-create":
      return create(argv);
    case "profile-list":
      return list();
    case "profile-disable":
    case "profile-enable":
      edit(argv[0], (reg, s) => reg.setDisabled(s, cmd === "profile-disable"));
      console.log(`${argv[0]} ${cmd === "profile-disable" ? "disabled" : "enabled"} (the gateway applies it within 5 s)`);
      return;
    case "profile-rename":
      edit(argv[0], (reg, s) => reg.rename(s, argv[1] ?? ""));
      return;
    case "profile-commands":
      if (argv[1] !== "on" && argv[1] !== "off") die(PROFILE_USAGE);
      edit(argv[0], (reg, s) => reg.setAllowCommands(s, argv[1] === "on"));
      return;
    case "profile-delete":
      return remove(argv);
    case "profile-login":
      return login(argv);
    case "profile-env":
      return setEnv(argv);
    case "bot-import":
      return importBot(argv);
    case "pair-code": {
      const slug = argv[0] ?? OWNER;
      edit(slug, () => {});
      const code = withStore(slug, (store) => createPairCode(store));
      console.log(`Pairing code for profile "${slug}": ${code.slice(0, 3)} ${code.slice(3)}  (valid ${PAIR_CODE_TTL_MS / 60000} minutes, single use)`);
      return;
    }
    default:
      die(PROFILE_USAGE);
  }
}
