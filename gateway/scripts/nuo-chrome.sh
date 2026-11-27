#!/usr/bin/env bash
# Shared persistent browser of the user and his agents (systemd user unit nuo-browser.service).
# Headful Chrome in a private Xvfb display: real rendering, no headless fingerprint. The DevTools protocol only
# listens on 127.0.0.1; the gateway streams it to the app (docs/protocol.md, « Navigateur partagé »).
# Other profiles: the gateway runs a copy (/srv/nuo/runtime/bin/nuo-chrome) as nuo-<slug> through the launcher,
# with --port and --dir, since the launcher passes no NUO_* variable.
set -euo pipefail

R="${NUO_HOME:-$HOME/nuo}"
DIR="$R/browser"
PROFILE="${NUO_BROWSER_PROFILE:-}"
PORT="${NUO_BROWSER_CDP_PORT:-9222}"
while (($#)); do
  case "$1" in
    --port) PORT="${2:?--port needs a value}"; shift 2 ;;
    --dir) DIR="${2:?--dir needs a value}"; PROFILE=""; shift 2 ;;
    *) echo "nuo-chrome: unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "nuo-chrome: invalid port $PORT" >&2; exit 2; }
PROFILE="${PROFILE:-$DIR/profile}"
WIDTH="${NUO_BROWSER_WIDTH:-1280}"
HEIGHT="${NUO_BROWSER_HEIGHT:-800}"

umask 077
mkdir -p "$DIR" "$PROFILE"
# The profile holds session cookies: only this user may read it.
chmod 700 "$DIR" "$PROFILE"

BIN="${NUO_BROWSER_BIN:-}"
if [[ -z "$BIN" ]]; then
  for c in google-chrome chromium; do
    if command -v "$c" >/dev/null; then BIN="$(command -v "$c")"; break; fi
  done
fi
[[ -n "$BIN" ]] || { echo "nuo-chrome: no google-chrome or chromium" >&2; exit 1; }

display=""
for n in $(seq 90 130); do
  if [[ ! -e "/tmp/.X$n-lock" && ! -e "/tmp/.X11-unix/X$n" ]]; then display=":$n"; break; fi
done
[[ -n "$display" ]] || { echo "nuo-chrome: no free X display" >&2; exit 1; }

# A cookie-protected display: other local users cannot screenshot or type into the browser.
export XAUTHORITY="$DIR/Xauthority"
rm -f "$XAUTHORITY"
xauth -q -f "$XAUTHORITY" add "$display" . "$(mcookie)"

Xvfb "$display" -screen 0 "${WIDTH}x${HEIGHT}x24" -nolisten tcp -auth "$XAUTHORITY" &
for _ in $(seq 1 50); do
  [[ -e "/tmp/.X11-unix/X${display#:}" ]] && break
  sleep 0.1
done
export DISPLAY="$display"

# Exec: when Chrome exits, systemd ends the unit and kills Xvfb with the rest of the cgroup.
exec "$BIN" \
  --user-data-dir="$PROFILE" \
  --remote-debugging-address=127.0.0.1 \
  --remote-debugging-port="$PORT" \
  --no-first-run \
  --no-default-browser-check \
  --password-store=basic \
  --disable-features=Translate,MediaRouter,OptimizationHints \
  --disable-backgrounding-occluded-windows \
  --disable-renderer-backgrounding \
  --hide-crash-restore-bubble \
  --lang=fr-FR \
  --window-position=0,0 \
  --window-size="$WIDTH,$HEIGHT" \
  about:blank
