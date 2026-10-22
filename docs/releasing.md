# Releasing Avo and its updates

Avo updates itself with [Sparkle 2](https://sparkle-project.org) (2.10.0,
through Swift Package Manager; `host/project.yml`). The Control Panel
(`host/Avo/AppUpdater.swift`) reads an appcast, an RSS feed that lists the
releases. Each release's archive carries an EdDSA (Ed25519) signature, and
installed copies check it with the public key in their Info.plist.

## Where things are

| What | Where |
|---|---|
| The feed's URL | `SUFeedURL` in `host/Avo/Info.plist` |
| The public key | `SUPublicEDKey` in `host/Avo/Info.plist` |
| The private key | The release Mac's login Keychain, never the repository |
| Automatic checks | On by default (`SUEnableAutomaticChecks`), once a day (`SUScheduledCheckInterval`). Settings › About turns them off. |
| Signing and publishing | `scripts/release-update.sh` |
| Sparkle's tools | `<derived data>/SourcePackages/artifacts/sparkle/Sparkle/bin`: `generate_keys`, `sign_update`, `generate_appcast`. Xcode puts them there when it fetches the package. |

### The feed

`SUFeedURL` is a placeholder until the feed exists:
`https://updates.avo.invalid/appcast.xml`. A `.invalid` host can never
resolve. While it is the placeholder:

- Avo does not start its updater: no checks run, and no error alerts appear.
- Settings › About says this build has no update feed.
- Avo › Check for Updates… is dimmed.

To set the feed up:

1. Put `appcast.xml` and the archives on an HTTPS host, for example GitHub
   Pages, a GitHub release's assets, or an S3 or R2 bucket.
2. Write the appcast's URL into `SUFeedURL`.
3. Build a release.

Sparkle reads the feed only over HTTPS.

To try a staging feed with an installed build:

```sh
defaults write com.avodroid.emulator AvoUpdateFeedURL https://…/appcast.xml
defaults delete com.avodroid.emulator AvoUpdateFeedURL   # back to Info.plist's
```

### The key

The key pair was made on 2026-10-18 with `generate_keys`:

- **Public key:** `W/SKL81r8nkZRC+f1CYNMK2uhNWWWbRmHhHFarxIG9M=`.
- **Private key:** the login Keychain item "Private key for signing Sparkle
  updates" (service `https://sparkle-project.org`, account `ed25519`).

Back the private key up now, and keep the copy offline (a password manager
or an encrypted disk):

```sh
"$BIN/generate_keys" -x ~/Desktop/avo-sparkle-key   # export; then move it somewhere safe
"$BIN/generate_keys" -f avo-sparkle-key             # on another release Mac: import
"$BIN/generate_keys" -p                             # prints the public key
```

Running `generate_keys` again is safe: it never overwrites a key and only
prints the existing one.

**Never lose the private key, and never change or remove `SUPublicEDKey`.**
Installed copies accept only updates signed with that key. While Avo is
signed ad hoc, the key cannot be rotated either (see below). Without the key,
every installed copy needs a manual download.

## Preview builds

Preview builds are published as GitHub pre-releases, without the update feed:

```sh
make project
scripts/build-dmg.sh --version 0.1.0 --build 32     # build/Avo-0.1.0-b32.dmg, signed ad hoc
gh release create v0.1.0-preview.1 build/Avo-0.1.0-b32.dmg --prerelease \
    --title "Avo 0.1.0 Preview 1" --notes-file notes.md
```

`build-dmg.sh` signs ad hoc by default, re-signing each framework, the
daemon, `avoctl`, avo-vmm, the Bluetooth controller and the app with their
own entitlements and `com.avodroid` identifiers.

### Developer ID and notarization

A notarized build opens like any app: no Open Anyway in System Settings.

