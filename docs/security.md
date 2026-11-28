# Nuo security model

One owner and a few friends, each in an isolated profile ([profiles.md](profiles.md)), one gateway on
a host the owner controls, clients: iPhone/Mac apps and their extensions (share, widgets, watch). The gateway can run shell commands, read personal data and drive agents on that host, so anyone who gets a
working token gets a lot. Wire format and endpoints: [protocol.md](protocol.md#auth).

## Layers, outside in

| Layer | Protects against | Mechanism |
|---|---|---|
| Cloudflare Access | Anonymous internet traffic, scanners, exploits of the gateway's unauthenticated routes | The tunnel hostname only lets through requests with the Access service token (`CF-Access-Client-Id/Secret`). No inbound port on the home network (cloudflared dials out). |
| Network zones | Enrolment from outside, spoofed client IPs, the local token leaking through a proxy | `local` / `lan` / `internet` from the peer address; forwarding headers believed from Caddy and cloudflared only; any Cloudflare header means `internet`. `/api/pair` is 404 from the internet. |
| TOTP + pairing code (enrolment) | A stolen Access token or a LAN intruder enrolling a device | Pairing needs the profile name, the one-time code printed on the gateway host for that profile **and** that profile's TOTP/recovery code. Unknown profile and wrong codes get the same `401` after the same minimum delay. 5 failures per IP, 10 per typed profile name, 20 in total per 15 minutes lock pairing (persisted). Every pairing and repeated failures push an alert. |
| Profiles | A friend's device, agent or token reaching the owner's (or another friend's) data | One set of databases and folders per profile, one set of services per profile: another profile's ids are `404`; sockets, pushes and local tokens are per profile. Other profiles' agents and command tasks run as their own Linux user `nuo-<slug>` through a single sudo-allowed launcher, cannot read the owner's home or other trees, and only reach the gateway port on loopback (no DevTools, no home network). |
| Device key | Token theft from backups, other apps or another device | P-256 key generated at pairing, in the Secure Enclave when available (non-exportable), else a this-device-only Keychain key. Refresh and step-up need a signature of a fresh server nonce. |
| Short access tokens | Replay of a captured token | Opaque, 15 minutes, stored hashed, bound to the key thumbprint (`cnf`), revoked with the device; sockets are closed when their token expires. |
| Scoped extension tokens | A compromised extension or watch reaching everything | `share`, `widgets` (read only), `watch` tokens limited to the routes they need, 30 days, no step-up. Their text, and a machine token's, cannot attach a file: Claude Code reads any file named `@path` in a prompt without a tool or a permission, so every `@` but one after a letter, a digit or a slash (addresses, shared links) becomes `＠` (`src/agents/mentions.ts`), in the transcript too. |
| Bot without tools | A bot reading other people's words (meeting notes) steered into acting | `noTools` in the bot's config: no MCP server (not even `nuo`), no built-in tool, every permission refused, every `@` that could start a file mention neutralized; Claude only (others keep built-in tools). Read only is not enough: it still reads files and uses `nuo`. |
| App lock | Someone holding the unlocked phone or Mac | Face ID / Touch ID (passcode fallback) at launch and after 0/1/5/15 minutes in the background; blurred screen in the app switcher. |
| Biometric step-up | Same, for the dangerous actions | Revoking a device, editing finance collections, creating/editing command tasks, deleting documents need an access token minted by a signed step-up less than 60 s after Face ID. Revealing, adding, editing or deleting a secret needs one step-up per call. Enforced by the gateway. |
| Overview bot | A bot reading e-mails or web pages, steered into reading every conversation | The local token, shared by all of a profile's bots, never reaches `/api/bots` or `/api/conversations` alone: the overview routes (`src/api/overview.ts`: list bots, search, read a conversation, ask a bot) also need `x-nuo-conversation` naming a conversation whose bot has `overview`, and only those bots' `nuo` server lists the tools. Since an overview bot can ask a bot with full access, share, watch and machine tokens are refused on it like on an `auto` bot. Bots running as the gateway user can still read `nuo.db` from a shell. |
| Secrets manager | A stolen session or a bot reading or rewriting the machine's secrets | `/api/secrets` (owner profile, app scope only; extension and local tokens refused, so no MCP tool reaches it): the list carries names only, a value leaves the gateway only through `reveal`; each reveal and change is an `auth_events` row naming the file and key, never the value. Writes replace the file atomically with its permissions and its other lines kept. Bots running as the gateway user can still read `~/.secrets` from a shell. |
| Speech to text | A stolen session running up the transcription bill, the provider's key leaking | `/api/transcriptions` is for the paired app only (extension tokens `403`), 120 calls per device per 10 min and 3 at once, 64 MB per recording; a background job is read, stopped (`DELETE`) or found again only by the device that sent it. The app sends the audio to the gateway, which calls the provider with `NUO_ELEVENLABS_API_KEY`: the key never reaches a device. Meetings send only the voiced parts of each stream, and the Mac deletes the recording once transcribed. A meeting stream sent as a background job is written to the profile's data folder (`<data>/transcriptions/<id>.audio`, file 0600 in a 0700 folder: a friend's profile's agents, which run as their own Linux user, cannot read it; the owner's bots run as the gateway user and can) only while it is transcribed: deleted as soon as the result or an error comes back, or when a restart finds it orphaned. The job's `<id>.json` (0600) holds its state and, once done, the text, readable only by the device that sent it and deleted 24 h after it finished (the text only: the audio is never kept that long). |
| Scheduled tasks of bots | A bot without full access lending itself `auto` by scheduling a task for a bot that has it | A task runs later as the bot it names, with that bot's policy: through the local token (`nuo` server, `x-nuo-conversation`), a bot whose policy is not `auto` cannot create, retarget, rewrite or run now a task of an `auto` bot (`403`); only the app, or an `auto` bot, can. |
| Relay access (watch) | The watch's spoken requests lost while the iPhone is locked; that access turned against the owner by whoever holds the locked iPhone | A third P-256 key of the device, kept by the iPhone `AfterFirstUnlockThisDeviceOnly` in the Secure Enclave (so usable while locked, from the first unlock after a restart; no software fallback outside the simulator), apart from the device key (`WhenUnlocked`) and the Face ID key. Set up only from the app's consent screen with a Face ID given for that action (step-up `reason: relay`, used once), from home only, and on the owner's profile only: the gateway refuses a relay key or token to any other profile. One per device, replaced or revoked from « Sécurité » on that iPhone (`POST`/`GET`/`DELETE /api/auth/relay` act on the calling device only, the `GET` giving the key's thumbprint), gone with the device: a lost iPhone is cut off by revoking the device from another one. Revoking either stops its running turns. It signs a nonce for a `relay` token (`POST /api/auth/relay-token`, 15 minutes, bound to the device). A `relay` token reaches only, route by route (`src/api/relay.ts`): a short dictation (4 MB, never a background or named job, by header, form field or query string, within the device's transcription budget), the published bots by name and emoji, opening a conversation (20 an hour), and, in the conversations it opened only (`relay_conversations`), prompting (text only, no slash command however padded, 4,000 characters, 30 an hour), reading the turn and its messages, and answering `allow_once` or `reject_once` a confirmation its own relay turn asked. **A relay turn can only add**, enforced by the gateway, not by the prompt (`src/relay/whitelist.ts`, every tool classified and tested): its session (and the session of any bot an overview bot asks during it, and that session's later unprompted work) gets no built-in tool but the schema loader, no third-party MCP server or browser, and only the `nuo` server's add tools: a reminder (add, or tick one by 3 characters or more of its title), an event (create; move only one this turn created; Google with no `attendees` field at all, in any form, and the field is dropped from what the local route passes on), a note (new file only), a collection item (no finance collection), a request to a bot in a new conversation; each asks first, whatever the bot's policy, and the watch shows what the yes adds, in the user's language (`Add the reminder "Dentist appointment", Thu, Nov 19, 09:00`), with « once » answers only. Any other tool is refused before anyone is asked, again on every local route the `nuo` server calls for that session (each add route passes once per yes given), and answers "to do from the unlocked iPhone": reading mails, Drive, Mac files, documents, collections, conversations, memory, the location; sending anything; deleting or changing what exists; scheduled tasks; the shell. **Nothing is read through the prompt either**: Claude Code attaches a file named with `@` (`@/path`, `@../path`, `@"path"`) without any tool, so a relay prompt, and the text a bot passes on with `bot_ask` during a relay turn, has every `@` that could start one turned into `＠` (`src/agents/mentions.ts`, as for extension tokens; an e-mail address is left as it is), in the transcript too. A relay session works in its own empty folder (`<instructions>/relay/<bot>`, not under the bot's folder, whose `CLAUDE.md` holds the memory) and gets the bot's instructions in the system prompt, without its memory, the database schema or the data paths; the bot's shared `CLAUDE.md` is not rewritten. The request then waits on the iPhone and goes through the app once it is unlocked. **The app's turns stay out of the relay's reach**: the first turn of the app in a conversation the relay opened takes it back (it leaves `relay_conversations`: the relay token no longer reads or prompts it), and a relay session keeps its own Claude session (`agentSessions["claude:relay"]`), never resumed by the app nor resuming the app's (an idle compaction keeps it under that key), with no transcript of the conversation's other turns. At the unlock, the app's fresh session gets the relay turns' transcript before the iPhone's follow-up, so the request it replays is the whole one. A relay turn cut by a restart is not started again (it would run as the app's): it is closed with a notice and waits for the unlock. **What the watch shows is what is done**: a time is taken only as written, `YYYY-MM-DDTHH:MM` in Paris time (`at`, `start`, `end`; any zone, seconds or whole day is refused), the account and the calendar cannot be chosen (`account`, `calendar_id`, `calendar` are dropped: the default ones), a Google or device error reaches the relay only as "did not go through" (it would name accounts or calendars), and the confirmation says the time and the end (`10:00-11:00`, or `until Tue, Nov 16, 2027, 10:00` on another day), the place, the alerts, the whole day, the recurrence (`every day`, `every 2 weeks`) and `+ attached text` when notes, a description, a URL or a note's text go with it. What an event tool answers comes back without the account, the link or the calendar: a Google event's id and title, an Apple event's own fields without its calendar, account, organizer or attendees. Bots on another agent than Claude never run a relay turn, asked directly or through `bot_ask` (`409`, waits for the unlock). Each key change, token, conversation, prompt, confirmation (with its tool), refused tool (`relay_refused`) and dictation is an `auth_events` row. |
| Santé on the iPhone | Health data spreading beyond the question that needed it, or a bot writing to Santé | The `health_*` tools read HealthKit inside the iPhone app, at the moment of the call, and answer into that turn only (`docs/health.md`): the gateway stores no figure, no sample and no session — only the list of tool names the device allows. Nuo asks Santé for read rights only, never write, so no bot can change what Santé holds. The user grants each data type in Santé's own sheet and can cut the whole family in Nuo › Réglages › Accès des bots; the app declares the tools only while both say yes. A Mac holds no Santé data and never declares them, so there is no Mac fallback, and a locked iPhone answers that Santé is locked rather than giving a partial read. `workout_schedule` writes nothing to Santé: it puts a session in Fitness, which syncs it to the watch, and WorkoutKit asks the user separately. Every one of these tools is refused during a relay turn (`src/relay/whitelist.ts`). |
| Audit and revocation | Undetected or lasting compromise | `auth_events` (pairings, refreshes, step-ups, revocations, failures, rejected local/legacy tokens) and `auth_requests` (every internet request: IP, route, status, device), shown in « Activité de sécurité ». `DELETE /api/devices/:id` or `auth-revoke` cuts a device and its extensions at once. |

