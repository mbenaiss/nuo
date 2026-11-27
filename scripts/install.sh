#!/usr/bin/env bash
# Installs, upgrades or removes the Nuo Gateway for the current user (docs/install.md): a systemd user service on
# Debian/Ubuntu, a launchd agent on macOS. The one-line installer (install.sh at the root) runs it from a checkout.
# Idempotent: what is already in place is kept; ~/.secrets/nuo.env and the live config are never overwritten.
# Written for bash 3.2: it runs with macOS's /bin/bash.
set -euo pipefail

BUN_VERSION=1.4.2
REPO_URL="${NUO_REPO_URL:-https://github.com/mbenaiss/nuo.git}"
REF=main
HOST=""
FROM_LOCAL=0
DRY_RUN=0
NO_SERVICE=0
YES=0
PORT=""
LISTEN=""
SETUP_2FA=0
ACCOUNT=""
PAIR=0
UNINSTALL=0
PURGE=0
UNIT=nuo-gateway.service
LABEL=local.nuo.gateway

usage() {
  cat <<EOF
usage: scripts/install.sh [--host user@ip] [--from-local] [--repo <url>] [--ref <branch>] [--dry-run] [--no-service]
                          [--yes] [--port <n>] [--listen all|local] [--setup-2fa [--account <label>]] [--pair]
       scripts/install.sh [--host user@ip] --uninstall [--purge] [--yes] [--dry-run]
  --host        run on that host over ssh instead of here
  --from-local  take the gateway from this checkout (with private/gateway/ laid over it, docs/private-overlay.md)
                instead of cloning <repo> (default $REPO_URL, or NUO_REPO_URL)
  --ref         branch or tag to clone (default main)
  --dry-run     print what would change, change nothing
  --no-service  do not install or start the service (systemd user unit on Linux, launchd agent on macOS)
  --yes         answer yes to every confirmation, sudo commands included
  --port        NUO_PORT written into a new env file (default 8790; an existing file is kept as is)
  --listen      NUO_HOST written into a new env file: all (default, the local network can reach it) or local
                (127.0.0.1 only, for a reverse proxy or tunnel on this machine)
  --setup-2fa   enrol the 2FA second factor when it is not set up yet (prints a QR code and recovery codes)
  --account     label of the 2FA entry in the authenticator app (default: the user name)
  --pair        print a one-time pairing code at the end
  --uninstall   stop and remove the service, the gateway code and the helpers; data and secrets stay
  --purge       with --uninstall: also delete ~/nuo (every conversation, document and database) and ~/.secrets/nuo.env
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
    -y | --yes) YES=1; shift ;;
    --port) PORT="${2:?--port needs a number}"; shift 2 ;;
    --listen) LISTEN="${2:?--listen needs all or local}"; shift 2 ;;
    --setup-2fa) SETUP_2FA=1; shift ;;
    --account) ACCOUNT="${2:?--account needs a label}"; shift 2 ;;
    --pair) PAIR=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --purge) PURGE=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ -z "$PORT" || "$PORT" =~ ^[0-9]+$ ]] || { echo "install: --port must be a number" >&2; exit 2; }
[[ -z "$LISTEN" || "$LISTEN" == all || "$LISTEN" == local ]] || { echo "install: --listen must be all or local" >&2; exit 2; }
((PURGE == 0 || UNINSTALL == 1)) || { echo "install: --purge goes with --uninstall" >&2; exit 2; }

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
  # shellcheck disable=SC2029 # cmd is quoted with printf %q on purpose, for the remote shell.
  if [[ -t 0 ]]; then ssh -t "$HOST" "$cmd"; else ssh "$HOST" "$cmd"; fi
  exit 0
fi

USER="${USER:-$(id -un)}"
R="${NUO_HOME:-$HOME/nuo}"
APP="$R/app"
SECRETS_DIR="$HOME/.secrets"
SECRETS_FILE="$SECRETS_DIR/nuo.env"
UNIT_DIR="$HOME/.config/systemd/user"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
MAC_LOG="$HOME/Library/Logs/nuo-gateway.log"
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/.npm-global/bin:/home/linuxbrew/.linuxbrew/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

