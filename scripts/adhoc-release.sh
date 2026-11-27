#!/usr/bin/env bash
# Ad Hoc build of the iPhone app (with watch app, widgets and share extension) for a few registered devices,
# plus an itms-services install page. See docs/distribution.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$ROOT/ios"
SCHEME="Nuo"
APP_TITLE="Nuo"
IPA_NAME="Nuo.ipa"

usage() {
  cat <<'EOF'
Usage: scripts/adhoc-release.sh [options]

Registers new device UDIDs, archives the Nuo scheme, exports an Ad Hoc .ipa with automatic signing and
writes an OTA install page (manifest.plist + index.html).

Options:
  --devices FILE    Device list, one "<UDID> <name...>" per line, # comments (default: $NUO_DEVICES_FILE)
  --skip-register   Do not register devices with App Store Connect
  --skip-build      Reuse the .ipa already in --out (only regenerate/publish the install page)
  --out DIR         Output directory (default: build/adhoc/<timestamp>)
  --base-url URL    HTTPS URL where the output files will be uploaded by hand (no upload)
  --publish         Upload to Cloudflare R2 under a random path (needs NUO_R2_BUCKET, NUO_R2_PUBLIC_URL)
  --dry-run         Print what would happen; only read-only checks are run
  -h, --help        Show this help

Environment:
  NUO_DEVICES_FILE          Default for --devices
  ASC_KEY_PATH              App Store Connect API key (.p8) for xcodebuild; else ASC_KEY_PASS_ENTRY
  ASC_KEY_PASS_ENTRY        pass entry holding the .p8 contents (e.g. nuo/asc-api-key.p8)
  ASC_KEY_ID, ASC_ISSUER_ID Key id / issuer; default: asc's default key in ~/.asc/config.json
                            Without a key file, xcodebuild uses the account signed in to Xcode.
  NUO_R2_BUCKET             R2 bucket name (--publish)
  NUO_R2_PUBLIC_URL         Public HTTPS base of the bucket: custom domain or https://pub-<id>.r2.dev
  NUO_CF_TOKEN_PASS         pass entry for CLOUDFLARE_API_TOKEN (else env or `wrangler login`)
  NUO_CF_ACCOUNT_PASS       pass entry for CLOUDFLARE_ACCOUNT_ID (optional)
EOF
}

DEVICES_FILE="${NUO_DEVICES_FILE:-}"
REGISTER=1
BUILD=1
OUT=""
BASE_URL=""
PUBLISH=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --devices) DEVICES_FILE="${2:?--devices needs a file}"; shift 2 ;;
    --skip-register) REGISTER=0; shift ;;
    --skip-build) BUILD=0; shift ;;
    --out) OUT="${2:?--out needs a directory}"; shift 2 ;;
    --base-url) BASE_URL="${2:?--base-url needs a URL}"; shift 2 ;;
    --publish) PUBLISH=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
run() {
  if (( DRY_RUN )); then printf '[dry-run] %s\n' "$*"; else "$@"; fi
}
need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found${2:+ ($2)}"; }

