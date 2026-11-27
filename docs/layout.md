# Files on the gateway machine

Everything the gateway keeps on its host lives in one folder, `NUO_HOME` (default `~/nuo`). Each profile
([profiles.md](profiles.md)) has its own tree under `profiles/`; the owner's is `profiles/owner`:

```
~/nuo/
  app/                    gateway code (repo gateway/), replaced by every scripts/deploy-gateway.sh
  os/                     profile-os-setup.sh, profile-os-remove.sh, nuo-agent, nuo-firewall (run with sudo by the user)
  config/                 chmod 700, gateway-wide (and the owner's tools)
    env                   chmod 600: NUO_LOCAL_TOKEN, APNS_*, NUO_PUBLIC_URL, NUO_CF_ACCESS_CLIENT_ID/SECRET,
                          NUO_TUNNEL_SOURCES, NUO_PROXY_SOURCES, … (systemd EnvironmentFile, bun --env-file on macOS)
    apns.p8               chmod 600: APNs key (APNS_KEY_PATH)
    tools.json            live copies, edited here; copied from app/config only when missing,
    machine-tools.json    so a deploy never overwrites them (app/config stays the repo default)
    bots.seed.json
  profiles/               chmod 700
    registry.db           profiles (id, name, disabled, command tasks allowed) and pairing failures of all profiles
    owner/                chmod 700: the owner's tree (below)
    alice -> /srv/nuo/alice   another profile, moved out of the owner's home by profile-os-setup.sh
  data, docs, dashboards, bots, instructions, memory, browser
                          links to profiles/owner/… left by the migration (installs from before profiles only)
  archive/                legacy assistant files (OpenClaw/clawd); archive/profiles/<slug>-<date> = deleted profiles
```

A profile tree (`profiles/owner`, or `/srv/nuo/<slug>` for the others):

```
  data/                   chmod 700
    nuo.db (+ -wal, -shm) bots, conversations, messages, tasks, devices (public keys, APNs tokens), hashed access/
                          extension tokens, the sealed TOTP secret, hashed recovery codes and pairing codes, the auth
                          audit log (auth_events, auth_requests)
    media/                images produced by tools and attachments, served at /api/media/<file>
    data.db (+ -wal, -shm) collections, reminders and their history (docs/data.md), created and migrated at start
    files/                attachments of data rows (`file` columns hold paths relative to this folder)
  docs/                   git repository of Markdown documents; initialised with a first commit at start
  dashboards/<slug>.json  dashboard definitions; app/config/dashboards/*.json are copied on the owner's very first run
  bots/<slug>/            agent cwd of each bot (cobot, voyages, coach…)
    .nuo/attachments/  files sent from the app (other profiles: inbox/<slug>/.nuo/attachments, see below)
    CLAUDE.md, AGENTS.md, GEMINI.md -> ../../instructions/<slug>.md
  instructions/<slug>.md  effective instructions the agent reads, regenerated at every session start
                          (bot instructions + memory + card guide + voice rule)
  memory/<slug>/MEMORY.md persistent memory of the bot (nuo MCP tools memory_*, GET/PUT /api/bots/:id/memory)
  browser/                chmod 700, owner only: the shared browser (nuo-browser.service, docs/protocol.md « Shared browser »)
    profile/              Chrome profile with the user's logged-in sessions; backed up only with --with-secrets
    Xauthority            cookie of its private Xvfb display
  config/                 other profiles only, chmod 700 (no tool servers by default)
  home/                   other profiles only: HOME of nuo-<slug> (2770 nuo-<slug>:<owner group>), the person's CLI
                          logins (~/.claude, ~/.codex, ~/.gemini, ~/.grok) and .config/nuo/agents.env (API keys)
  inbox/<slug>/           other profiles only: files the gateway writes for the agent (outside the folders it can write)
```

Other profiles' trees: `/srv/nuo` is `root 0711` (not listable), `/srv/nuo/<slug>` is `<owner>:nuo-<slug> 0750`;
the gateway keeps `data`, `docs`, `dashboards`, `memory`, `browser`, `config` at `0700` and makes each bot folder
`2777` (only the gateway and `nuo-<slug>` can reach it). `/srv/nuo/runtime` (owner, `0755`) holds what profile users
run from the gateway: a copy of bun, the bundled `nuo` MCP server and a link to the Claude CLI bundled with
claude-agent-acp, refreshed at every gateway start.

- The slug comes from the bot name when the bot is created (lowercase ascii, `-`, `-2` suffix when taken) and is
  stored in the database: renaming a bot never moves its folders. Deleting a bot deletes its folder, instructions
  and memory.
- A bot with `workdir` (e.g. `/home/alex`) still runs in its bot folder; the instructions point it at
  `workdir` and its MCP servers start there.
- `NUO_DATA_DIR` and `NUO_CONFIG_DIR` still override the owner's `data/` and the gateway `config/` alone
  (tests use temporary folders for everything).
- The CLI (`bun run src/cli.ts …`) works on the owner's tree unless a command takes a profile
  (`pair-code <slug>`, `auth-* --profile <slug>`, `profile-*`).
- `data.db` schema files are `app/src/data/schema/*.sql`, applied once each (table `_migrations`); history triggers
  are regenerated at every start and by `bun run src/cli.ts data-triggers`. Notion exports are imported with
  `bun run src/cli.ts data-import <dir>` (see docs/data.md).
- `~/.secrets/nuo.env` (chmod 600, outside `NUO_HOME`, never deployed or backed up with it) holds
  `NUO_AUTH_KEY`, the key that seals the TOTP secret in `nuo.db`. `bun run src/cli.ts auth-totp-setup`
  creates it when missing; the gateway reads it at start (`NUO_AUTH_KEY` in the environment wins,
  `NUO_SECRETS_FILE` changes the path). Losing it means running `auth-totp-reset`; paired devices keep working.
- `scripts/nuo-notify` reads `~/nuo/config/env`, then `~/.config/nuo/env` (`NUO_ENV_FILE` overrides).
- `bun run sync-seed` reads the live `config/bots.seed.json`; to push the repo's seed commands, run it with
  `NUO_CONFIG_DIR=~/nuo/app/config`.

## Migrating to profiles

At its first start, a gateway with profiles moves `data`, `docs`, `dashboards`, `bots`, `instructions`, `memory` and
`browser` from `~/nuo` to `~/nuo/profiles/owner/` (a rename: same filesystem, nothing copied) and leaves a
relative link at each old path, so `nuo-browser.service`, `nuo-notify` and old scripts keep working
(`src/profiles/migrate.ts`). It is idempotent: a path that is already a link is skipped, and a destination that
exists is never overwritten (the old folder stays, with a warning). Claude Code's session history of each bot
folder (`~/.claude/projects/<cwd>`) moves with it. The registry gets the `owner` row; paired devices keep working.
A backup first is cheap: `scripts/backup.sh --host … --with-secrets`.
