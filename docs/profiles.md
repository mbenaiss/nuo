# Profiles

One gateway host serves a few people (the owner and 2–3 friends), each in their own **profile**: their own
bots, conversations, data, documents, calendars, devices and 2FA, and their own agent logins. Nobody uses the
owner's Claude/Codex/Gemini/Grok subscriptions but the owner. The app is not on the App Store: see
[distribution.md](distribution.md) for installing it on a friend's iPhone or Mac.

## Model

- A profile has an id (slug, `[a-z][a-z0-9-]{1,23}`), a display name and a creation date, stored in
  `~/nuo/profiles/registry.db` with the pairing failures of all profiles. The person types the id or the display
  name (case, accents and spaces ignored) in the app's « Profil » field at pairing.
- The owner's existing install is the profile `owner`. At its first start, the gateway moves `~/nuo/{data,docs,
  dashboards,bots,instructions,memory,browser}` to `~/nuo/profiles/owner/` and leaves a link at each old path
  (`src/profiles/migrate.ts`, idempotent). The owner's devices, bots, conversations and data are unchanged; the
  owner's agents keep running as the gateway user with the existing logins. Claude Code sessions move with the bot
  folders; a codex/gemini/grok session that cannot be resumed from the new folder silently starts a fresh one (the
  conversation's messages stay).
- **Separate databases per profile**, not a `profile_id` column: each profile has its own `nuo.db` (bots,
  conversations, messages, tasks, devices, push tokens, auth tokens, TOTP secret, recovery codes, audit log) and
  `data.db` (collections, reminders, places, calendars, booking types), its own docs repo, dashboards, memory,
  instructions, bot folders and media. The gateway builds one set of services per profile (`ProfileStack`,
  `src/profiles/stack.ts`) on those files only. Isolation therefore holds by construction: no query can forget a
  filter, and code written before profiles stays correct. The cost (one SQLite file pair per profile, a loop over
  2–4 profiles to find which one a token belongs to) is negligible at this scale.

## What is per profile, and what stays the owner's

| | owner | other profiles |
|---|---|---|
| Bots, conversations, tasks, data, docs, dashboards, calendars, devices, 2FA | own | own |
| WebSocket events, turn snapshots, pushes (answers, reminders, tasks, alerts) | own devices only | own devices only |
| Agents | gateway user, owner's logins | Linux user `nuo-<slug>`, the person's own logins; none until set up |
| Tool servers (`config/tools.json`), machine tools (`#tags`) | yes | none |
| Command tasks | yes | refused, unless `profile-commands <slug> on` (then they run as `nuo-<slug>`) |
| Shared browser (logged-in Chrome) | own (`nuo-browser.service`, `127.0.0.1:9222`) | own: Chrome runs as `nuo-<slug>`, profile in its home, DevTools on `127.0.0.1:<29000 + uid>`; none until set up |
| Google calendars (gog), public booking host | yes | no (device calendars and local data only) |
| Starter dashboards, seeded bots | yes | no |
| Agents' direct access to the data (`sqlite3 data.db`, docs repo) | `auto` bots | none: the data is managed in the app |

## Guarantees

Through the API (tests: `gateway/test/profiles.test.ts`):

- a device's tokens (app and extension scopes) only ever reach its profile's services. Ids of another profile's
  bots, conversations, tasks, reminders, places, projects, documents, dashboards, booking types and devices answer
  `404` — exactly as ids that do not exist, never `403`;
- sockets are registered in their profile's hub: broadcasts, turn snapshots and prompts never cross profiles;
  pushes go to the profile's own devices;
- each profile's agents get their own local token (the `nuo` MCP server): it reaches that profile's tasks and
  memory only;
- pairing: `{profile, code, totp, …}`. An unknown or disabled profile, another profile's pairing code, a wrong code
  or a wrong 2FA code all get `401 {"error": "invalid profile, pairing code or 2FA code"}` after the same minimum
  delay (400 ms). Lockouts: 5 failures per IP, 10 per typed name (existing or not), 20 in total per 15 minutes. No
  route lists profiles; `GET /api/me` only returns the caller's.

On the machine (tested end to end in a throwaway Debian container, see « Checking » below):

- a profile's agents, their tools and MCP servers, its logins and its command tasks run as `nuo-<slug>`, a system
  user without password or shell, through one launcher (`/usr/local/lib/nuo/nuo-agent`) that the gateway user may
  run as that user and nothing else (sudoers rule checked with `visudo`). The launcher rebuilds the environment from
  scratch: no gateway variable (local token, APNs, Access token) reaches it;
- `nuo-<slug>` cannot read the owner's home (`0700`: `~/nuo/profiles/owner`, `~/.secrets`, `~/.claude`, the
  repos…), the profile's own databases, docs and memory (`0700`, reached through the gateway only), another
  profile's tree, nor list `/srv/nuo`. It can write in its home and in its bots' folders only;
