#!/usr/bin/env bash
# Day-to-day deploy of the gateway from this checkout to a host already set up with scripts/install.sh
# (docs/install.md): rsync, bun install, restart. Files under private/gateway/ are laid over gateway/ first
# (docs/private-overlay.md).
set -euo pipefail

HOST="${NUO_DEPLOY_HOST:-}"
if [[ -z "$HOST" ]]; then
  cat >&2 <<'EOF'
deploy-gateway: NUO_DEPLOY_HOST is not set.
Set it to the ssh destination of the gateway host, for example:
  NUO_DEPLOY_HOST=alex@192.0.2.10 scripts/deploy-gateway.sh
  NUO_DEPLOY_HOST=nuo-host make deploy        # an alias from ~/.ssh/config
The host must have been set up once with scripts/install.sh (docs/install.md).
EOF
  exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
rsync -a --exclude node_modules --exclude .DS_Store "$ROOT/gateway/" "$stage/"
if [[ -d "$ROOT/private/gateway" ]]; then
  echo "private overlay: $ROOT/private/gateway"
  rsync -a --exclude node_modules --exclude .DS_Store "$ROOT/private/gateway/" "$stage/"
fi

rsync -az --rsync-path="mkdir -p ~/.config/systemd/user ~/nuo/app && rsync" "$ROOT/deploy/nuo-gateway.service" "$ROOT/deploy/nuo-browser.service" "$HOST:.config/systemd/user/"
rsync -az --delete --exclude node_modules "$stage/" "$HOST:nuo/app/"
# Profile OS setup (docs/profiles.md): run by the user with sudo, from ~/nuo/os.
rsync -az --rsync-path="mkdir -p ~/nuo/os && rsync" "$ROOT/scripts/profile-os-setup.sh" "$ROOT/scripts/profile-os-remove.sh" "$ROOT/scripts/nuo-agent-update.sh" "$ROOT/scripts/nuo-agent" "$ROOT/scripts/nuo-firewall" "$HOST:nuo/os/"

ssh "$HOST" 'bash -se' <<'REMOTE'
set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/.bun/bin:/home/linuxbrew/.linuxbrew/bin:$PATH"
install -d -m 700 ~/nuo/config
test -f ~/nuo/config/env || install -m 600 /dev/null ~/nuo/config/env
cd ~/nuo/app
bun install --production
systemctl --user daemon-reload
systemctl --user enable nuo-gateway.service >/dev/null
systemctl --user restart nuo-gateway.service
sleep 2
systemctl --user --no-pager --lines=10 status nuo-gateway.service
REMOTE