Secrets on the gateway host: `NUO_AUTH_KEY` in `~/.secrets/nuo.env` (0600) seals the TOTP secret in `nuo.db`;
recovery codes, pairing codes and tokens are only stored as SHA-256 hashes; the local token
(`NUO_LOCAL_TOKEN`) is only accepted from a direct loopback connection.

Internet hardening in the gateway: per-route body limits, `Content-Length` required, no CORS, security headers,
generic auth errors, `405` shown as `404`, minimal `/api/health`. There is deliberately no request-volume rate
limiting on the app's hostnames: only failed pairing attempts are counted and locked out. The hooks host has its own
limits (below).

## Public booking host

The booking pages (`NUO_BOOKING_HOSTS`, e.g. `rdv.example.com`, see [calendar.md](calendar.md)) are the only
unauthenticated internet surface. Cloudflare Access must not protect that hostname; instead the gateway serves it
from a separate router chosen by the `Host` header, before the auth gate: only the booking page, free slots, the
booking POST, the manage link pages and two static assets exist there, everything else is `404`, and the app's
hostnames never serve them. They expose free slots only (no titles, calendars or other bookings), check a Cloudflare
Turnstile token and a honeypot on every write, take strict JSON bodies of at most 16 KB, and send a strict CSP
(no inline script/style, scripts and frames only from self and `challenges.cloudflare.com`). The manage link token
(32 random bytes) is stored hashed. No request-volume rate limiting there either, by choice.

