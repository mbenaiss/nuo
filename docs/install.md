# Installing the gateway on a server

This is level 3 of [getting started](getting-started.md): a gateway that runs all the time on a machine you control
(a home server, a mini PC, a VPS, a Mac that stays on), as a service of one user: a systemd **user** service on
Debian or Ubuntu, a launchd agent on macOS. Everything lives under `~/nuo` ([layout.md](layout.md)) and its secrets
in `~/.secrets/nuo.env`.

| Script | Does |
|---|---|
| `install.sh` (repository root) | the [one-line install](#one-line-install): clones or updates the repository, then runs `scripts/install.sh` from it with 2FA enrolment and a pairing code |
| `scripts/install.sh` | installs, upgrades or removes: packages, Bun, code, folders, secrets file, service, then starts the gateway |
| `scripts/deploy-gateway.sh` | day-to-day deploy from your checkout: rsync, `bun install`, restart (`NUO_DEPLOY_HOST=user@host`) |
| `scripts/backup.sh` | one archive with, for every profile, the databases (`sqlite3 .backup`), files, media, docs repo, bots, instructions, memory, dashboards; the profile registry and the live config |
| `scripts/restore.sh` | checks an archive, stops the gateway, swaps the data in (the old copy is kept), starts it again |
| `scripts/profile-os-setup.sh` | run with sudo, once per profile other than the owner's: its Linux user, sudoers rule, network rules ([profiles.md](profiles.md)) |

`scripts/install.sh`, `backup.sh` and `restore.sh` run on the gateway host, or from your computer with
`--host user@host` (over ssh).

## One-line install

On the machine that will run the gateway, as the user that will own it (not root):

```sh
curl -fsSL https://raw.githubusercontent.com/mbenaiss/nuo/main/install.sh | bash
```

It asks a few questions, each with a default (Enter keeps it): the folder of the source checkout, the port, whether
the local network or only this machine reaches the gateway, service or not, 2FA now or later. It prints its plan and
waits for a yes, and shows every `sudo` command before asking to run it. Then it:

1. installs `git` with apt when it is missing (macOS: the Xcode Command Line Tools must be there,
   `xcode-select --install`);
2. clones the repository into `~/.local/share/nuo`, or updates that checkout (it stops when the checkout has local
   changes);
3. runs `scripts/install.sh --from-local` from the checkout: everything listed under [Install](#install), with the
   service of the platform;
4. enrols the 2FA second factor when it is not set up yet: a QR code for your authenticator app and ten recovery
   codes, printed once;
5. checks `GET /api/health`, lists the agents the gateway found and how to install or log in to the missing ones;
6. prints a pairing code and the gateway URL to type in the app.

Running it again updates the checkout and the gateway, keeps `~/.secrets/nuo.env` and the data, and skips the 2FA
enrolment. It opens no port and changes no firewall rule ([Network](#network)).

Options go after `bash -s --`, for example `curl -fsSL <url> | bash -s -- --yes --port 8791`. Each one also has an
environment variable, for scripts:

| Option | Variable | Default | |
|---|---|---|---|
| `--yes` | `NUO_INSTALL_YES=1` | asks | accept the defaults and every confirmation, `sudo` included; needed without a terminal |
| `--dir <path>` | `NUO_INSTALL_DIR` | `~/.local/share/nuo` | folder of the source checkout |
| `--repo <url>` | `NUO_INSTALL_REPO` | `https://github.com/mbenaiss/nuo.git` | repository to clone, for a fork |
| `--ref <ref>` | `NUO_INSTALL_REF` | `main` | branch, tag or commit |
| `--port <n>` | `NUO_INSTALL_PORT` | `8790` | `NUO_PORT` of a new env file |
| `--listen all\|local` | `NUO_INSTALL_LISTEN` | `all` | `local` writes `NUO_HOST=127.0.0.1` into a new env file: only this machine (a reverse proxy or tunnel on it) reaches the gateway |
| `--no-service` | `NUO_INSTALL_SERVICE=0` | service | no systemd unit or launchd agent: you start the gateway yourself (the installer prints the command) |
| `--no-2fa` | `NUO_INSTALL_2FA=0` | enrol | skip the 2FA enrolment and the pairing code |
| `--account <label>` | `NUO_INSTALL_ACCOUNT` | user name | label of the 2FA entry in the authenticator app |
| `--dry-run` | | | print the plan and change nothing (the code it would run is fetched into a temporary folder, removed at the end) |
| `--uninstall` | | | see [Uninstall](#uninstall) |

A fork installs from its own repository:

```sh
curl -fsSL https://raw.githubusercontent.com/<you>/nuo/main/install.sh | NUO_INSTALL_REPO=https://github.com/<you>/nuo.git bash
```

A pipe from the network can be cut halfway: the whole script is one function called on its last line, so a
truncated download defines nothing that runs. Read it before running it if you prefer:
`curl -fsSL <url> -o install.sh`, then `bash install.sh`.

To let a coding agent do all this for you, see [install-with-an-agent.md](install-with-an-agent.md).

### On macOS

The gateway runs as the launchd agent `local.nuo.gateway` (`~/Library/LaunchAgents/local.nuo.gateway.plist`), with
Bun reading `~/nuo/config/env` (`bun --env-file`) and its output in `~/Library/Logs/nuo-gateway.log`. A launchd agent
runs while you are logged in to the Mac. Restart it with `launchctl kickstart -k gui/$(id -u)/local.nuo.gateway`.
Bun reads the env file a little differently from systemd: it expands `$NAME` and ends an unquoted value at `#`, so
write a value holding either in double quotes, with `\$` for a literal `$`.
When the gateway listens on all interfaces and the macOS firewall is on, macOS asks once whether `bun` may accept
incoming connections: allow it for your iPhone to reach it. The shared browser (`nuo-browser.service`) and the
profile helpers are Linux only.

The installer does not build the apps. The Mac app needs a signing team: its entitlements include push
notifications, WeatherKit and a keychain group, which a build signed without a team cannot carry, so it is built in
Xcode with your account ([getting-started.md](getting-started.md#building-with-your-own-apple-account)).

## Requirements

- A Debian or Ubuntu host, or a Mac (the script refuses anything else), a user account with sudo for the first
  install on Linux.
- From your computer, for `--host`: ssh access to that user, and `rsync`.

Installed by `scripts/install.sh` when missing, each `sudo` command shown and confirmed first (`--yes` confirms
them all):

- `git`, `sqlite3`, `rsync`, `curl`, `unzip`, `zstd`, `openssl`, `xvfb`, `xauth` and Chromium (apt, through `sudo`).
  On Ubuntu, whose Chromium is a snap, the shared browser stays off until you install Google Chrome. On macOS the
  script only checks that the tools it needs are there (they come with the Xcode Command Line Tools);
- Bun **1.4.2** in `~/.bun`, with Bun's own installer; a newer Bun already installed is used as is, an older one
  stops the script (`bun upgrade`);
- `loginctl enable-linger <user>` so the user unit runs without a login session.

Installed and logged in by hand, as the gateway user (the script lists which ones it finds). The gateway looks for
them in `~/.local/bin`, `~/.bun/bin`, `~/.npm-global/bin`, `/home/linuxbrew/.linuxbrew/bin`, `/opt/homebrew/bin`,
`/usr/local/bin`. You need at least one agent:

| Agent | Binaries the gateway runs | Install | Login |
|---|---|---|---|
| Claude Code | `claude-agent-acp`, `claude` | `curl -fsSL https://claude.ai/install.sh \| bash`, `npm i -g @agentclientprotocol/claude-agent-acp` | `claude` then `/login` (or `ANTHROPIC_API_KEY`) |
| Codex | `codex-acp`, `codex` | `npm i -g @agentclientprotocol/codex-acp @openai/codex` | `codex login` (or `CODEX_API_KEY`) |
| Gemini (Antigravity) | `agy` (one `agy --print` per prompt, no MCP tools yet) | Antigravity CLI in `~/.local/bin/agy` | `agy`, Google sign-in (or `GEMINI_API_KEY` with `"modelProvider": "gemini"` in `~/.gemini/antigravity-cli/settings.json`) |
| Grok | `grok` | `npm i -g @xai-official/grok` | `grok`, sign in when asked |
| Google tools (optional) | `gog` (calendar, booking, mail tools) | gogcli 0.45 in `/usr/local/bin/gog` | `gog auth add <account>`; `GOG_KEYRING_PASSWORD` in the env file |

The npm packages need Node.js 20 or newer. An agent that is missing or logged out shows as unavailable in the app;
the gateway still starts.

## Install

From your computer, in a checkout of this repository:

```sh
scripts/install.sh --host alex@192.0.2.10 --from-local --dry-run   # what would change
scripts/install.sh --host alex@192.0.2.10 --from-local
```

`--from-local` sends the gateway from your checkout (with your [private overlay](private-overlay.md) laid over it).
Without it, the host clones `https://github.com/mbenaiss/nuo.git` (`--repo <url>` or `NUO_REPO_URL` for a fork,
`--ref <branch>` for another branch). On the host itself: `bash scripts/install.sh`. `--no-service` skips the
service (containers, or to start the gateway by hand with
`bun --env-file=../config/env run src/index.ts` in `~/nuo/app`).

Other options: `--yes` (confirm every `sudo` command, needed without a terminal), `--port <n>` and
`--listen all|local` (applied to a new env file only), `--setup-2fa [--account <label>]` (enrol 2FA when it is not
set up yet), `--pair` (print a pairing code at the end), `--uninstall [--purge]`. `scripts/install.sh --help` lists
them.

The script:

1. refuses anything but Debian/Ubuntu and macOS, and root;
2. installs the missing packages and Bun (Linux), or checks that they are there (macOS);
3. copies the repository's `gateway/` to `~/nuo/app` and runs `bun install --production`;
4. initialises `~/nuo/docs` as a git repository and copies the starter dashboards (first run only);
5. creates the `~/nuo` folders and `~/.secrets` with mode 700;
6. creates `~/.secrets/nuo.env` (600) from [`deploy/nuo.env.example`](../deploy/nuo.env.example) with a
   random `NUO_LOCAL_TOKEN`, **only when the file does not exist**, and links `~/nuo/config/env` to it;
7. installs `~/.local/bin/nuo-notify`, and on Linux the profile helpers in `~/nuo/os`;
8. with `--setup-2fa`, enrols 2FA when it is not set up yet;
9. on Linux, installs `nuo-gateway.service` and `nuo-browser.service`, enables linger and restarts the gateway; on
   macOS, installs and loads the launchd agent `local.nuo.gateway`. Database migrations run at start; the script
   waits for `GET /api/health`;
10. lists the agents the gateway found, prints a pairing code with `--pair`, then the next steps.

Running it again is safe: it only changes what differs, and restarts the gateway.

## First pairing

On the host:

```sh
cd ~/nuo/app
bun run src/cli.ts auth-totp-setup --account "Alex"   # 2FA: QR code + recovery codes, writes NUO_AUTH_KEY
systemctl --user restart nuo-gateway
bun run src/pair.ts                                   # one-time pairing code for the owner profile
```

Then, in the app, on the same local network: type the gateway URL (`http://<host address>:8790`, or your reverse
proxy URL), the profile `owner`, the pairing code and the current code of your authenticator app. Pairing is refused
from the internet.

Every other setting in `~/.secrets/nuo.env` is optional; restart the gateway after a change. The main ones:

| Setting | For |
|---|---|
| `APNS_KEY_PATH`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC` | push notifications: an APNs key (`.p8`) from your Apple developer account, `APNS_TOPIC` = the app's bundle id (`NUO_BUNDLE_ID` in `ios/Local.xcconfig`). Put the key in `~/.secrets/apns.p8` (600), linked as `~/nuo/config/apns.p8`, and set `APNS_KEY_PATH=/home/<user>/nuo/config/apns.p8` |
| `NUO_PUBLIC_URL`, `NUO_TUNNEL_SOURCES`, `NUO_CF_ACCESS_CLIENT_ID/SECRET` | reaching the gateway from the internet (see [Network](#network)) |
| `NUO_PROXY_SOURCES` | your reverse proxy's address, when it is not on the gateway host |
| `NUO_BOOKING_*`, `NUO_GOOGLE_*`, `GOOGLE_OAUTH_*` | calendar and public booking pages ([calendar.md](calendar.md)) |
| `NUO_ELEVENLABS_API_KEY` | server-side speech to text (the apps transcribe on the device without it) |

## Network

The scripts never touch the firewall, the reverse proxy or the tunnel. The gateway speaks plain HTTP on port 8790
and classifies each request by where it comes from ([protocol.md](protocol.md#network-zones)):

- **local**: loopback, for scripts and the bots' own tools;
- **lan**: a private address, directly or through a reverse proxy listed in `NUO_PROXY_SOURCES`. Pairing works
  only from here;
- **internet**: anything else, or any request carrying Cloudflare headers.

A setup that works well, with documentation addresses as examples (gateway `192.0.2.10`, reverse proxy
`192.0.2.20`, tunnel connector `192.0.2.30`):

- **Firewall on the gateway host.** Accept port 8790 only from the machines that front it:

  ```
  table inet nuo {
    chain input {
      type filter hook input priority 0; policy accept;
      tcp dport 8790 ip saddr { 192.0.2.20, 192.0.2.30 } accept
      tcp dport 8790 drop
    }
  }
  ```

  Without a proxy (the apps talk to `http://192.0.2.10:8790` on your network), accept your local subnet instead.

- **Reverse proxy on the local network or VPN (optional).** TLS and a friendly name, for example with Caddy:

  ```
  nuo.home.example.com {
    reverse_proxy 192.0.2.10:8790
  }
  ```

  WebSockets pass through `reverse_proxy` as is. Put the proxy's address in `NUO_PROXY_SOURCES` (default
  `127.0.0.1,::1`, enough when the proxy runs on the gateway host).

- **Internet access (optional).** A tunnel avoids opening a port on your router. With Cloudflare Tunnel:
  route the public hostname (`nuo.example.com`) to `http://192.0.2.10:8790`, protect it with a Cloudflare Access
  application that requires a service token, and set `NUO_PUBLIC_URL=https://nuo.example.com`,
  `NUO_TUNNEL_SOURCES=<address of the cloudflared host>` and `NUO_CF_ACCESS_CLIENT_ID/SECRET` (handed to the
  apps at pairing). The booking hostname (`NUO_BOOKING_HOSTS`, e.g. `rdv.example.com`) stays outside Access
  ([security.md](security.md#public-booking-host)), and so does the hooks hostname (`NUO_HOOKS_HOSTS`, see
  [deploy/mail-worker/README.md](../deploy/mail-worker/README.md)). A VPN (WireGuard, Tailscale) is the simpler alternative: the
  apps then always see the gateway as `lan`.

## Upgrade

```sh
NUO_DEPLOY_HOST=alex@192.0.2.10 scripts/deploy-gateway.sh   # or: NUO_DEPLOY_HOST=... make deploy
scripts/install.sh --host alex@192.0.2.10 --from-local         # same, plus packages, folders and unit changes
```

Both restart the gateway; database migrations run at start. A backup first is cheap:
`scripts/backup.sh --host alex@192.0.2.10 --out ~/nuo-backups`.

## Apps built under an earlier name

The gateway and the apps share names built on the app's name: the signed messages (`nuo-auth:v1:…`,
`nuo-action:v1:…`), the `x-nuo-…` headers, the notification categories (`nuo.answer`…) and the `nuo://` links. When
a deployment renames the project, the apps already installed still use the earlier name until each one is updated,
and a locked iPhone or a watch is not updated the same minute. `NUO_LEGACY_APP_PREFIX=<earlier name>` covers that
time:

- the gateway accepts both names: signatures, `x-<name>-action-nonce`/`-signature`, `x-<name>-transcription-id`,
  `<name>://` links sent to `POST /api/notify` (kept in the current name);
- it remembers which name each device last signed with (token refresh, Face ID, relay token, secret confirmation)
  and sends that device's pushes, their category and links, and the end of a Google sign-in in that name. A device
  paired before this was tracked counts as an earlier app until it signs in the current name, which an updated app
  does at its first launch (its access token lives in memory only, so every launch starts with a signed refresh);
- nothing is relaxed: each name is checked against the same key, purpose and single-use nonce, and the earlier name
  may only be letters and digits, so no message in one name reads as another message in the other.

Links written inside messages and documents stay in the current name: an earlier app shows them but cannot open them.
Remove the variable once every iPhone, Mac and watch runs a build of the current name: from then on a forgotten
device fails to refresh its token and must be updated.

The booking invitations (`.ics`) keep their UID only with `NUO_BOOKING_UID_DOMAIN=<earlier name>` (docs/calendar.md):
unlike `NUO_LEGACY_APP_PREFIX`, it stays set for good, since guests keep the invitations they already downloaded.

## Moving to a new host

```sh
# 1. new host: code, unit, empty install
scripts/install.sh --host alex@192.0.2.11 --from-local

# 2. archive the old host (the gateway keeps running; databases are copied with sqlite3 .backup)
scripts/backup.sh --host alex@192.0.2.10 --out ~/nuo-backups --with-secrets

# 3. stop the old host so nothing changes after the archive (and so two gateways do not run the same schedules)
ssh alex@192.0.2.10 'systemctl --user disable --now nuo-gateway'

# 4. restore on the new host (asks for the passphrase, then for confirmation)
scripts/restore.sh ~/nuo-backups/nuo-backup-192.0.2.10-<date>.tar.zst.enc --host alex@192.0.2.11
```

Then point the reverse proxy and the tunnel at the new host, and move the firewall rule. Paired devices keep
working: their keys and tokens are in `nuo.db`.

What the archive holds: `data/nuo.db` and `data/data.db` (integrity checked, SHA-256 in `MANIFEST`), `data/files`,
`data/media`, `docs` (with its `.git`), `bots`, `instructions`, `memory`, `dashboards`, the live
`config/{tools,machine-tools,bots.seed}.json`; `archive/` only with `--with-archive`. Never: `app/` (reinstalled),
`node_modules`, the agent CLIs and their logins.

Secrets:

- Without `--with-secrets` the archive is plain `tar.zst` (`tar.gz` without zstd) and holds no secret, but it holds
  all personal data: keep it private. On the new host, fill `nuo.env` again; with a new `NUO_AUTH_KEY` the
  sealed TOTP secret cannot be opened, so run `bun run src/cli.ts auth-totp-reset` (devices stay paired).
- With `--with-secrets` it also holds `~/.secrets/nuo.env` and the APNs key, and the whole archive is encrypted
  (`openssl enc -aes-256-cbc -pbkdf2 -iter 600000`, `.enc`). The passphrase (12 characters minimum) is asked on the
  terminal, or read from the first line of stdin, never from the command line. `restore.sh` installs a secret file
  only when the target has none; otherwise it writes `<file>.restored-<date>` next to it to merge by hand.

`restore.sh` checks the manifest, the integrity and checksums of both databases and the docs commit before changing
anything; then it stops the unit, moves what it replaces (and the old `-wal`/`-shm` files) to
`~/nuo/.pre-restore-<date>/`, moves the archive's copy in, restarts the unit and waits for `/api/health`.
Delete `.pre-restore-*` once everything works. Options: `--no-service` (no stop/start), `--yes` (no prompt, needed
when stdin is not a terminal).

Paths that are absolute in the data and must be fixed by hand when the user or home folder changes: a bot's
`workdir`, `config/tools.json`, `APNS_KEY_PATH`. Agent conversation history (`~/.claude/projects`, `~/.codex`, ...)
is not in the archive: a conversation whose agent session cannot be resumed starts a fresh agent session, its
messages stay in Nuo.

## Uninstall

```sh
scripts/backup.sh --host alex@192.0.2.10 --out ~/nuo-backups --with-secrets   # keep a copy first
curl -fsSL https://raw.githubusercontent.com/mbenaiss/nuo/main/install.sh | bash -s -- --uninstall   # on the host
scripts/install.sh --host alex@192.0.2.10 --uninstall                           # or from your checkout
```

`--uninstall` stops and removes the service (the systemd units, or the launchd agent and its log), `~/nuo/app`,
`~/nuo/os` and `~/.local/bin/nuo-notify`; the one-line installer also removes its checkout when it has no local
changes. Your data in `~/nuo` and `~/.secrets/nuo.env` stay. Add `--purge` to delete them too, for good, once the
backup is checked (`~/.secrets/apns.p8`, if you made one, stays: remove it by hand). Bun, the packages and the agent
CLIs stay; on Linux, `sudo loginctl disable-linger <user>` if nothing else needs linger.

## Profiles

Friends get their own profile on the same gateway: [profiles.md](profiles.md) (creation, Linux user with
`sudo bash ~/nuo/os/profile-os-setup.sh <slug>`, agent logins, pairing, removal). Archives hold every profile
tree under `nuo/profiles/<slug>` and `profiles/registry.db`, but not a profile's agent HOME (CLI logins, API
keys: the person logs in again) nor files an agent made private (`0600`, the backup says so). After restoring a
profile other than the owner's, run `profile-os-setup.sh <slug>` again: it moves the restored tree to
`/srv/nuo/<slug>`.
