#!/usr/bin/env bash
# Consistent backup of a Nuo install, to move it to another machine or keep a copy (docs/install.md).
# Databases are copied with sqlite3 .backup (safe while the gateway runs); the rest is copied as is.
# Secrets (~/.secrets/nuo.env, the APNs key) are only included with --with-secrets, and then the whole
# archive is encrypted with a passphrase read from stdin.
set -euo pipefail

HOST=""
OUT="."
WITH_SECRETS=0
WITH_ARCHIVE=0
EMIT_TAR=0

usage() {
  cat <<EOF
usage: scripts/backup.sh [--host user@ip] [--out <dir>] [--with-secrets] [--with-archive]
  --host          back up that host over ssh; the archive is written here
  --out           folder of the archive (default: current folder)
  --with-secrets  include ~/.secrets/nuo.env, the APNs key and the shared browser profile (session
                  cookies), and encrypt the archive
                  (openssl AES-256, passphrase from stdin: prompted on a terminal, else the first line)
  --with-archive  include ~/nuo/archive (legacy assistant files, large)
EOF
}

while (($#)); do
  case "$1" in
    --host) HOST="${2:?--host needs user@ip}"; shift 2 ;;
    --out) OUT="${2:?--out needs a folder}"; shift 2 ;;
    --with-secrets) WITH_SECRETS=1; shift ;;
    --with-archive) WITH_ARCHIVE=1; shift ;;
    --emit-tar) EMIT_TAR=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

die() { printf 'backup: %s\n' "$*" >&2; exit 1; }

