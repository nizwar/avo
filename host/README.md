# macOS host

```
Avo/            Control Panel (SwiftUI) — Avo.app
AvoDaemon/      Runtime Daemon + menu bar item — Avo.app/Contents/Library/Helpers/AvoDaemon.app
AvoWindowHost/  Window Host framework, loaded by every App Shim
AvoShim/        App Shim template (a tiny loader)
avoctl/         Command-line control of the daemon — Avo.app/Contents/MacOS/avoctl
AvoKit/         Swift package with all platform-independent logic and its tests
Config/         Shared build settings (Base.xcconfig; optional Local.xcconfig)
project.yml     XcodeGen spec for Avo.xcodeproj
```

All Xcode targets link one dynamic framework, `AvoHostKit` (every module of
the AvoKit package), embedded once in `Avo.app/Contents/Frameworks`.

## Build and test

```sh
xcodegen generate                        # after changing project.yml
xcodebuild -project Avo.xcodeproj -scheme Avo build
cd AvoKit && swift test                  # core tests, no Xcode project needed
```

To sign with your team, create `Config/Local.xcconfig` (ignored by git):

```
AVO_TEAM_ID = ABCDE12345
CODE_SIGN_IDENTITY = Apple Development   // or Developer ID Application for releases
```

A daemon signed with a team switches to team-based caller validation
automatically.

## Running during development

A normal launch of Avo.app registers the daemon as a LaunchAgent with
`SMAppService`, which adds a Login Item for that build. To try a build without
registering it, run the daemon with `launchctl` and tell the Control Panel to
skip registration:

```sh
APP=/path/to/DerivedData/Build/Products/Debug/Avo.app
cat > /tmp/com.avodroid.daemon.dev.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.avodroid.daemon.dev</string>
  <key>Program</key><string>$APP/Contents/Library/Helpers/AvoDaemon.app/Contents/MacOS/AvoDaemon</string>
  <key>MachServices</key><dict><key>com.avodroid.daemon</key><true/></dict>
  <key>RunAtLoad</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
EOF
launchctl bootstrap gui/$(id -u) /tmp/com.avodroid.daemon.dev.plist
open "$APP" --args -AvoSkipDaemonRegistration YES
"$APP/Contents/MacOS/avoctl" status

# afterwards
launchctl bootout gui/$(id -u)/com.avodroid.daemon.dev
```

Keep `ProcessType Interactive` as in the real agent (Avo/LaunchAgents): a
plain launchd job runs at utility QoS, and the engine it starts inherits the
clamp, so its timers drift by tens of milliseconds (audio breaks up). Builds
signed ad hoc get new code identities, so macOS asks for location and
microphone access again after each rebuild.

Development builds are signed to run locally, so the daemon accepts callers
signed inside the same Avo.app (the Control Panel, `avoctl`) and App Shims it
created itself; anything else is rejected.

Things to know:

- The daemon reads package files only through descriptors passed by the
  caller, so installing from Downloads or Documents needs no extra permission.
- Building with Xcode registers the built Avo.app with LaunchServices, which
  makes it the handler for `.apk` files. Remove a stale build's registration
  with `lsregister -u <path to Avo.app>`.
- macOS shows Android notifications only while LaunchServices knows a copy
  of Avo outside temporary folders (`/tmp`, `/var/folders`): it leaves apps
  there out, and Notification Center then refuses the daemon without asking
  ("Notifications are not allowed for this application"). A copy in
  /Applications, or a build in Xcode's default DerivedData, is enough. The
  Notifications pane and Settings › System have Request Permission.

## Android to test with

Avo.app ships no Android. On a first launch (or with no usable image) the
Control Panel opens the Setup Assistant (Help › Setup Assistant…), which
lists the AOSP Cuttlefish builds Google's public Android Build API has
(`aosp_cf_arm64_only_phone-userdebug`, the newest build of each Android
version from Android 16 on), downloads one with pause, resume and an MD5
check, or imports an image zip or folder, and then starts Android.
Settings › System › Android version changes it later. Images Avo installs
live in `~/Library/Application Support/Avo/images/android-<version>-<build>/`
with a `manifest.json` the daemon checks before every start; see
docs/architecture.md, "Android images (Cuttlefish)".

