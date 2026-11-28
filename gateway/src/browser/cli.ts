import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { defaultLayout } from "../paths";

export const BROWSER_USAGE = `  bun run src/cli.ts browser-start
    Starts the shared browser when it is not running (or keeps it from idling out) and prints its DevTools endpoint
    (127.0.0.1 only), for Playwright connectOverCDP or \`playwright-cli attach --cdp=<endpoint>\`.
  bun run src/cli.ts browser-status
  bun run src/cli.ts browser-login-needed --site <name> [--url <login page>] [--bot <slug|id>] [--timeout <seconds>] [--no-wait]
    Pushes "Login needed on <site>" (in the user's language) to the user's devices with a link to the app's browser,
    then waits until they tap Done (exit 0) or the timeout passes (exit 3; default 900 s). Passwords and 2FA codes are typed by
    the user in the app, never by an agent.`;

/** Same lookup as scripts/nuo-notify: the environment, then the gateway's env file (parsed, never sourced). */
export function localGateway(env: Record<string, string | undefined> = process.env): { url: string; token: string } {
  const files = env.NUO_ENV_FILE ? [env.NUO_ENV_FILE] : [join(defaultLayout(env).config, "env"), join(homedir(), ".config/nuo/env")];
  const file = files.find((f) => existsSync(f));
  const vars: Record<string, string> = {};
  if (file) {
    for (const line of readFileSync(file, "utf8").split("\n")) {
      const m = line.match(/^\s*(?:export\s+)?(NUO_LOCAL_TOKEN|NUO_PORT|NUO_URL)=(.*)$/);
      if (m) vars[m[1]!] = m[2]!.trim().replace(/^(['"])(.*)\1$/, "$2");
    }
  }
  const token = env.NUO_LOCAL_TOKEN || vars.NUO_LOCAL_TOKEN;
  if (!token) throw new Error(`NUO_LOCAL_TOKEN is missing (${file ?? files[0]})`);
  return { url: env.NUO_URL || vars.NUO_URL || `http://127.0.0.1:${env.NUO_PORT || vars.NUO_PORT || 8790}`, token };
}

async function call(method: string, path: string, body?: unknown): Promise<any> {
  const g = localGateway();
  const res = await fetch(g.url + path, {
    method,
    headers: { authorization: `Bearer ${g.token}`, ...(body === undefined ? {} : { "content-type": "application/json" }) },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(60_000),
  });
  const text = await res.text();
  const data = text ? JSON.parse(text) : undefined;
  if (!res.ok) throw new Error(`${method} ${path}: ${res.status} ${data?.error ?? text}`);
  return data;
}

export async function browserCommand(cmd: string, argv: string[], resolveBot: (ref: string) => string | undefined): Promise<number> {
  switch (cmd) {
    case "browser-start": {
      const r = await call("POST", "/api/browser/start");
      console.log(r.endpoint);
      return 0;
    }
    case "browser-status": {
      const s = await call("GET", "/api/browser");
      console.log(`${s.running ? "running" : "stopped"}  ${s.endpoint}  viewers ${s.viewers}${s.idleStopAt ? `  idle stop at ${s.idleStopAt}` : ""}`);
      for (const l of s.logins) console.log(`login needed: ${l.site}${l.url ? ` (${l.url})` : ""} since ${l.createdAt}`);
      return 0;
    }
    case "browser-login-needed": {
      const { values } = parseArgs({
        args: argv,
        options: { site: { type: "string" }, url: { type: "string" }, bot: { type: "string" }, timeout: { type: "string" }, "no-wait": { type: "boolean", default: false } },
        strict: true,
      });
      if (!values.site) throw new Error("--site is required");
      const botId = values.bot ? resolveBot(values.bot) : undefined;
      if (values.bot && !botId) throw new Error(`unknown bot "${values.bot}"`);
      await call("POST", "/api/browser/start");
      const r = await call("POST", "/api/browser/login-requests", { site: values.site, url: values.url, botId });
      console.log(`Notification "Login needed on ${r.site}" sent; the user logs in from the Nuo app (Browser screen), then taps Done.`);
      if (values["no-wait"]) {
        console.log(`request ${r.id}`);
        return 0;
      }
      const deadline = Date.now() + (Number(values.timeout) || 900) * 1000;
      while (Date.now() < deadline) {
        await Bun.sleep(3000);
        const s = await call("GET", `/api/browser/login-requests/${r.id}`);
        if (s.status === "done") {
          console.log("The user is done: now check that the session is logged in.");
          return 0;
        }
        // Waiting is activity: the browser must not idle out while the user logs in.
        await call("POST", "/api/browser/start");
      }
      console.log("Timed out: the user did not log in.");
      return 3;
    }
  }
  throw new Error(`unknown command ${cmd}`);
}
