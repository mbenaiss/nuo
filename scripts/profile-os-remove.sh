#!/usr/bin/env bash
# Undoes scripts/profile-os-setup.sh for one profile, after `bun run src/cli.ts profile-delete <slug>` archived
# its tree (docs/profiles.md). Run with sudo on the gateway host:
#
#   sudo bash ~/nuo/os/profile-os-remove.sh <slug> [--owner <user>]
#
# Stops the user's processes, removes its sudoers rule, its network rules and the user itself. What is left
# in /srv/nuo/<slug> (normally nothing but an empty folder) is given to <owner> and kept, never deleted.
set -euo pipefail

SLUG=""
OWNER="${SUDO_USER:-}"
while (($#)); do
  case "$1" in
    --owner) OWNER="${2:?--owner needs a user}"; shift 2 ;;
    -h | --help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) SLUG="$1"; shift ;;
  esac
done
die() { printf 'profile-os-remove: %s\n' "$*" >&2; exit 1; }
[[ "$(id -u)" == 0 ]] || die "run it with sudo"
[[ "$SLUG" =~ ^[a-z][a-z0-9-]{1,23}$ && "$SLUG" != owner ]] || die "invalid profile slug \"$SLUG\""
[[ -n "$OWNER" && "$OWNER" != root ]] || die "--owner <gateway user> is required"
USER_NAME="nuo-$SLUG"

pkill -KILL -u "$USER_NAME" 2>/dev/null || true
rm -f "/etc/sudoers.d/$USER_NAME"
if [[ -f /etc/nuo/profiles ]]; then
  grep -vx "$USER_NAME" /etc/nuo/profiles >/etc/nuo/profiles.new || true
  mv /etc/nuo/profiles.new /etc/nuo/profiles
fi
systemctl restart nuo-firewall.service 2>/dev/null || /usr/local/lib/nuo/nuo-firewall || true
if getent passwd "$USER_NAME" >/dev/null; then userdel "$USER_NAME"; fi
getent group "$USER_NAME" >/dev/null && groupdel "$USER_NAME" 2>/dev/null || true
if [[ -d "/srv/nuo/$SLUG" ]]; then
  chown -R "$OWNER:$(id -gn "$OWNER")" "/srv/nuo/$SLUG"
  echo "kept /srv/nuo/$SLUG (now owned by $OWNER)"
fi
echo "ok: $USER_NAME removed"
