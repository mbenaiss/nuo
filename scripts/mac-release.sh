#!/usr/bin/env bash
# Developer ID build of the Mac app, notarized and stapled, as a zip (and optionally a dmg).
# See docs/distribution.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$ROOT/ios"
SCHEME="NuoMac"
APP_NAME="Nuo"

usage() {
  cat <<'EOF'
Usage: scripts/mac-release.sh [options]

Archives the NuoMac scheme, exports it for Developer ID with automatic signing, notarizes, staples and
checks it with Gatekeeper.

Options:
  --out DIR          Output directory (default: build/mac/<timestamp>)
  --dmg              Also build, sign, notarize and staple a .dmg
  --skip-notarize    Export and zip only (the result will be blocked by Gatekeeper on other Macs)
  --dry-run          Print what would happen; only read-only checks are run
  -h, --help         Show this help

Notarization credentials, first match wins:
  NOTARY_PROFILE            notarytool keychain profile (xcrun notarytool store-credentials <name> ...)
  ASC_KEY_PATH              App Store Connect API key (.p8); else ASC_KEY_PASS_ENTRY
  ASC_KEY_PASS_ENTRY        pass entry holding the .p8 contents
  ASC_KEY_ID, ASC_ISSUER_ID Key id / issuer; default: asc's default key in ~/.asc/config.json
The same API key, when present, is passed to xcodebuild; otherwise xcodebuild uses the Xcode account.
EOF
}

OUT=""
DMG=0
NOTARIZE=1
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="${2:?--out needs a directory}"; shift 2 ;;
    --dmg) DMG=1; shift ;;
    --skip-notarize) NOTARIZE=0; shift ;;
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

command -v xcodebuild >/dev/null || die "xcodebuild not found"
OUT="${OUT:-$ROOT/build/mac/$(date +%Y%m%d-%H%M%S)}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

LOCAL_XCCONFIG="$IOS/Local.xcconfig"
[[ -f "$LOCAL_XCCONFIG" ]] || die "ios/Local.xcconfig is missing: cp ios/Local.xcconfig.example ios/Local.xcconfig, then set DEVELOPMENT_TEAM to your Apple team ID (docs/getting-started.md)"
TEAM_ID="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*//p' "$LOCAL_XCCONFIG" | tail -n 1 | tr -d '[:space:]')"
[[ -n "$TEAM_ID" ]] || die "DEVELOPMENT_TEAM is empty in ios/Local.xcconfig: set it to your Apple team ID (Xcode, Settings, Accounts, or developer.apple.com, Membership)"
log "Xcode $(xcodebuild -version | awk 'NR==1 {print $2}'), team $TEAM_ID"

# Listing identities reads no secret; the cert can also be created by automatic signing (Account Holder only).
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application:.*($TEAM_ID)"; then
  log "Developer ID Application certificate found"
else
  echo "warning: no local Developer ID Application certificate for $TEAM_ID; export relies on -allowProvisioningUpdates (cloud signing)" >&2
fi

KEY_PATH="${ASC_KEY_PATH:-}"
KEY_ID="${ASC_KEY_ID:-}"
ISSUER="${ASC_ISSUER_ID:-}"
if [[ -z "$KEY_PATH" && -n "${ASC_KEY_PASS_ENTRY:-}" ]]; then
  KEY_PATH="$WORK/AuthKey.p8"
  (umask 077; pass show "$ASC_KEY_PASS_ENTRY" >"$KEY_PATH") || die "cannot read pass entry $ASC_KEY_PASS_ENTRY"
fi
if [[ -n "$KEY_PATH" && ( -z "$KEY_ID" || -z "$ISSUER" ) && -f "$HOME/.asc/config.json" ]]; then
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
  [[ -z "$KEY_ID" ]] && KEY_ID="${defaults%% *}"
  [[ -z "$ISSUER" ]] && ISSUER="${defaults#* }"
fi