```sh
scripts/build-dmg.sh --version 0.3.0 --build 81 \
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
  next to the disk image. Every build, preview or not, raises
`CURRENT_PROJECT_VERSION`; the changelog ([CHANGELOG.md](../CHANGELOG.md))
gets an entry per release.

## Every release

1. **Raise the build number.** Sparkle compares `CFBundleVersion`, and
   installs only a higher one. Avo's targets all take it from
   `CURRENT_PROJECT_VERSION` (`host/Config/Base.xcconfig`), so either raise it
   there or pass it to xcodebuild:

   ```sh
   xcodebuild … CURRENT_PROJECT_VERSION=22 MARKETING_VERSION=0.1.1
   ```

   The daemon and the App Shims use the same number to notice the new build
   (below).
2. **Build and sign the app,** then make the DMG (or a zip:
   `ditto -c -k --sequesterRsrc --keepParent Avo.app Avo-0.1.1.zip`). The
   archive must hold `Avo.app` at its top level: Sparkle finds the app by
   that name. `codesign --verify --deep --strict` must pass, because Sparkle
   checks the new bundle's own signature, ad hoc included. See *Signing
   Sparkle* below.
3. **Sign and publish:**

   ```sh
   scripts/release-update.sh ~/Desktop/Avo-0.1.1-b22.dmg --notes notes-0.1.1.md \
       --download-url-prefix https://…/downloads/
   ```

   The script checks the archive's `Avo.app` first:

   - the feed is not the placeholder;
   - its `SUPublicEDKey` is the Keychain's key;
   - its signature is valid;
   - its build is newer than every build in the feed.

   Then it signs the archive with `sign_update`, and runs `generate_appcast`
   in `build/updates/` (git-ignored). That writes or updates `appcast.xml`
   and adds delta updates from the older archives kept there.
4. **Upload** the folder's contents (`appcast.xml`, the archive, its notes,
   any `*.delta`) to where `SUFeedURL` and the download prefix point. Keep
   the folder: the next release's deltas are made from it.

## How Sparkle trusts an update

Sparkle's rule (`SUUpdateValidator.m` in Sparkle 2.10.0): it accepts an
update when the old and new EdDSA keys are the same and the archive's
signature is valid, or when the old and new code signing identities match
and are valid.

An ad hoc signature's designated requirement is the build's own code
directory hash, so two ad hoc builds never match each other. **For ad hoc
builds, the EdDSA signature is the only thing that lets an update through.**
Sparkle still checks that the new bundle's signature is valid by itself.

| Update | Same EdDSA key, valid signature | No EdDSA signature |
|---|---|---|
| ad hoc → ad hoc (today) | **Accepted** | Rejected |
| ad hoc → Developer ID (the first notarized build) | **Accepted**: the signing identity may change while the key stays | Rejected |
| Developer ID → Developer ID, same team | Accepted | Accepted (code signing alone) |
| Developer ID → another team | Accepted | Rejected |
| any → unsigned, or a build without `SUPublicEDKey` | Rejected | Rejected |

Rules for the move to Developer ID and after:

- **Keep the EdDSA key forever.** The first Developer ID build must still
  carry the same `SUPublicEDKey`, and be signed with it.
- **Never change the key and the signing identity in the same release.**
  Sparkle rotates only one of them at a time, and only for Developer ID apps:
  the old app's team must match to accept a new key. An ad hoc Avo can never
  rotate its key.
- **Leave `SUVerifyUpdateBeforeExtraction` unset while builds are ad hoc.**
  Its fallback needs a Developer ID–signed DMG from the old app's team.
- **Notarize Developer ID builds as usual.** Sparkle removes the quarantine
  attribute from what it installs, so an update needs no Gatekeeper approval.
  The first download of an ad hoc Avo still does: System Settings › Privacy &
  Security › Open Anyway.
- **TCC needs a stable identity.** Each ad hoc build is a new app to TCC, so
  macOS asks again for the microphone and location after an update. A
  Developer ID signature gives Avo one identity, and the prompts stop.
- **The daemon stays a LaunchAgent of Avo's own** with a Developer ID too
  (`DaemonAgent`): Login Items would pin it to the code they saw at
  registration, and could not wait for Android to stop after an update.

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

1. Build release N, with the real feed or a staging feed (see *The feed*),
   and install it in `/Applications`.
2. Build release N+1 with a higher `CURRENT_PROJECT_VERSION`, run
   `scripts/release-update.sh` on its archive, and upload.
3. In N: Avo › Check for Updates…. Install with Android stopped, then again
   with an app open, and check that:
   - Avo asks before it stops Android;
   - the daemon restarts on N+1 (its hello in Report a Problem shows the
     new build);
   - the app's shim is made again.