## Hooks host and bot mail

The hooks host (`NUO_HOOKS_HOSTS`, `hooks.example.com`) is the second unauthenticated internet surface, outside
Cloudflare Access (an Access application covers one hostname; none covers this one). Like the booking host it is routed
by the `Host` header before the auth gate (and before the Google OAuth callback), and serves two routes only:
`POST /hooks/<token>` and `POST /mail`; everything else is `404`, and the app's hostnames never serve them ([protocol.md](protocol.md#wake-ups-from-outside--réveils-)).

- **Secrets.** A webhook token is 32 random bytes, stored as a SHA-256 hash and shown once to the app; revoking it
  is immediate. `POST /mail` needs `NUO_MAIL_SECRET` as a bearer token, compared in constant time; the same value
  is a Worker secret, never in `wrangler.toml` or the repository. Without it the route does not exist.
- **Limits.** Bodies of 64 KB (webhooks) and 512 KB (mail), read as a capped stream. Per hour, in separate budgets
  so a stranger never blocks the owner: 30 turns per hook and 300 for all webhooks; 30 per bot for the owner's verified
  mail; 5 per sender and bot, 20 per bot and 60 in all for unverified mail, which all goes to one « E-mails non
  vérifiés » conversation per bot. 30 refused calls from one IP lock that IP out of the host. Counters live in memory.