`scripts/fetch-cuttlefish.sh` still works: its downloads in
`~/Library/Caches/Avo/cuttlefish/<build>/img` are used where they are; the
daemon boots the chosen image with `avo-vmm` (see docs/engine.md).
`defaults write com.avodroid.daemon AvoCuttlefishImages <img folder>` overrides
the choice. The catalog's source is `AndroidBuildSource` (AvoPackages);
`defaults write com.avodroid.emulator` with `AvoBuildAPIEndpoint`, `AvoBuildAPIKey`,
`AvoBuildBranches` (comma-separated), `AvoBuildTarget` or
`AvoBuildMinimumSDK` changes it, and `-AvoSkipSetupAssistant YES` keeps the
assistant from opening by itself. `AVO_LIVE_BUILD_API=1 swift test --filter
AndroidImageLiveTests` checks the listing and a small download against the
real API (`AVO_IMPORT_IMAGE=<zip or folder>` also imports an image into a
scratch folder).

`guest/samples/hello` builds *Avo Hello*, a small app
for trying windows, input, resizing, key mapping (its Arena game and
`keymap/dev.avo.hello.json`), GPS and notifications.

GPU rendering (Graphics › Renderer) needs the Android Emulator 37 or later:
install it with Android Studio's SDK Manager (SDK Tools › Android Emulator)
into `~/Library/Android/sdk/emulator`, or point the daemon at another copy
with `defaults write com.avodroid.daemon AvoAndroidEmulator <dir>`. Without it
Android renders in software. `avoctl retry-gpu` forgets a failed GPU start;
`~/Library/Logs/Avo/avo-vmm-gpu-failed.log` keeps that start's log.
Compiled shaders are kept in `~/Library/Caches/Avo/gpu-cache`; `avoctl gpu-cache`
shows its size and `avoctl gpu-cache clear` empties it (docs/engine.md, "Shader cache").

`avoctl` drives the daemon from Terminal: `status`, `start`, `stop`,
`install <file>`, `apps`, `shortcuts [package]` (recreate shims and icons),
`config key=value` (for example `adbEnabled=true`, then `adb connect
127.0.0.1:5555`) and `fingerprints` (`add <name>`, `rename <id> <name>`,
`remove <id>`, `touch <id>|unregistered`).

## Localization

The UI is written in English and translated into Indonesian with String
Catalogs:

```
Avo/Localizable.xcstrings          Control Panel
Avo/InfoPlist.xcstrings            document type names, microphone prompt
AvoDaemon/Localizable.xcstrings    menu bar item
AvoDaemon/InfoPlist.xcstrings      location and microphone prompts
AvoWindowHost/Localizable.xcstrings  app windows, menus, key mapping editor
AvoShim/Localizable.xcstrings      shim alerts
AvoShim/InfoPlist.xcstrings        camera, microphone and location prompts
AvoKit/Sources/AvoKit/Resources/Localizable.xcstrings
                                   errors and messages from the AvoKit package
```

Code in the AvoKit package uses `String(localized: "…", bundle: .avoKit)`;
the Window Host uses `bundle: .windowHost`. Xcode adds new strings to the
catalogs when you build in the IDE; from the command line run
`make build strings`. The Indonesian text follows the terms in
`docs/spec.md` (tabs Performa, Storage, Grafis, Display, Aplikasi, Sistem;
the “Game berat” preset).

Try a language without changing the system language:

```sh
open "$APP" --args -AvoSkipDaemonRegistration YES -AppleLanguages '(id)'
```

Frameworks and resource bundles follow the language of the main bundle, so
every executable bundle (Avo, AvoDaemon, AvoShim) lists its languages in
`CFBundleLocalizations`. Add a new language there as well as in the catalogs.
