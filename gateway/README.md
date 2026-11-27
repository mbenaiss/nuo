# Nuo Gateway

Bun server between the iOS app and the agent CLIs (ACP). Contract: `../docs/protocol.md`.

```sh
bun install
bun run start        # HTTP + WebSocket on NUO_PORT
bun run pair         # prints a one-time 6-digit pairing code (10 min)
bun run typecheck && bun test
bun run sync-seed    # adds the seed bots' slash commands to an existing data dir (new version per bot, idempotent)
../scripts/deploy-gateway.sh   # rsync to dev + systemd user unit nuo-gateway
```

New host, migration, backup/restore, upgrade, uninstall: `../docs/install.md` (`scripts/install.sh`,
`scripts/backup.sh`, `scripts/restore.sh`).

## Environment

On `dev` these live in `~/nuo/config/env` (loaded by the systemd unit), a link to `~/.secrets/nuo.env`; every
variable is listed in `../deploy/nuo.env.example`. Folder layout: `../docs/layout.md`.

| Variable | Default | |
|---|---|---|
| `NUO_PORT` | `8790` | listen port |
| `NUO_HOST` | all interfaces | listen address |
| `NUO_HOME` | `~/nuo` | root of everything below (`config/`, `data/`, `bots/`, `instructions/`, `memory/`) |
| `NUO_DATA_DIR` | `$NUO_HOME/data` | `nuo.db`, `media/` only |
| `NUO_CONFIG_DIR` | `$NUO_HOME/config` | live `tools.json`, `bots.seed.json`, `machine-tools.json`, copied from `gateway/config` when missing |
| `NUO_MAX_SESSIONS` | `3` | live agent sessions (LRU eviction, 10 min idle close) |
| `NUO_LOCAL_TOKEN` | | bearer accepted on `POST /api/notify`, `/api/schedules*` and `/api/bots/:id/memory` only |
| `APNS_KEY_PATH`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC` | | APNs .p8 key; push is a no-op when unset |

`gateway/config` ships examples only: one bot with its tool server, generic machine tools and a reminders dashboard.

## Private additions

A private deployment can lay its own files over `gateway/` (same relative paths) before starting the gateway:

- `config/*.json`, `config/dashboards/*.json`: the owner's bots, tools and dashboards (copied only when missing
  from `$NUO_CONFIG_DIR` and from a new dashboards folder).
- `src/data/schema/NNN_*.sql` whose first line is `-- owner-only`: the owner's own collections. They are applied
  to the owner's `data.db` only, recorded by name in `_migrations`, so a database that already has them keeps
  working whether the files are present or not.
- `config/finance-collections.json`: a JSON array of collection ids whose edits need a Face ID step-up, on top of
  every collection with a `money` column.

## Bot workspace

Each bot runs with cwd `$NUO_HOME/bots/<slug>/`. Before a session starts, the gateway writes the effective
instructions (bot instructions + memory + card guide + voice rule) to `$NUO_HOME/instructions/<slug>.md`;
`CLAUDE.md`, `AGENTS.md` and `GEMINI.md` in the bot folder are relative symlinks to it. The slug is set once
from the bot name (`cobot`, `voyages-2`) and never changes on rename.
When a bot sets `workdir`, the cwd stays the bot folder so the user's repository is never overwritten:
the instructions tell the agent to work in `workdir` with absolute paths, and its MCP servers start in
`workdir` (unless `tools.json` gives them a `cwd`) with `NUO_WORKDIR` set.

The built-in `nuo` MCP server (schedules, memory) is added to every session. Memory lives in
`$NUO_HOME/memory/<slug>/MEMORY.md`; its newest ~8 KB are injected in the instructions under `## Mémoire`.

MCP servers receive `NUO_MEDIA_DIR` (`$NUO_DATA_DIR/media`): images written there are served at `/api/media/<file>`.
Slash commands of type `tool` bypass the agent: the gateway keeps one MCP stdio client per tool server
(same command, env and cwd as the agents get), closed after 5 min idle.
`envFile` values from `tools.json` are read at session start and never logged or returned by the API.

## Machine tools

`GET /api/machine/tools` lists the CLIs of `config/machine-tools.json` found on the gateway's `PATH` (version probed
with a 3 s timeout), the MCP servers of `~/.claude.json` and the skills of `~/.claude/skills/*/SKILL.md`, cached 1 h.
A `#<id>` tag in a prompt (or a slash command template) prepends a French usage hint for that turn only; the stored
user message keeps the typed text.