# Writes an uncompressed tar of the install to stdout; runs on the gateway host.
emit_tar() {
  local R="${NUO_HOME:-$HOME/nuo}"
  export PATH="$HOME/.local/bin:$HOME/.bun/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:$PATH"
  command -v sqlite3 >/dev/null || die "sqlite3 is missing on $(hostname)"
  umask 077
  local stage
  stage="$(mktemp -d "${TMPDIR:-/tmp}/nuo-backup.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$stage'" EXIT
  # Each profile tree (docs/profiles.md) is saved under nuo/profiles/<slug>; trees moved to /srv/nuo by
  # profile-os-setup.sh are followed through their link. A profile's agent HOME (CLI logins) is not saved.
  local trees=() format=nuo-backup-2
  if [[ -d "$R/profiles/owner" ]]; then
    for t in "$R"/profiles/*/; do trees+=("profiles/$(basename "$t")"); done
  else
    [[ -f "$R/data/nuo.db" ]] || die "no $R/profiles/owner nor $R/data/nuo.db on $(hostname)"
    trees=(.)
    format=nuo-backup-1
  fi
  mkdir -p "$stage/nuo"
  if [[ -f "$R/profiles/registry.db" ]]; then
    mkdir -p "$stage/nuo/profiles"
    sqlite3 "$R/profiles/registry.db" ".timeout 10000" ".backup '$stage/nuo/profiles/registry.db'"
  fi
  local dbs=()
  for t in "${trees[@]}"; do
    local src="$R/$t"
    src="$(cd "$src" && pwd -P)"
    mkdir -p "$stage/nuo/$t/data"
    for db in nuo.db data.db; do
      [[ -f "$src/data/$db" ]] || continue
      sqlite3 "$src/data/$db" ".timeout 10000" ".backup '$stage/nuo/$t/data/$db'"
      [[ "$(sqlite3 "$stage/nuo/$t/data/$db" 'PRAGMA integrity_check')" == ok ]] || die "integrity check failed on the copy of $t/data/$db"
      dbs+=("$t/data/$db")
    done
    for p in data/files data/media docs bots instructions memory dashboards config inbox; do
      [[ -e "$src/$p" && ! -L "$src/$p" ]] || continue
      [[ "$t" == . && "$p" == config ]] && continue
      mkdir -p "$stage/nuo/$t/$(dirname "$p")"
      # Files a profile's agent made private (0600) cannot be read by the gateway user: they are skipped, loudly.
      cp -a "$src/$p" "$stage/nuo/$t/$p" || echo "backup: some files of $t/$p could not be read and are missing" >&2
    done
  done
  local parts=(config)
  ((WITH_ARCHIVE)) && parts+=(archive)
  for p in "${parts[@]}"; do
    [[ -e "$R/$p" ]] || continue
    cp -a "$R/$p" "$stage/nuo/$p"
  done
  # config/env and config/apns.p8 are links into ~/.secrets on a standard install, a file on an old one.
  rm -f "$stage/nuo/config/env" "$stage/nuo/config/apns.p8"
  if ((WITH_SECRETS)); then
    mkdir -p "$stage/secrets"
    local env_src="$R/config/env"
    [[ -e "$env_src" ]] || env_src="$HOME/.secrets/nuo.env"
    [[ -e "$env_src" ]] && cp -L "$env_src" "$stage/secrets/nuo.env"
    [[ -e "$R/config/apns.p8" ]] && cp -L "$R/config/apns.p8" "$stage/secrets/apns.p8"
    # The shared browser's profile holds the owner's session cookies: only in an encrypted archive, without caches.
    local browser="$R/browser" bdest="$stage/nuo/browser"
    [[ -d "$R/profiles/owner/browser" ]] && { browser="$R/profiles/owner/browser"; bdest="$stage/nuo/profiles/owner/browser"; }
    if [[ -d "$browser/profile" ]]; then
      mkdir -p "$bdest"
      tar -C "$browser" -cf - --exclude='Singleton*' --exclude='*Cache*' --exclude='Service Worker/CacheStorage' \
        --exclude='Crashpad' --exclude='component_crx_cache' profile 2>/dev/null | tar -C "$bdest" -xf - || true
    fi
  fi
  {
    echo "format=$format"
    echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host=$(hostname)"
    echo "user=$(id -un)"
    echo "home=$R"
    echo "with_secrets=$WITH_SECRETS"
    echo "with_archive=$WITH_ARCHIVE"
    for db in "${dbs[@]}"; do
      echo "sha256 ${db#./} $(sha256sum "$stage/nuo/$db" | cut -d' ' -f1)"
    done
    local docs="$R/docs"
    [[ -d "$R/profiles/owner/docs" ]] && docs="$R/profiles/owner/docs"
    git -C "$docs" rev-parse HEAD 2>/dev/null | sed 's/^/docs_head=/'
  } >"$stage/MANIFEST"
  local top=(MANIFEST nuo)
  ((WITH_SECRETS)) && top+=(secrets)
  tar -C "$stage" -cf - "${top[@]}"
}

if ((EMIT_TAR)); then
  emit_tar
  exit 0
fi

if command -v zstd >/dev/null; then
  ext=tar.zst; compress=(zstd -q -T0 -10)
else
  ext=tar.gz; compress=(gzip -6)
fi

pass=""
if ((WITH_SECRETS)); then
  command -v openssl >/dev/null || die "openssl is needed to encrypt an archive with secrets"
  if [[ -t 0 ]]; then
    IFS= read -rsp "Passphrase for the archive: " pass; echo >&2
    IFS= read -rsp "Again: " again; echo >&2
    [[ "$pass" == "$again" ]] || die "passphrases differ"
    unset again
  else
    IFS= read -r pass || true
  fi
  ((${#pass} >= 12)) || die "passphrase too short (12 characters minimum)"
  ext+=.enc
fi

name="${HOST:-$(hostname)}"
name="${name#*@}"
mkdir -p "$OUT"
file="$OUT/nuo-backup-$name-$(date +%Y%m%d-%H%M%S).$ext"
umask 077
trap '[[ -n "${done:-}" ]] || rm -f "$file"' EXIT

flags=()
((WITH_SECRETS)) && flags+=(--with-secrets)
((WITH_ARCHIVE)) && flags+=(--with-archive)

produce() {
  if [[ -n "$HOST" ]]; then
    ssh "$HOST" "bash -s -- --emit-tar ${flags[*]-}" <"$0"
  else
    bash "$0" --emit-tar ${flags[@]+"${flags[@]}"}
  fi
}

if ((WITH_SECRETS)); then
  produce | "${compress[@]}" | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 -salt -pass fd:3 -out "$file" 3< <(printf '%s\n' "$pass")
else
  produce | "${compress[@]}" >"$file"
fi
unset pass

[[ -s "$file" ]] || die "empty archive"
done=1
echo "$file ($(du -h "$file" | cut -f1))"
