#!/usr/bin/env bash
# Restores an archive made by scripts/backup.sh into ~/nuo (docs/install.md). The archive is checked first
# (manifest, database integrity and checksums); then the gateway is stopped, what it replaces is moved to
# ~/nuo/.pre-restore-<date>/ (nothing is deleted), and the gateway is started again.
# Run scripts/install.sh on a new host first: it installs bun, the code and the systemd unit.
set -euo pipefail

HOST=""
ARCHIVE=""
NO_SERVICE=0
YES=0
UNIT=nuo-gateway.service

usage() {
  cat <<EOF
usage: scripts/restore.sh <archive> [--host user@ip] [--no-service] [--yes]
  --host        restore on that host over ssh (the archive is copied there, then removed)
  --no-service  do not stop or start the systemd user unit
  --yes         do not ask for confirmation
An encrypted archive (.enc) asks for its passphrase on the terminal, or reads it from the first line of stdin.
EOF
}

while (($#)); do
  case "$1" in
    --host) HOST="${2:?--host needs user@ip}"; shift 2 ;;
    --no-service) NO_SERVICE=1; shift ;;
    --yes) YES=1; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) [[ -z "$ARCHIVE" ]] || { usage >&2; exit 2; }; ARCHIVE="$1"; shift ;;
  esac
done

die() { printf 'restore: %s\n' "$*" >&2; exit 1; }
[[ -n "$ARCHIVE" ]] || { usage >&2; exit 2; }
[[ -f "$ARCHIVE" ]] || die "no such archive: $ARCHIVE"

if [[ -n "$HOST" ]]; then
  remote_tmp="$(ssh -n "$HOST" 'mktemp -d /tmp/nuo-restore.XXXXXX')"
  trap 'ssh -n "$HOST" "rm -rf $remote_tmp" || true' EXIT
  rsync -a "$0" "$ARCHIVE" "$HOST:$remote_tmp/" </dev/null
  cmd="bash $remote_tmp/$(basename "$0") $remote_tmp/$(printf '%q' "$(basename "$ARCHIVE")")"
  ((NO_SERVICE)) && cmd+=" --no-service"
  ((YES)) && cmd+=" --yes"
  if [[ -t 0 ]]; then ssh -t "$HOST" "$cmd"; else ssh "$HOST" "$cmd"; fi
  exit 0
fi

R="${NUO_HOME:-$HOME/nuo}"
SECRETS_DIR="$HOME/.secrets"
export PATH="$HOME/.local/bin:$HOME/.bun/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:$PATH"
for bin in tar sqlite3 sha256sum; do command -v "$bin" >/dev/null || die "$bin is missing"; done

case "$ARCHIVE" in
  *.tar.zst | *.tar.zst.enc) command -v zstd >/dev/null || die "zstd is missing"; decompress=(zstd -dcq) ;;
  *.tar.gz | *.tar.gz.enc) decompress=(gzip -dc) ;;
  *) die "unknown archive type (expected .tar.zst, .tar.gz, optionally .enc)" ;;
esac

umask 077
mkdir -p "$R"
stage="$(mktemp -d "$R/.restore.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

echo "== unpacking $(basename "$ARCHIVE")"
if [[ "$ARCHIVE" == *.enc ]]; then
  command -v openssl >/dev/null || die "openssl is missing"
  if [[ -t 0 ]]; then
    IFS= read -rsp "Passphrase: " pass; echo >&2
  else
    IFS= read -r pass || true
  fi
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 -pass fd:3 -in "$ARCHIVE" 3< <(printf '%s\n' "$pass") |
    "${decompress[@]}" | tar -xf - -C "$stage" || die "cannot decrypt or unpack (wrong passphrase?)"
  unset pass
else
  "${decompress[@]}" <"$ARCHIVE" | tar -xf - -C "$stage" || die "cannot unpack"
fi