- **Untrusted turns.** A webhook body and any mail that is not the owner's verified own run with `untrusted: true`:
  never a goal, no `@` file mention, no Claude Code command, the content wrapped between markers the bot is told to
  read as data, with the sender's own markers defused. The bot's policy still applies: an `ask` bot asks the user
  before each sensitive action, and these turns cannot answer for him.
- **Trust rule for mail.** Trusted (a goal turn) only when the From address is one of the owner's
  (`NUO_OWNER_EMAILS`, or a Google account connected to the profile), **and** Cloudflare's own
  `Authentication-Results` (authserv-id `mx.cloudflare.net`, the one stamped right under Email Routing's own `Received` line and closed by its `X-CF-*` headers, parsed per
  RFC 8601) shows DMARC pass for the From domain or an aligned DKIM or SPF pass, **and** the bot's address is in To or
  Cc, **and** the Date is under 2 days old. The From header alone never counts; a verdict header written by the sender,
  unbalanced syntax or a repeated SPF or DMARC result count as unverified, and a quoted string is read whole, so an
  envelope sender cannot smuggle `;dmarc=pass` through one (Cloudflare itself quotes `smtp.remote-ip`). The To/Cc and Date checks stop a genuine signed mail of the owner from being resent to the
  bot later. In a trusted mail, only the owner's own words are the request: quoted and forwarded parts (and a reply's
  subject) are wrapped as external data. Verified and unverified mails live in separate conversations, so unverified
  text never enters a goal turn's context. A goal turn still confirms mails, invitations and deletions on the iPhone.
- **Exposed bots.** A bot with full access (`auto`) or with `overview`, in its published config or its draft, cannot
  get a webhook, and only the owner's verified mail wakes it; an existing hook stops working (`403`) as soon as the
  config its conversation runs on (the draft for a draft conversation) or the published one gains that access.
- **Audit.** Hook creation, revocation, every call and every mail are auth events (`hook_create`, `hook_revoke`,
  `hook_call`, `mail_wake`) with the IP and the sender.
