# Bot mail and webhooks: the Cloudflare side

Two public entry points wake a bot from outside ([docs/protocol.md](../../docs/protocol.md), « Réveils »):

- **Webhooks** on `https://hooks.example.com/hooks/<token>`, served by the gateway through the existing tunnel.
- **Mail** to `<bot>@bots.example.com`: Cloudflare Email Routing hands it to this Worker, which parses it with
  `postal-mime` and posts it to `https://hooks.example.com/mail` with a shared secret.

Security rules: [docs/security.md](../../docs/security.md), « Hooks host and bot mail ».

## 1. Hooks hostname in the tunnel, without Access

In the cloudflared config of the tunnel (on `192.0.2.30`), next to the app and booking hostnames, before the final
`http_status:404` rule:

```yaml
ingress:
  - hostname: hooks.example.com
    service: http://<gateway host>:8790
```

Then route the DNS name to the tunnel and restart cloudflared:

```sh
cloudflared tunnel route dns <tunnel name> hooks.example.com
sudo systemctl restart cloudflared
```

Do **not** create a Cloudflare Access application for `hooks.example.com`: Linear, GitHub and the Worker cannot
log in. Check that no wildcard Access application (`*.example.com`) covers it. The gateway serves only the two hook
routes on that hostname and `404` for everything else.

## 2. Gateway environment

In `~/.secrets/nuo.env` on the gateway host (see `deploy/nuo.env.example`), then restart the gateway:

```sh
NUO_HOOKS_HOSTS=hooks.example.com
NUO_MAIL_DOMAIN=bots.example.com
NUO_MAIL_SECRET=<openssl rand -base64 32>
NUO_OWNER_EMAILS=<the owner's own addresses, comma separated>
```

`NUO_MAIL_AUTHSERV_ID` only needs setting if Cloudflare's `Authentication-Results` header ever starts with
another name than `mx.cloudflare.net` (look at the raw source of a routed mail to check).

## 3. Deploy the Worker

```sh
cd deploy/mail-worker
bun install
npx wrangler@4.156.2 login
npx wrangler@4.156.2 secret put MAIL_SECRET      # paste the same value as NUO_MAIL_SECRET
npx wrangler@4.156.2 deploy
```

`wrangler.toml` holds no secret: `GATEWAY_URL` and the optional `FALLBACK_FORWARD`, a verified Email Routing
destination address that gets the mail when the gateway cannot take it (down, refused, rate limited). Left empty,
such a mail is dropped and logged. A recipient the gateway does not know (`404`) is bounced with `Unknown recipient`.

Set `GATEWAY_URL` to your own hooks hostname before deploying. To keep your values out of the repository, put a
copy of `wrangler.toml` in `private/deploy/mail-worker/` ([private overlay](../../docs/private-overlay.md)) with
`main = "../../../deploy/mail-worker/src/index.ts"`, and deploy it with
`npx wrangler@4.156.2 deploy --config ../../private/deploy/mail-worker/wrangler.toml`.

Logs: `npx wrangler@4.156.2 tail nuo-mail`.

## 4. Email Routing on the subdomain only

The apex `example.com` usually receives your own mail elsewhere (iCloud, Google Workspace): Email Routing must
never be enabled on it. Enable it for the subdomain only:

1. Dashboard → `example.com` → Email → Email Routing → Settings → **Subdomains** → add `bots`. Cloudflare adds the
   MX and SPF TXT records of `bots.example.com` and leaves the apex records alone. Check in DNS that the apex MX
   still point to your mail provider.
2. Email Routing → Routing rules → **Catch-all address** of `bots.example.com` → action *Send to a Worker* →
   `nuo-mail` → enable. Every bot address then works without a rule per bot; the gateway decides which exist.
3. If `FALLBACK_FORWARD` is set, add that address under Destination addresses and confirm it.

A bot's address is shown in its settings in the app (« Réveils »): `<slug>@bots.example.com`, or its alias.

## 5. Check

```sh
# 404: the hooks host serves nothing else
curl -s -o /dev/null -w '%{http_code}\n' https://hooks.example.com/api/health
```

Create a webhook in the app (bot settings → Réveils), then:

```sh
curl -s -X POST '<url copied from the app>' -H 'content-type: application/json' \
  -d '{"action":"create","data":{"title":"Bug checkout iOS"}}'
```

Send a mail from one of `NUO_OWNER_EMAILS` to the bot's address (in To or Cc): the bot's « Mes e-mails »
conversation gets the request as a goal turn. A mail from any other address lands in « E-mails non vérifiés » and
runs untrusted.

Email Routing puts its own `Received` line first, then its ARC, `Received-SPF` and `Authentication-Results` headers,
closed by `X-CF-*` headers. The Worker passes on only an `Authentication-Results` header inside that closed block (as
seen on a real routed Gmail on 2026-11-27); if Cloudflare ever changes that layout, the owner's mail simply runs
unverified.

## Tests

```sh
bun install && bun run typecheck && bun test    # also run by `make all`
```