echo "== checking"
M="$stage/MANIFEST"
format="$(sed -n 's/^format=//p' "$M" 2>/dev/null)"
[[ "$format" == nuo-backup-1 || "$format" == nuo-backup-2 ]] || die "not a nuo backup (MANIFEST missing or unknown format)"
S="$stage/nuo"
# nuo-backup-1: the layout before profiles (the gateway moves it under profiles/owner at its next start);
# nuo-backup-2: profiles/<slug>/… for every profile, profiles/registry.db.
owner_tree=.
[[ "$format" == nuo-backup-2 ]] && owner_tree=profiles/owner
[[ -f "$S/$owner_tree/data/nuo.db" ]] || die "the archive has no $owner_tree/data/nuo.db"
while read -r _ db sum; do
  [[ -f "$S/$db" ]] || die "$db is listed in the manifest but missing"
  [[ "$(sqlite3 "$S/$db" 'PRAGMA integrity_check')" == ok ]] || die "$db fails its integrity check"
  [[ "$sum" == "$(sha256sum "$S/$db" | cut -d' ' -f1)" ]] || die "$db checksum mismatch"
  echo "  $db ok"
done < <(grep '^sha256 ' "$M")
docs_head="$(sed -n 's/^docs_head=//p' "$M")"
if [[ -n "$docs_head" ]]; then
  [[ "$(git -C "$S/$owner_tree/docs" rev-parse HEAD 2>/dev/null)" == "$docs_head" ]] || die "docs repository does not match the manifest"
  echo "  docs at ${docs_head:0:12}"
fi
src_home="$(sed -n 's/^home=//p' "$M")"
sed -n 's/^\(created\|host\|user\|home\|with_secrets\|format\)=/  \1: /p' "$M"

parts=()
if [[ "$format" == nuo-backup-2 ]]; then
  for p in profiles archive; do [[ -e "$S/$p" ]] && parts+=("$p"); done
else
  for p in data/nuo.db data/data.db data/files data/media docs bots instructions memory dashboards archive browser; do
    [[ -e "$S/$p" ]] && parts+=("$p")
  done
fi
# Restoring the old layout over a migrated install: its profiles/ and the links at the old paths are put aside
# first, so the restored tree is migrated again by the gateway.
legacy_over_profiles=0
[[ "$format" == nuo-backup-1 && -e "$R/profiles" ]] && legacy_over_profiles=1
config_files=()
if [[ -d "$S/config" ]]; then
  for f in "$S/config"/* "$S/config"/.[!.]*; do
    [[ -e "$f" ]] && config_files+=("config/$(basename "$f")")
  done
fi

echo "== will replace in $R: ${parts[*]} ${config_files[*]-}"
[[ -d "$stage/secrets" ]] && echo "   secrets: installed into $SECRETS_DIR when missing there, else saved next to them as *.restored-<date>"
if ((!YES)); then
  [[ -t 0 ]] || die "not a terminal: pass --yes to restore without confirmation"
  read -rp "Restore? [y/N] " answer
  [[ "$answer" == y || "$answer" == Y ]] || die "aborted, nothing changed"
fi

if ((!NO_SERVICE)); then
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  echo "== stopping $UNIT"
  systemctl --user stop "$UNIT" 2>/dev/null || true
  # Its profile may be replaced; the gateway starts it again on demand.
  systemctl --user stop nuo-browser.service 2>/dev/null || true
fi

ts="$(date +%Y%m%d-%H%M%S)"
aside="$R/.pre-restore-$ts"
mkdir -p "$aside/data" "$aside/config"
move_aside() { [[ -e "$R/$1" || -L "$R/$1" ]] && { mkdir -p "$aside/$(dirname "$1")"; mv "$R/$1" "$aside/$1"; }; return 0; }
if ((legacy_over_profiles)); then
  move_aside profiles
  for d in data docs bots instructions memory dashboards browser; do [[ -L "$R/$d" ]] && move_aside "$d"; done
fi
for db in nuo.db data.db; do
  # A -wal left from the old database would be replayed into the restored one.
  [[ -e "$S/data/$db" ]] && { move_aside "data/$db-wal"; move_aside "data/$db-shm"; }
done
for p in "${parts[@]}" ${config_files[@]+"${config_files[@]}"}; do
  move_aside "$p"
  [[ -e "$S/$p" ]] || continue
  mkdir -p "$R/$(dirname "$p")"
  mv "$S/$p" "$R/$p"
done
for d in "$R" "$R/config" "$R/data" "$R/bots" "$R/instructions" "$R/memory" "$R/docs" "$R/dashboards" "$R/browser" "$R/browser/profile" "$R/profiles" "$R"/profiles/*/; do
  [[ -d "$d" && ! -L "${d%/}" ]] && chmod 700 "$d"