(( PUBLISH )) && [[ -n "$BASE_URL" ]] && die "--publish and --base-url are exclusive"
[[ -z "$BASE_URL" || "$BASE_URL" == https://* ]] || die "--base-url must be https:// (itms-services refuses plain HTTP)"
BASE_URL="${BASE_URL%/}"

OUT="${OUT:-$ROOT/build/adhoc/$(date +%Y%m%d-%H%M%S)}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

need xcodebuild
need plutil
LOCAL_XCCONFIG="$IOS/Local.xcconfig"
[[ -f "$LOCAL_XCCONFIG" ]] || die "ios/Local.xcconfig is missing: cp ios/Local.xcconfig.example ios/Local.xcconfig, then set DEVELOPMENT_TEAM to your Apple team ID (docs/getting-started.md)"
TEAM_ID="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*//p' "$LOCAL_XCCONFIG" | tail -n 1 | tr -d '[:space:]')"
[[ -n "$TEAM_ID" ]] || die "DEVELOPMENT_TEAM is empty in ios/Local.xcconfig: set it to your Apple team ID (Xcode, Settings, Accounts, or developer.apple.com, Membership)"

# Xcode 15.3 renamed the "ad-hoc" export method to "release-testing".
xcode_version="$(xcodebuild -version | awk 'NR==1 {print $2}')"
xc_major="${xcode_version%%.*}"
xc_minor="$(cut -d. -f2 <<<"$xcode_version.0")"
if (( xc_major > 15 || (xc_major == 15 && xc_minor >= 3) )); then EXPORT_METHOD="release-testing"; else EXPORT_METHOD="ad-hoc"; fi
log "Xcode $xcode_version, team $TEAM_ID, export method $EXPORT_METHOD"

AUTH_ARGS=()
resolve_auth() {
  local key_path="${ASC_KEY_PATH:-}" key_id="${ASC_KEY_ID:-}" issuer="${ASC_ISSUER_ID:-}"
  if [[ -z "$key_path" && -n "${ASC_KEY_PASS_ENTRY:-}" ]]; then
    need pass
    key_path="$WORK/AuthKey.p8"
    (umask 077; pass show "$ASC_KEY_PASS_ENTRY" >"$key_path") || die "cannot read pass entry $ASC_KEY_PASS_ENTRY"
  fi
  if [[ -n "$key_path" && ( -z "$key_id" || -z "$issuer" ) && -f "$HOME/.asc/config.json" ]]; then
    local defaults
    defaults="$(python3 -I - "$HOME/.asc/config.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
name = c.get("default_key_name")
for k in c.get("keychain_metadata") or []:
    if k.get("name") == name:
        print(k.get("key_id", ""), k.get("issuer_id", ""))
        break
PY
)"
    [[ -z "$key_id" ]] && key_id="${defaults%% *}"
    [[ -z "$issuer" ]] && issuer="${defaults#* }"
  fi
  if [[ -n "$key_path" ]]; then
    [[ -f "$key_path" && -n "$key_id" && -n "$issuer" ]] || die "API key auth needs a key file, ASC_KEY_ID and ASC_ISSUER_ID"
    AUTH_ARGS=(-authenticationKeyPath "$key_path" -authenticationKeyID "$key_id" -authenticationKeyIssuerID "$issuer")
    log "xcodebuild auth: App Store Connect API key $key_id"
  else
    log "xcodebuild auth: account signed in to Xcode (Settings > Accounts)"
  fi
}

register_devices() {
  [[ -n "$DEVICES_FILE" ]] || die "no device file: pass --devices FILE or --skip-register"
  [[ -f "$DEVICES_FILE" ]] || die "device file not found: $DEVICES_FILE"
  need asc "brew install asc"
  local tsv="$WORK/devices.tsv" n=0 udid name
  : >"$tsv"
  while read -r udid name || [[ -n "${udid:-}" ]]; do
    [[ -z "$udid" || "$udid" == \#* ]] && continue
    [[ "$udid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}$ || "$udid" =~ ^[0-9A-Fa-f]{40}$ ]] \
      || die "not an iPhone UDID: $udid"
    [[ -n "$name" ]] || die "missing device name for $udid"
    printf '%s\t%s\tIOS\n' "$udid" "$name" >>"$tsv"
    n=$((n + 1))
  done <"$DEVICES_FILE"
  log "$n device(s) in $DEVICES_FILE"
  (( n > 0 )) || return 0
  # register-batch skips UDIDs already registered; its own --dry-run only lists, it creates nothing.
  if (( DRY_RUN )); then
    asc devices register-batch --file "$tsv" --platform IOS --dry-run --output table \
      || echo "[dry-run] asc registration plan unavailable (auth or network)"
  else
    asc devices register-batch --file "$tsv" --platform IOS --confirm --output table
  fi
}

build_ipa() {
  resolve_auth
  local archive="$OUT/Nuo.xcarchive" export_dir="$WORK/export" opts="$OUT/ExportOptions.plist"
  run mkdir -p "$OUT"
  if command -v xcodegen >/dev/null 2>&1; then
    run bash -c "cd '$IOS' && xcodegen generate --quiet"
  fi
  if (( DRY_RUN )); then
    printf '[dry-run] write %s (method %s, signingStyle automatic, team %s)\n' "$opts" "$EXPORT_METHOD" "$TEAM_ID"
  else
    cat >"$opts" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>$EXPORT_METHOD</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>thinning</key><string>&lt;none&gt;</string>
  <key>stripSwiftSymbols</key><true/>
</dict>
</plist>
EOF
  fi
  run xcodebuild -project "$IOS/Nuo.xcodeproj" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$archive" \
    -allowProvisioningUpdates ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} archive
  run xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_dir" \
    -exportOptionsPlist "$opts" -allowProvisioningUpdates ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}
  if (( DRY_RUN )); then
    printf '[dry-run] move the exported .ipa to %s/%s\n' "$OUT" "$IPA_NAME"
  else
    local ipa
    ipa="$(find "$export_dir" -maxdepth 1 -name '*.ipa' | head -1)"
    [[ -n "$ipa" ]] || die "no .ipa produced in $export_dir"
    mv "$ipa" "$OUT/$IPA_NAME"
  fi
}

read_ipa_info() {
  local ipa="$OUT/$IPA_NAME" app
  [[ -f "$ipa" ]] || die "missing $ipa"
  (cd "$WORK" && unzip -q -o "$ipa" 'Payload/*')
  app="$(find "$WORK/Payload" -maxdepth 1 -name '*.app' | head -1)"
  BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$app/Info.plist")"
  BUNDLE_VERSION="$(plutil -extract CFBundleShortVersionString raw "$app/Info.plist")"
  BUILD_NUMBER="$(plutil -extract CFBundleVersion raw "$app/Info.plist")"
  log "$BUNDLE_ID $BUNDLE_VERSION ($BUILD_NUMBER)"
  # Ad Hoc profiles sign push as production; the gateway must send to api.push.apple.com for these devices.
  local aps
  aps="$(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -extract aps-environment raw - 2>/dev/null || true)"
  log "aps-environment: ${aps:-<none>}"
  [[ "$aps" == "production" ]] || echo "warning: expected aps-environment production in an Ad Hoc build" >&2
  if [[ -f "$app/embedded.mobileprovision" ]]; then
    local count
    count="$(python3 -I - "$app/embedded.mobileprovision" <<'PY' || echo "?"
import plistlib, sys
raw = open(sys.argv[1], "rb").read()
start, end = raw.index(b"<?xml"), raw.index(b"</plist>") + len(b"</plist>")
print(len(plistlib.loads(raw[start:end]).get("ProvisionedDevices", [])))
PY
)"
    log "devices in the app's Ad Hoc profile: $count"
  fi
}

write_install_page() {
  local base="$1"
  cat >"$OUT/manifest.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key><string>software-package</string>
          <key>url</key><string>$base/$IPA_NAME</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key><string>$BUNDLE_ID</string>
        <key>bundle-version</key><string>$BUNDLE_VERSION</string>
        <key>kind</key><string>software</string>
        <key>title</key><string>$APP_TITLE</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
EOF
  plutil -lint -s "$OUT/manifest.plist"
  local manifest_url="$base/manifest.plist"
  local encoded
  encoded="$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$manifest_url")"
  cat >"$OUT/index.html" <<EOF
<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Installer $APP_TITLE</title>
<style>
  body { font: 17px/1.5 -apple-system, system-ui, sans-serif; max-width: 34rem; margin: 2rem auto; padding: 0 1rem; color: #1c1c1e; background: #fff; }
  a.install { display: block; text-align: center; padding: .9rem; border-radius: .8rem; background: #0a84ff; color: #fff; text-decoration: none; font-weight: 600; margin: 1.5rem 0; }
  ol { padding-left: 1.2rem; } small { color: #6e6e73; }
  @media (prefers-color-scheme: dark) { body { color: #f2f2f7; background: #000; } small { color: #98989d; } }
</style>
</head>
<body>
<h1>$APP_TITLE $BUNDLE_VERSION <small>($BUILD_NUMBER)</small></h1>
<a class="install" href="itms-services://?action=download-manifest&amp;url=$encoded">Installer $APP_TITLE</a>
<ol>
  <li>Ouvre cette page dans <strong>Safari</strong> sur ton iPhone (pas dans une autre app ni un aperçu de lien).</li>
  <li>Touche « Installer $APP_TITLE », puis confirme. L'icône apparaît sur l'écran d'accueil.</li>
  <li>Au premier lancement, iOS demande le <strong>Mode développeur</strong> : Réglages › Confidentialité et sécurité › Mode développeur, active-le, redémarre l'iPhone puis confirme « Activer ». Aucun profil à approuver dans « VPN et gestion de l'appareil ».</li>
  <li>Si l'installation échoue (« impossible d'installer »), ton iPhone n'est sans doute pas encore dans cette version : envoie ton UDID et attends le lien suivant.</li>
</ol>
<p><small>Pour une mise à jour, rouvre le nouveau lien et installe par-dessus : les données sont conservées.</small></p>
</body>
</html>
EOF
}

publish_r2() {
  local base="$1" prefix="$2"
  [[ -n "${NUO_R2_BUCKET:-}" ]] || die "NUO_R2_BUCKET is not set"
  need wrangler
  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" && -n "${NUO_CF_TOKEN_PASS:-}" ]]; then
    CLOUDFLARE_API_TOKEN="$(pass show "$NUO_CF_TOKEN_PASS")" || die "cannot read $NUO_CF_TOKEN_PASS"
    export CLOUDFLARE_API_TOKEN
  fi
  if [[ -z "${CLOUDFLARE_ACCOUNT_ID:-}" && -n "${NUO_CF_ACCOUNT_PASS:-}" ]]; then
    CLOUDFLARE_ACCOUNT_ID="$(pass show "$NUO_CF_ACCOUNT_PASS")" || die "cannot read $NUO_CF_ACCOUNT_PASS"
    export CLOUDFLARE_ACCOUNT_ID
  fi
  local f type
  for f in "$IPA_NAME" manifest.plist index.html; do
    case "$f" in
      *.ipa) type="application/octet-stream" ;;
      *.plist) type="text/xml" ;;
      *.html) type="text/html; charset=utf-8" ;;
    esac
    run wrangler r2 object put "$NUO_R2_BUCKET/$prefix/$f" --remote --file "$OUT/$f" \
      --content-type "$type" --cache-control "no-store"
  done
  if (( ! DRY_RUN )); then
    local code
    code="$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' "$base/manifest.plist" || true)"
    [[ "$code" == "200" ]] || echo "warning: $base/manifest.plist answered HTTP $code" >&2
  fi
}

if (( REGISTER )); then register_devices; else log "device registration skipped"; fi

if (( BUILD )); then
  build_ipa
else
  log "build skipped, reusing $OUT/$IPA_NAME"
fi

PREFIX=""
if (( PUBLISH )); then
  [[ -n "${NUO_R2_PUBLIC_URL:-}" ]] || die "NUO_R2_PUBLIC_URL is not set"
  [[ "$NUO_R2_PUBLIC_URL" == https://* ]] || die "NUO_R2_PUBLIC_URL must be https://"
  PREFIX="$(openssl rand -hex 16)"
  BASE_URL="${NUO_R2_PUBLIC_URL%/}/$PREFIX"
fi

if (( DRY_RUN )); then
  if [[ -n "$BASE_URL" ]]; then
    printf '[dry-run] write %s/manifest.plist and index.html for %s\n' "$OUT" "$BASE_URL"
  else
    printf '[dry-run] no --base-url/--publish: only the .ipa would be produced\n'
  fi
  (( PUBLISH )) && publish_r2 "$BASE_URL" "$PREFIX"
  [[ -n "$BASE_URL" ]] && log "install page would be: $BASE_URL/index.html"
  exit 0
fi

read_ipa_info

if [[ -z "$BASE_URL" ]]; then
  log "done: $OUT/$IPA_NAME (no install page: pass --base-url or --publish)"
  exit 0
fi

write_install_page "$BASE_URL"
(( PUBLISH )) && publish_r2 "$BASE_URL" "$PREFIX"

log "files in $OUT"
(( PUBLISH )) || log "upload $IPA_NAME, manifest.plist and index.html to $BASE_URL/"
log "install page: $BASE_URL/index.html"
