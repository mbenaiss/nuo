import { browserCommand } from "./cli";

/**
 * `nuo-browser`, the browser commands of a profile's agents (bundled into /srv/nuo/runtime by src/profiles/runtime.ts):
 * same as the gateway CLI's `browser-*`, without its database (`--bot` is passed through as an id).
 */
const COMMANDS = ["browser-start", "browser-status", "browser-login-needed"];
const [cmd = "", ...rest] = process.argv.slice(2);
const name = cmd.startsWith("browser-") ? cmd : `browser-${cmd}`;
if (!COMMANDS.includes(name)) {
  console.error("usage: nuo-browser start | status | login-needed --site <name> [--url <login page>] [--timeout <seconds>] [--no-wait]");
  process.exit(2);
}
browserCommand(name, rest, (ref) => ref).then(
  (code) => process.exit(code),
  (e) => {
    console.error(`error: ${(e as Error)?.message ?? e}`);
    process.exit(1);
  },
);