XCODE_AUTH=()
if [[ -n "$KEY_PATH" ]]; then
  [[ -f "$KEY_PATH" && -n "$KEY_ID" && -n "$ISSUER" ]] || die "API key auth needs a key file, ASC_KEY_ID and ASC_ISSUER_ID"
  XCODE_AUTH=(-authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER")
  log "xcodebuild auth: App Store Connect API key $KEY_ID"
else
  log "xcodebuild auth: account signed in to Xcode (Settings > Accounts)"
fi

NOTARY_AUTH=()
if (( NOTARIZE )); then
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
    log "notarytool auth: keychain profile $NOTARY_PROFILE"
    xcrun notarytool history "${NOTARY_AUTH[@]}" </dev/null >/dev/null 2>&1 \
      || die "notarytool cannot use profile $NOTARY_PROFILE (xcrun notarytool store-credentials $NOTARY_PROFILE ...)"
  elif [[ -n "$KEY_PATH" ]]; then
    NOTARY_AUTH=(--key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER")
    log "notarytool auth: App Store Connect API key $KEY_ID"
  elif (( DRY_RUN )); then
    echo "warning: no notarization credentials (NOTARY_PROFILE or ASC_KEY_PATH/ASC_KEY_PASS_ENTRY); a real run would stop here" >&2
  else
    die "no notarization credentials: set NOTARY_PROFILE or ASC_KEY_PATH/ASC_KEY_PASS_ENTRY, or pass --skip-notarize"
  fi
fi

notarize() {
  local file="$1"
  if (( NOTARIZE )); then
    run xcrun notarytool submit "$file" ${NOTARY_AUTH[@]+"${NOTARY_AUTH[@]}"} --wait --timeout 1h
  fi
}

ARCHIVE="$OUT/$APP_NAME.xcarchive"
EXPORT="$OUT/export"
OPTS="$OUT/ExportOptions.plist"
APP="$EXPORT/$APP_NAME.app"

run mkdir -p "$OUT"
if command -v xcodegen >/dev/null 2>&1; then
  run bash -c "cd '$IOS' && xcodegen generate --quiet"
fi
if (( DRY_RUN )); then
  printf '[dry-run] write %s (method developer-id, signingStyle automatic, team %s)\n' "$OPTS" "$TEAM_ID"
else
  cat >"$OPTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM_ID</string>
</dict>
</plist>
EOF
fi

run xcodebuild -project "$IOS/Nuo.xcodeproj" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates ${XCODE_AUTH[@]+"${XCODE_AUTH[@]}"} archive
run xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$OPTS" -allowProvisioningUpdates ${XCODE_AUTH[@]+"${XCODE_AUTH[@]}"}

VERSION="0.0.0"
if (( ! DRY_RUN )); then
  [[ -d "$APP" ]] || die "no $APP_NAME.app in $EXPORT"
  VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
  log "$APP_NAME $VERSION ($(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist"))"
fi
ZIP="$OUT/$APP_NAME-$VERSION.zip"
DMG_PATH="$OUT/$APP_NAME-$VERSION.dmg"

# notarytool needs an archive; the stapled app is zipped again afterwards so the ticket ships inside.
if (( NOTARIZE )); then
  run ditto -c -k --keepParent "$APP" "$WORK/$APP_NAME-submit.zip"
  notarize "$WORK/$APP_NAME-submit.zip"
  run xcrun stapler staple "$APP"
  run xcrun stapler validate "$APP"
fi
run ditto -c -k --keepParent "$APP" "$ZIP"

if (( DMG )); then
  run hdiutil create -volname "$APP_NAME" -srcfolder "$APP" -ov -format UDZO "$DMG_PATH"
  if (( DRY_RUN )); then
    printf '[dry-run] codesign the dmg with the Developer ID Application identity\n'
  else
    identity="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p' | head -1)"
    [[ -n "$identity" ]] || die "the exported app is not signed with Developer ID"
    codesign --sign "$identity" --timestamp "$DMG_PATH"
  fi
  notarize "$DMG_PATH"
  (( NOTARIZE )) && run xcrun stapler staple "$DMG_PATH"
fi

if (( NOTARIZE )); then
  run spctl -a -vv -t exec "$APP"
  (( DMG )) && run spctl -a -vv -t open --context context:primary-signature "$DMG_PATH"
fi

log "done: $ZIP$( (( DMG )) && printf ' and %s' "$DMG_PATH")"
