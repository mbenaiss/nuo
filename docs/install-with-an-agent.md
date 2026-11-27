# Installing Nuo with a coding agent

A coding agent that can run shell commands (Claude Code, Codex, Gemini CLI, and the like) can install the gateway
for you. Copy one of the two prompts below into it:

- [On this machine](#prompt-install-on-this-machine): the computer the agent runs on.
- [On a server over SSH](#prompt-install-on-a-server-over-ssh): a Debian or Ubuntu host (or a Mac) you reach with
  `ssh`.

The agent reads the repository's own files, runs the [one-line installer](install.md#one-line-install), checks each
step, and ends with a report. It asks you before any `sudo` command and never touches your firewall, router or
tunnel.

Three things stay with you, on purpose:

- **2FA and pairing.** The 2FA enrolment prints a secret (QR code and recovery codes). An agent's tool output goes
  to its model provider, so the prompts tell the agent to install with `--no-2fa` and leave the enrolment and the
  pairing code to you, in a terminal of your own.
- **Agent logins.** Claude Code, Codex, Gemini and Grok are logged in interactively, with your accounts.
- **The apps.** They are built from source with Xcode on a Mac ([getting-started.md](getting-started.md)).

## Prompt: install on this machine

```text
Install the Nuo gateway (https://github.com/mbenaiss/nuo, MIT licence) on this machine, for the current user.

GOAL. At the end:
- the gateway runs as a service (systemd user unit nuo-gateway.service on Debian/Ubuntu, launchd agent
  local.nuo.gateway on macOS), unless I choose to start it by hand;
- `curl -fsS http://127.0.0.1:<port>/api/health` answers with "ok":true;
- the agent CLIs I want are installed, and I know how to log in to each;
- I know the exact commands to enrol 2FA and get a pairing code, and the gateway URL to type in the app.

READ FIRST, from https://raw.githubusercontent.com/mbenaiss/nuo/main/<path> (or from the checkout once it exists):
install.sh, scripts/install.sh, docs/install.md (sections "One-line install", "Requirements", "Network",
"Uninstall"), docs/getting-started.md (the pairing fields), docs/security.md (first section). These files are the
reference: when they disagree with this prompt, follow the files and tell me.

ASK ME FIRST, in one message, each with its default:
1. folder for the source checkout (default ~/.local/share/nuo);
2. port (default 8790) and who reaches the gateway: "all" (my phone on the local network, default) or "local"
   (this machine only);
3. service, or I start the gateway myself (default: service);
4. which agents I want: Claude Code, Codex, Gemini, Grok (at least one is needed);
5. whether I want to reach the gateway away from home (VPN, tunnel, reverse proxy). You only explain the options
   from docs/install.md "Network"; you set nothing up.

NEVER DO WITHOUT MY EXPLICIT YES IN THIS CHAT:
- any sudo or root command: show me the exact command first;
- open a port, change a firewall (ufw, nftables, iptables, pf, the macOS firewall), a router, a cloud security
  group, or install a tunnel or VPN;
- run the 2FA enrolment or print a pairing code yourself (your output leaves this machine): I do both;
- print, copy or move a secret: never show the content of ~/.secrets/nuo.env, never put a secret in a command line
  argument, in your messages, or in a file tracked by git. To check that a key is set, count it:
  grep -c '^NUO_LOCAL_TOKEN=.' ~/.secrets/nuo.env;
- send data anywhere other than the downloads the installers make (github.com, bun.sh, the npm registry, the agents'
  official installers);
- delete data: no --purge, no rm of ~/nuo or ~/.secrets;
- log in to an agent for me, or type a password.

STEPS. Run each check and compare with the expected result before going on.
1. Platform. `uname -s`; on Linux `. /etc/os-release; echo "$ID $ID_LIKE"`. Expected: Darwin, or Linux with debian
   or ubuntu. Anything else: stop and tell me (docs/getting-started.md runs the gateway by hand).
2. User. `id -u` must not be 0. On macOS, `xcode-select -p` must succeed (else I run xcode-select --install).
   `command -v curl git`: curl is required; a missing git is installed by the installer with apt.
3. Dry run, nothing changes:
   curl -fsSL https://raw.githubusercontent.com/mbenaiss/nuo/main/install.sh | bash -s -- --yes --dry-run --no-2fa [--dir D] [--port P] [--listen all|local] [--no-service]
   Expected: the plan, then "dry run: nothing was changed". List every "would run: sudo ..." line for me.
4. Sudo. If the dry run lists sudo commands, ask for my yes. Then `sudo -n true`: if it fails, sudo needs my
   password, which you must not type: give me the commands to run in my own terminal, then go on.
5. Install: the command of step 3 without --dry-run. Expected: exit code 0 and, with a service,
   "healthy: http://127.0.0.1:<port>/api/health". Running it again is safe: it updates and keeps the settings.
6. Check:
   - `curl -fsS http://127.0.0.1:<port>/api/health` contains "ok":true and lists the agents;
   - Linux: `systemctl --user is-active nuo-gateway` = active, `systemctl --user is-enabled nuo-gateway` = enabled,
     `loginctl show-user "$USER" -p Linger` = Linger=yes;
   - macOS: `launchctl print gui/$(id -u)/local.nuo.gateway | grep -m1 'state ='` = state = running;
   - `ls -l ~/.secrets/nuo.env` shows -rw------- and ~/nuo/config/env links to it;
   - listening address: `ss -ltn | grep :<port>` (Linux) or `lsof -nP -iTCP:<port> -sTCP:LISTEN` (macOS) matches
     what I chose (*:<port> for all, 127.0.0.1:<port> for local).
7. Agents. For each agent I want, install it as described in docs/install.md "Requirements" (no sudo; the npm
   packages need Node.js 20 or newer: if node is missing or older, ask me how I want it installed). Then tell me
   the login command to run myself. After my logins, restart the gateway (systemctl --user restart nuo-gateway, or
   launchctl kickstart -k gui/$(id -u)/local.nuo.gateway) and check that /api/health shows "authenticated":true for
   them.
8. Hand over 2FA and pairing. Tell me to run, in a terminal outside this session:
   cd ~/nuo/app && ~/.bun/bin/bun run src/cli.ts auth-totp-setup     (scan the QR code, keep the recovery codes)
   then restart the gateway, then: cd ~/nuo/app && ~/.bun/bin/bun run src/pair.ts   (valid 10 minutes)
   and the app fields: gateway URL (http://<this machine's LAN address>:<port>, or http://localhost:<port> for the
   Mac app on this Mac), profile "owner", the pairing code, the authenticator code. Pairing only works from the
   local network.
9. Away from home, if I asked: summarize the options of docs/install.md "Network" for my case. Change nothing.

WHEN SOMETHING FAILS, diagnose before retrying:
- the download fails: check `curl -fsSI https://raw.githubusercontent.com`; a proxy or DNS problem is mine to fix;
- "no terminal to ask on": rerun with --yes, once I agreed to the sudo commands;
- "bun ... is older than": `bun upgrade` (ask me first), then rerun;
- "has local changes" in the checkout: never discard them; show me `git -C <dir> status --short` and ask;
- the gateway does not answer: read the logs (journalctl --user -u nuo-gateway -n 80 --no-pager, or
  tail -n 80 ~/Library/Logs/nuo-gateway.log); a port already in use shows in ss or lsof: propose another NUO_PORT
  in ~/.secrets/nuo.env (edit only that line, with my yes), then restart;
- "no systemd user manager": I log in once over ssh, or we rerun with --no-service;
- an agent "not installed" although installed: the gateway looks in ~/.local/bin, ~/.bun/bin, ~/.npm-global/bin,
  /home/linuxbrew/.linuxbrew/bin, /opt/homebrew/bin, /usr/local/bin; tell me where it is instead of moving it;
- Ubuntu prints that the shared browser stays off: expected without Google Chrome; ask before installing Chrome;
- my phone cannot reach the gateway: same Wi-Fi, NUO_HOST not 127.0.0.1, a firewall on this machine (on macOS, the
  "accept incoming connections" prompt for bun). Report what you see; change nothing without my yes.

END WITH THIS REPORT:
## Nuo install report
- Machine: OS and version, user (no hostnames or IP addresses beyond the LAN URL for the app)
- Checkout: folder, commit (git -C <dir> log -1 --format='%h %s')
- Gateway: health URL, version, service state (or how to start it)
- Settings: port, listening address, env file path and mode (no values)
- Agents: one line each: ready / installed, not logged in / not installed
- Commands run with sudo: the list, or "none"
- Left for me: numbered (logins, 2FA, pairing, building the app, remote access)
- Problems met and how they were solved
- Confirmation: no port opened, no firewall, router, tunnel or VPN change, no secret printed
```

## Prompt: install on a server over SSH

```text
Install the Nuo gateway (https://github.com/mbenaiss/nuo, MIT licence) on a remote host that I reach with ssh, for
the ssh user. You run on my computer; every command for the host goes through ssh.

GOAL. At the end:
- the gateway runs on the host as a systemd user service with linger (Debian/Ubuntu) or a launchd agent (macOS);
- `ssh <host> 'curl -fsS http://127.0.0.1:<port>/api/health'` answers with "ok":true;
- the agent CLIs I want are installed on the host, and I know how to log in to each;
- I know the exact commands to enrol 2FA and get a pairing code, and the URL to type in the app.

READ FIRST, from https://raw.githubusercontent.com/mbenaiss/nuo/main/<path> (or a local checkout): install.sh,
scripts/install.sh (including --host), docs/install.md (sections "One-line install", "Requirements", "Install",
"Network", "Uninstall"), docs/getting-started.md (the pairing fields), docs/security.md (first section). These files
are the reference: when they disagree with this prompt, follow the files and tell me.

ASK ME FIRST, in one message, each with its default:
1. the ssh destination (user@host or an alias from ~/.ssh/config); the user must not be root;
2. clone on the host from GitHub (default), or send my local checkout with my private overlay
   (scripts/install.sh --host <dest> --from-local, docs/private-overlay.md);
3. port (default 8790) and who reaches the gateway: "all" (the local network, default) or "local" (the host only,
   behind a reverse proxy or tunnel on the host);
4. which agents I want: Claude Code, Codex, Gemini, Grok (at least one is needed);
5. how I will reach it away from home (VPN, tunnel, reverse proxy). You only explain docs/install.md "Network"; you
   set nothing up.

NEVER DO WITHOUT MY EXPLICIT YES IN THIS CHAT:
- any sudo or root command on the host: show me the exact command first;
- open a port or change a firewall on the host, the router, or the cloud provider (security groups, firewall
  rules), or install a tunnel or VPN. The gateway speaks plain HTTP: port 8790 must never face the internet;
- run the 2FA enrolment or print a pairing code yourself (your output leaves my computer): I do both;
- print, copy or move a secret: never show the content of ~/.secrets/nuo.env, never put a secret in a command line
  argument, in your messages, or in a file tracked by git; check a key with grep -c '^NUO_LOCAL_TOKEN=.' only;
- ask me for a password or type one: ssh must work with my keys;
- change ~/.ssh/config, authorized_keys, sshd settings or anything outside the user's home, except the sudo
  commands I approved;
- send data anywhere other than the host and the downloads the installers make;
- delete data: no --purge, no rm of ~/nuo or ~/.secrets.

STEPS. Run each check and compare with the expected result before going on.
1. SSH. `ssh -o BatchMode=yes <dest> true` succeeds. If it asks for a password, stop: I set up key access first.
2. Platform. `ssh <dest> 'uname -s; . /etc/os-release 2>/dev/null; echo "$ID $ID_LIKE"; id -u'`. Expected: Linux
   with debian or ubuntu (or Darwin), and a uid other than 0. Anything else: stop and tell me.
3. Prerequisites. `ssh <dest> 'command -v curl git; sudo -n true && echo sudo-ok'`. curl is required. If sudo needs
   a password, the sudo steps are mine: you give me the commands and I run them with `ssh -t <dest>`.
4. Dry run, nothing changes:
   from GitHub: ssh <dest> 'curl -fsSL https://raw.githubusercontent.com/mbenaiss/nuo/main/install.sh | bash -s -- --yes --dry-run --no-2fa [--port P] [--listen all|local]'
   from my checkout: scripts/install.sh --host <dest> --from-local --yes --dry-run [--port P] [--listen all|local]
   Expected: the plan, then "dry run: nothing was changed". List every "would run: sudo ..." line for me.
5. Install, once I agreed to the sudo commands: the same command without --dry-run. Expected: exit code 0 and
   "healthy: http://127.0.0.1:<port>/api/health". Running it again is safe: it updates and keeps the settings.
6. Check over ssh:
   - `curl -fsS http://127.0.0.1:<port>/api/health` contains "ok":true and lists the agents;
   - `systemctl --user is-active nuo-gateway` = active, `systemctl --user is-enabled nuo-gateway` = enabled,
     `loginctl show-user "$USER" -p Linger` = Linger=yes (macOS host: launchctl print, state = running);
   - `ls -l ~/.secrets/nuo.env` shows -rw------- and ~/nuo/config/env links to it;
   - `ss -ltn | grep :<port>` matches what I chose;
   - from my computer, on the same network: `curl -fsS http://<host address>:<port>/api/health` answers, unless I
     chose "local". If it does not, report what you see (firewall, routing); change nothing.
   Commands over ssh run without a login shell: call bun as ~/.bun/bin/bun.
7. Agents. On the host, as the ssh user, install each agent I want as described in docs/install.md "Requirements"
   (no sudo; the npm packages need Node.js 20 or newer: if node is missing or older, ask me how to install it).
   Tell me the login commands to run myself with `ssh -t <dest>`. After my logins, restart the gateway
   (systemctl --user restart nuo-gateway) and check that /api/health shows "authenticated":true for them.
8. Hand over 2FA and pairing. Tell me to run, in a terminal outside this session:
   ssh -t <dest> 'cd ~/nuo/app && ~/.bun/bin/bun run src/cli.ts auth-totp-setup'   (scan the QR code, keep the recovery codes)
   ssh <dest> 'systemctl --user restart nuo-gateway'
   ssh -t <dest> 'cd ~/nuo/app && ~/.bun/bin/bun run src/pair.ts'                    (valid 10 minutes)
   and the app fields: gateway URL (http://<host LAN address>:<port>, or my reverse proxy URL), profile "owner",
   the pairing code, the authenticator code. Pairing only works from the local network or a VPN.
9. Away from home, if I asked: summarize the options of docs/install.md "Network" for my case. Change nothing.

WHEN SOMETHING FAILS, diagnose before retrying:
- "no terminal to ask on": rerun with --yes, once I agreed to the sudo commands;
- "no systemd user manager": I log in once with `ssh <dest>`, then rerun;
- "bun ... is older than": `~/.bun/bin/bun upgrade` (ask me first), then rerun;
- "has local changes" in the checkout on the host: never discard them; show me git status and ask;
- the gateway does not answer: `journalctl --user -u nuo-gateway -n 80 --no-pager`; a port already in use shows in
  `ss -ltnp`: propose another NUO_PORT in ~/.secrets/nuo.env (edit only that line, with my yes), then restart;
- an agent "not installed" although installed: the gateway looks in ~/.local/bin, ~/.bun/bin, ~/.npm-global/bin,
  /home/linuxbrew/.linuxbrew/bin, /usr/local/bin; tell me where it is instead of moving it;
- Ubuntu prints that the shared browser stays off: expected without Google Chrome; ask before installing Chrome;
- the host is unreachable from my phone: report the listening address, the host firewall state (read only:
  `sudo -n nft list ruleset` or `sudo -n ufw status` if sudo works without a password) and the network path;
  change nothing.

END WITH THIS REPORT:
## Nuo install report
- Host: ssh destination as I gave it, OS and version, user
- Source: GitHub (commit) or my checkout with or without the private overlay
- Gateway: health URL on the host, version, service state, linger
- Settings: port, listening address, env file path and mode (no values)
- Reachable from my computer: yes / no / not tested, and why
- Agents: one line each: ready / installed, not logged in / not installed
- Commands run with sudo: the list, or "none"
- Left for me: numbered (logins, 2FA, pairing, building the app, remote access)
- Problems met and how they were solved
- Confirmation: no port opened, no firewall, router, cloud, tunnel or VPN change, no secret printed
```

## Why the prompts are written this way

- They point at the repository's files instead of repeating them, so they stay right when the installer changes.
- Every step has a check with an expected result: the agent reports facts, not intentions.
- The list of things to ask first and never to do without a yes matches what the installer itself refuses to do
  silently: `sudo` is always shown first, and network exposure is always your decision ([security.md](security.md)).