- **Known limits.** Anyone holding a webhook URL can start turns up to the limits: treat it like a password and revoke
  it from the app if it leaks. Webhook signatures (GitHub, Linear) are not checked; the token in the URL is the
  credential. Rate limits reset when the gateway restarts. Mail trust rests on Cloudflare's verdict and on the
  Worker passing only the header inside the block Email Routing stamps under its own `Received` line; an account compromise at the owner's mail provider makes its
  mail trusted. Telling the owner's words from a quote relies on the usual markers: a quote pasted without them reads
  as the owner's own words, and an HTML-only mail loses its `<blockquote>` structure in the Worker's text conversion.

## Shared browser

A persistent Chrome on the gateway host keeps the user's logged-in sessions (LinkedIn…) for their agents. The user
types every password and 2FA code themselves in the app's « Navigateur » screen; agents are told never to type credentials, solve
captchas or read cookies, to call `browser-login-needed` instead, and to get an explicit confirmation before any
outbound action (bot instructions). Protections:

- DevTools (full control of the browser, cookies included) listens on `127.0.0.1` only; the live view reaches the
  app through `/api/browser/ws` on the existing port and auth: paired app token only (no extension or local token),
  same `4401` closes as `/api/ws`. No new port, daemon or VNC; works through Caddy and the tunnel.
- The Xvfb display needs a cookie (`~/nuo/browser/Xauthority`, 600) and listens on no TCP port.
- `~/nuo/browser` and the profile are 700. Chrome runs with `--password-store=basic` (no keyring on a headless
  host): the cookies on disk are only protected by these permissions, so the profile is only included in
  `scripts/backup.sh --with-secrets` (encrypted archive), without caches. It does not inherit the gateway's env file.
- The gateway never logs frames, input, typed text or cookies; the address bar only opens `http(s)` URLs.
- One browser per profile. The owner's runs as the gateway user (`nuo-browser.service`, `127.0.0.1:9222`).
  Another profile's runs as `nuo-<slug>` through the launcher (Xvfb and Chrome, profile `/srv/nuo/<slug>/home/.browser`,
  700), on `127.0.0.1:<29000 + uid of nuo-<slug>>`, started on demand by the gateway and stopped when idle like the
  owner's. `nuo-firewall.service` lets each `nuo-*` user connect to its own port only (and its Chrome answer there),
  never to `9222` or another profile's. Its agents use `nuo-browser`, which reads the profile's local token from
  `/srv/nuo/<slug>/gateway.env` (644 in a tree only that user and the gateway can enter, rewritten at each start).
- Known limits: any process of the gateway user can drive the browser through `127.0.0.1:9222` (the owner's agents do,
  by design); while the user watches from an iPhone, the viewed page is laid out at the phone's width for agents too.
  Sites may detect automation (CDP) and lock the account; their terms may forbid it (LinkedIn does).

## Goal mode

A prompt sent with `goal: true` from the paired app (never an extension, the watch or the relay) runs without
confirmations: for that turn only, the gateway answers the agent's permission requests with « allow once ». The bot's
policy still bounds it: a `readonly` bot stays read-only (its refusals never reach the user), and a goal on an `ask`
bot gives that one turn the reach of `auto` without a Face ID step-up, because the user asked for it in the unlocked
app. The composer keeps « Objectif » on until the user turns it off, so each message sent meanwhile is its own goal
turn; the gateway never carries a goal over to a prompt that does not ask for it. What acts on other people or loses data is held where it runs, whatever the agent and its own mode (Grok's
`yoloMode` included): the `nuo` server's calls to `gmail_send`, `calendar_create` with guests, `calendar_delete`,
`apple_event_delete`, `apple_calendar_delete` and `workout_cancel` wait on `/api/google/tools/*` and
`/api/device/tools/*` for a confirmation that names the recipients, the subject or the event (`src/runner/goal.ts`).
Known limit: an `auto` bot can reach Gmail or a calendar by other means (the `gog` CLI on the host) that this check
does not see; its instructions still ask it to use the Nuo tools.

## Tool rules

From a permission card the user can keep, for one bot, « Toujours pour cet outil » (`allow`) or « Bloquer cet outil »
(`block`), and remove either from the bot's settings (`BotConfig.toolRules`, docs/protocol.md « Tool rules »).

- A rule is per tool, not per call: allowing `Bash` lets that bot run any command without a card from then on, so the
  card names the tool before the user keeps it. No Face ID step-up: it widens less than `auto`, which needs one.