say() { printf '== %s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }
run() { ((DRY_RUN)) || "$@"; }
n_changed=0
did() {
  n_changed=$((n_changed + 1))
  if ((DRY_RUN)); then printf '  would: %s\n' "$*"; else printf '  %s\n' "$*"; fi
}

# Answers come from the terminal even when stdin is a pipe (curl | bash); with no terminal, only --yes says yes.
tty_ok() { [[ -t 0 ]] || (exec </dev/tty) 2>/dev/null; }
confirm() {
  ((YES)) && return 0
  local answer=""
  if [[ -t 0 ]]; then
    read -r -p "  $1 [Y/n] " answer || return 1
  elif tty_ok; then
    read -r -p "  $1 [Y/n] " answer </dev/tty || return 1
  else
    printf '  %s: no terminal to ask on, rerun with --yes to accept\n' "$1" >&2
    return 1
  fi
  [[ -z "$answer" || "$answer" == [yY]* ]]
}

SUDO=()
((EUID == 0)) || SUDO=(sudo)
# Every privileged command is shown, then run only once the user agreed (or --yes).
priv() {
  if ((DRY_RUN)); then
    printf '  would run: %s\n' "${SUDO[*]+${SUDO[*]} }$*"
    return 0
  fi
  printf '  needs administrator rights: %s\n' "${SUDO[*]+${SUDO[*]} }$*"
  confirm "Run it?" || die "declined: run it yourself, then run this script again"
  ${SUDO[@]+"${SUDO[@]}"} "$@"
}

mode_of() { stat -L -c %a "$1" 2>/dev/null || stat -L -f %Lp "$1"; }
install_file() { # mode src dst
  mkdir -p "$(dirname "$3")"
  install -m "$1" "$2" "$3"
}
version_ge() { # a >= b, dotted numbers
  local IFS=. i
  # shellcheck disable=SC2206
  local a=($1) b=($2)
  for i in 0 1 2; do
    ((${a[i]:-0} > ${b[i]:-0})) && return 0
    ((${a[i]:-0} < ${b[i]:-0})) && return 1
  done
  return 0
}

OS="$(uname -s)"
case "$OS" in
  Linux)
    [[ -r /etc/os-release ]] || die "/etc/os-release missing: only Debian and Ubuntu are supported on Linux"
    # shellcheck disable=SC1091
    os_id="$(. /etc/os-release && printf '%s %s' "${ID:-}" "${ID_LIKE:-}")"
    [[ " $os_id " == *" debian "* || " $os_id " == *" ubuntu "* ]] || die "only Debian and Ubuntu are supported on Linux (found: $os_id)"
    ;;
  Darwin) ;;
  *) die "only Debian/Ubuntu Linux and macOS are supported (this is $OS)" ;;
esac
((EUID == 0)) && [[ "${NUO_ALLOW_ROOT:-}" != 1 ]] && die "run it as the user that will own the gateway, not root (NUO_ALLOW_ROOT=1 to force)"

mac_domain() {
  if launchctl print "gui/$(id -u)" >/dev/null 2>&1; then printf 'gui/%s' "$(id -u)"; else printf 'user/%s' "$(id -u)"; fi
}

