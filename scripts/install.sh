#!/usr/bin/env bash
# Installs or upgrades the Nuo Gateway on a Debian/Ubuntu host for the current user (docs/install.md).
# Idempotent: what is already in place is kept; ~/.secrets/nuo.env and the live config are never overwritten.
set -euo pipefail

BUN_VERSION=1.4.2
REPO_URL="${NUO_REPO_URL:-https://github.com/mbenaiss/nuo.git}"
REF=main
HOST=""
FROM_LOCAL=0
DRY_RUN=0
NO_SERVICE=0
UNIT=nuo-gateway.service

usage() {
  cat <<EOF
usage: scripts/install.sh [--host user@ip] [--from-local] [--repo <url>] [--ref <branch>] [--dry-run] [--no-service]
  --host        run on that host over ssh instead of here
  --from-local  take the gateway from this checkout (with private/gateway/ laid over it, docs/private-overlay.md)
                instead of cloning <repo> (default $REPO_URL, or NUO_REPO_URL)
  --ref         branch or tag to clone (default main)
  --dry-run     print what would change, change nothing
  --no-service  do not install, enable or start the systemd user unit
EOF
}

orig_args=("$@")
while (($#)); do
  case "$1" in
    --host) HOST="${2:?--host needs user@ip}"; shift 2 ;;
    --from-local) FROM_LOCAL=1; shift ;;
    --repo) REPO_URL="${2:?--repo needs a url}"; shift 2 ;;
    --ref) REF="${2:?--ref needs a branch}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-service) NO_SERVICE=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -n "$HOST" ]]; then
  # The script runs on the target from a throwaway copy, with the gateway sources when --from-local.
  fwd=()
  skip=0
  for a in "${orig_args[@]}"; do
    if ((skip)); then skip=0; continue; fi
    [[ "$a" == --host ]] && { skip=1; continue; }
    fwd+=("$a")
  done
  remote_tmp="$(ssh -n "$HOST" 'mktemp -d /tmp/nuo-install.XXXXXX')"
  trap 'ssh -n "$HOST" "rm -rf $remote_tmp" || true' EXIT
  files=(scripts/install.sh scripts/nuo-notify scripts/profile-os-setup.sh scripts/profile-os-remove.sh scripts/nuo-agent scripts/nuo-firewall deploy/)
  if ((FROM_LOCAL)); then
    files+=(gateway/)
    [[ -d "$ROOT/private/gateway" ]] && files+=(private/gateway/)
  fi
  (cd "$ROOT" && rsync -azR --exclude node_modules --exclude .DS_Store "${files[@]}" "$HOST:$remote_tmp/")
  cmd="bash $remote_tmp/scripts/install.sh"
  for a in ${fwd[@]+"${fwd[@]}"}; do cmd+=" $(printf '%q' "$a")"; done
  if [[ -t 0 ]]; then ssh -t "$HOST" "$cmd"; else ssh "$HOST" "$cmd"; fi
  exit 0
fi

USER="${USER:-$(id -un)}"
R="${NUO_HOME:-$HOME/nuo}"
APP="$R/app"
SECRETS_DIR="$HOME/.secrets"
SECRETS_FILE="$SECRETS_DIR/nuo.env"
UNIT_DIR="$HOME/.config/systemd/user"
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/.npm-global/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:$PATH"

