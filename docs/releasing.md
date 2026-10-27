# Releasing Avo and its updates

Avo updates itself with [Sparkle 2](https://sparkle-project.org) (2.10.0,
through Swift Package Manager; `host/project.yml`). Its feed (`SUFeedURL`)
is the `appcast.xml` of the latest GitHub release,
`https://github.com/nizwar/avo/releases/latest/download/appcast.xml`. Each
release carries one next to its DMG, made by `build-dmg.sh --notarize` with
Sparkle's `generate_appcast`, which signs the DMG with Avo's update key.
Nothing else is hosted: making a release *is* publishing the update.

Sparkle installs a DMG whose EdDSA signature is valid for the running app's
key (`SUPublicEDKey`), or whose `Avo.app` carries the running app's
Developer ID (the same team, `2Y5JPG373S`): see *How Sparkle trusts an
update*. Updates run only in a Developer ID build, never a local ad hoc one
(`AppUpdater.signedForUpdates`). No build before 0.4.0 updated itself: until
0.3.0 the feed was a placeholder, then the Control Panel handed Sparkle a
local file, which Sparkle does not load. Those builds move to 0.4.0 by hand.

## Where things are

| What | Where |
|---|---|
| The feed | `SUFeedURL` in `host/Avo/Info.plist`: the `appcast.xml` asset of GitHub's latest release, the newest one that is neither a pre-release nor a draft |
| What it offers | that release's DMG, `Avo-<version>-b<build>.dmg`, when its build (`sparkle:version`, the app's `CFBundleVersion`) is above the running one's; build numbers only rise |
| Betas | pre-releases, never "latest": they reach nobody by themselves ([versioning.md](versioning.md#who-gets-a-beta)) |
| Automatic checks | on by default (`SUEnableAutomaticChecks`), once a day (`SUScheduledCheckInterval`), on Sparkle's own schedule. Settings › About turns them off. |
| Validation | Sparkle: the DMG's EdDSA signature for `SUPublicEDKey`, or the app's Developer ID (*How Sparkle trusts an update*) |
| The update key | the release Mac's login Keychain (Sparkle's `generate_keys`, account `ed25519`, made 2026-10-18); its public half is `SUPublicEDKey` |

Avo does not update itself in a local (ad hoc) build: Settings › About says
so and Avo › Check for Updates… is dimmed. Build a Developer ID release
(below) to try updates end to end — run an older build and point it at a
newer release.

## Publishing a release

A release is a GitHub release whose assets are the **notarized** DMG named
`Avo-<version>-b<build>.dmg` and the `appcast.xml` made with it (the
`--notarize` build below). Installed copies read the feed of the latest
release, so a final is published as the latest one (`gh release create
--latest`); a draft is read by nobody until it is published.

What a release is called, and which numbers go up when, is set out in
[versioning.md](versioning.md): the version (`0.4.0`), the beta label
(`Beta 2`, tag `v0.5.0-beta.2`) and the build number, one counter shared by
releases and test builds.

## Test builds

A test build is a DMG that is not published: for trying a change, for a
tester, or for trying an update. It takes the next build number like a
release does, and the version it is heading for
([versioning.md](versioning.md#test-builds)):

```sh
make project
scripts/build-dmg.sh --version 0.5.0 --build 128    # build/Avo-0.5.0-b128.dmg, signed ad hoc
```

`build-dmg.sh` signs ad hoc by default, re-signing each framework, the
daemon, `avoctl`, avo-vmm, the Bluetooth controller and the app with their
own entitlements and `com.avodroid` identifiers. Only a notarized build can
update installed copies; an ad hoc one is for a single Mac.

### Developer ID and notarization

A notarized build opens like any app: no Open Anyway in System Settings.

```sh
scripts/build-dmg.sh --version 0.4.0 --build 125 \
    --identity "Developer ID Application: Mochamad Syafuan (2Y5JPG373S)" --notarize
```

- **Signing:** `--identity` signs every piece with the hardened runtime and a
  secure timestamp, Sparkle's inner pieces inside-out first (*Signing
  Sparkle* below). The identity must be in the login Keychain;
  `codesign` may ask once for its key (Always Allow).
- **Notarization:** `--notarize` sends the app to Apple's notary service as a
  zip and staples the ticket to it, then makes the disk image, signs it,
  notarizes and staples it too. Gatekeeper then calls the app "Notarized
  Developer ID", even offline.
- **Credentials:** the Apple ID comes from `APPLE_ID` and an app-specific
  password (appleid.apple.com › Sign-In and Security) from
  `APPLE_APP_SPECIFIC_PASSWORD`, both from the release Mac's environment;
  the script never prints them. The team is the identity's.
- **A rejection** leaves the notary service's log in `notary-<build>.json`
  next to the disk image.

## Every release

1. **Pick the version and the build number** ([versioning.md](versioning.md)):
   a minor release for anything new, a patch for fixes only, a beta label if
   it is not the final yet; the build number is the next free one, above
   every release and test build so far. `--build` sets
   `CURRENT_PROJECT_VERSION` for this build only: `Base.xcconfig` keeps 1.
2. **Prepare the release in one commit**, `Prepare 0.4.0 as build 125` (or
   `Prepare 0.5.0 Beta 2 as build 131`): `MARKETING_VERSION` in
   `host/Config/Base.xcconfig`, the changelog entry
   ([CHANGELOG.md](../CHANGELOG.md)) headed `## 0.4.0 (build 125)`, and the
   website's `release.version` and `release.downloadUrl`
   (`website/site.config.mjs`).
3. **Build the notarized DMG** (*Developer ID and notarization* above):

   ```sh
   scripts/build-dmg.sh --version 0.4.0 --build <N> --out ~/Desktop \
       --identity "Developer ID Application: Mochamad Syafuan (2Y5JPG373S)" --notarize
   ```

   It names the DMG `Avo-<version>-b<N>.dmg` and holds `Avo.app` at the top
   level, which is how Sparkle finds the app. Last, it makes the update
   feed, `appcast.xml`, next to the DMG: `generate_appcast` signs the DMG
   with the update key, after the script has checked that the Keychain's key
   is the app's `SUPublicEDKey` (macOS may ask once to let Sparkle's tools
   use the Keychain: Always Allow). The feed is of that exact file: build
   again, and it changes. A beta passes its tag, `--tag v0.5.0-beta.2`, so
   the feed's links point at its release.
4. **Publish a GitHub release** with the DMG and `appcast.xml` as assets,
   tagged on the release-prep commit. A final is a regular release, the
   latest:

   ```sh
   gh release create v0.4.0 ~/Desktop/Avo-0.4.0-b<N>.dmg ~/Desktop/appcast.xml \
       --title "Avo 0.4.0" --notes-file notes.md --latest
   ```

   A beta is a pre-release:

   ```sh
   gh release create v0.5.0-beta.2 ~/Desktop/Avo-0.5.0-b<N>.dmg ~/Desktop/appcast.xml --prerelease \
       --title "Avo 0.5.0 Beta 2" --notes-file notes.md
   ```

   That is the whole update: installed copies read the latest release's feed
   on their next check and Sparkle installs it. A beta's feed waits unread
   ([versioning.md](versioning.md#who-gets-a-beta)). Push the release-prep
   commit when the release is published, not before: the website deploys on
   every push that touches `website/`, and its download button points at the
   new DMG.

## How Sparkle trusts an update

Sparkle (`SUUpdateValidator` in 2.10.0) installs an update when either
holds:

- the DMG's EdDSA signature, from the feed, is valid for the running app's
  `SUPublicEDKey`;
- the new `Avo.app` has a valid code signature that matches the running
  app's: a Developer ID of the same team (`2Y5JPG373S`).

Either one is enough, which is what lets one of them be replaced: a release
signed with a new key installs on its Developer ID (and must then be valid
for the new key it carries), one from a new signing identity on the key.
Whatever the signatures, an update must keep an EdDSA key and a code
signature (Sparkle refuses one that drops either), and a DMG with a valid
EdDSA signature whose app's code signature is broken is refused. So every
release is notarized with the Developer ID and signed with the update key,
both.

**Keep the update key.** Its private half is only in the release Mac's
login Keychain. Back it up (`generate_keys -x <file>`, kept somewhere safe
and offline). If it is lost, a release signed with a new key still installs
on its Developer ID, and carries the new `SUPublicEDKey` from then on.

- **Quarantine.** Sparkle removes the quarantine attribute from what it
  installs, so an update needs no Gatekeeper approval; only the first manual
  download goes through System Settings › Privacy & Security.
- **TCC.** The one Developer ID identity keeps macOS from asking again for the
  microphone and location after an update (each ad hoc build was a new app to
  TCC).
- **The daemon** stays a LaunchAgent of Avo's own with that identity
  (`DaemonAgent`), so it can wait for Android to stop after an update rather
  than being pinned to the code a Login Item saw at registration.

## Signing Sparkle

Sparkle's Swift package ships `Sparkle.framework` with:

- `Versions/B/Autoupdate`;
- `Versions/B/Updater.app`;
- `Versions/B/XPCServices/Installer.xpc` and `Downloader.xpc`.

Each is signed ad hoc with the hardened runtime. Xcode's Embed & Sign signs
only the outer framework.

A release script that re-signs the app must sign Sparkle's pieces inside-out,
each keeping its entitlements, before the framework itself:

```sh
F=Avo.app/Contents/Frameworks/Sparkle.framework
codesign -f -s "$ID" -o runtime "$F/Versions/B/XPCServices/Installer.xpc"
codesign -f -s "$ID" -o runtime --preserve-metadata=entitlements "$F/Versions/B/XPCServices/Downloader.xpc"
codesign -f -s "$ID" -o runtime --preserve-metadata=entitlements "$F/Versions/B/Autoupdate"
codesign -f -s "$ID" -o runtime "$F/Versions/B/Updater.app"
codesign -f -s "$ID" "$F"
```

Never use `--deep` to sign. Avo is not sandboxed, so the two XPC services go
unused (`SUEnableInstallerLauncherService` and `SUEnableDownloaderService`
stay off). A script may delete `Versions/B/XPCServices` and the
`XPCServices` link, then re-sign the framework. A Developer ID build signs
the same pieces with its identity and the hardened runtime, with
`--timestamp`.

## What an update does to a running Avo

Sparkle swaps `Avo.app` at the same path. It does this when the player
chooses Install and Relaunch, or when the Control Panel quits after a
download: Sparkle always installs a downloaded update at quit. Android is
never stopped for an update without the player's say.

- **Before Install and Relaunch:** if Android runs, Avo asks first. The
  choices are:
  - **Stop Android and Install:** Android shuts down cleanly first.
  - **Install Now:** Android keeps running the old build.
  - **Later:** the update installs when Avo quits.

  (`AppUpdater.updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)`)
- **The daemon** (`AvoDaemon/AppUpdateWatcher.swift`) notices the swap. A
  watch on `Avo.app` fires at once, and a check every five minutes catches
  anything it misses. Once Android holds nothing, the daemon exits with
  status 75. launchd starts the new build's daemon at the same path, because
  `KeepAlive` restarts it after a non-zero exit (Quit Avo exits with 0).
  While Android runs it waits. Its menu bar item then offers Restart Android
  to Finish Updating Avo: Android stops, and the new daemon starts it again.
- **The new Control Panel** compares the running daemon's hello
  (`DaemonHello.daemonVersion`: version, build and the start of its code
  hash) with its own Avo.app's daemon (`ControlPanelModel.checkDaemonBuild`).
  - With an older daemon and Android stopped, it restarts the agent at once.
  - With Android running, it leaves both. Settings › About shows "Android
    runs the previous version" with Restart Android, and the restart happens
    by itself when Android next stops.
  - A changed LaunchAgent plist waits the same way.
- **App Shims** made from another build's template are made again when the
  daemon next syncs the apps (`ShortcutManager.madeForAnotherAvo` compares
  their `CFBundleVersion` with the template's, as well as their
  `AvoHostApplication`).

## Testing an update by hand

An update can be tried end to end before anything is published: build N
installed, N+1 served from this Mac.

1. Build release N with `--identity` (Developer ID; notarizing is not needed
   on the Mac that built it) and a lower build number, and install it in
   `/Applications`.
2. Build N+1 the same way with a higher build number, and make its feed
   with the DMG's local address:

   ```sh
   mkdir -p /tmp/avo-feed && cp ~/Desktop/Avo-0.4.0-b<N+1>.dmg /tmp/avo-feed/
   "$SPARKLE_BIN/generate_appcast" --download-url-prefix http://127.0.0.1:8765/ /tmp/avo-feed
   (cd /tmp/avo-feed && python3 -m http.server 8765 --bind 127.0.0.1)
   ```
3. Point N at it, check, then put the feed back:

   ```sh
   defaults write com.avodroid.emulator SUFeedURL http://127.0.0.1:8765/appcast.xml
   # Avo › Check for Updates…: install with Android stopped, then again with an app open
   defaults delete com.avodroid.emulator SUFeedURL
   ```

   Check that Avo asks before it stops Android, that the daemon restarts on
   N+1 (its hello in Report a Problem shows the new build), and that the
   app's shim is made again.
