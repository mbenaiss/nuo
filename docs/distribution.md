# Distributing the apps to a few friends

Nuo is not on the App Store. For two or three friends, the iPhone app goes out as an **Ad Hoc** build installed
from a private web page, and the Mac app as a **Developer ID** build, notarized by Apple. Each friend then pairs the
app with the gateway under their own profile ([profiles.md](profiles.md)).

| Script | Does |
|---|---|
| `scripts/adhoc-release.sh` | registers new UDIDs, archives `Nuo` (app, widgets, share extension, watch app), exports an Ad Hoc `.ipa`, writes `manifest.plist` + `index.html`, optionally uploads them to R2 |
| `scripts/mac-release.sh` | archives `NuoMac`, exports it for Developer ID, notarizes, staples, checks with Gatekeeper, outputs a zip (and a dmg with `--dmg`) |

Both take `--dry-run` (prints the plan, only read-only checks run) and `--help`. Outputs go to `build/` (ignored).

Both sign with your own Apple developer account: they read `DEVELOPMENT_TEAM` from `ios/Local.xcconfig` and stop
with a message when it is missing or empty. Set it up once as in
[getting started](getting-started.md#building-with-your-own-apple-account) (team, `NUO_BUNDLE_ID`, `NUO_APP_GROUP`).
Ad Hoc and Developer ID builds need a paid membership.

## iPhone: Ad Hoc

### Limits

- Only devices whose UDID is in the provisioning profile can install the build. A new UDID means: register it,
  re-export, send the new link. Older builds keep working on the devices they already listed.
- 100 devices per device class (iPhone, iPad, Apple Watch, Mac…) per membership year. Disabling a device does not
  free its slot before the membership renews.
- Ad Hoc profiles and the Apple Distribution certificate last one year. When they expire the installed app stops
  launching: rebuild and reinstall before that.
- The build embeds the watch app, widgets, share extension and the app group, so every one of these targets needs
  its own Ad Hoc profile. Automatic signing with `-allowProvisioningUpdates` creates or regenerates all of them
  (and a cloud-managed distribution certificate if needed) after device registration.
- The watch app only installs on an Apple Watch whose UDID is also registered (Xcode › Devices and Simulators lists
  the paired watch under the iPhone). Without it, the iPhone app works and the watch app is skipped.

### Getting a friend's UDID

No configuration profile (`.mobileconfig`) to install. The iPhone's Settings app does not show the UDID; any of
these does:

- **Finder** (macOS) or iTunes/Apple Devices (Windows): connect the iPhone by cable, trust the computer, select the
  iPhone, then click the grey line under its name (model, capacity…) until the UDID appears; right-click › Copy.
- **Apple Configurator**: connect the iPhone, select it, Get Info, UDID.
- **Xcode** › Window › Devices and Simulators: the *Identifier* field.

Recent iPhones give a 25-character UDID (`00008110-000A1B2C3D4E5F60`), older ones 40 hex characters.

### Building

The device list is a text file kept out of the repo, one `<UDID> <name>` per line, `#` for comments:

```
# friends
00008110-000A1B2C3D4E5F60 iPhone Sam
00008301-0011223344556677 Watch Sam
```

```bash
scripts/adhoc-release.sh --devices ~/nuo-devices.txt --dry-run            # plan + asc's own registration dry run
scripts/adhoc-release.sh --devices ~/nuo-devices.txt --publish             # register, build, upload to R2
scripts/adhoc-release.sh --devices ~/nuo-devices.txt --base-url https://…  # files only, upload by hand
```

Registration uses `asc devices register-batch` (platform `IOS`, which also covers Apple Watch), which skips UDIDs
already in the account. The export method is `release-testing` (Xcode 15.3 renamed `ad-hoc`; the script picks the
name from the installed Xcode). After the export the script prints the build's `aps-environment` and the number of
devices in the embedded profile.

Authentication:

- `asc` uses its stored API key (`asc auth status`).
- `xcodebuild` needs the key as a `.p8` file: `ASC_KEY_PATH`, or `ASC_KEY_PASS_ENTRY=<pass entry>` (the script
  writes it to a 0600 temp file and deletes it on exit). Key id and issuer default to asc's default key in
  `~/.asc/config.json`. Without a key file, `xcodebuild` uses the account signed in to Xcode › Settings › Accounts.
  Creating distribution certificates through cloud signing needs the Admin or Account Holder role.

### Hosting the install page

iOS installs over the air from an `itms-services://?action=download-manifest&url=…` link. The manifest and the
`.ipa` must be served over **HTTPS** with a certificate iOS trusts, without authentication.

`--publish` uploads `Nuo.ipa`, `manifest.plist` and `index.html` with `wrangler r2 object put` to
`$NUO_R2_BUCKET/<32 random hex>/…` and builds the URLs from `NUO_R2_PUBLIC_URL` (an R2 custom domain or the
bucket's `https://pub-<id>.r2.dev` URL). Public R2 buckets cannot be listed, so the random prefix is the only
secret: whoever has the link can download the build, which is useless on a device that is not in the profile. Each
release gets a new prefix; delete old ones from the bucket. Wrangler authenticates with `CLOUDFLARE_API_TOKEN` (or
`NUO_CF_TOKEN_PASS=<pass entry>`) or `wrangler login`.

Not on the gateway's hostnames:

- **The app hostname** sits behind Cloudflare Access with a service token ([security.md](security.md)). Safari and
  the iOS installer fetching the manifest and the `.ipa` cannot send `CF-Access-Client-Id/Secret`, so the install
  would fail on an Access login page; opening Access for these paths would put an unauthenticated route on the
  gateway.
- **The booking host** is the gateway's only unauthenticated internet surface, a strict router that serves the
  booking pages and nothing else ([security.md](security.md#public-booking-host)). An install route there widens
  that surface and ties every download to the home connection.

### Installing (friend side)

1. Open the link in **Safari** on the iPhone (not in an in-app browser), tap « Installer Nuo », confirm.
2. On iOS 16 and later, apps signed for development or Ad Hoc only run with **Developer Mode** on. The first launch
   shows a prompt; then Settings › Privacy & Security › Developer Mode (the entry appears once such an app is
   installed), turn it on, restart, confirm « Turn On ». Nothing to trust under General › VPN & Device Management:
   that screen is for enterprise builds.
3. If iOS says the app cannot be installed, the UDID is not in this build: register it and send a new link.

**Updating**: open the new link and install over the existing app; data and pairing are kept as long as the bundle
id and team stay the same.

### Push notifications

An Ad Hoc build is signed with `aps-environment` **production**, so its APNs tokens only work against
`api.push.apple.com`. The gateway picks the APNs host per token from the `environment` the app sends when it
registers (`POST` with `apnsToken` + `environment`). The app reads that environment from its own signing
(`ios/Nuo/Stores/APNSEnvironment.swift`: the embedded provisioning profile's `aps-environment`, `production`
without a profile, `development` on the simulator), so Ad Hoc and Developer ID builds register production tokens.

## Mac: Developer ID

```bash
scripts/mac-release.sh --dry-run
NOTARY_PROFILE=nuo-notary scripts/mac-release.sh --dmg
```

- Signed with a **Developer ID Application** certificate (created by automatic signing if missing; cloud-managed
  Developer ID certificates need the Account Holder role) and a Developer ID provisioning profile, which carries
  the keychain group and production push entitlements.
- Notarization: `notarytool submit --wait` with `NOTARY_PROFILE` (a keychain profile made once with
  `xcrun notarytool store-credentials <name> --key … --key-id … --issuer …`) or the API key found as above
  (`--key/--key-id/--issuer`). The ticket is stapled to the app (and to the dmg) and `spctl -a -vv` checks the
  result, so Gatekeeper accepts it offline.
- `--skip-notarize` exports and zips only; Gatekeeper blocks such a build on other Macs.
- Friend side: unzip (or open the dmg) and drag **Nuo** into Applications. macOS shows the usual « downloaded from
  the Internet » confirmation once, nothing more. Updates: replace the app the same way.
- No UDID is needed for the Mac; the 100-Mac limit does not apply to Developer ID.

## After installing

Each friend pairs the app with the gateway, on their own profile: see [profiles.md](profiles.md).
