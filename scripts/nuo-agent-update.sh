#!/usr/bin/env bash
# Installs the nuo-agent launcher sitting next to this script, and only it, then checks every profile user with it.
# For a launcher change without the rest of profile-os-setup.sh (users, folders, sudoers, firewall stay as they are):
#
#   sudo bash ~/nuo/os/nuo-agent-update.sh
#
# The new launcher applies to agents started afterwards; running ones keep their environment until they are closed.
set -euo pipefail

die() { printf 'nuo-agent-update: %s\n' "$*" >&2; exit 1; }
say() { printf '== %s\n' "$*"; }

[[ "$(id -u)" == 0 ]] || die "run it with sudo"
HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$HERE/nuo-agent"
LAUNCHER=/usr/local/lib/nuo/nuo-agent
[[ -f "$SOURCE" ]] || die "nuo-agent must sit next to this script"
bash -n "$SOURCE" || die "$SOURCE has a syntax error: nothing installed"

say "launcher"
if [[ -f "$LAUNCHER" ]] && cmp -s "$SOURCE" "$LAUNCHER"; then
  echo "$LAUNCHER is already up to date"
else
  install -d -o root -g root -m 0755 /usr/local/lib/nuo
  install -o root -g root -m 0755 "$SOURCE" "$LAUNCHER"
  echo "$LAUNCHER installed"
fi

failed=0
for user in $(getent passwd | cut -d: -f1 | grep '^nuo-' || true); do
  say "$user"
  check="$(sudo -n -u "$user" "$LAUNCHER" --check 2>&1 | tail -n 1)"
  echo "check: $check"
  [[ "$check" == ok ]] || failed=1
done
((failed == 0)) || die "some profile users are not ready (see above)"
say "done"