- network: `nuo-*` users can reach the gateway port and their own browser's DevTools port on loopback, DNS and the
  internet; every other loopback port (the owner's browser DevTools `127.0.0.1:9222`, another profile's, databases…) and the home network (`10/8`, `172.16/12`,
  `192.168/16`, `169.254/16`, Tailscale's `100.64/10`, IPv6 ULA and link-local) are rejected (`nuo-firewall.service`);
- the gateway refuses to start a profile's agents (`available: false` in `GET /api/agents`, a turn ends with an
  error) until `nuo-agent --check` passes: user, home owned and closed, owner's home unreadable, network rules loaded.

## Limits

- The owner is root-equivalent on the gateway host (sudo): they can read everything, including a friend's API keys in their
  `agents.env` and their conversations. Profiles protect people from each other, not from the owner.
- Process names and command lines are visible to every user (`ps`); `/tmp` is shared (agents get their own
  `TMPDIR`, but a world-readable file another process left in `/tmp` is readable). Secrets are never put on command
  lines (repo rule), so this leaks activity, not credentials.
- Internet access is open for profile agents (that is their job): an agent can still be steered into exfiltrating
  what its own profile holds. CPU, memory and disk are shared without quotas.
- The Cloudflare Access service token handed over at pairing is the same for everyone (it only gets traffic to the
  gateway, which then needs a device key and a valid token).
- The owner's starter dashboards, tool servers, machine tools, browser and Google calendars are not offered to other
  profiles; per-profile calendars are not implemented. A profile's browser is a child of the gateway: it stops when the
  gateway restarts, and the owner's processes can reach its DevTools port like any loopback port.
- A profile created before `profile-os-setup.sh` lives in `~/nuo/profiles/<slug>` until the script moves it to
  `/srv/nuo/<slug>`; restart the gateway after the script so the agents use the new path.

## Onboarding a person

On the gateway host (`ssh` into it); `cd ~/nuo/app` for the `bun run` lines.

1. Create the profile and give the person the 2FA enrolment (shown once: QR code, `otpauth://` URI, 10 recovery
   codes). They scan it with their authenticator app; send the recovery codes privately.
   ```sh
   bun run src/cli.ts profile-create alice --name "Alice"
   ```
2. Give it a Linux user (the owner runs this themselves, with sudo; idempotent):
   ```sh
   sudo bash ~/nuo/os/profile-os-setup.sh alice
   systemctl --user restart nuo-gateway
   ```
   After a change to `scripts/nuo-agent` (deployed to `~/nuo/os`), install only the launcher and check every
   profile user with `sudo bash ~/nuo/os/nuo-agent-update.sh`.
3. Their agent logins, in a terminal on the gateway host, with the person signing in on their own account (they open the link
   and give back the code):
   ```sh
   bun run src/cli.ts profile-login alice claude    # then /login in Claude Code, then /exit
   bun run src/cli.ts profile-login alice codex     # device code flow
   bun run src/cli.ts profile-login alice gemini
   bun run src/cli.ts profile-login alice grok
   ```
   Or an API key instead (read on stdin, never shown, stored in `/srv/nuo/alice/home/.config/nuo/agents.env`):
   ```sh
   bun run src/cli.ts profile-env alice ANTHROPIC_API_KEY
   ```
   Until one of these is done, the profile has no available agent.
4. Install the app on their device ([distribution.md](distribution.md)), then, on the home network or VPN, a
   pairing code:
   ```sh
   bun run src/cli.ts pair-code alice
   ```
   They type the profile name `alice` (or « Alice »), the code and their current 2FA code.
5. Optional: `bun run src/cli.ts profile-commands alice on` lets them create command tasks (they run as `nuo-alice`).

Day to day: `profile-list`; `auth-devices --profile alice`, `auth-revoke <device id> --profile alice`,
`auth-events --profile alice`, `auth-totp-reset --profile alice` (new 2FA secret and recovery codes);
`profile-rename alice "Alice M."`; `profile-disable alice` / `profile-enable alice` (a disabled profile cannot pair,
its devices are refused and its sockets, agents and tasks stop within 5 s).

## Removing a person

```sh
bun run src/cli.ts profile-delete alice --yes        # disables it, then moves the tree to ~/nuo/archive/profiles/alice-<date>
sudo bash ~/nuo/os/profile-os-remove.sh alice     # kills its processes, removes the sudoers rule, network rule and user
```

Nothing is erased: delete the archive by hand once it is no longer needed. Their devices stop working at the
disable step.

## Checking

- `bun test test/profiles.test.ts` (part of `make gateway-check`): pairing answers and timing, 404s across profiles,
  sockets, pushes, local tokens, disabling, agents refused until the host is ready, folder modes, migration.
- `sudo -u <owner> sudo -n -u nuo-alice /usr/local/lib/nuo/nuo-agent --check` prints `ok` on the gateway host.
- The OS isolation was tested in a privileged `oven/bun:1.4.2-debian` container: owner user with a `0700` home, two
  profiles, `profile-os-setup.sh`, then as `nuo-alice`: owner files, other profile and own databases unreadable,
  `/srv/nuo` not listable, gateway port reachable, DevTools port and the home network blocked, an ACP agent session
  through sudo and the launcher, no process left after closing a session, after a `SIGKILL` of sudo or a command
  timeout, command task variables passed on stdin; `profile-delete` and `profile-os-remove.sh` afterwards.
