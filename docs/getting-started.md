# Getting started

Three levels, each one building on the previous:

1. [Try the apps in demo mode](#1-try-the-apps-in-demo-mode): no server, no account, sample data. 10 minutes.
2. [Run the gateway on your computer](#2-run-the-gateway-on-your-computer): pair the apps with a real gateway,
   talk to your own agents. 15 minutes.
3. [Install it on a server](install.md): a gateway that runs all the time, reachable from anywhere.

You need a Mac for the apps.

## Requirements

| For | You need |
|---|---|
| the apps | macOS with Xcode 26 or newer (the apps target iOS, watchOS and macOS 26), [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) |
| the gateway | [Bun](https://bun.sh) 1.4.2 or newer, `git`; at least one agent CLI logged in (Claude Code, Codex, Gemini or Grok, see [install.md](install.md#requirements)) |
| a real iPhone, Mac app or Apple Watch | an Apple developer account (a free one is enough for your own devices, without push notifications) |

The apps' interface is in French for now.

## 1. Try the apps in demo mode

Demo mode runs the apps against a built-in fake gateway with sample bots, conversations, reminders, calendar and
documents. Nothing leaves the device.

```sh
git clone https://github.com/mbenaiss/nuo.git
cd nuo/ios
xcodegen generate
open Nuo.xcodeproj
```

In Xcode:

1. Choose the `Nuo` scheme (iPhone) or `NuoMac` (Mac) and an iPhone simulator or "My Mac".
2. Product, Scheme, Edit Scheme, Run, Arguments: add `-demo` under "Arguments Passed On Launch".
3. Run.

The simulator needs no Apple account. On a real device or for the Mac app, set up signing first
([below](#building-with-your-own-apple-account)).

From the command line, once the app is installed on a booted simulator:

```sh
xcrun simctl launch booted com.example.nuo -demo   # or your NUO_BUNDLE_ID
```

## 2. Run the gateway on your computer

The gateway runs on macOS or Linux without systemd. Everything it writes stays in `.nuo-local/` at the root of the
repository (ignored by git).

```sh
make local-setup    # bun install, then 2FA enrolment: scan the QR code with an authenticator app, keep the recovery codes
make local-run      # gateway on port 8790 (LOCAL_PORT=8791 make local-run to change it); leave it running
make local-pair     # in another terminal: one-time pairing code, valid 10 minutes
```

No setting is required: push notifications, remote access, calendar, speech to text and the other integrations
are off until you configure them. Install and log in to at least one agent CLI first (`claude`, then `/login`, and
`npm i -g @agentclientprotocol/claude-agent-acp`, for example); `curl http://127.0.0.1:8790/api/health` lists the
agents the gateway found.

Then pair the app (run without `-demo`):

| Field | Value |
|---|---|
| Passerelle (gateway URL) | simulator or Mac app: `http://localhost:8790`; iPhone on the same Wi-Fi: `http://<your Mac's address>:8790` |
| Profil | `owner` |
| Code | the code printed by `make local-pair` |
| Second factor | the current code of your authenticator app, or a recovery code |

Pairing only works from the local network (or loopback). To start over, stop the gateway and delete `.nuo-local/`.

The equivalent without make, from `gateway/`:

```sh
export NUO_HOME="$PWD/../.nuo-local" NUO_SECRETS_FILE="$PWD/../.nuo-local/secrets.env" NUO_PORT=8790
bun install
bun run src/cli.ts auth-totp-setup
bun run src/index.ts
bun run src/pair.ts
```

| Variable | Meaning |
|---|---|
| `NUO_HOME` | where the gateway keeps its data (default `~/nuo`) |
| `NUO_SECRETS_FILE` | file that receives `NUO_AUTH_KEY`, the key that seals the 2FA secret (default `~/.secrets/nuo.env`) |
| `NUO_PORT`, `NUO_HOST` | listening port (default 8790) and address (default all interfaces) |

Every other setting is listed in [`deploy/nuo.env.example`](../deploy/nuo.env.example).

## 3. Install it on a server

See [install.md](install.md): `scripts/install.sh` sets up a Debian or Ubuntu host over ssh, and
`scripts/deploy-gateway.sh` deploys later changes.

## Building with your own Apple account

Signing settings live in `ios/Local.xcconfig`, which git ignores; `ios/Base.xcconfig` holds neutral defaults that
build for the simulator.

```sh
cp ios/Local.xcconfig.example ios/Local.xcconfig
```

| Key | Value |
|---|---|
| `DEVELOPMENT_TEAM` | your Team ID, ten characters (Xcode, Settings, Accounts, or developer.apple.com, Membership) |
| `NUO_BUNDLE_ID` | a bundle id you own, e.g. `com.lumenstudio.nuo`. The widgets, share extension and Watch app derive theirs from it |
| `NUO_APP_GROUP` | an app group, e.g. `group.com.lumenstudio.nuo` |
| `NUO_DEFAULT_GATEWAY` | optional: the gateway URL prefilled on the pairing screen |

Then `cd ios && xcodegen generate` and build. Automatic signing creates the identifiers and profiles; with a paid
account the app group and push capability are registered for you. For push notifications, create an APNs key in
your developer account and set `APNS_*` on the gateway ([install.md](install.md#first-pairing)), with
`APNS_TOPIC` equal to `NUO_BUNDLE_ID`.

To hand builds to a few friends (Ad Hoc for iPhone, Developer ID for Mac), see [distribution.md](distribution.md).
