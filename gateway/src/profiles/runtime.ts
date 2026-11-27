import { accessSync, constants, copyFileSync, chmodSync, existsSync, lstatSync, mkdirSync, readlinkSync, realpathSync, renameSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { findBinary, PROFILE_RUNTIME_DIR } from "../agents/host";
import { NUO_MCP_SERVER } from "../runner/runner";
import { AGENT_GATEWAY_ENV } from "../browser/profile";

const BROWSER_SCRIPT = fileURLToPath(new URL("../../scripts/nuo-chrome.sh", import.meta.url));
const BROWSER_CLI = fileURLToPath(new URL("../browser/agent-cli.ts", import.meta.url));

export interface ProfileRuntime {
  /** The built-in `nuo` MCP server as a profile's user starts it. */
  nuoMcp: { command: string; args: string[] };
  /** A copy of the gateway user's lightpanda, for the profile's bots to browse. */
  lightpanda?: string;
}

function copyIfChanged(src: string, dst: string) {
  const s = statSync(src);
  if (existsSync(dst) && statSync(dst).size === s.size && statSync(dst).mtimeMs >= s.mtimeMs) return;
  const tmp = `${dst}.tmp-${process.pid}`;
  copyFileSync(src, tmp);
  chmodSync(tmp, 0o755);
  renameSync(tmp, dst);
}

function link(target: string, path: string) {
  try {
    if (lstatSync(path).isSymbolicLink() && readlinkSync(path) === target) return;
    rmSync(path, { force: true });
  } catch {
    // missing
  }
  symlinkSync(target, path);
}

/**
 * Profile users cannot reach anything in the gateway user's home (bun, the gateway code): the gateway keeps a
 * copy of bun, a bundle of the `nuo` MCP server and a link to the Claude CLI bundled with claude-agent-acp, copies of agy and lightpanda, the browser script and `nuo-browser` in
 * /srv/nuo/runtime (created by scripts/profile-os-setup.sh, owned by the gateway user, world-readable).
 * Returns undefined when that folder is not set up.
 */
export async function prepareProfileRuntime(dir = PROFILE_RUNTIME_DIR): Promise<ProfileRuntime | undefined> {
  try {
    accessSync(dir, constants.W_OK);
  } catch {
    return undefined;
  }
  const bin = join(dir, "bin");
  mkdirSync(bin, { recursive: true, mode: 0o755 });
  copyIfChanged(process.execPath, join(bin, "bun"));
  const out = await Bun.build({ entrypoints: [NUO_MCP_SERVER], target: "bun", outdir: dir, naming: "nuo-mcp.js" });
  if (!out.success) throw new Error(`cannot bundle the nuo MCP server: ${out.logs.map(String).join("; ")}`);
  chmodSync(join(dir, "nuo-mcp.js"), 0o644);
  copyIfChanged(BROWSER_SCRIPT, join(bin, "nuo-chrome"));
  const cli = await Bun.build({ entrypoints: [BROWSER_CLI], target: "bun", outdir: dir, naming: "nuo-browser.js" });
  if (!cli.success) throw new Error(`cannot bundle nuo-browser: ${cli.logs.map(String).join("; ")}`);
  chmodSync(join(dir, "nuo-browser.js"), 0o644);
  // HOME is <tree>/home (scripts/profile-os-setup.sh); the gateway writes the profile's local token next to it.
  const wrapper = join(bin, "nuo-browser");
  writeFileSync(wrapper, `#!/bin/sh\nexport NUO_ENV_FILE="$(dirname "$HOME")/${AGENT_GATEWAY_ENV}"\nexec "${join(bin, "bun")}" "${join(dir, "nuo-browser.js")}" "$@"\n`);
  chmodSync(wrapper, 0o755);
  const adapter = findBinary("claude-agent-acp");
  if (adapter) {
    const pkg = dirname(dirname(realpathSync(adapter)));
    const claude = join(pkg, "node_modules", "@anthropic-ai", `claude-agent-sdk-linux-${process.arch}`, "claude");
    if (existsSync(claude)) link(claude, join(bin, "claude"));
  }
  // agy installs itself in the gateway user's ~/.local/bin and self-updates there: a copy follows each restart.
  const agy = findBinary("agy");
  if (agy) copyIfChanged(realpathSync(agy), join(bin, "agy"));
  const lightpanda = findBinary("lightpanda");
  if (lightpanda) copyIfChanged(realpathSync(lightpanda), join(bin, "lightpanda"));
  return { nuoMcp: { command: join(bin, "bun"), args: ["run", join(dir, "nuo-mcp.js")] }, ...(lightpanda ? { lightpanda: join(bin, "lightpanda") } : {}) };
}