uninstall() {
  say "uninstall"
  if [[ "$OS" == Linux ]]; then
    if [[ -f "$UNIT_DIR/$UNIT" || -f "$UNIT_DIR/nuo-browser.service" ]]; then
      did "stop and disable $UNIT, remove $UNIT_DIR/$UNIT and nuo-browser.service"
      if ! ((DRY_RUN)); then
        if command -v systemctl >/dev/null; then
          export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
          systemctl --user disable --now "$UNIT" >/dev/null 2>&1 || true
          systemctl --user stop nuo-browser.service >/dev/null 2>&1 || true
        fi
        rm -f "$UNIT_DIR/$UNIT" "$UNIT_DIR/nuo-browser.service"
        systemctl --user daemon-reload >/dev/null 2>&1 || true
      fi
    fi
  elif [[ -f "$PLIST" ]]; then
    did "stop the launchd agent $LABEL, remove $PLIST and $MAC_LOG"
    if ! ((DRY_RUN)); then
      launchctl bootout "$(mac_domain)/$LABEL" >/dev/null 2>&1 || true
      rm -f "$PLIST" "$MAC_LOG"
    fi
  fi
  if [[ -f "$HOME/.local/bin/nuo-notify" ]]; then did "remove ~/.local/bin/nuo-notify"; run rm -f "$HOME/.local/bin/nuo-notify"; fi
  if [[ -d "$APP" ]]; then did "remove the gateway code $APP"; run rm -rf "$APP"; fi
  if [[ -d "$R/os" ]]; then did "remove the helpers $R/os"; run rm -rf "$R/os"; fi
  if ((PURGE)); then
    if [[ -e "$R" || -e "$SECRETS_FILE" ]]; then
      echo "  --purge deletes $R (conversations, documents, databases, bots, memory) and $SECRETS_FILE, for good."
      if ! ((DRY_RUN)); then confirm "Delete them?" || die "kept $R and $SECRETS_FILE"; fi
      did "delete $R and $SECRETS_FILE"
      run rm -rf "$R"
      run rm -f "$SECRETS_FILE"
    fi
  elif [[ -e "$R" ]]; then
    echo "  kept your data in $R and your secrets in $SECRETS_FILE (--uninstall --purge deletes them)"
  fi
  if [[ "$OS" == Linux ]]; then
    echo "  left in place: Bun, the system packages, the agent CLIs and their logins, linger (sudo loginctl disable-linger $USER)"
  else
    echo "  left in place: Bun, the agent CLIs and their logins"
  fi
  if ((DRY_RUN)); then say "dry run: nothing was changed ($n_changed actions listed above)"; fi
  return 0
}

if ((UNINSTALL)); then
  uninstall
  exit 0
fi

