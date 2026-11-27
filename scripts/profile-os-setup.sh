#!/usr/bin/env bash
# Gives a Nuo profile its own Linux user, so that its agents, logins and command tasks cannot read the owner's
# files (docs/profiles.md). Run on the gateway host, with sudo, once per profile; idempotent:
#
#   sudo bash ~/nuo/os/profile-os-setup.sh <slug> [--owner <user>] [--gateway-port 8790]
#
# What it does, for profile <slug> and the gateway user <owner> (default: the user who ran sudo):
# - creates the system user nuo-<slug> (no password, no login shell), home /srv/nuo/<slug>/home (2770,
#   group <owner>: the gateway reads the CLIs' state there, nobody else can);
# - moves ~<owner>/nuo/profiles/<slug> to /srv/nuo/<slug> (<owner>:nuo-<slug>, 0750) and leaves a link, so the
#   profile's agents never need to cross the owner's home, which stays 0700;
# - installs /usr/local/lib/nuo/nuo-agent (root, 0755) and a sudoers rule that lets <owner> run that launcher,
#   and nothing else, as nuo-<slug> (validated with visudo before it is put in place);
# - installs nuo-firewall.service: nuo-* users may reach the gateway and their own browser's DevTools on loopback,
#   and DNS, never another loopback port (the owner's browser DevTools, databases…) nor the home network;
# - checks the result as nuo-<slug>.
# Restart the gateway afterwards (systemctl --user restart nuo-gateway as <owner>).
set -euo pipefail

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

SLUG=""
OWNER="${SUDO_USER:-}"
PORT=8790
while (($#)); do
  case "$1" in
    --owner) OWNER="${2:?--owner needs a user}"; shift 2 ;;
    --gateway-port) PORT="${2:?--gateway-port needs a port}"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) [[ -z "$SLUG" ]] || { usage >&2; exit 2; }; SLUG="$1"; shift ;;
  esac
done

die() { printf 'profile-os-setup: %s\n' "$*" >&2; exit 1; }
say() { printf '== %s\n' "$*"; }

[[ "$(id -u)" == 0 ]] || die "run it with sudo"
[[ "$SLUG" =~ ^[a-z][a-z0-9-]{1,23}$ ]] || die "invalid profile slug \"$SLUG\""
[[ "$SLUG" != owner ]] || die "the owner profile runs as the gateway user"
[[ -n "$OWNER" && "$OWNER" != root ]] || die "--owner <gateway user> is required"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "invalid --gateway-port"
getent passwd "$OWNER" >/dev/null || die "unknown user $OWNER"
command -v iptables >/dev/null || die "iptables is missing (apt install iptables)"
command -v visudo >/dev/null || PATH="/usr/sbin:/sbin:$PATH"
command -v visudo >/dev/null || die "visudo is missing (apt install sudo)"

HERE="$(cd "$(dirname "$0")" && pwd)"
[[ -f "$HERE/nuo-agent" && -f "$HERE/nuo-firewall" ]] || die "nuo-agent and nuo-firewall must sit next to this script"
USER_NAME="nuo-$SLUG"
OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
OWNER_GROUP="$(id -gn "$OWNER")"
NUO="${NUO_HOME:-$OWNER_HOME/nuo}"
LINK="$NUO/profiles/$SLUG"
TREE="/srv/nuo/$SLUG"
LAUNCHER=/usr/local/lib/nuo/nuo-agent

say "launcher and firewall"
install -d -o root -g root -m 0755 /usr/local/lib/nuo /etc/nuo
install -o root -g root -m 0755 "$HERE/nuo-agent" "$LAUNCHER"
install -o root -g root -m 0755 "$HERE/nuo-firewall" /usr/local/lib/nuo/nuo-firewall

say "user $USER_NAME"
if ! getent passwd "$USER_NAME" >/dev/null; then
  useradd --system --user-group --home-dir "$TREE/home" --no-create-home --shell /usr/sbin/nologin "$USER_NAME"