say() { printf '== %s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }
run() { ((DRY_RUN)) || "$@"; }
changed=()
did() { changed+=("$*"); ((DRY_RUN)) && printf '  would: %s\n' "$*" || printf '  %s\n' "$*"; }

[[ "$(uname -s)" == Linux ]] || die "only Linux hosts are supported (this is $(uname -s))"
[[ -r /etc/os-release ]] || die "/etc/os-release missing: only Debian and Ubuntu are supported"
# shellcheck disable=SC1091
os_id="$(. /etc/os-release && printf '%s %s' "${ID:-}" "${ID_LIKE:-}")"
[[ " $os_id " == *" debian "* || " $os_id " == *" ubuntu "* ]] || die "only Debian and Ubuntu are supported (found: $os_id)"
((EUID == 0)) && [[ "${NUO_ALLOW_ROOT:-}" != 1 ]] && die "run it as the user that will own the gateway, not root (NUO_ALLOW_ROOT=1 to force)"

SUDO=()
((EUID == 0)) || SUDO=(sudo)

say "system packages"
declare -A pkg_of=([git]=git [sqlite3]=sqlite3 [rsync]=rsync [curl]=curl [unzip]=unzip [zstd]=zstd [openssl]=openssl [Xvfb]=xvfb [xauth]=xauth)
missing=()
for bin in git sqlite3 rsync curl unzip zstd openssl Xvfb xauth; do
  command -v "$bin" >/dev/null || missing+=("${pkg_of[$bin]}")
done
# The shared browser (nuo-browser.service) runs Google Chrome when installed, else Debian's Chromium.
command -v google-chrome >/dev/null || command -v chromium >/dev/null || missing+=(chromium)
if ((${#missing[@]})); then
  ((EUID == 0)) || command -v sudo >/dev/null || die "missing ${missing[*]} and no sudo to install them"
  did "apt-get install ${missing[*]}"
  run "${SUDO[@]}" apt-get update -qq
  run "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates "${missing[@]}" >/dev/null
else
  echo "  git sqlite3 rsync curl unzip zstd openssl xvfb xauth chrome present"
fi

say "bun $BUN_VERSION"
if command -v bun >/dev/null; then
  have="$(bun --version)"
  if [[ "$have" == "$BUN_VERSION" ]]; then
    echo "  bun $have at $(command -v bun)"
  else
    echo "  bun $have at $(command -v bun) (pinned version is $BUN_VERSION; left as is, run \`bun upgrade\` to change it)"
  fi
else
  did "install bun $BUN_VERSION into ~/.bun"
  if ! ((DRY_RUN)); then
    curl -fsSL https://bun.sh/install | bash -s "bun-v$BUN_VERSION" >/dev/null 2>&1 || die "the bun installer failed"
    command -v bun >/dev/null || die "bun did not install"
  fi
fi

say "gateway code in $APP"
src_tmp=""
cleanup() { [[ -n "$src_tmp" ]] && rm -rf "$src_tmp"; return 0; }
trap cleanup EXIT
if ((FROM_LOCAL)); then
  SRC="$ROOT"
  [[ -f "$SRC/gateway/src/index.ts" ]] || die "--from-local: no gateway in $SRC"
else
  src_tmp="$(mktemp -d)"
  SRC="$src_tmp/repo"
  echo "  cloning $REPO_URL ($REF)"
  git clone -q --depth 1 --branch "$REF" "$REPO_URL" "$SRC" || die "cannot clone $REPO_URL: check the URL (--repo), give this host access to it, or use --from-local"
fi
GW_SRC="$SRC/gateway"
if [[ -d "$SRC/private/gateway" ]]; then
  echo "  private overlay: $SRC/private/gateway"
  src_tmp="${src_tmp:-$(mktemp -d)}"
  GW_SRC="$src_tmp/gateway-staged"
  mkdir -p "$GW_SRC"
  rsync -a --exclude node_modules --exclude .DS_Store "$SRC/gateway/" "$GW_SRC/"
  rsync -a --exclude node_modules --exclude .DS_Store "$SRC/private/gateway/" "$GW_SRC/"
fi
# Same shape as scripts/deploy-gateway.sh: app/ holds the repo's gateway/ folder, node_modules survive.
if ((DRY_RUN)); then
  n="$(rsync -ai --dry-run --delete --exclude node_modules --exclude .DS_Store "$GW_SRC/" "$APP/" 2>/dev/null | grep -vc '^\.' || true)"
  did "sync gateway sources into $APP ($n entries to update)"
  did "bun install --production"
else
  install -d -m 700 "$R" "$APP"
  rsync -a --delete --exclude node_modules --exclude .DS_Store "$GW_SRC/" "$APP/"
  chmod 700 "$APP"
  (cd "$APP" && bun install --production >/dev/null)
  echo "  synced, dependencies installed"
fi

say "docs repository and starter dashboards"
if [[ -d "$R/docs/.git" && -d "$R/dashboards" ]]; then
  echo "  $R/docs is a git repository, $R/dashboards exists"
else
  did "prepare data folders: git init $R/docs, copy the starter dashboards"
  if ! ((DRY_RUN)); then
    (cd "$APP" && NUO_HOME="$R" bun -e 'import { defaultLayout } from "./src/paths"; import { prepareDataLayout } from "./src/data/service"; prepareDataLayout(defaultLayout())')
  fi
fi

say "folders under $R"
for d in "$R" "$R/config" "$R/data" "$R/data/files" "$R/data/media" "$R/bots" "$R/instructions" "$R/memory" "$R/docs" "$R/dashboards" "$SECRETS_DIR"; do
  if [[ ! -d "$d" ]]; then
    did "create $d (700)"
    run install -d -m 700 "$d"
  elif [[ "$(stat -c %a "$d")" != 700 ]]; then
    did "chmod 700 $d"
    run chmod 700 "$d"
  fi
done

say "secrets"
if [[ -e "$SECRETS_FILE" ]]; then
  echo "  $SECRETS_FILE exists, left untouched"
  [[ "$(stat -L -c %a "$SECRETS_FILE")" == 600 ]] || { did "chmod 600 $SECRETS_FILE"; run chmod 600 "$SECRETS_FILE"; }
else
  did "create $SECRETS_FILE from deploy/nuo.env.example, with a random NUO_LOCAL_TOKEN"
  if ! ((DRY_RUN)); then
    install -m 600 "$SRC/deploy/nuo.env.example" "$SECRETS_FILE"
    token="$(openssl rand -base64 32 | tr -d '\n=' | tr '+/' '-_')"
    sed -i "s|^NUO_LOCAL_TOKEN=\$|NUO_LOCAL_TOKEN=$token|" "$SECRETS_FILE"
    unset token
  fi
fi
if [[ -L "$R/config/env" ]]; then
  echo "  $R/config/env -> $(readlink "$R/config/env")"
elif [[ -e "$R/config/env" ]]; then
  echo "  warning: $R/config/env is a regular file and stays the one the unit reads; move it to $SECRETS_FILE and link it to use the standard layout"
else
  did "link $R/config/env -> $SECRETS_FILE"
  run ln -s "$SECRETS_FILE" "$R/config/env"
fi

say "helpers"
# Profile OS setup scripts (docs/profiles.md), run by the user with sudo from ~/nuo/os.
for f in profile-os-setup.sh profile-os-remove.sh nuo-agent nuo-firewall; do
  os_src="$ROOT/scripts/$f"
  [[ -f "$SRC/scripts/$f" ]] && os_src="$SRC/scripts/$f"
  [[ -f "$os_src" ]] || continue
  if ! cmp -s "$os_src" "$R/os/$f"; then
    did "install $R/os/$f"
    run install -D -m 755 "$os_src" "$R/os/$f"
  fi
done

notify_src="$ROOT/scripts/nuo-notify"
[[ -f "$SRC/scripts/nuo-notify" ]] && notify_src="$SRC/scripts/nuo-notify"
if [[ -f "$notify_src" ]] && ! cmp -s "$notify_src" "$HOME/.local/bin/nuo-notify"; then
  did "install ~/.local/bin/nuo-notify"
  run install -D -m 755 "$notify_src" "$HOME/.local/bin/nuo-notify"
else
  echo "  nuo-notify up to date"
fi

# Only non-secret keys are read from the env file.
env_value() {
  grep -E "^[[:space:]]*(export[[:space:]]+)?$1=" "$R/config/env" 2>/dev/null | tail -n 1 | sed -E 's/^[^=]*=//; s/["'\'' ]//g'
}

health_url() {
  local port host
  port="$(env_value NUO_PORT)"
  host="$(env_value NUO_HOST)"
  [[ "$port" =~ ^[0-9]+$ ]] || port=""
  [[ -z "$host" || "$host" == 0.0.0.0 || "$host" == :: ]] && host=127.0.0.1
  printf 'http://%s:%s/api/health' "$host" "${port:-8790}"
}

if ((NO_SERVICE)); then
  say "service: skipped (--no-service)"
else
  say "systemd user unit"
  command -v systemctl >/dev/null || die "systemctl missing: rerun with --no-service and start the gateway yourself"
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  if ! cmp -s "$SRC/deploy/$UNIT" "$UNIT_DIR/$UNIT"; then
    did "install $UNIT_DIR/$UNIT"
    run install -D -m 644 "$SRC/deploy/$UNIT" "$UNIT_DIR/$UNIT"
  fi
  # Started on demand by the gateway, never enabled.
  if ! cmp -s "$SRC/deploy/nuo-browser.service" "$UNIT_DIR/nuo-browser.service"; then
    did "install $UNIT_DIR/nuo-browser.service"
    run install -D -m 644 "$SRC/deploy/nuo-browser.service" "$UNIT_DIR/nuo-browser.service"
  fi
  if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != yes ]]; then
    did "loginctl enable-linger $USER (keeps the gateway running without a login session)"
    ((DRY_RUN)) || loginctl enable-linger "$USER" 2>/dev/null || "${SUDO[@]}" loginctl enable-linger "$USER"
  fi
  did "systemctl --user enable + restart $UNIT (applies migrations)"
  if ! ((DRY_RUN)); then
    systemctl --user daemon-reload
    systemctl --user enable "$UNIT" >/dev/null 2>&1
    systemctl --user restart "$UNIT"
    url="$(health_url)"
    for _ in $(seq 1 30); do
      curl -fsS "$url" >/dev/null 2>&1 && break
      sleep 1
    done
    if curl -fsS "$url" >/dev/null 2>&1; then
      echo "  healthy: $url"
    else
      systemctl --user --no-pager --lines=30 status "$UNIT" || true
      die "the gateway did not answer on $url"
    fi
  fi
fi

say "agent CLIs (the gateway looks in ~/.local/bin, ~/.bun/bin, ~/.npm-global/bin, linuxbrew, /usr/local/bin)"
for bin in node claude claude-agent-acp codex codex-acp grok agy gog; do
  if p="$(command -v "$bin")"; then printf '  %-18s %s\n' "$bin" "$p"; else printf '  %-18s missing\n' "$bin"; fi
done

((DRY_RUN)) && say "dry run: nothing was changed (${#changed[@]} actions listed above)"

cat <<EOF

Next steps (docs/install.md):
  1. Agent CLIs, as $USER, then log in to each interactively (the gateway never logs in for you):
       Node.js >= 20 for the npm packages (e.g. linuxbrew: brew install node)
       Claude Code:  curl -fsSL https://claude.ai/install.sh | bash      then: claude  (/login)
       ACP adapters: npm i -g @agentclientprotocol/claude-agent-acp @agentclientprotocol/codex-acp
       Codex:        npm i -g @openai/codex                               then: codex login
       Gemini:       install the agy CLI into ~/.local/bin                 then: agy  (Google sign-in, or GEMINI_API_KEY + modelProvider gemini)
       Grok:         npm i -g @xai-official/grok                          then: grok  (sign in when asked)
       gog (Google calendar/mail tools): install gogcli 0.45 into /usr/local/bin/gog, then gog auth add <account>
  2. Optional settings in $SECRETS_FILE (push, remote access, calendar...), then
       systemctl --user restart $UNIT
  3. 2FA:      cd $APP && bun run src/cli.ts auth-totp-setup
  4. Pairing:  cd $APP && bun run src/pair.ts     (from your local network: pairing is refused over the internet)
  5. Network:  see "Network" in docs/install.md to reach the gateway from outside your local network
               (firewall, reverse proxy, tunnel) and set NUO_PROXY_SOURCES / NUO_TUNNEL_SOURCES.
EOF