say "system packages"
if [[ "$OS" == Linux ]]; then
  missing=()
  for pair in git:git sqlite3:sqlite3 rsync:rsync curl:curl unzip:unzip zstd:zstd openssl:openssl Xvfb:xvfb xauth:xauth; do
    command -v "${pair%%:*}" >/dev/null || missing+=("${pair#*:}")
  done
  # The shared browser (nuo-browser.service) runs Google Chrome when installed, else Debian's Chromium.
  # Ubuntu ships Chromium only as a snap, which the unit cannot run: there it waits for Google Chrome.
  want_chromium=0
  if ! command -v google-chrome >/dev/null && ! command -v chromium >/dev/null; then
    if [[ " $os_id " == *" ubuntu "* ]]; then
      echo "  no Google Chrome: the shared browser stays off until you install it (Ubuntu's Chromium is a snap)"
    else
      want_chromium=1
    fi
  fi
  if ((${#missing[@]} || want_chromium)); then
    ((EUID == 0)) || command -v sudo >/dev/null || die "missing ${missing[*]-} chromium and no sudo to install them"
    if ((DRY_RUN)); then
      ((want_chromium)) && missing+=(chromium)
      priv apt-get update -qq
      priv env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates "${missing[@]}"
    else
      priv apt-get update -qq
      ((want_chromium)) && missing+=(chromium)
      if ((${#missing[@]})); then
        priv env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates "${missing[@]}" >/dev/null
        did "installed ${missing[*]}"
      fi
    fi
  else
    echo "  git sqlite3 rsync curl unzip zstd openssl xvfb xauth chrome present"
  fi
else
  missing=()
  for bin in git sqlite3 rsync curl unzip openssl; do command -v "$bin" >/dev/null || missing+=("$bin"); done
  ((${#missing[@]} == 0)) || die "missing ${missing[*]}: install the Xcode Command Line Tools (xcode-select --install), then run this script again"
  echo "  git sqlite3 rsync curl unzip openssl present"
fi

say "bun $BUN_VERSION or newer"
if command -v bun >/dev/null; then
  have="$(bun --version)"
  version_ge "$have" "$BUN_VERSION" || die "bun $have at $(command -v bun) is older than $BUN_VERSION: run \`bun upgrade\`, then this script again"
  echo "  bun $have at $(command -v bun)"
else
  did "install bun $BUN_VERSION into ~/.bun with its official installer (https://bun.sh/install)"
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
  (cd "$APP" && bun install --production --no-progress >/dev/null </dev/null)
  echo "  synced, dependencies installed"
fi

say "docs repository and starter dashboards"
if [[ -d "$R/docs/.git" && -d "$R/dashboards" ]]; then
  echo "  $R/docs is a git repository, $R/dashboards exists"
else
  did "prepare data folders: git init $R/docs, copy the starter dashboards"
  if ! ((DRY_RUN)); then
    (cd "$APP" && NUO_HOME="$R" bun -e 'import { defaultLayout } from "./src/paths"; import { prepareDataLayout } from "./src/data/service"; prepareDataLayout(defaultLayout())' </dev/null)
  fi
fi

say "folders under $R"
for d in "$R" "$R/config" "$R/data" "$R/data/files" "$R/data/media" "$R/bots" "$R/instructions" "$R/memory" "$R/docs" "$R/dashboards" "$SECRETS_DIR"; do
  if [[ ! -d "$d" ]]; then
    did "create $d (700)"
    run install -d -m 700 "$d"
  elif [[ "$(mode_of "$d")" != 700 ]]; then
    did "chmod 700 $d"
    run chmod 700 "$d"
  fi
done

say "secrets"
if [[ -e "$SECRETS_FILE" ]]; then
  echo "  $SECRETS_FILE exists, left untouched"
  if [[ -n "$PORT$LISTEN" ]]; then echo "  --port and --listen only apply to a new file: edit NUO_PORT and NUO_HOST in it to change them"; fi
  [[ "$(mode_of "$SECRETS_FILE")" == 600 ]] || { did "chmod 600 $SECRETS_FILE"; run chmod 600 "$SECRETS_FILE"; }
else
  host_value=""
  [[ "$LISTEN" == local ]] && host_value=127.0.0.1
  did "create $SECRETS_FILE from deploy/nuo.env.example, with a random NUO_LOCAL_TOKEN${PORT:+, NUO_PORT=$PORT}${host_value:+, NUO_HOST=$host_value}"
  if ! ((DRY_RUN)); then
    token="$(openssl rand -base64 32 | tr -d '\n=' | tr '+/' '-_')"
    [[ ${#token} -ge 40 ]] || die "openssl did not produce a token"
    # Written by bash builtins only: the token never appears in a command line.
    (
      umask 077
      while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
          NUO_LOCAL_TOKEN=) printf 'NUO_LOCAL_TOKEN=%s\n' "$token" ;;
          NUO_PORT=) printf 'NUO_PORT=%s\n' "$PORT" ;;
          NUO_HOST=) printf 'NUO_HOST=%s\n' "$host_value" ;;
          *) printf '%s\n' "$line" ;;
        esac
      done <"$SRC/deploy/nuo.env.example" >"$SECRETS_FILE.tmp"
    )
    mv "$SECRETS_FILE.tmp" "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
    unset token
  fi
fi
if [[ -L "$R/config/env" ]]; then
  echo "  $R/config/env -> $(readlink "$R/config/env")"
elif [[ -e "$R/config/env" ]]; then
  echo "  warning: $R/config/env is a regular file and stays the one the service reads; move it to $SECRETS_FILE and link it to use the standard layout"
else
  did "link $R/config/env -> $SECRETS_FILE"
  run ln -s "$SECRETS_FILE" "$R/config/env"
fi

say "helpers"
if [[ "$OS" == Linux ]]; then
  # Profile OS setup scripts (docs/profiles.md), run by the user with sudo from ~/nuo/os.
  for f in profile-os-setup.sh profile-os-remove.sh nuo-agent nuo-firewall; do
    os_src="$ROOT/scripts/$f"
    [[ -f "$SRC/scripts/$f" ]] && os_src="$SRC/scripts/$f"
    [[ -f "$os_src" ]] || continue
    if ! cmp -s "$os_src" "$R/os/$f"; then
      did "install $R/os/$f"
      run install_file 755 "$os_src" "$R/os/$f"
    fi
  done
fi
notify_src="$ROOT/scripts/nuo-notify"
[[ -f "$SRC/scripts/nuo-notify" ]] && notify_src="$SRC/scripts/nuo-notify"
if [[ -f "$notify_src" ]] && ! cmp -s "$notify_src" "$HOME/.local/bin/nuo-notify"; then
  did "install ~/.local/bin/nuo-notify"
  run install_file 755 "$notify_src" "$HOME/.local/bin/nuo-notify"
else
  echo "  nuo-notify up to date"
fi

gateway_cli() { (cd "$APP" && NUO_HOME="$R" NUO_SECRETS_FILE="$SECRETS_FILE" bun run "$@" </dev/null); }

totp_ready=0
if [[ -f "$R/data/nuo.db" ]] && command -v sqlite3 >/dev/null; then
  db_uri="file:$R/data/nuo.db?mode=ro"
  # immutable leaves even the -shm file alone, at the cost of ignoring a WAL not yet checkpointed.
  ((DRY_RUN)) && db_uri="file:$R/data/nuo.db?immutable=1"
  if [[ "$(sqlite3 "$db_uri" 'SELECT count(*) FROM auth_totp WHERE id = 1' 2>/dev/null)" == 1 ]]; then totp_ready=1; fi
fi
if ((SETUP_2FA)); then
  say "2FA"
  if ((totp_ready)); then
    echo "  already set up (bun run src/cli.ts auth-totp-reset in $APP replaces it)"
  else
    did "enrol the 2FA second factor; its sealing key NUO_AUTH_KEY is added to $SECRETS_FILE"
    if ! ((DRY_RUN)); then
      cat <<'EOF'

  Scan the QR code below with an authenticator app (Apple Passwords, 1Password, Google Authenticator...).
  The app asks for its current code when you pair. Keep the recovery codes offline: they are not shown again.

EOF
      gateway_cli src/cli.ts auth-totp-setup --account "${ACCOUNT:-$USER}" | grep -v '^Restart the gateway'
      totp_ready=1
    fi
  fi
fi

# Only non-secret keys are read from the env file.
env_value() {
  grep -E "^[[:space:]]*(export[[:space:]]+)?$1=" "$R/config/env" 2>/dev/null | tail -n 1 | sed -E 's/^[^=]*=//; s/["'\'' ]//g'
}
gw_port() {
  local p
  p="$(env_value NUO_PORT)"
  if [[ "$p" =~ ^[0-9]+$ ]]; then printf '%s' "$p"; else printf 8790; fi
}
health_url() {
  local host
  host="$(env_value NUO_HOST)"
  [[ -z "$host" || "$host" == 0.0.0.0 || "$host" == :: ]] && host=127.0.0.1
  printf 'http://%s:%s/api/health' "$host" "$(gw_port)"
}
healthy=0
wait_health() {
  local url
  url="$(health_url)"
  for _ in $(seq 1 60); do
    curl -fsS "$url" >/dev/null 2>&1 && break
    sleep 1
  done
  curl -fsS "$url" >/dev/null 2>&1 || return 1
  echo "  healthy: $url"
  healthy=1
}

xml_escape() { local s="${1//&/&amp;}"; s="${s//</&lt;}"; printf '%s' "${s//>/&gt;}"; }

if ((NO_SERVICE)); then
  say "service: skipped (--no-service)"
  if ! ((DRY_RUN)) && curl -fsS "$(health_url)" >/dev/null 2>&1; then
    healthy=1
    echo "  a gateway already answers on $(health_url): restart it to run the updated code"
  fi
elif [[ "$OS" == Linux ]]; then
  say "systemd user unit"
  command -v systemctl >/dev/null || die "systemctl missing: rerun with --no-service and start the gateway yourself"
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  if ! cmp -s "$SRC/deploy/$UNIT" "$UNIT_DIR/$UNIT"; then
    did "install $UNIT_DIR/$UNIT"
    run install_file 644 "$SRC/deploy/$UNIT" "$UNIT_DIR/$UNIT"
  fi
  # Started on demand by the gateway, never enabled.
  if ! cmp -s "$SRC/deploy/nuo-browser.service" "$UNIT_DIR/nuo-browser.service"; then
    did "install $UNIT_DIR/nuo-browser.service"
    run install_file 644 "$SRC/deploy/nuo-browser.service" "$UNIT_DIR/nuo-browser.service"
  fi
  if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != yes ]]; then
    did "loginctl enable-linger $USER (keeps the gateway running without a login session)"
    ((DRY_RUN)) || loginctl enable-linger "$USER" 2>/dev/null || priv loginctl enable-linger "$USER"
  fi
  # Without a login session (a first install over a non-login shell), the user manager starts with linger.
  if ! ((DRY_RUN)); then
    for _ in $(seq 1 15); do
      [[ -S "$XDG_RUNTIME_DIR/bus" ]] && break
      sleep 1
    done
    [[ -S "$XDG_RUNTIME_DIR/bus" ]] || die "no systemd user manager for $USER ($XDG_RUNTIME_DIR/bus missing): log in once over ssh, or rerun with --no-service"
  fi
  did "systemctl --user enable + restart $UNIT (applies migrations)"
  if ! ((DRY_RUN)); then
    systemctl --user daemon-reload
    systemctl --user enable "$UNIT" >/dev/null 2>&1
    systemctl --user restart "$UNIT"
    wait_health || {
      systemctl --user --no-pager --lines=30 status "$UNIT" || true
      die "the gateway did not answer on $(health_url)"
    }
  fi
else
  say "launchd agent $LABEL"
  bun_bin="$(command -v bun || printf '%s' "$HOME/.bun/bin/bun")"
  plist_tmp="$(mktemp)"
  cat >"$plist_tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "$bun_bin")</string>
    <string>--env-file=$(xml_escape "$R/config/env")</string>
    <string>run</string>
    <string>src/index.ts</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$(xml_escape "$APP")</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>NUO_HOME</key>
    <string>$(xml_escape "$R")</string>
    <key>PATH</key>
    <string>$(xml_escape "$HOME/.local/bin:$HOME/.bun/bin:$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>5</integer>
  <key>ExitTimeOut</key>
  <integer>20</integer>
  <key>StandardOutPath</key>
  <string>$(xml_escape "$MAC_LOG")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "$MAC_LOG")</string>
</dict>
</plist>
EOF
  domain="$(mac_domain)"
  if cmp -s "$plist_tmp" "$PLIST"; then
    rm -f "$plist_tmp"
    did "restart $LABEL (applies migrations)"
    if ! ((DRY_RUN)); then
      launchctl kickstart -k "$domain/$LABEL" >/dev/null 2>&1 || launchctl bootstrap "$domain" "$PLIST"
    fi
  else
    did "install $PLIST and load it in $domain (logs: $MAC_LOG)"
    if ((DRY_RUN)); then
      rm -f "$plist_tmp"
    else
      mkdir -p "$(dirname "$PLIST")" "$(dirname "$MAC_LOG")"
      launchctl bootout "$domain/$LABEL" >/dev/null 2>&1 || true
      install -m 644 "$plist_tmp" "$PLIST"
      rm -f "$plist_tmp"
      launchctl bootstrap "$domain" "$PLIST"
    fi
  fi
  if ! ((DRY_RUN)); then
    wait_health || {
      tail -n 30 "$MAC_LOG" 2>/dev/null || true
      die "the gateway did not answer on $(health_url)"
    }
  fi
fi

say "agents"
if ((healthy)); then
  # The gateway's own probe: it knows which agents it can run and whether they are logged in.
  # shellcheck disable=SC2016 # JavaScript template literals, not shell expansions.
  curl -fsS "$(health_url)" | bun -e '
    const hint = {
      claude: "curl -fsSL https://claude.ai/install.sh | bash, then npm i -g @agentclientprotocol/claude-agent-acp; log in: claude, then /login",
      codex: "npm i -g @agentclientprotocol/codex-acp @openai/codex; log in: codex login",
      gemini: "the Antigravity CLI in ~/.local/bin/agy; log in: agy",
      grok: "npm i -g @xai-official/grok; log in: grok",
    };
    const h = JSON.parse(await Bun.stdin.text());
    let ready = 0;
    for (const a of h.agents ?? []) {
      const state = !a.available ? "not installed" : !a.authenticated ? "installed, not logged in" : "ready";
      if (state === "ready") ready++;
      console.log(`  ${a.name.padEnd(12)} ${state}`);
      if (state !== "ready" && hint[a.id]) console.log(`  ${"".padEnd(12)} ${hint[a.id]}`);
    }
    console.log(ready ? `  ${ready} agent(s) ready.` : "  No agent is ready yet: install and log in to at least one (the npm packages need Node.js 20 or newer), then restart the gateway.");
  ' || echo "  could not read the agents from the gateway"
else
  echo "  binaries the gateway looks for (in ~/.local/bin, ~/.bun/bin, ~/.npm-global/bin, linuxbrew, /opt/homebrew/bin, /usr/local/bin):"
  for bin in node claude claude-agent-acp codex codex-acp grok agy gog; do
    if p="$(command -v "$bin")"; then printf '  %-18s %s\n' "$bin" "$p"; else printf '  %-18s missing\n' "$bin"; fi
  done
  echo "  install and log in to at least one agent: docs/install.md, Requirements"
fi

if ((PAIR)) && ! ((DRY_RUN)); then
  say "pairing"
  if ((totp_ready)); then
    gateway_cli src/pair.ts
  else
    echo "  skipped: pairing needs 2FA first (rerun with --setup-2fa, or bun run src/cli.ts auth-totp-setup in $APP)"
  fi
fi

if ((DRY_RUN)); then say "dry run: nothing was changed ($n_changed actions listed above)"; fi

lan_addresses() {
  if [[ "$OS" == Darwin ]]; then
    for i in en0 en1 en2; do ipconfig getifaddr "$i" 2>/dev/null || true; done
  else
    hostname -I 2>/dev/null | tr ' ' '\n' || true
  fi | grep -E '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' || true
}

port="$(gw_port)"
listen_host="$(env_value NUO_HOST)"
if [[ "$OS" == Linux ]]; then
  restart_cmd="systemctl --user restart $UNIT"
  logs_cmd="journalctl --user -u $UNIT -f"
else
  restart_cmd="launchctl kickstart -k $(mac_domain)/$LABEL"
  logs_cmd="tail -f $MAC_LOG"
fi
((NO_SERVICE)) && restart_cmd="cd $APP && NUO_HOME=$R bun --env-file=$R/config/env run src/index.ts"

echo
echo "Next steps (docs/install.md):"
step=1
next() { printf '  %s. %s\n' "$step" "$1"; step=$((step + 1)); }
more() { printf '     %s\n' "$1"; }
if ((NO_SERVICE)); then
  if ((healthy)); then next "Restart the gateway you started (stop it, then run it again):"; else next "Start the gateway (no service was installed) and leave it running:"; fi
  more "  $restart_cmd"
fi
((totp_ready)) || next "2FA, needed to pair: cd $APP && bun run src/cli.ts auth-totp-setup"
if ! ((PAIR && totp_ready)) || ((DRY_RUN)); then next "Pairing code: cd $APP && bun run src/pair.ts   (valid 10 minutes)"; fi
next "Pair an app: gateway URL, profile \"owner\", the pairing code, then the current code of your authenticator app."
more "Pairing works only from your local network or this machine."
if [[ "$listen_host" == 127.0.0.1 || "$listen_host" == localhost || "$listen_host" == ::1 ]]; then
  more "The gateway listens on this machine only (NUO_HOST=$listen_host): http://127.0.0.1:$port here; a phone"
  more "needs a reverse proxy or a tunnel on this machine (\"Network\" in docs/install.md)."
else
  addrs="$(lan_addresses)"
  if [[ -n "$addrs" ]]; then
    more "Gateway URL from a phone or computer on the same network:"
    for a in $addrs; do more "  http://$a:$port"; done
  else
    more "Gateway URL from a phone or computer on the same network: http://<this machine's address>:$port"
  fi
  [[ "$OS" == Darwin ]] && more "From the Mac app on this Mac: http://localhost:$port"
fi
more "The apps are built from source with Xcode on a Mac (demo mode needs no gateway): docs/getting-started.md"
next "Away from home: a VPN (WireGuard, Tailscale) is simplest; tunnels and reverse proxies are under \"Network\" in"
more "docs/install.md. This script opened no port and changed no firewall rule."
next "Optional settings (push, calendar, speech to text...) go in $SECRETS_FILE, then:"
more "  $restart_cmd"
((NO_SERVICE)) || more "Logs: $logs_cmd"