- `block` is checked before the policy and the goal mode: it refuses even on an `auto` bot or in a goal turn.
- `allow` only spares the card under `ask`: it never widens a `readonly` bot, and the session decides again at each
  call, so a removed rule applies at once.
- Sending, inviting and deleting through Nuo's own tools stay confirmed: the gateway never offers nor stores an
  `allow` for them, and ignores one for a `calendar_create` with attendees.
- A call the agent does not name (a tool from an agent other than Claude whose title is not `mcp__server__name`) is
  never decided by a rule; it gets the card as before.
- The relay ignores the rules: its sessions keep the whitelist and their « once » confirmations, and a rule cannot be
  set from a relay session or from any token but the paired app's.
- Known limit: rules are enforced where the agent asks the gateway. An agent that runs a tool without asking (Codex
  or Grok in `auto`) is not stopped by a `block`.

## What an attacker needs

- From the internet: the Access service token **and** a valid access token (15 minutes) or the device key
  (Secure Enclave, not extractable). Enrolling a new device is impossible from the internet. A friend's valid
  device only gets that friend's profile.
- On the home network/VPN, to enrol: a pairing code (only printed on the gateway host) **and** the TOTP secret or a recovery
  code, within the lockout budget.
- With the unlocked phone: the app lock; for dangerous actions, Face ID again.
- With the locked phone (after its first unlock) and its relay key: requests to the bots that can only add a
  reminder, an event, a note or a collection item (or tick a reminder, or ask a bot to do the same), each with a yes
  given through the relay, 30 requests and 20 conversations an hour, every one in the audit log; nothing to read but
  the conversations the relay opened (until the app writes in them) and what the add tools answer.

## Known limits

- Access tokens are bearer tokens: one stolen from memory or the wire is usable until it expires (15 min). There
  is no per-request proof of possession (DPoP); `cnf` only ties the token to the key the device had when it was
  minted.
- Extension tokens live 30 days in the shared Keychain (readable after first unlock) and skip the app lock: they
  can read bots, conversations and reminders, and (`share`, `watch`) send prompts — which can drive agents.
- The Access service token is a shared secret stored on each device; it only gets traffic as far as the gateway.
- The software fallback key (simulator, Macs without Secure Enclave) is extractable by anyone who can read the
  Keychain of the unlocked device.
- Refresh needs the device unlocked (`WhenUnlockedThisDeviceOnly`): background work while locked relies on a still
  valid access token, the `watch` token, or for the watch's spoken requests the relay key.
- The relay key is usable while the iPhone is locked, by design: someone holding the locked iPhone (after its first
  unlock) can add reminders, events, notes and collection items through it, tick a reminder, and ask bots to do the
  same, answering each confirmation once. What it can learn, by asking: the add tools' answers name what was added;
  ticking a reminder takes 3 characters of its title and says whether one, several (their number only) or none of
  the open reminders match, so trying fragment after fragment reads titles bit by bit; adding to an unknown
  collection lists the names of the non-finance collections, and a failed add their columns; and the bot's own
  instructions, which the relay session has, can be said back in an answer. It reads no mail, file, document, bot
  memory or location, and sends no mail or invitation. An event added to a shared calendar (the default one may be)
  is seen by its other members. Revoking the relay access on that iPhone, or the device from any other one, ends it,
  running turns included; `DELETE /api/auth/relay` acts only on the device that calls it.
- The whitelist holds for Claude sessions: the gateway sets their tools and checks each permission request and each
  local call of the `nuo` server. A Claude Code setting that pre-allows a tool would skip its question, but not the
  gateway's check, which lets an add call through only after a yes given in that turn.
- Rate limits and audit IPs rely on `NUO_TUNNEL_SOURCES` / `NUO_PROXY_SOURCES` being right; a wrong value
  makes every internet client share one IP (lockout) but never upgrades it to `lan`.
- The gateway host itself is trusted: root there can read `nuo.db` and `~/.secrets/nuo.env`. The owner (sudo) can read
  every profile, friends' API keys included; profiles protect people from each other, not from the owner.
- Profile users see process command lines (`ps`) and share `/tmp`; their agents have open internet access and no CPU,
  memory or disk quota ([profiles.md](profiles.md#limits)).
