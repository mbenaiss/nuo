#!/usr/bin/env bash
# One-line installer for the Nuo gateway (docs/install.md):
#   curl -fsSL https://raw.githubusercontent.com/mbenaiss/nuo/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/mbenaiss/nuo/main/install.sh | bash -s -- --yes
# It clones or updates the repository, then runs scripts/install.sh from that checkout, which does the actual work.
# Written for bash 3.2 (macOS's /bin/bash). Run with --help for the options.

nuo_usage() {
  cat <<'EOF'
Nuo installer: clones the repository, installs the gateway as a service, sets up 2FA and prints a pairing code.

usage: install.sh [options]          (from a pipe: curl -fsSL <url> | bash -s -- [options])
  --yes, -y           accept the defaults and every confirmation, sudo commands included (NUO_INSTALL_YES=1)
  --dir <path>        where the repository checkout lives (NUO_INSTALL_DIR, default ~/.local/share/nuo)
  --repo <url>        repository to clone (NUO_INSTALL_REPO, default https://github.com/mbenaiss/nuo.git)
  --ref <ref>         branch, tag or commit (NUO_INSTALL_REF, default main)
  --port <n>          gateway port for a new install (NUO_INSTALL_PORT, default 8790)
  --listen all|local  all: reachable from your local network (default); local: this machine only (NUO_INSTALL_LISTEN)
  --no-service        do not install a service; you start the gateway yourself (NUO_INSTALL_SERVICE=0)
  --no-2fa            skip the 2FA enrolment (pairing stays impossible until it is done) (NUO_INSTALL_2FA=0)
  --account <label>   label of the 2FA entry in your authenticator app (NUO_INSTALL_ACCOUNT, default: user name)
  --dry-run           print what would change and change nothing (the checkout goes to a temporary folder)
  --uninstall         remove the service, the gateway code, the helpers and the checkout; keep data and secrets
  --purge             with --uninstall: also delete ~/nuo (all data) and ~/.secrets/nuo.env
  -h, --help          this help

Supported: Debian and Ubuntu (systemd user service), macOS (launchd agent). Run it as the user that will own the
gateway, not root. Running it again updates the checkout and the gateway and keeps your settings and data.
EOF
}

nuo_install_main() {
  set -euo pipefail

  local yes="${NUO_INSTALL_YES:-0}" dir="${NUO_INSTALL_DIR:-}" repo="${NUO_INSTALL_REPO:-https://github.com/mbenaiss/nuo.git}"
  local ref="${NUO_INSTALL_REF:-main}" port="${NUO_INSTALL_PORT:-}" listen="${NUO_INSTALL_LISTEN:-}"
  local service="${NUO_INSTALL_SERVICE:-1}" twofa="${NUO_INSTALL_2FA:-1}" account="${NUO_INSTALL_ACCOUNT:-}"
  local dry_run=0 uninstall=0 purge=0
  while (($#)); do
    case "$1" in
      -y | --yes) yes=1; shift ;;
      --dir) dir="${2:?--dir needs a path}"; shift 2 ;;
      --repo) repo="${2:?--repo needs a url}"; shift 2 ;;
      --ref) ref="${2:?--ref needs a branch, tag or commit}"; shift 2 ;;
      --port) port="${2:?--port needs a number}"; shift 2 ;;
      --listen) listen="${2:?--listen needs all or local}"; shift 2 ;;
      --no-service) service=0; shift ;;
      --no-2fa) twofa=0; shift ;;
      --account) account="${2:?--account needs a label}"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --uninstall) uninstall=1; shift ;;
      --purge) purge=1; shift ;;
      -h | --help) nuo_usage; return 0 ;;
      *) printf 'install: unknown option %s\n\n' "$1" >&2; nuo_usage >&2; return 2 ;;
    esac
  done

  say() { printf '\n==> %s\n' "$*"; }
  die() { printf 'install: %s\n' "$*" >&2; exit 1; }
  # Answers are read from the terminal: when piped from curl, stdin is the script itself.
  has_tty() { [[ -t 0 ]] || (exec </dev/tty) 2>/dev/null; }
  read_tty() { if [[ -t 0 ]]; then read -r "$@"; else read -r "$@" </dev/tty; fi; }
  ask() { # var question default
    local answer=""
    if [[ "$yes" == 1 ]] || ! has_tty; then
      printf -v "$1" '%s' "$3"
      return 0
    fi
    read_tty -p "    $2 [$3] " answer || true
    printf -v "$1" '%s' "${answer:-$3}"
  }
  confirm() {
    local answer=""
    [[ "$yes" == 1 ]] && return 0
    has_tty || die "no terminal to ask on: rerun with --yes (curl ... | bash -s -- --yes) to accept the defaults"
    read_tty -p "    $1 [Y/n] " answer || return 1
    [[ -z "$answer" || "$answer" == [yY]* ]]
  }

  [[ "$listen" == "" || "$listen" == all || "$listen" == local ]] || die "--listen must be all or local"
  [[ "$port" == "" || "$port" =~ ^[0-9]+$ ]] || die "--port must be a number"
  [[ "$purge" == 0 || "$uninstall" == 1 ]] || die "--purge goes with --uninstall"

  local os
  os="$(uname -s)"
  case "$os" in
    Linux)
      local os_id=""
      # shellcheck disable=SC1091
      [[ -r /etc/os-release ]] && os_id="$(. /etc/os-release && printf '%s %s' "${ID:-}" "${ID_LIKE:-}")"
      [[ " $os_id " == *" debian "* || " $os_id " == *" ubuntu "* ]] ||
        die "this Linux (${os_id:-unknown}) is not supported: the installer knows Debian and Ubuntu. Other systems: docs/getting-started.md runs the gateway by hand."
      ;;
    Darwin) ;;
    *) die "$os is not supported: the installer knows Debian, Ubuntu and macOS. Other systems: docs/getting-started.md runs the gateway by hand." ;;
  esac
  if [[ "$(id -u)" == 0 && "${NUO_ALLOW_ROOT:-}" != 1 ]]; then
    die "run it as the user that will own the gateway, not root (the installer asks before each sudo command)"
  fi

  dir="${dir:-${XDG_DATA_HOME:-$HOME/.local/share}/nuo}"
  local engine_args=()
  [[ "$yes" == 1 ]] && engine_args+=(--yes)
  [[ "$dry_run" == 1 ]] && engine_args+=(--dry-run)
  local engine_in=/dev/null
  has_tty && engine_in=/dev/tty

  if [[ "$uninstall" == 1 ]]; then
    say "Uninstall Nuo"
    engine_args+=(--uninstall)
    [[ "$purge" == 1 ]] && engine_args+=(--purge)
    if [[ -f "$dir/scripts/install.sh" ]]; then
      bash "$dir/scripts/install.sh" "${engine_args[@]}" <"$engine_in"
      if [[ -n "$(git -C "$dir" --no-optional-locks status --porcelain 2>/dev/null)" ]]; then
        echo "  kept the checkout $dir: it has local changes"
      elif [[ "$dry_run" == 1 ]]; then
        echo "  would: remove the checkout $dir"
      else
        echo "  remove the checkout $dir"
        rm -rf "$dir"
      fi
    else
      # The checkout is gone (an earlier --uninstall, before a --purge): fetch the uninstaller into a temporary folder.
      command -v git >/dev/null || die "no Nuo checkout in $dir and no git to fetch the uninstaller (pass --dir with the folder you installed into)"
      NUO_INSTALL_TMP="$(mktemp -d)"
      trap 'if [[ -n "${NUO_INSTALL_TMP:-}" ]]; then rm -rf "$NUO_INSTALL_TMP"; fi' EXIT
      git -C "$NUO_INSTALL_TMP" init -q
      git -C "$NUO_INSTALL_TMP" fetch -q --depth 1 "$repo" "$ref" </dev/null || die "no Nuo checkout in $dir, and cannot fetch $ref from $repo"
      git -C "$NUO_INSTALL_TMP" -c advice.detachedHead=false checkout -q --detach FETCH_HEAD
      bash "$NUO_INSTALL_TMP/scripts/install.sh" "${engine_args[@]}" <"$engine_in"
    fi
    return 0
  fi

  printf 'Nuo installer: sets up the Nuo gateway for %s on this %s.\n' "$(id -un)" "$([[ "$os" == Darwin ]] && echo Mac || echo machine)"
  [[ "$dry_run" == 1 ]] && echo "Dry run: nothing is changed."

  say "Prerequisites"
  command -v curl >/dev/null || die "curl is missing: install it first (Debian/Ubuntu: sudo apt-get install curl)"
  if [[ "$os" == Darwin ]]; then
    # On a Mac without the Command Line Tools, /usr/bin/git is a stub that opens an install dialog.
    xcode-select -p >/dev/null 2>&1 || die "the Xcode Command Line Tools are missing (they provide git): run xcode-select --install, then this installer again"
  fi
  local need_git=0
  if ! command -v git >/dev/null; then
    [[ "$os" == Linux ]] || die "git is missing"
    command -v sudo >/dev/null || die "git is missing and sudo is not installed: install git as root, then run this installer again"
    need_git=1
    echo "  curl present, git missing (installed with apt after the questions)"
  else
    echo "  curl and git present"
  fi

  local fresh=1
  [[ -e "$HOME/.secrets/nuo.env" ]] && fresh=0
  if [[ "$yes" != 1 ]] && has_tty; then
    say "Questions (Enter keeps the default)"
    ask dir "Folder for the Nuo source checkout?" "$dir"
    dir="${dir/#\~/$HOME}"
    if [[ "$fresh" == 1 ]]; then
      ask port "Gateway port?" "${port:-8790}"
      [[ "$port" =~ ^[0-9]+$ ]] || die "the port must be a number"
      local reach=""
      ask reach "Reachable from your local network (an iPhone on your Wi-Fi), or this machine only? all/local" "${listen:-all}"
      [[ "$reach" == all || "$reach" == local ]] || die "answer all or local"
      listen="$reach"
    else
      echo "    port and listening address: kept from ~/.secrets/nuo.env"
    fi
    local a=""
    ask a "Run the gateway as a service that starts by itself? y/n" "$([[ "$service" == 1 ]] && echo y || echo n)"
    [[ "$a" == [yY]* ]] && service=1 || service=0
    ask a "Set up 2FA now (needed to pair an app; shows a QR code to scan)? y/n" "$([[ "$twofa" == 1 ]] && echo y || echo n)"
    [[ "$a" == [yY]* ]] && twofa=1 || twofa=0
  fi

  say "Plan"
  echo "  checkout:  $dir ($repo, $ref)"
  echo "  gateway:   ~/nuo/app, data in ~/nuo, settings and secrets in ~/.secrets/nuo.env (created once, never overwritten)"
  if [[ "$fresh" == 1 ]]; then
    echo "  network:   port ${port:-8790}, $([[ "$listen" == local ]] && echo "this machine only" || echo "all interfaces (pairing is accepted from the local network only)")"
  fi
  echo "  service:   $([[ "$service" == 1 ]] && { [[ "$os" == Darwin ]] && echo "launchd agent local.nuo.gateway" || echo "systemd user unit nuo-gateway.service, with linger"; } || echo "none")"
  echo "  2FA:       $([[ "$twofa" == 1 ]] && echo "enrolled now if not done yet" || echo "skipped")"
  echo "  missing system packages and Bun are installed; each sudo command is shown and asked for first"
  [[ "$need_git" == 1 ]] && echo "  git:       sudo apt-get update && sudo apt-get install -y git ca-certificates"
  [[ "$dry_run" == 1 ]] || confirm "Go ahead?" || die "nothing was changed"

  if [[ "$need_git" == 1 ]]; then
    if [[ "$dry_run" == 1 ]]; then
      echo
      echo "Dry run stops here: the gateway's own dry run needs git, which is not installed. Nothing was changed."
      return 0
    fi
    say "git"
    echo "  needs administrator rights: sudo apt-get update && sudo apt-get install -y git ca-certificates"
    confirm "Run it?" || die "declined: install git yourself, then run this installer again"
    sudo apt-get update -qq </dev/null
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git ca-certificates >/dev/null </dev/null
  fi

  # Global, not local: the EXIT trap runs after this function has returned.
  NUO_INSTALL_TMP=""
  trap 'if [[ -n "${NUO_INSTALL_TMP:-}" ]]; then rm -rf "$NUO_INSTALL_TMP"; fi' EXIT
  local checkout="$dir" update=0
  say "Source checkout"
  if [[ -d "$dir/.git" ]]; then
    [[ -f "$dir/scripts/install.sh" && -d "$dir/gateway" ]] || die "$dir is a git checkout but not of Nuo: pass another --dir"
    if [[ -n "$(git -C "$dir" --no-optional-locks status --porcelain --untracked-files=no)" ]]; then
      die "$dir has local changes: commit or discard them, or pass another --dir (nothing was changed)"
    fi
    update=1
  elif [[ -e "$dir" && -n "$(ls -A "$dir" 2>/dev/null)" ]]; then
    die "$dir exists and is not a Nuo checkout: pass another --dir"
  fi
  if [[ "$dry_run" == 1 ]]; then
    # The plan comes from the code that would run, fetched into a temporary folder.
    [[ "$update" == 1 ]] && echo "  would: update $dir to $ref from $repo" || echo "  would: clone $repo ($ref) into $dir"
    NUO_INSTALL_TMP="$(mktemp -d)"
    checkout="$NUO_INSTALL_TMP/nuo"
    update=0
  elif [[ "$update" == 1 ]]; then
    echo "  updating $dir to $ref"
  else
    echo "  cloning $repo ($ref) into $dir"
  fi
  if [[ "$update" == 1 ]]; then
    git -C "$checkout" fetch -q --depth 1 "$repo" "$ref" </dev/null || die "cannot fetch $ref from $repo"
  else
    mkdir -p "$checkout"
    git -C "$checkout" init -q
    git -C "$checkout" remote add origin "$repo"
    git -C "$checkout" fetch -q --depth 1 origin "$ref" </dev/null || {
      rm -rf "$checkout"
      die "cannot fetch $ref from $repo: check --repo and --ref"
    }
  fi
  git -C "$checkout" -c advice.detachedHead=false checkout -q --detach FETCH_HEAD
  echo "  at $(git -C "$checkout" log -1 --format='%h %s' | cut -c1-80)"

  say "Gateway"
  engine_args+=(--from-local)
  [[ -n "$port" ]] && engine_args+=(--port "$port")
  [[ -n "$listen" ]] && engine_args+=(--listen "$listen")
  [[ "$service" == 1 ]] || engine_args+=(--no-service)
  if [[ "$twofa" == 1 ]]; then
    engine_args+=(--setup-2fa --pair)
    [[ -n "$account" ]] && engine_args+=(--account "$account")
  fi
  bash "$checkout/scripts/install.sh" "${engine_args[@]}" <"$engine_in"

  cat <<EOF

Update later: run the same command again. Uninstall: add --uninstall (--purge also deletes your data).
Checkout: $dir. Documentation: $dir/docs/install.md
EOF
}

# Braces make bash read this whole line before running it: a download cut short runs nothing.
{ nuo_install_main "$@"; }