fi
passwd -l "$USER_NAME" >/dev/null 2>&1 || true

say "folders"
install -d -o root -g root -m 0711 /srv/nuo
install -d -o "$OWNER" -g "$OWNER_GROUP" -m 0755 /srv/nuo/runtime
install -d -o "$OWNER" -g "$USER_NAME" -m 0750 "$TREE"
chown "$OWNER:$USER_NAME" "$TREE"
chmod 0750 "$TREE"
if [[ -d "$LINK" && ! -L "$LINK" ]]; then
  find "$LINK" -mindepth 1 -maxdepth 1 -exec mv -t "$TREE" {} +
  rmdir "$LINK"
fi
if [[ ! -L "$LINK" ]]; then
  install -d -o "$OWNER" -g "$OWNER_GROUP" -m 0700 "$NUO/profiles"
  ln -s "$TREE" "$LINK"
  chown -h "$OWNER:$OWNER_GROUP" "$LINK"
fi
install -d -o "$USER_NAME" -g "$OWNER_GROUP" -m 2770 "$TREE/home"
chown "$USER_NAME:$OWNER_GROUP" "$TREE/home"
chmod 2770 "$TREE/home"
install -d -o "$USER_NAME" -g "$OWNER_GROUP" -m 2770 "$TREE/home/.config" "$TREE/home/.config/nuo"

mode="$(stat -c %a "$OWNER_HOME")"
if [[ "${mode: -1}" != 0 ]]; then
  say "$OWNER_HOME was $mode: removing access for other users"
  chmod o-rwx "$OWNER_HOME"
fi

say "sudoers"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
printf 'Defaults!%s !use_pty, !lecture, env_reset\n' "$LAUNCHER" >"$tmp"
visudo -cqf "$tmp" || die "invalid sudoers defaults"
install -o root -g root -m 0440 "$tmp" /etc/sudoers.d/nuo
printf '%s ALL=(%s) NOPASSWD: %s\n' "$OWNER" "$USER_NAME" "$LAUNCHER" >"$tmp"
visudo -cqf "$tmp" || die "invalid sudoers rule"
install -o root -g root -m 0440 "$tmp" "/etc/sudoers.d/$USER_NAME"
visudo -c >/dev/null || { visudo -c >&2; die "sudoers no longer parses: check /etc/sudoers.d/nuo*"; }

say "network rules"
touch /etc/nuo/profiles
grep -qx "$USER_NAME" /etc/nuo/profiles || echo "$USER_NAME" >>/etc/nuo/profiles
printf 'GATEWAY_PORT=%s\n' "$PORT" >/etc/nuo/firewall.conf
cat >/etc/systemd/system/nuo-firewall.service <<'UNIT'
[Unit]
Description=Network rules of the Nuo profile users (loopback and home network closed but the gateway)
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/lib/nuo/nuo-firewall

[Install]
WantedBy=multi-user.target
UNIT
if [[ -d /run/systemd/system ]]; then
  systemctl daemon-reload
  systemctl enable nuo-firewall.service >/dev/null 2>&1
  systemctl restart nuo-firewall.service
else
  echo "   no systemd here: rules applied now, not at boot"
  /usr/local/lib/nuo/nuo-firewall
fi

say "checks as $USER_NAME"
out="$(sudo -u "$OWNER" sudo -n -u "$USER_NAME" "$LAUNCHER" --check 2>&1 | tail -1 || true)"
[[ "$out" == ok ]] || die "launcher check failed: $out"
for p in "$OWNER_HOME" "$NUO/config/env" "$OWNER_HOME/.secrets" "$OWNER_HOME/.claude" "$NUO/profiles/owner"; do
  if sudo -u "$USER_NAME" test -r "$p" 2>/dev/null; then die "$USER_NAME can read $p"; fi
done
if sudo -u "$USER_NAME" sudo -n true 2>/dev/null; then die "$USER_NAME can use sudo"; fi
echo "ok: $USER_NAME is set up. Now, as $OWNER: systemctl --user restart nuo-gateway"