done

if [[ -d "$stage/secrets" ]]; then
  echo "== secrets"
  install -d -m 700 "$SECRETS_DIR"
  for f in nuo.env apns.p8; do
    [[ -f "$stage/secrets/$f" ]] || continue
    if [[ ! -e "$SECRETS_DIR/$f" ]]; then
      install -m 600 "$stage/secrets/$f" "$SECRETS_DIR/$f"
      echo "  $SECRETS_DIR/$f installed"
    elif cmp -s "$stage/secrets/$f" "$SECRETS_DIR/$f"; then
      echo "  $SECRETS_DIR/$f unchanged"
    else
      install -m 600 "$stage/secrets/$f" "$SECRETS_DIR/$f.restored-$ts"
      echo "  $SECRETS_DIR/$f kept; the archive's copy is $SECRETS_DIR/$f.restored-$ts (merge it by hand)"
    fi
  done
  [[ -e "$R/config/env" || -L "$R/config/env" ]] || ln -s "$SECRETS_DIR/nuo.env" "$R/config/env"
  [[ -e "$SECRETS_DIR/apns.p8" && ! -e "$R/config/apns.p8" && ! -L "$R/config/apns.p8" ]] && ln -s "$SECRETS_DIR/apns.p8" "$R/config/apns.p8"
fi
rmdir "$aside/data" "$aside/config" "$aside" 2>/dev/null || true

if ((!NO_SERVICE)); then
  echo "== starting $UNIT"
  systemctl --user start "$UNIT"
  port="$(grep -E '^[[:space:]]*(export[[:space:]]+)?NUO_PORT=' "$R/config/env" 2>/dev/null | tail -n 1 | sed -E 's/^[^=]*=//; s/["'\'' ]//g')"
  [[ "$port" =~ ^[0-9]+$ ]] || port=8790
  for _ in $(seq 1 30); do
    curl -fsS "http://127.0.0.1:$port/api/health" >/dev/null 2>&1 && break
    sleep 1
  done
  if ! curl -fsS "http://127.0.0.1:$port/api/health" >/dev/null 2>&1; then
    systemctl --user --no-pager --lines=30 status "$UNIT" || true
    die "the gateway does not answer on port $port"
  fi
  echo "  healthy on port $port"
fi

echo "== done"
[[ -d "$aside" ]] && echo "previous files: $aside (delete it once everything works)"
if [[ -n "$src_home" && "$src_home" != "$R" ]]; then
  echo "note: the backup comes from $src_home; absolute paths under it (bot workdir, config/tools.json, APNS_KEY_PATH) need updating"
fi
if [[ "$format" == nuo-backup-2 ]] && compgen -G "$R/profiles/*/" >/dev/null; then
  for t in "$R"/profiles/*/; do
    slug="$(basename "$t")"
    [[ "$slug" == owner ]] && continue
    echo "note: profile $slug was restored into $R/profiles/$slug: run sudo bash $R/os/profile-os-setup.sh $slug again (it moves it"
    echo "      to /srv/nuo/$slug; move an old /srv/nuo/$slug aside first), then the person logs in again (profile-login)"
  done
fi
if [[ ! -d "$stage/secrets" ]]; then
  echo "note: no secrets in the archive. If NUO_AUTH_KEY differs from the old host's, run"
  echo "      cd $R/app && bun run src/cli.ts auth-totp-reset   (paired devices keep working)"
fi
