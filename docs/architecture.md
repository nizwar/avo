# Architecture notes

How the [specification](spec.md) is implemented, and the decisions the spec
left open. Protocol details are in [protocol.md](protocol.md), the VM engine in
[engine.md](engine.md).

## Processes on the Mac

| Process | Bundle | Role |
| --- | --- | --- |
| `Avo` | `Avo.app` (`com.avodroid.emulator`) | Control Panel. Registers the daemon with `SMAppService`, handles `.apk/.xapk/.apkm/.apks` opens and drops. |
| `AvoDaemon` | `Avo.app/Contents/Library/Helpers/AvoDaemon.app` (`com.avodroid.daemon`) | Runtime Daemon (LaunchAgent, Mach service `com.avodroid.daemon`). Also hosts the menu bar item and posts notifications. |
| `avo-vmm` | `Avo.app/Contents/MacOS/avo-vmm` | Engine VM, a child of the daemon (see engine.md). |
| `<App>` | `~/Applications/Android Apps/<Label>.app` | App Shim, one per Android app; loads `AvoWindowHost.framework` from Avo.app. |
| `avoctl` | `Avo.app/Contents/MacOS/avoctl` | Command line for scripts and CI. |

The daemon is an accessory app rather than a bare executable for two reasons:
notifications must be posted by a bundle with an identity (the user sees
"Avo"), and clicks on them are delivered to the posting process, which must be
running — the daemon always is. The spec lists the Menu Bar Item as its own
component; it lives in the same process because its state is the daemon's
state and it should stay visible while Android runs in the background.

All Swift code shared between targets is one dynamic framework,
`AvoHostKit.framework` (every module of the `AvoKit` package). Linking the
package products separately produced two copies of the same classes in one
process, which breaks NSXPC class checks.

What Avo shares with Avo Hub is a package of its own,
[avo_kit](https://github.com/nizwar/avo_kit), a submodule at
`vendor/avo_kit` in both projects: `AvoKeymap` (profiles and the engine),
`AvoKeymapUI` (the key mapping a window runs: its controller, the editor and
its panels, the hints over the game and `GamepadHub`), `AvoHazeUI` (the haze
in small: `QuickHaze`, the `Quick*` controls of an app window's panels,
`HazeMenu`, and `HazeAppearance`, the System / Light / Dark choice), `AvoInput` (the Input channel's records) and `AvoScreen` (screen
samples and motion). The AvoKit package depends on it by path; its
`AvoShared` module re-exports the UI modules, and `AvoProtocol` and `AvoKit`
re-export `AvoInput` and `AvoScreen`, so they are linked into
`AvoHostKit.framework` once and Avo's code imports them as before. A window
gives the key mapping its game view (`KeymapDisplay`) and where to keep
profiles and Game Mode (`KeymapStore`; `KeymapStore.avo` is Avo's), in
KeymapHost.swift. The kit's text is in its own catalog
(`Bundle.avoSharedKit`, `avo_kit_AvoKitResources.bundle` in Avo.app); a
change there is committed in avo_kit, then the submodule moves to it.

## XPC and caller validation

The daemon vends one Mach service. Each connection declares a role in
`hello` (`controlPanel`, `shim(package)`, `engine`) and every later call is
checked against it: shims may only open, drive and close displays for their
own package; only the Control Panel (and `avoctl`) may change settings or
install. Identity checks (spec: "validasi code signature pemanggil"):

- **Release builds** (signed with a Developer ID team): the listener's code
  signing requirement admits Avo's team plus the code directory hash of every
  shim the daemon created. A shim's connection is then pinned to its own hash.
- **Development builds** (ad hoc): the caller must be signed and live inside
  the Avo.app bundle the daemon runs from; shims are still pinned by hash.

App Shims are re-signed ad hoc after their Info.plist and icon are written
(editing a signed bundle breaks its signature). Their hashes are kept in the
app registry. A shim that is not in the registry is rejected — verified with a
hand-made shim against the running daemon.

## Files chosen by the user

The daemon is a separate process, so it does not inherit the access macOS
gives the Control Panel (or a shim) to a file the user double-clicked, dropped
or picked from Downloads/Documents; reading the path itself triggers a privacy
prompt for the daemon. Clients therefore open the file and pass the
descriptor over XPC (`install(_:file:)`, `shareFiles(_:files:names:)`); the
daemon reads the package through that descriptor.

## Installing a package (spec §3)

1. The Control Panel inspects the file locally (`PackageArchive`) and shows
   name, version, size, notable permissions and blocking problems: native code
   without `arm64-v8a` (Apple Silicon cannot run 32-bit ARM or x86) or a
   `minSdkVersion` above the image's.
2. On confirmation it sends the open file to the daemon, which re-inspects it,
   starts Android if needed, and streams the selected APKs through
   `pm install-create / install-write / install-commit` over ADB. ABI splits for
   other ABIs are skipped. Streams use `ChunkPipe`, a bounded queue between the
   ZIP inflater and the ADB writer, so a multi-gigabyte XAPK never sits in
   memory.
3. XAPK OBB files go to `/sdcard/Android/obb/<package>/` with ADB sync.
4. Android's `PACKAGE_ADDED` reaches the daemon as `AppInstalled`; that event
   (not the installer) creates the shim, so apps installed from inside Android
   get shims too.

Formats are detected from content, not the extension: `AndroidManifest.xml` at
the root (APK), `manifest.json` (XAPK), `info.json` (APKM), or APKs (APKS; for
bundletool sets only `splits/` is used). Labels and icons are resolved from
`resources.arsc`, including sparse and compact (Android 14+) tables; icons in
split bundles are looked up across density splits.

## App Shims and icons (spec §4)

- `ShimBuilder` copies the template bundle, writes `CFBundleIdentifier`
  (`com.avodroid.shim.<package>`, `_` → `-`), the label, version and
  `AvoAndroidPackage`, swaps the bundle into place atomically
  (`renamex_np(RENAME_SWAP)`), signs it ad hoc and registers it with
  LaunchServices. Same label for two apps: the second becomes
  `Label (package).app`. A label change renames the bundle.
- Icons: the Bridge Agent renders adaptive icon layers at 432 px (108 dp);
  `MacIconRenderer` maps the 72 dp safe zone onto Apple's 824 pt
  continuous-corner squircle on a 1024 canvas with the standard shadow, and
  writes every `.icns` size with ImageIO. Opaque square legacy icons are
  masked to the squircle; others sit on a white plate.
- Desktop alias (on by default) and Dock tile (off by default) follow the
  Control Panel options and are removed on uninstall. Aliases never replace a
  real file.
- Dock badges (Settings › System › Notifications, on by default): the daemon
  keeps the notifications Android shows (`activeNotifications`, the same ones
  the Notifications list takes: no ongoing, foreground-service or group
  summary ones, none without text) and sends each app's App Shims
  `notificationCount` when it changes and when they connect. The shim sets
  `NSApp.dockTile.badgeLabel`. A shim runs only while the app has a window,
  so an app that is not open shows no badge.
- Notification buttons: an Android notification's actions come with it
  (`Notification.actions`, NotificationAction) and become a Notification
  Center category per set of buttons (`UserNotificationPresenter`, at most 64
  kept): a button that takes text (a free-form RemoteInput, Reply) is a text
  field with Send, the others plain buttons. Pressing one sends
  `PerformNotificationAction`; Android fires the button's PendingIntent as
  its shade does, with the text as the RemoteInput's result
  (SOURCE_FREE_FORM_INPUT). The app's update of an answered notification comes
  back quietly, as in Android.
- Now Playing: what Android plays (the first playing media session, or else
  the most recent one with a title) is in Control Center and on the media
  keys and AirPods (`MacNowPlaying`, MPNowPlayingInfoCenter and
  MPRemoteCommandCenter, in the daemon): title, artist, album, artwork,
  duration and position, and play, pause, next, previous and scrubbing when
  the app allows them. The commands go to that session itself
  (`MediaCommand`), not to whichever Android's own media keys would pick.
  Avo takes the commands only while something plays in Android, so with
  nothing playing the media keys stay with the Mac's apps.

## Windows (spec §2, "Native")

Each shim window asks the daemon for a display sized from the window's
content and the app's graphics settings (see "Resolution and scaling"
below); at the default interface size 1 dp equals 1 pt, so Android apps
look the same size as Mac UI. Resizes are debounced to the end of a live
resize. Minimising or fully covering a window tells the guest to
detach the display's surface (the app keeps running, but stops rendering),
except while the window is being recorded, so the movie does not freeze.
Window frames are remembered per app. When the Android task finishes, the
window closes. Closing an app's last window (Close, ⌘W, Quit, or the shim
going away) ends the app like a force stop: the shim quits, and the daemon
force-stops the package before its display is unplugged
(`DaemonCore.closeDisplay`). Unplugged first, the app's task would move to
Android's own screen, where the task watch (`checkDefaultDisplay`) takes a
known app's visible task for a new start and opens its window again.
`flutter run` and Android Studio force-stop the app, install it and start it
again over adb, usually before the watch closed the window the stop left
empty: that window takes the new task (`moveIntoEndedWindow`), since its
shim would otherwise quit with it right after being asked for a new one. An
app adb starts right after installing it gets its window once the package
poll has found it.

Frames: the engine renders each display into a small swapchain of IOSurfaces,
hands them to the daemon once (`engineSetSurfaces`) and then only announces
which surface to show (`enginePresent`). The daemon forwards both to the shim
that owns the display; the shim wraps the IOSurfaces as Metal textures and
scales them into a `CAMetalLayer` (see "Resolution and scaling"). No frame
is copied or encoded on the CPU, except for screenshots and recordings.
avo-vmm, for now, writes frames to shared memory instead (triple buffered;
with the GPU renderer the GPU copies them there from gfxstream, on a thread
of the engine's own), and the daemon's
`FrameBridge` copies them into those IOSurfaces. A copy the engine wrote over
meanwhile is dropped, and a daemon that falls behind skips presents, never a
swapchain. A window nobody sees (minimized, covered, on another Space, and
not recorded: the shim's `setDisplayVisible`) gets no copies after its first
frame, which at 1080×2400 and 120 Hz saves over 1 GB/s; shown again, it gets
the newest frame at once.

Frames are presented as they arrive, at whatever rate Android draws, up to
120 Hz (engine.md, "Refresh rate"). While Android draws above 60 Hz, the
window's display view runs a `CADisplayLink` (`FrameRateHint`) whose
preferred frame rate range is Android's rate, at most its screen's
(`FrameRates.presentPacing`), so a ProMotion or adaptive screen does not
settle at 60 Hz. When Android draws faster than the screen refreshes (120
on a 75 Hz monitor), the link's ticks draw the newest frame once a refresh
instead (`MetalRenderer.refreshed`): frames replace each other rather than
queueing up behind the screen with their latency, and nothing draws faster
than the screen shows. The link pauses for hidden windows and static
screens.

Screenshots and screen recordings come from File › Take Screenshot (⌘⇧S)
and File › Record Screen (⌘⇧R; again to stop), or the title bar's Device
menu. Both take only what Android draws, at the
display's full pixel size: no title bar, key mapping hints or recording
indicator.

- A screenshot copies the frame on screen into a PNG in `~/Pictures/Avo`.
- A recording has the GPU draw each frame a second time, into the recorder's
  own pixel buffers, and writes H.264 to a `.mov` in `~/Movies/Avo`. Each
  frame keeps the time it was presented, so the frame rate varies with what
  Android draws; pictures larger than 4096 × 2304 are scaled down. The movie
  is written in 2 s fragments, so a file that is cut off (a crash, a full
  disk) still plays up to its last fragment. The movie keeps its size
  when Android's display is re-plugged at another size of the same
  orientation (a resize, a graphics setting), fitted with black bars; it
  stops on a rotation and when the window closes. A red
  dot and timer in the title bar show it is running; in full screen, where
  the title bar hides, a small badge at the top right does.
- Android's sound goes into the same movie as AAC (48 kHz stereo,
  160 kbit/s) while Record Android's Sound is on (the Device and File
  menus; on by default, for every app, in the Window Host's defaults). The
  engine copies every period the Mac has played into a ring in shared memory
  (`audio/playback.ring` in the instance, `virtio/sound/tap.rs`) with the host
  time it played at; its sticky `audio playback <epoch> <path>` event goes
  through `FrameBridge` to the daemon, which tells every App Shim
  (`DaemonEvent.audioTap`, also when one connects). The recording window maps
  the ring read-only (`AudioTapReader`) and reads it every 40 ms
  (`RecordingAudio`): `AudioTimeline` puts each block at its host time on the
  frames' clock, right after the one before it when they follow each other
  within 30 ms, and pads silence up to 0.25 s before now, so a movie of a
  silent app has a silent track and the writer never waits for sound. A stop
  waits that long for the last of it. It is all of Android's sound, not only
  this app's (Android mixes its apps into one output). An engine without the
  ring gives a video-only movie. With a sound track the newest frame is
  written again after a second without a new one, and the session ends
  before the tracks close, so the picture lasts as long as the sound.
- A notice says where the file went, with Show in Finder; while the key
  mapping is in charge of clicks (Game Mode) the notice has no button, so it
  never takes a click meant for the game.
- Files go to Pictures and Movies, not the Desktop: a shim that writes to
  Desktop, Documents or Downloads gets a privacy prompt for every app.
  ⌘⇧S and ⌘⇧R stay with the window; ⌘S still reaches the app as Ctrl+S.

Each shim has one View menu: Translate Screen (⌘⇧T) and Translate Into
first, then the graphics items for this app (profile, follow
window resolution, render scale or resolution, aspect ratio, scaling
filter, performance HUD, Use Default Graphics Settings, full screen), then
Keep on Top and Picture in Picture.
`GraphicsMenu` is that menu's delegate; a menu edit saves a sparse
per-app override through `setAppGraphics`. Translate Screen reads the frame
on screen and translates it on the Mac, and draws plates over the text in a
view above `DisplayView`: clicks pass through, and nothing is drawn into
frames, so screenshots and recordings stay clean. It follows the screen: ten
times a second it compares the frame on screen with the one the plates were
read from (`ScreenWatch`, a 16-pixel grid of gray cells), drops at once
every plate over something that changed, and reads the screen again once it
holds still; text and screens read before are not read or translated again.
Through a scroll the plates move with their text instead (`ScreenFollow`):
each look measures how far a strip of the frame (rows of about 4 pixels)
slid since the last one, the way the mouse wheel's scroll watch does, and a
plate shows at its new place only where the strip there shows what was
under it.

The reading and the translating are one engine's for every app, the
daemon's (`ScreenTextEngine`). The shim sends the frame it shows
(`readScreenText`, its pixels beside the request) and gets the text back in
blocks with their colors and languages (Vision, `ScreenTextLayout`), then
sends the text without a translation yet (`translateTexts`, Apple's
Translation framework, which macOS 26 runs without a window for languages
on the Mac). macOS translates about five texts a second however they are
sent, so the engine keeps every app's translations while the daemon runs (in
memory only: they are the screen's text), and a window asks for the known
ones of a new screen at once (`knownTranslations`) before anything new is
translated. Vision builds its text models for each program that reads text
(about 25 s, again after a macOS update; an update of Avo keeps them) and
loads them in a moment at that program's next start; a model another program
built is built again over it, so App Shims, each a program of its own, could
not share them. The daemon builds and loads them once: at its start (Settings
› General › Translate Screen, `translationAtStartup`, on by default) or when
Translate Screen first turns on in any app (`wakeScreenText`, which also
loads the language pair translated last: macOS lets go of a pair's model a
minute after its last use). A pair macOS must download first, and every pair
on macOS 15, is translated in the window instead, by a SwiftUI translation
session, which can show the system's download sheet.

Keep on Top floats every window of the app over other apps' windows
(`window.level = .floating`; not in full screen), remembered per app in the
shim's defaults (`WindowModeSettings`). Picture in Picture moves the window's
content into a small borderless panel (`PictureInPictureWindow`) that floats
over every window, on every Space and over full-screen apps, and orders the
window out. Android's display keeps its size and the picture is scaled down
in the panel's shape, so the app does not lay out again; clicks, typing and
the gamepad still reach it, and the panel does not activate the app when
clicked. Its size starts at about 6% of the screen and stays within limits
(`PictureInPicture` in AvoKit); it sits in a corner and snaps to the nearest
one after a drag; corner and size are remembered per app. A capsule at the
top, shown while the pointer is over the panel, moves it and has Back to
Window and Close (a double-click goes back too); the Dock icon, the menu item
and Android's screen lock bring the window back. Whether Android sees the
display follows the panel then, not the hidden window. Chosen in full screen,
it opens once full screen has ended. Its ✕ quits the app, as the red light
does, and says so ("Quit PUBG MOBILE").

Closing a game's window ends the game in Android, and one wrong click must
not end a match: the red light, Close Window (⌘W) and Picture in Picture's ✕
ask first (`windowShouldClose`, `askToQuit`) while Android runs a game (the
Games preset or a key mapping): Quit, Run in Background or Cancel, with
Don't Ask Again. That is every app's setting (`QuitSettings` in the Window
Host's defaults), also Settings › Graphics › App windows › Ask before
quitting a game. Quitting the app (⌘Q) and closes Android asks for never ask.

The window's own three lights have a fourth after them, blue: Run in
Background (`BackgroundLightButton`, also Window › Run in Background). It is
the system's own red light turned blue: a new close widget
(`NSWindow.standardWindowButton(_:for:)`) draws each look for a moment
inside the button, as it is and pressed, whenever the window comes to the
front or goes to the back or the appearance changes, and the button shows
that picture with every coloured pixel's hue made macOS's blue. So it has
the lights' fill, shine, pressed look and back-window gray, in their row
(the title bar's sides are as tall as the title bar, their buttons on the
lights' middle) and 23 points after the green one, as they are apart. A
fresh widget each time: one that has drawn a look may still draw it a
moment after it changed. Its glyph shows while the pointer is over the
row. Full screen ends first, or its Space would stay behind, black and
empty. Every window of the app goes and the shim turns into an accessory app,
so its Dock icon and menu bar go too, while the app runs on in Android: its
displays stay open (unseen, so Android draws nothing for them and neither
stops nor pauses) and say they are in the background
(`setDisplayInBackground`), so the menu bar and the Library say In the
Background, not Minimized. Opening the app again (the Library, the menu bar item, a
notification, a tile kept in the Dock; `applicationShouldHandleReopen`,
`applicationDidBecomeActive`) brings the windows back as they were. The red
light still quits the app, and Android force-stops it. Back (Android's) comes
after the blue light, then the app's name (`TitlebarTitle`): AppKit's own
title is hidden, because it stays centred between the title bar's sides and
was cut to "F…" while there was room by Back. The name takes the title's
font and colour (which dims by itself in a window in the back), and what
Android calls the screen it shows follows when it says more than the name.

On the other side the title bar has menus of the menu bar's actions: the game
controller's (Game Mode, key mapping, hints, scrolling), Translate Screen's,
and the Device menu for the phone itself: Shake (⌃⌘Z, also in Game Controls: the
engine's `shake` swings Android's accelerometer for a second; the window
gives a little shake too, unless Reduce Motion is on), Rotate, Location…,
Fingerprint, the screenshot and recording items, Keep on Top, Picture in
Picture (not while the key mapping editor is open) and Phone Style. The
fingerprint also has a button of its own at the front, shown only while
this app, the lock screen or Settings asks for a finger; the trailing side
keeps room for it. A recording's red dot and time come first. The trailing
side is as wide as its buttons, and the leading side, with the name, takes
the rest (`fitTitlebar`, again on every resize).

That is the Standard app bar style (`AppBarStyle`). Settings › Graphics ›
App windows › App bar style (`VMConfig.appBarStyle`, applied at once) sets
it for every app, and an app may have its own (`WindowModeSettings.appBarStyle`
in its App Shim's defaults), as a location may be every app's or one app's.
It is one click away, never in a submenu: Phone Style, checked, in the
Device menu and the View menu, and an App bar style card in Quick Settings.
An app's own style is kept only while it differs from the Control Panel's,
so choosing the Control Panel's one follows the Control Panel again. The
other style:

- **Phone** (from TheGemDev's pull request #6, `WindowChrome.swift`): the
  window shows the app's screen alone with a phone's rounded corners, and
  the Standard title bar grows out above it as the pointer leaves the
  screen through its top, as in iPhone Mirroring; moving back into the app
  or away shrinks it after half a second, and it stays while Quick Settings
  or one of its menus is open. The window keeps its size throughout, so the
  frame never re-plugs Android's display: every size comes from the screen
  in the window (`screenSize`, the chrome's `screenInsets`), and a locked
  shape is kept by `windowWillResize`, AppKit's aspect lock being the
  frame's. Full screen and Picture in Picture have their own looks, and the
  recording badge shows over the game while the title bar is away.

All Settings for the app (at the bottom of Quick Settings) opens its page
in the Library through `avo-control-panel://app/<package>`.

The title bar's last button opens Quick Settings (`QuickSettings.swift`), a
transient popover in the Library's haze look with only the settings whose
effect shows at once: this app's graphics (preset, screen size with its
resolution or render scale and aspect ratio, orientation, sharp upscaling
(MetalFX) with sharpness, smooth edges), Android's frame rate cap as Max FPS
(for every app), the performance HUD, Game Mode and the key hints when the
app has a key mapping, the scroll mode, and Translate Screen with Translate
Into. Each card puts a line between its settings (`QuickRows`; the ones that
belong together, like a toggle and its slider, stay in one), and what a
setting does is behind its (?), not under it. Graphics save through `setAppGraphics`, which a shim may call only for
the package it said hello as; the frame rate cap saves through
`setFrameRateLimit`, which changes nothing else (a cap that needs another
display rate says Android runs at it after a restart). Everything that
needs a restart stays in the Control Panel.

Input from a window, in order of precedence:

1. The keymap engine, when the app has a profile, Game Mode is on (⌘G) and
   the input is bound. In Game Mode a left click that no control takes also
   goes through the engine, as one more finger in its touch set, so clicking
   a game button does not break the touches that keys or the right button
   hold.
2. Defaults: a click is a touch; trackpad scrolling becomes a one-finger drag
   (momentum events are dropped so Android flings natively); the mouse wheel
   goes by the scroll mode (below); pinch becomes two fingers around the
   cursor; Esc and a two-finger swipe left are Back; Cmd+C/V/X/A/Z map to
   Android's Ctrl shortcuts; editing keys (Return, Delete, arrows, …) are key
   events and everything printable goes through the macOS input method and
   arrives as committed text, so every keyboard layout and IME types correctly.

The guest focuses each display separately (`config_perDisplayFocusEnabled`),
so typing goes to the app in the window you are typing in. With the GPU
engine Android focuses one display at a time; the window that becomes the
Mac's key window takes it (`FocusDisplay`), so its app has the focus a
phone's one app has (games pause their sound without it).

### Mouse wheel scrolling

Many Android views ignore `ACTION_SCROLL` (ViewPager, many Compose, Flutter,
React Native and custom views, games), while touch drags alone would lose the
wheel's precision where views support it. Game Controls › Scrolling (also in the
title bar's game controller menu) picks the scroll mode for the app, and the
default for every app: the app's choice is kept in its App Shim's defaults
(`AvoScrollMode`), the default in the Window Host's defaults
(`AvoScrollModeDefault`, which every shim reads); choosing the default's mode
for an app follows the default again (`ScrollModeSettings`).

- **Automatic** (default): a burst of notches (closer than 0.35 s) goes out
  as `AXIS_VSCROLL`/`AXIS_HSCROLL` while the window watches a band of the
  frame around the pointer (`ScrollRegion`, read in place from the frame's
  IOSurface on the render queue and scaled to gray cells; compared off the
  main thread). If the content slides that way within 0.22 s
  (`ScreenSample.motion`: only changed cells count, matched both ways so
  content that vanished is no slide), the app scrolls with the wheel.
  Otherwise the same lines are replayed as a swipe, and if the content
  follows that finger the app gets swipes from then on (`WheelRoute`). Scroll
  events are tried again after 30 s (doubling up to 5 min while the app still
  ignores them) or, no sooner than 3 s, when more than half of the screen
  changed since the last swipe left it (another screen). Where neither moved
  anything (the end of a list, a picture) nothing is learned, and that place
  and direction get scroll events only for 8 s.
- **Mouse Wheel**: scroll events only, the trackpad's too (pixels converted
  to lines of Android's 64 dp, the rest carried to the next event, macOS's
  momentum included).
- **Swipe**: swipes only; the trackpad drags a finger as before.

The wheel's finger (`WheelSwipe`) moves one continuous drag per burst from
the pointer: 160 dp per line up and down (about three list items), 66% of
the width per line sideways (past a pager's turning point), plus Android's
8 dp touch slop. It moves at once (no tap or long press), eases to where the
notches take it, rests 90 ms and lifts, so Android sees no velocity and does
not fling; a fast spin (6 lines in 0.2 s) lifts while moving and flings. It
stays inside the display, goes down where the first notch's way fits, and a
burst that goes further rests, lifts and goes down again. The window watches
the content under it (`SwipeWatch`): a finger whose content did not follow
within 0.18 s lifts with `ACTION_CANCEL`, so a swipe over a picture or a big
button never clicks it, and goes no further. Shift turns the wheel sideways.
The finger never overlaps another touch: not while a click, drag, trackpad
gesture or pinch holds the touches, and not while the key mapping is in
charge (Game Mode with a profile, or the mouse locked for aiming): the wheel
then goes to the key mapping first and the rest as scroll events, as before.
A click, a trackpad gesture, a pinch, a display change or focus leaving the
window lifts it with `ACTION_CANCEL`.

Checked on Android 17 (AOSP Cuttlefish) by sending the shim's Input records
to the Bridge Agent's `InputInjector`: RecyclerView and Compose `LazyColumn`
and `HorizontalPager` scroll with scroll events (128 px per notch at 2×; the
pager turns a page), a list that ignores the wheel switches to swipes after
the first burst, and the end of a list and a big button stay unswiped (no
click). ViewPager2 (and other RecyclerView pagers) slides with scroll events
along its axis without snapping to a page, as it does with a mouse on
Android; Swipe mode turns its pages when a burst's drag passes the middle.

## Resolution and scaling

Each app resolves its graphics settings from one of three profiles in
`VMConfig`, Apps (`appGraphics`), Games (`gameGraphics`) and Phone
(`phoneGraphics`: the device profile's screen at its density, only when the
user chooses it for an app, which then opens in its own orientation), plus a
sparse per-app override (`graphicsOverrides`) that holds only the fields the
user changed.
An app is a game when the user chose so, it has a usable key mapping
(`KeymapProfile.usable`), or it says it is one: its manifest's
`android:appCategory="game"` or the older `android:isGame`, which the helper's
`appinfo` reads from Android (`AppInfo.game`, kept as `AppRecord.isGame`; an
APK read on the Mac or a bare listing leaves what Android said). App Shims
learn it from the configuration snapshot's `games`. Such a game keeps the
Games profile's performance settings but opens in the orientation its
activities ask for (`AppInfo.orientation`: the launcher activity's
`screenOrientation`, else the one its activities agree on; kept as
`AppRecord.orientation`, `gameOrientations` in the snapshot), so a portrait
game is not turned; one that lets the screen turn takes the profile's. The shared math is in AvoKit's `DisplaySizing`,
so the window, touches and the renderer always agree.

Android's screen (`GraphicsSettings.mode`, Screen size: Window, Fixed or Phone) is sized one of three ways:

- **Window** (`followWindow`, the Apps default): Android's size is
  the window's pixels × the render scale (50–100 %), widths a multiple of 8.
  Below 100 % MetalFX enlarges the picture back to the window. Its own
  aspect ratio (`followAspectRatio`) is Match window (the window resizes
  freely) or a ratio that locks the window's shape; in full screen Android
  then renders the largest part of the screen in that shape, with bars.
- **Fixed** (`fixed`, the Games default, 720p 16:9): a short side
  of 360–2160 px (presets 540p to 4K) and an aspect ratio (`aspectRatio`).
  With a ratio the window is locked to that shape; with Match window the
  ratio comes from the window.
- **Phone** (`deviceProfile`): the screen of the device profile
  chosen under Privacy & Security (`DeviceProfile.display`), its width ×
  height at its dpi, so apps lay out as on that phone; widths that are not a
  multiple of 8 lose the rest (1220 → 1216). The window is locked to the
  phone's shape, and the interface size does not apply. Avo's own identity
  has no screen: the mode is disabled in the editor, and a saved one follows
  the window (`effectiveMode`). The Window Host keeps the profiles from its
  `ConfigurationSnapshot`, so a new device profile changes open windows in
  this mode at once, like any graphics change (the identity itself still
  waits for a restart).
- **Orientation** (`orientation`, Apps portrait, Games landscape; older
  files take Display's `defaultOrientation` for Apps): the shape of an app's
  first window (`defaultWindowSize`, turned to it) and of a locked shape.
  A locked window opens in it, a free one as it was left; changing it turns
  open windows, and apps that ask for an orientation still turn theirs.
- **Smooth edges** (`antiAliasing`, off by default): Fast is FXAA in the
  renderer, High and Ultra supersampling 2× and 4× (below, under the
  renderer).
- **Interface size** (75–150 %) sets the density in follow and fixed mode,
  so changing the resolution or render scale changes sharpness only, never
  the layout, up to Android's highest density, 640 dpi: fixed resolutions
  above 1600 px reach it and lay out a little larger (540 dp at 4K), still
  short of a tablet's 600. Nothing else caps 4K: the engine takes scanouts
  up to 8192 px per side (a DisplayID EDID extension above 4095) and frame
  buffers of any size (3 × 41.5 MB for 4800 × 2160). With the Software
  renderer the editor says when Android renders more than 3.2 million
  pixels, since the CPU draws each of them.

Android's own screen (display 0), which no window shows, is sized at boot
by the same math (`VMConfig.androidScreen`, the engine's `--display` and
`--density`): with "Emulate this phone's hardware" it is the phone's screen
at its dpi, else what a new app window gets from the Apps profile on the
default window size at the main display's backing scale, upright and
without supersampling. Android sizes resources from it and apps can read it
(`Resources.getSystem()`); it changes at the next start.

Files from before the modes keep their meaning: `followsWindow` is still
read (true is follow, false fixed, `mode` wins when both are there) but no
longer written, and a ratio stored in `aspectRatio` still applies to fixed
mode only.

Changing Android's size gives its display the new size in place when Avo's
composer runs (`GuestComposer`, docs/engine.md): the app keeps its display
and only lays out again. Otherwise it re-plugs the display (HostAgent unplugs
it, plugs it back at the new size and brings the app back). Either way it happens only when
needed: in follow mode at the end of a resize and on a backing-scale change;
with Match window when the window's shape changed by more than 1 %; with a
fixed ratio or the phone's screen only on rotation and setting changes. Never during a live resize
or a full-screen transition, and a hidden window waits until it shows.
Bursts (a window turned back and forth) become one re-plug at a time
toward the newest size (`DisplayResizing`). HostAgent plugs the scanout
back only once Android has let go of the old display: nothing in
SurfaceFlinger's `--display-id` list names its HWC display any more, and
DisplayManager no longer lists it (`waitForDisplayRemoved`). The composer
forgets an unplugged display at once, so its EDID (`port=`) leaves that
list a frame or more before SurfaceFlinger drops the display at its next
commit. A plug in that gap reached SurfaceFlinger before the commit, which
then deleted the new display's HWComposer state, and the next frame crashed
SurfaceFlinger (a null pointer in `HWComposer::executeCommands`) and every
app with it. For the same reason a closed window's scanout goes to a new
window only once Android has let go of it (`releasing`); a window opened
meanwhile takes another scanout.
While Android changes size, the renderer holds a copy of the last frame
(`holdCurrentFrame`) until the first frame of the new size after the
daemon's reply (or at the reply, when that frame came first), at most 4 s,
so the window never flashes black; the held frame then fades out over the
new one in 0.2 s. Shims hear
`configurationChanged`, and an app's own override changes only through
`setAppGraphics`.

The picture is placed by `presentationRect`: 1:1 when the window is at most
a few pixels larger (the edge pixels repeat into the gap), filling the
window when the shapes differ by 2 % or less, aspect-fitted otherwise, over
a backdrop instead of black bars: the frame shrunk to 48 pixels, blurred
there, dimmed and stretched over the window (`avo_backdrop`; recordings keep
black bars). The renderer (`MetalRenderer`) then picks a path with
`scalingPath`:

- **1:1:** a copy shader.
- **Enlarging:** MetalFX Spatial (`MTLFXSpatialScaler`, perceptual mode)
  reads a private copy of the frame and writes the presentation size, at
  most ×4; beyond that a bilinear pass does the rest. Scalers are built per
  input and output size on a background queue (`SpatialUpscalerCache`),
  only for a drawable size that held for 150 ms (one pre-warmed on entering
  full screen, or still cached, is used at once); the current one and one
  previous are kept, and hiding the window or critical memory pressure
  frees them. Bilinear (Smooth) and Nearest (Pixel art) are the other upscaling choices.
- **Shrinking:** an averaging filter of 2–4 × 2–4 samples per pixel.
- **Sharpening:** optional AMD FidelityFX RCAS (MIT) on 1:1 pictures (after
  1:1, bilinear or MetalFX at the full size), off while resizing.
- **Anti-aliasing** (`antiAliasing`): FXAA is a pass on Android's frame at its
  own size, before any of the above (`avo_fxaa`: where the corners' luma
  differs enough to be an edge, a blend along it; flat areas are left as
  they are), so MetalFX gets the smoothed frame it works best with.
  Supersampling 2× and 4× is DisplaySizing's instead: Android's size and
  density × √2 or × 2 (`supersampled`, after the mode's own request; the
  height and density follow the width reached, so the layout stays the
  same), up to the 8192-px display and 1280 dpi, past Android's own 640.
  The renderer then shrinks the frame to the window, and Android lays out
  the same either way. Recordings and screenshots keep Android's frame.

When MetalFX does not apply the picture is drawn bilinearly, and the
performance HUD (⌥⌘P) says why: preparing, resizing, failed (remembered
until the swapchain changes) or low memory. Its "Display scaling" line
shows when macOS itself scales the screen: the panel's native pixel width
(the mode flagged `kDisplayModeNativeFlag`) ÷ (screen points × backing
scale). Temporal upscaling and frame
interpolation need depth and motion vectors, which Android frames lack.
Known quirk: a user key mapping that binds Option sees Option when ⌥⌘P is
pressed in Game Mode (bundled profiles use F8).

## Keymapping (spec §5, §5a)

`KeymapEngine` is a pure state machine: input and timestamps in, complete
multitouch events out (every event carries all active pointers, as
`MotionEvent` requires). Controls: tap, hold, D-pad (keys or left stick),
mouse aim, ADS, swipe, repeated tap, macros, anchor taps, mode switches and
keys that lock or free the mouse, and for MOBAs move by mouse and smart cast.
FPS mode: the first click captures the pointer
(`CGAssociateMouseAndMouseCursorPosition`) and raw,
unaccelerated deltas come from every mouse GameController sees (`GCMouse`;
not only the current one, which is the mouse moved last); for a mouse it
does not see (some wireless receivers) the window's own mouse events stand
in, counted only while no raw motion comes; the camera touch swipes from its
point (the area's centre unless moved) across the whole of its area, then
lifts at the edge, touches down at its point again and carries the rest of
the movement over, so the camera turns without limit (a tall area lets a
look up or down travel further per swipe); an anchor tap's finger stays in
the circle around its point (`radius`, a fraction of the window's height, like
a joystick's), or goes anywhere on the screen without one; ADS switches to its own sensitivity; Option toggles a
cursor layer for inventories and maps; up to 16 simultaneous touches. Profile
validation enforces the spec's hard limits: in FPS mode, repeated taps and
macros are rejected and swipes may not touch the aim area (no automatic rapid
fire or recoil compensation).

**Running.** A D-pad control may have a key held to run (`run`: its
trigger and a `scale` of 1 to 4): while it is held the finger goes that many
times further from the centre, for games that walk with the joystick
partway and run with it all the way, or lock a sprint past its edge. The key
counts among the joystick's triggers, so pressing or letting go of it moves
the finger out or back at once (gliding), a controller button works too, and
resetting the controller mapping takes a button's off.

**Modes.** A profile may have modes (`modes`: an id, a name, and
`mouse_look`, what the mouse does on entering: locked to the eye, free, or as
it was), for the different sets of buttons a game shows: on foot and in a
vehicle, an inventory. A control acts in every mode unless it names the ones
it acts in (`modes`), and only the controls of the current mode answer their
keys, show as hints and touch the screen. The engine starts in the first mode
and stays in its mode through a reset (Game Mode off and on). A control's
switch action (`{"switch_mode": id}`, below) enters its mode when its key
or controller button goes down; on entering, the fingers of controls that do
not act there lift (taps and holds still lift with their keys), and a
joystick of the new mode takes keys that are already held, so W held while
getting in drives on.

**Actions.** Every control but a joystick and the eye may list `actions`,
done in their order after its own touch: `{"switch_mode": id}`, and
`{"mouse": "lock" | "free" | "toggle"}` (with the eye: lock the mouse to it,
free it, or the other of the two), so F presses the game's Enter button
and switches to the vehicle, and Tab opens the inventory and frees the
mouse. A `hotkey` touches nothing and only does its actions (it needs at
least one), and a `click_area` (`area`, a rectangle like the eye's) does
them when it is clicked while the mouse is free, the click still touching
the game there unless `pass_through` is false (back to combat when the
inventory's Close button is clicked). Before actions, Avo saved
`switch_mode` and `mouse_look` controls of their own; they load as the
actions of the control on exactly their keys in exactly their modes, else
as hotkeys, and are saved so.

**Scroll bars and click zones.** A `scroll_bar` (`from`, `to`, `rest`,
`step`, an optional `reset` key) drags a slider of the game, a map's zoom,
with the wheel: each notch puts a finger on the thumb where Avo last left it
(or at `rest`, a fraction of the track from `from`), glides it a `step`
towards `to` for a notch up (back for one down), never past an end, and lifts
it 0.2 s after the last notch. A new mode starts every scroll bar from
`rest`, and its `reset` key drags the thumb back there. Any control with a key
of its own may also have a `click_zone` (`area`, and a `shape`: `rectangle`,
`rounded` or `ellipse`): a left click inside it with the mouse free presses
the control as its key would, held while the button is down, its actions run
once, and the click itself never reaches the game, so the game's button is
touched once.

**Shared keys.** A key, mouse button or controller button may drive any
number of controls: F can press the game's Enter button and a hotkey can
switch the mode on it too. On a press, the controls that touch the screen go
first and the actions after, so the game's button is pressed in the mode it
belongs to and lifts with its key. The eye's lock key may press
controls too (Tab: the game's inventory and a free cursor). Within a joystick
a key is one direction only.

MOBA controls aim from the profile's hero point (where the camera keeps the
character; the centre unless the player drags the hero marker in the editor)
towards the visible cursor: move by mouse pushes the joystick that way while
its button is held (typically the right button), and smart cast drags a
skill that way while its key is held and casts on release, further the
further the cursor is from the hero. Their targets are read once per display
frame and glide like the D-pad. They follow the free cursor, so with the
mouse locked in FPS mode they rest.

The editor (KeymapEditorView.swift, in `AvoKeymapUI`) is drawn over the game. Its panel
(KeymapEditorPanel.swift, in the Quick Settings' haze) stands beside the
window, in a window of its own (`KeymapSidePanel` in KeymapOverlay.swift, a
child window with rounded corners), so the game keeps its whole size while
controls are placed on it. It goes on the right when the screen has room
there, else on the left, else the window moves over a little as the editor
opens (and back as it closes, unless it was moved meanwhile), and it changes
sides when the window is moved until it leaves the screen. It takes the
keyboard only for a mode's name (`becomesKeyOnlyIfNeeded`), so keys stay
with the editor; drags from it to the game go by way of the screen. In full
screen, or on a screen too narrow even then, it takes the right of the
window instead and the game's picture moves over and gets smaller,
Android's display staying the same (the window keeps its size, so nothing
re-plugs). Cancel (and ⇧⌘K again) asks before throwing changes away.
Picture in Picture waits until the editor closes. The panel has a Controls
tab and a Controller tab, and on top what to do now:

- **Mapping a button:** click the game's own button, then press its key (or
  a controller button; right-click for a mouse button or the wheel). A tap
  is made there, in the mode being edited, and the next click goes on to
  the next button. A click on the waiting tap cancels it; Esc is a key like
  any other (the panel's ✕ deselects).
- **The other kinds:** the panel's controls (tap, repeat, anchor, joystick,
  swipe; eye, aim down sights, free and lock the mouse; move by mouse and
  smart cast; switch mode) are clicked, for one where that kind usually is,
  or dragged onto the game where one goes. A second joystick takes the arrow
  keys; the eye (one per layout) acts in every mode.
- **The selected control:** its key and controller button
  (waiting for a key while it has none), a mouse-button menu, remove; its
  type among tap, repeat, anchor and aim (the wheel only taps, and the eye
  allows no repeated taps); its settings (a repeat's interval, an anchor's
  finger reach, in a circle of some size or the whole screen, a joystick's
  keys, size, run key and running reach, a swipe's duration, the eye's
  sensitivity, aiming sensitivity, vertical look and swipe area, aiming
  held or toggled, a smart cast's drag distance and cursor range, a
  switch's mode, a mouse key's action); and, with modes, the modes it works
  in. A line separates each setting (or the ones that belong together),
  and what each does is behind its (?).
- **On the game:** drag a control to move it, ↘ for its reach, × to remove
  it; the eye's area is dragged while the eye is selected, so a click in it
  otherwise maps the game's button under it.
- The panel also has the layout's modes, whether and how clearly the keys
  show on the game, the editor's opacity, Templates, import, export and
  removing every control, a line between each part.

The editor's Templates menu inserts a starting layout for an FPS, MOBA,
racing game or platformer, either next to the existing controls (keys
already in use stay with the player's controls) or replacing them; the
positions are guesses at a typical HUD, to drag onto the game's own buttons,
and a template never changes the hero point. Controls of a kind this version
does not know are skipped when a profile loads (the editor says so, and
saving leaves them out), so a profile from a newer Avo still works.

### Game controllers

`GamepadHub` (`AvoKeymapUI`) is the one reader of the Mac's controllers in a
shim process. GameController keeps one handler per element, so the hub alone
sets each extended gamepad's `valueChangedHandler`, reads the whole controller
on every change (`GamepadReading`) and hands the difference
(`GamepadReading.inputs(since:)`) to its listeners: `GamepadForwarder`
(Android's own gamepad, below), the key window's `KeymapController`, and the
key mapping editor with its controller panel. A controller's buttons reach a
game one of two ways:

- As Android's gamepad (the engine's virtio Xbox pad), for games with
  controller support. This is the default.
- As touches, when Game Mode is on and the profile binds the controller
  (`KeymapProfile.usesGamepad`). While the key mapping editor is open the
  editor holds the controller too. In both cases Android has no gamepad, so
  the game does not switch to controller prompts.

In a profile, a controller button is a `pad:` trigger, and a stick drives a
D-pad control (joystick) or the eye (`stick`). A D-pad control may also follow
the controller's d-pad buttons (`dpad_buttons`). A control answers one key and
one controller button, so binding a key keeps the controller button and the
other way round (`Control.setTrigger`). Like a key, a button may drive several
controls, including a mode switch or a mouse lock. A stick or the d-pad drives
one control per mode: binding it takes it off the controls that share a mode
with the new one, so one stick can walk on foot and drive in a vehicle.

Stick behaviour comes from `"gamepad"`'s `left_stick` and `right_stick`:

- **Dead zone:** radial. Nothing happens inside it, then the stick's travel
  rises evenly from its edge to the rim (`StickSettings.deflection`).
- **Sensitivity:** multiplies the lean. A joystick goes no further than its
  rim; the eye turns at 1400 counts/s × sensitivity × the eye's own
  sensitivity.
- **Releasing the eye:** an eye driven by a stick lifts its finger once the
  stick has rested 0.1 s. FPS mode's locked mouse keeps that finger down.

`vibration` gives a 50 ms CoreHaptics pulse (`GCController.haptics`) when a
control takes a controller button's press. Android's own vibration is not
passed to the controller: the engine's virtio gamepad has no force feedback
and the guest's vibrator HAL is not bridged to the Mac.

`presets` are the game's saved controller layouts:

- **What a preset holds:** each control's controller buttons, stick and
  d-pad by control id, plus the stick settings and vibration.
- **Applying one:** first takes the whole controller off the layout.
  Bindings for controls that are gone or changed kind are left out.
- **Ready-made layouts:** `KeymapTemplate.gamepadPreset(for:)` builds one for
  shooters, MOBAs, racing games and platformers. It goes by each control's
  role, guessed from its id or key (Space jumps, R reloads, the left mouse
  button fires), and the remaining controls get the buttons that are left,
  easiest to reach first.

The editor's controller panel (ControllerPanel.swift, the panel's Controller
tab) draws the connected controller's kind from `GamepadDiagram` and
`GamepadLayout`:

- **Diagram:** Xbox, PlayStation or Nintendo legends with SF Symbols'
  controller glyphs. Without a controller connected, the player picks which
  kind to show.
- **Live state:** buttons light up as they are pressed, and the sticks show
  their position and dead zone.
- **Dropping a part onto the game:** on a control that it can drive, it
  binds there. Anywhere else, a menu offers the controls that fit
  (`GamepadPlacement`: tap, repeat tap, swipe, anchor tap, ADS for a button;
  joystick or eye for a stick, plus the stick's press; joystick for the
  d-pad). `KeymapProfile.place` adds and binds the control, or binds the
  layout's one eye.
- **Binding the selected control:** press the part on the controller, push
  a stick past halfway, or click the part in the panel.
- **Sticks tab:** sets dead zones and sensitivity, with a live preview, and
  vibration on controllers that have motors.
- **Presets tab:** applies a ready-made layout, saves, applies and deletes
  presets, and resets. Reset (`removeGamepadMapping`) takes the controller
  off every control and removes the controls that only the controller
  worked.

The editor shows one mode at a time, from the mode tabs on its panel (the
flag marks the one the game starts in, the number its own controls). + Mode
adds an empty mode and its name is typed in its tab; the layout's first
also makes "Default", which takes the controls the layout had (the eye
stays in every mode). New controls, controller parts dropped on the game
and templates go into the mode shown, and the controller panel lists only
its bindings; a control acting in every mode is marked ∞ on the game. The
tab of the mode shown (clicked again, or right-clicked) has its menu:
rename, duplicate (its own controls copied, the others acting in the copy
too), start the game in it, the mouse on entering it, and delete it with
its own controls and the switches to it (the layout's only mode: the
layout is one set of controls again, and they all stay). The panel's Switch
adds a switch to the other mode, to one chosen in a menu, or with no other
mode to a new one; Free and Lock need the eye. Buttons have no size of
their own: every tap-like bubble is the same size, and ↘ appears only on
what has a reach (joysticks, move by mouse, smart cast, anchor taps).

There is no limit on the number of controls. Only Android's 16 multitouch
slots bound how many fingers are down at once.

Every new field is optional. Profiles from before them load unchanged and
are saved without them. An older Avo ignores `gamepad` and `dpad_buttons`,
and its keys still work; it also ignores a joystick's `run`, which then
walks. An anchor's rectangular `area` from before build 64 loads as a circle
half as tall as the rectangle. An older Avo skips
the controls it does not know (`hotkey`, `click_area`) and ignores `actions`
and `modes`, so there every control acts at once and only touches, and it
refuses a layout that binds a key or button to more than one control.

Profiles are JSON with positions normalized to the window, stored per package
in `~/Library/Application Support/Avo/keymaps/`, with community starters in
`profiles/keymaps/`.

## Settings (spec §6)

`VMConfig` holds every Control Panel setting with validation (RAM 2–16 GB
within what the Mac can spare, cores, Android's storage size, FPS cap
30 or 60–120, graphics settings, window size) and the spec's restart table:
Performance, renderer, OpenGL ES version, device profile and GMS need a
restart; the default
window size applies to an app's first window. Graphics' "OpenGL ES" picks
the highest version apps get on a GPU start — 3.2 by default (every image
Avo offers has the ANGLE for it), or a lower one to test an app against a
weaker phone's GPU (docs/engine.md, "GPU"). The FPS cap (60 by default)
picks the refresh rate every Android display has for a boot (`FrameRates`:
the cap above 60, else 60; avo-vmm `--refresh-rate`), and within it
Android's render rate (HostAgent: `peak_refresh_rate`, at once). Settings,
an app's page and Quick Settings offer 30, 60, 90 and 120 whatever the
screens show, the own rate of each screen of the Mac between 60 and 120
(NSScreen's maximum rate: a 75 Hz monitor's 75, so Android runs in step
with it), and the saved cap as it is. Under a cap that no screen shows
evenly (NSScreen's maximum rate and adaptive range), each says what the
screens make of it (`FrameRates.screenNote`: "This Mac’s screen shows up
to 75 Hz. Android runs at 120 fps; the window shows 75 of them…"). A cap
that needs another display rate than Android started at (60 → 120 Hz)
applies after a restart: `setFrameRateLimit` and the
configuration say `restartRequired`, and the banner shows. The Control Panel
applies changes as you make them and shows a "Restart Android" banner when
needed. Its Settings window is laid out like System Settings (a searchable
sidebar of panes, back and forward; Graphics holds rendering, resolution and
scaling, app windows and the performance HUD) and dressed like the Library: the same
haze, and every form's sections as cards (`HazeFormStyle`, with the haze's
switches, menus and segmented controls), a line between each two rows as in
System Settings; a row's note, caption or problem (`hazeRowNote`) stays
right under it. The app page's Graphics card has the same lines (`HazeRows`).

The haze has two looks, dark (as Avo has always looked, a game launcher's
near black) and light (the same haze on a soft green paper, deep green ink,
Avo's green deepened to moss for buttons and checks). Every token in
`HazeTheme.swift` and `QuickHaze` is a dynamic colour with both values
(`Color(haze:light:)`, an `NSColor` with a dynamic provider), so a view
takes the look of its appearance as macOS's own colours do; what the dark
look draws freely (a hero's gradient, its glows, an icon's palette) gets
its light counterpart from `HazeTone`, worked out in OKLab so it keeps its
hue. Settings › General › Appearance chooses System (the default, the Mac's
look as it changes), Light or Dark (`HazeAppearanceSetting.avo`, in the
Window Host's defaults). The Control Panel and every App Shim give it to
`NSApp.appearance`, and a change reaches running shims at once through a
distributed notification that carries the choice. The daemon gives it only
to the menu bar item's panel and the widgets: its own appearance stays the
Mac's, which Android's dark theme follows (`MacSystemState`). What draws
over a game (the performance HUD, notices, translations, the capture
flash and the key hints) stays dark in both looks. A haze menu wears the
appearance of what it opens from.

Android's storage size is chosen before Android creates its storage on a new
data disk (`DataDiskStore`), sized so that Android's Settings, which rounds
data plus system up to a phone size, shows exactly the chosen size. After that
it stays: `/data` is f2fs under metadata encryption (dm-default-key) with
inline-crypt file encryption, f2fs cannot grow while mounted, `/data` cannot
be unmounted at shutdown (incremental-fs mounts hold it), and an offline
`resize.f2fs` grow relocates file blocks through dm-default-key, which corrupts
file-encrypted data. So the daemon refuses a size change once the disk was
written, and Settings › Storage offers Change Size, which erases Android's data
first. Android's own figures (`statfs` of /data and /system) are kept in
`data-disk.json` next to the data disk for the pane.

Graphics › Renderer (`rendererMode`: Automatic, GPU (Metal), Software) picks
avo-vmm's gfxstream GPU path or software rendering at the next start; the
GPU renderer ships in Avo.app (docs/engine.md, "GPU"). A failed GPU start
falls back to software on its own and stays there until "Try GPU Again"
(`retryGPU`), a Renderer change, or a new avo-vmm, emulator or macOS;
`VMStatus.renderer` says which renderer runs and why, for the pane's status
line and banner. "Clear GPU cache" (`clearGPUCache`, with `gpuCacheStatus` for
its size; Control Panel only) empties the engine's Metal shader cache in
`~/Library/Caches/Avo/gpu-cache` (docs/engine.md, "Shader cache").

## Pausing Android

Android can pause: avo-vmm stops its vCPUs and its clock stands still
(engine.md, "Pause"), it keeps its place and uses no CPU, and it goes on
where it was. `VMState.suspending` and `.suspended` are those states, with
`VMStatus.pause` (since when, and whether Avo did it on its own); every
`.running` check treats a paused Android as not running, which is the safe
default.

- **Waking is using.** VMManager's channels (`controlSession`,
  `inputChannel`, `adbConnection`, `adbSocket`, `rescueShell`) and
  `ensureRunning` wake a paused Android before they hand it out, and so do
  what VMMEngine hands out itself (fingerprints, Google apps, the unlock,
  through `PausableEngine.onUse`). So opening an app, a notification click,
  avoctl, `adb` through ADB support and an install all resume it within a
  moment; a resume is no new start (no app listing). Pauses and wakes run one
  after the other. Reading the status, polling the running apps (only while
  Android runs) and copying on the Mac never wake it: the clipboard waits and
  reaches Android when it goes on. HostAgent's watches skip their turns while
  paused, and after a resume HostAgent puts Android's clock right
  (`clockResumed`). Stopping a paused Android resumes it first, for its clean
  power off.
- **Pause when idle** (Settings › Performance; `VMConfig.autoPauseMinutes`:
  Never, 5, 15 or 30 minutes, 15 by default; applies at once). Every 30 s the
  daemon looks (`AutoPause.swift`): Android must be running with no Avo
  window open (no App Shim display and no Control Panel), nothing under way
  (an app install, Google apps, a storage move, an ADB support connection,
  sound playing or recording as the engine reports them, a GPS route
  playing) and the engine
  using under 0.3 of a core (a download, an app updating), for the chosen
  time since the last of those and since anything last used Android
  (`VMManager.lastUse`). The pause is dropped when Android was used between
  the decision and the pause. While paused, nothing in Android runs, so its
  notifications and background work wait too; the setting's help says so.
- **The menu bar** pauses and resumes by hand (`pauseFromMenuBar`,
  `resumeFromMenuBar`).

## The menu bar item

A click on the item opens a small panel (`MenuBarPanel.swift`) in the
Library's haze: the daemon target compiles `HazeTheme.swift` and the
typefaces from the Avo target, so that file must stay free of types only
the Control Panel has. It shows Android's state (running, paused with why,
stopped), avo-vmm's CPU and memory (`proc_pidinfo` of the engine, every two
seconds while the panel is open, never otherwise), the apps that run (open,
minimized, in the background) and the ones used last (`AppUsage`), and
Start, Pause, Resume and Stop. A right click (or Control-click) opens a
menu with every app, in the haze too (`HazeMenu.swift`, below). The menu
also has:

- **Check for Updates…:** opens the Control Panel with
  `avo-control-panel://check-for-updates`.
- **Restart Android to Finish Updating Avo:** shown while an update waits for
  Android to stop.

## System Status (Library › System Status)

Like Activity Monitor, for Android (`SystemStatusView.swift`; the daemon's
side is `SystemMonitor.swift` and `GuestActivity.swift`). Four cards with
their last minute: Android (its state and CPU over all its cores), the
engine on the Mac (avo-vmm's CPU in percent of one core and its memory, as
in the menu bar), Android's memory (`MemTotal - MemAvailable`) and the GPU.
Under them, Android's apps (their processes added up) or all its
processes, with CPU (percent of one core since the last sample), resident
memory, state and FPS, sortable and searchable. An app's line opens its
page with a double click, has Open, its page and Force Stop under the
pointer, and the app's menu on a right click.

- **Only while it shows.** The Control Panel calls `systemActivity(watch:
  true)` while the view is on screen in a window that is not covered or
  minimized, and false otherwise; the daemon samples every 2 s while any
  Control Panel watches (`DaemonEvent.systemActivity`), never otherwise,
  and stops when the last one says false or disconnects.
- **No shell call of its own.** Android's part rides along with HostAgent's
  2-second look (`lookAround`): `ps -A -o PID,PPID,UID,TIME+,RSS,NAME` and
  one `grep` over `/proc/stat`, `/proc/meminfo`, every
  `/proc/<pid>/oom_score_adj` and the app cgroups' `cgroup.freeze`, as the
  shell user (about 13 ms of Android's CPU and 35 KB for 140 processes;
  0.6% of one vCPU). The daemon's own `ps -A -o NAME` poll for the running
  apps waits meanwhile and takes its answer from these samples. A paused
  Android is never asked: the look skips its turns, and the view says
  Android is paused.
- **State** comes from `oom_score_adj` (ActivityManager's levels: < 0
  Android's own, 0 foreground, < 300 visible or perceptible, < 900
  background, cached above), `cgroup.freeze` (frozen), and an Avo window
  showing the app (window open). Processes gone before the grep (`ps`
  itself) are left out.
- **GPU.** The card shows how busy the Mac's GPU is (IOAccelerator's
  `PerformanceStatistics` › "Device Utilization %") and avo-vmm's share of
  its time (the `AppUsage` › `accumulatedGPUTime` of its
  AGXDeviceUserClients, nanoseconds, what Activity Monitor's % GPU uses);
  both from IOKit without entitlements, about 1 ms. GPU time per Android app
  is not measured, and the view says so: every app's graphics run in the
  engine's one gfxstream renderer, and their commands reach it through
  shared-memory rings that the virtio-gpu queue never sees. Measured in the
  test VM: the guest names each gfxstream context after its process, but
  per context the fences go almost all to SurfaceFlinger (composition), and
  SUBMIT_3D counts follow frames and wake-ups, not work (glbench: the same
  580 submits/s at 2.7 times the load); gfxstream's host threads carry no
  names. Per-app GPU time would need timestamps per guest context inside
  gfxstream or MoltenVK.
- **FPS** is the frames avo-vmm published for an app's windows (the shared
  frames' sequence per scanout, `FrameBridge.publishedFrames`), on its main
  process.

## App icons in the Library

Every app tile, card and row in the Library (Home's hero, cards and tiles,
the Library section's All, Games and Apps tabs, search results, the
sidebar's running apps) answers the same way (`AppTileInteraction.swift`):

- **Click:** opens the app in its window.
- **Press and hold (0.45 s):** opens its page. The tile gives a little at
  once; past a click's length a ring of Avo green runs around it, and the
  page opens when it closes (with a haptic tick). Leaving the tile first
  cancels.
- **Right click or Control-click:** the app's menu in the haze
  (`HazeMenu.swift` in `AvoHazeUI`, a borderless panel at the pointer
  that turns to fit the screen): Open, App/Game Page, Force Stop, Show in Finder, Clear Data… and
  Uninstall… (in the haze's red), confirmed as on the page. The keyboard
  moves through it (arrows, Return or Space, Escape, typing an item's first
  letters); a click elsewhere, another app or scrolling closes it. One
  local event watch sends right clicks to the tile under the pointer.
- **Keyboard and VoiceOver:** with Full Keyboard Access, Return or Space
  opens, ⌘I opens the page and Control-Return the menu; VoiceOver's
  default action opens, with the page and the menu (Show Menu) as actions.

Every menu Avo pops up is such a haze menu (`HazeMenu.swift`, public in
`AvoHazeUI`, which the Control Panel, the daemon and the Window Host link
through AvoHostKit): the menus of app tiles and pages, the Control Panel's choices
(`HazePicker`: a check mark on the choice, sections, options that cannot be
chosen), an app window's title bar menus and Quick Settings' choices, the
key mapping editor's panel, mode and context menus, and the menu bar item's
menu. AppKit code still builds an `NSMenu`: `HazeMenuPresenter.popUp(_:…)`
has its delegate and validation update it as macOS would before showing
it, and an item sends its action to its target (one without is found when
the menu opens). Every action item of a menu's top level has an
illustration (an SF Symbol: `NSMenuItem.symbol(_:)`, or the entry's
`symbol`); a submenu's rows show none, only real pictures such as apps'
icons, and keep the column so their titles stay in line. A submenu opens in
place, under its item (→ and ← with the keyboard): the panel takes its new
size at once, so the rows spring open inside the menu (slid out from under
their item), and a menu that must move to stay on its screen glides there;
closing, it shrinks once the rows have gone. A menu taller than its screen
scrolls. While a menu shows it has
the keyboard, and the window that had it gets it back; a transient popover
it opens from (Quick Settings) stays open meanwhile. Only the menu bar's
menus and a text field's own context menu are still macOS's.

## Updating Avo

Avo updates itself with Sparkle 2. `docs/releasing.md` has the feed, the
key, the release steps and the code-signing rules.

`AppUpdater` (Control Panel) owns Sparkle's standard updater:

- **When it starts:** only in a Developer ID build whose Info.plist has an
  https `SUFeedURL` and an Ed25519 `SUPublicEDKey` (`AppUpdate.readiness`).
  The feed is the latest GitHub release's `appcast.xml`; Sparkle checks it
  once a day by itself.
- **Where it shows:** Avo › Check for Updates…, the menu bar item, and
  Settings › About › Software Update (automatic checks, last check, Check for
  Updates…).
- **Trust:** an update is trusted by its EdDSA signature (in the feed), or
  by the running app's Developer ID on the app it brings
  (`docs/releasing.md`).

Sparkle swaps `Avo.app` at the same path. Android is never taken away for
that without the player's say:

- **Install and Relaunch:** while Android runs, it first asks whether to stop
  Android, install anyway, or wait for Avo to quit.
- **The old daemon** (`AppUpdateWatcher`) watches `Avo.app`. Once its build
  on disk changes, Android has held nothing for 3 seconds, and the core says
  nothing is under way (`DaemonCore.claimRestartForUpdate`: no start,
  restart, reboot, checkpoint restore, Google apps work, storage move,
  install or root step), the daemon takes its menu bar item away and exits
  with `AppUpdate.daemonRestartExitStatus` (75); from that claim on it starts
  no Android. launchd's `KeepAlive` then starts the new build's daemon.
  Until Android stops, the old daemon keeps it running.
- **The new Control Panel** compares the daemon's hello (`daemonVersion`:
  version, build, start of the code hash) with the daemon in its own bundle.
  An older daemon restarts at once if Android is stopped. If Android runs,
  the restart waits for it to stop, and Settings › About offers Restart
  Android meanwhile (`ControlPanelModel.checkDaemonBuild`).
  `DaemonAgent.install` never stops a running daemon. A changed agent plist
  waits for `DaemonAgent.reload` the same way.
- **App Shims** made from another build's template are made again
  (`ShortcutManager.madeForAnotherAvo` compares `CFBundleVersion`).
- **From `dev.avo` to `com.avodroid`** (0.3.0 Preview 2): every helper's
  identifier, the agent's label (`com.avodroid.daemon.agent`) and the Mach
  service moved to Avo's domain (`AvoIdentifiers.prefix`; `formerPrefix` is
  the old one). The first Control Panel of the new build copies the
  helpers' and App Shims' preferences to their new domains
  (`IdentifierMigration`; Avo Hub's `dev.avo.hub…` are not Avo's). Only an
  old agent whose daemon runs Android's engine (`avo-vmm`) is kept: the
  Control Panel talks to it under the former Mach service and installs
  nothing beside it, and once Android stops `DaemonAgent.reload` boots it
  out, removes its plist and loads the new one. Any other old agent goes at
  once: launchd holds a background item to the signature it first saw, so
  an ad hoc build's job cannot even start a Developer ID daemon ("Unable to
  get updated LWCR", the daemon killed for a launch constraint violation).
  When the old agent is gone, `IdentifierMigration.finish` copies what the
  old daemon wrote since, then removes the old preference domains, its
  HTTP storage and its runtime folder: nothing of Avo's stays `dev.avo`. A
  new daemon that launchd started under the old job serves the job's
  former Mach service (`XPC_SERVICE_NAME`). App Shims with
  a `dev.avo.shim.` identifier are made again. macOS may ask once more for
  what the helpers had been allowed (camera, microphone, Bluetooth,
  location, notifications), which it keeps by identifier.
  In Android, Avo's helpers moved too (`com.avodroid.links`, `.widgets`, the
  `app_process` helpers' classes, `com.avodroid.feature.MAC`). HostAgent
  uninstalls `dev.avo.links` once this build's is in, passing on the browser
  role if it held it, and `dev.avo.widgets` (each widget panel gets its
  widget again from the new host when it opens; one that asks for settings
  asks once more). `IdentityFeature` removes `dev.avo.feature.mac.xml` where
  it writes the new file.

Every release must raise `CFBundleVersion` (`CURRENT_PROJECT_VERSION`).
Sparkle needs it, and so do the daemon's and the shims' build checks.

## Report a Problem

Help › Report a Problem… (`ReportProblem.swift`, `DiagnosticsReport` in
AvoKit) asks what happened and saves a zip where the user chooses, then
offers Show in Finder. Avo sends nothing; the user attaches it. The zip has
a README listing what is in it and:

- `report.json`: Avo's, the daemon's, macOS's and Android's versions, the
  Mac's model, memory and cores; Avo's settings; Android's status, renderer
  (`VMStatus.renderer`), ADB support, storage (`DataDiskStatus`,
  `StorageLocationStatus`) and GPU cache; the installed apps' packages and
  versions (optional); what could not be collected.
- `daemon.log`: `log show --last 3h` of Avo's subsystem (`com.avodroid`, and
  `dev.avo` of the builds before 0.3.0 Preview 2), whose
  private values the unified log already hides.
- `avo-vmm.log` (and `avo-vmm-gpu-failed.log`), the end of `kernel.log` and,
  optionally, of `logcat.log`; small state files (`gpu-fallback.json`,
  `data-disk.json`, `android-data.json`, `avo-image.json`).

Never in it: Android's disks or any app's files, `adbkey` or the Mac's own
ADB keys, `fingerprints.json`, the clipboard or notifications Avo keeps.
Every file passes `DiagnosticsRedactor`: the home folder becomes `~` and the
user's short name `<user>`; email addresses, `Account {name=…}`, bearer
tokens, `token`/`password`/`secret`/`cookie`/`authorization`/API key values,
Android, GSF and advertising ids, IMEI and IMSI, GNSS fixes and links'
query strings are replaced. Each log is cut to its end (at most a few MB).

## Android's screen lock

Avo turns Android's lock screen off at every start (`lock_settings
set-disabled`), which does nothing once the user gave Android a pattern, PIN
or password (in Android's Settings, one of the listed apps). Android then
starts with user 0's credential-encrypted storage closed: only direct-boot
apps resolve or start, and its lock screen covers every display, app windows
included.

- Apps never disappear for it: ListApps asks with
  `--query-flags 0xC0000` (direct-boot aware and unaware) and lists every
  installed package, launchable or not, and the daemon removes an app only
  when its package is gone (never on an empty listing).
- HostAgent finds the lock after `sys.boot_completed` (storage:
  `sys.user.0.ce_available`, `am get-started-user-state`; lock screen:
  `dumpsys trust`'s `deviceLocked`; the kind: `dumpsys lock_settings`) and
  reports it as `VMStatus.screenLock`, watching it every 2 s from then on. The
  Control Panel opens an unlock sheet by itself (Cancel leaves a banner with
  Unlock…); App Shim windows show a lock in place of the app and open their
  display once Android is unlocked, whichever window or panel unlocked it.
- `unlockAndroid` passes the credential to `cmd lock_settings verify`, which
  opens the storage but leaves the lock screen up; HostAgent then enters it
  on the bouncer on Android's own screen (display 0), as a person would:
  `input text` for a PIN or password, `input motionevent` through the
  pattern's dots, and only when `uiautomator dump` shows that bouncer. Unlocked,
  it describes the apps again, catches up on packages and the daemon syncs the
  apps (shims and icons come back).
- The credential is validated (pattern: 4–9 different dots 1–9; PIN: digits),
  single-quoted for the shell, and never logged or stored; `verify`'s output
  (which repeats a wrong credential) is only read for its outcome. After four
  wrong tries Android refuses attempts for about a minute.

## Mock fingerprints

Settings › Fingerprints keeps the user's fingers in Avo (`vm/fingerprints.json`,
next to Android's data disk): they are added, renamed and removed whether
Android runs or not. Android's own Settings app adds one to Android, as on a
phone, when its sensor is touched with it. That sensor is the virtual one of
AOSP's userdebug images (`com.android.hardware.biometrics.fingerprint.virtual`,
driven by system properties), so BiometricPrompt and the lock screen see
enrolled fingerprints. The daemon's `FingerprintCenter` runs the guest steps
through HostAgent (`GuestFingerprints` has the commands and their parsing):

- **Adding to Android:** while Settings enrolls (its scheduler's current
  operation is `FingerprintEnrollClient`), a touch with finger N sets
  `vendor.fingerprint.virtual.next_enrollment N:100,100,100:true` right before
  `cmd fingerprint fingerdown`. The sensor enrolls the finger under its own id
  and Android names it "Finger 1"; the helper (`guest/fingerprint`, a dex jar
  run as root with app_process) calls `IFingerprintService.rename` to give it
  the finger's name.
  - Only Avo's fingers, once each: an unregistered finger or one Android
    already has is refused.
  - A finger whose id Android or its sensor still holds from before takes a
    new id first.
  - `fingerdown` needs the Secure setting `biometric_fingerprint_virtual_enabled=1`.
    From the next boot Android then uses the sensor's `virtual` instance, which
    reads the same properties.
- **Touching:** `setprop vendor.fingerprint.virtual.enrollment_hit <id>` (0: a
  finger the sensor does not know) and `cmd fingerprint fingerdown`.
  - A finger Avo has but Android does not is not recognized, as a stranger's
    is.
  - The outcome comes from the counts `dumpsys fingerprint` prints (accept,
    reject, lockout).
  - What asks for a finger is the scheduler's current operation:
    `FingerprintAuthenticationClient` with the requesting package
    (`com.android.systemui` for the lock screen), or Settings enrolling.
  - An app's BiometricPrompt shows on display 0, which no window shows, so the
    daemon polls every 2 s while Avo has fingers, and the window's fingerprint
    button turns blue. Cancel Fingerprint Request sends Back to display 0.
- **Following Android:** at every start and refresh, Avo's fingers are merged
  with Android's list (`GuestFingerprints.merge`).
  - A finger Android lacks is not `enrolled`. That happens when it was never
    added, removed in Settings, or removed along with the screen lock or by
    Reset Android. The finger itself stays in Avo.
  - A fingerprint Avo has no finger for becomes one: added by an earlier Avo,
    which mirrored Android's list.
  - `androidNames` (Android's names at the last look) says which side renamed
    one. A name Android changed comes over; any other difference goes to
    Android, since Android cannot change while stopped.
  - Removing a finger in Avo removes it from Android through
    `IFingerprintService.remove`, which also takes it out of the sensor. The
    removal waits behind a running authentication (Android's scheduler runs one
    operation at a time), so it stays queued in `removing` until nothing asks
    for a finger.
- **Screen lock:** Android takes fingerprints only with a screen lock, and its
  Settings asks for one first. After a boot it wants the credential first
  (StrongAuth). Avo turns on phone-like lockout: 5 wrong fingers lock it for
  30 s; 20 in a row lock it until the credential is entered, which
  `cmd lock_settings verify` also does.
- **No hardware token:** the virtual sensor signs no hardware auth token, so
  keys bound to biometric authentication (CryptoObject) stay locked even after
  a recognized finger.

## Android widgets (Library › Widgets)

Android apps' home screen widgets show on the Mac in floating panels, live:
they update and take clicks as on a phone.

- **In Android:** Avo Widgets (`guest/widgets`, `com.avodroid.widgets`), built
  like Avo Links and installed by HostAgent at each start when Android's copy
  differs. `appwidget grantbind` (as root) lets it bind any app's widget
  without asking; QUERY_ALL_PACKAGES lets it see every app's.
  - `WidgetsProvider`: `content read --uri content://com.avodroid.widgets/providers`
    lists the widgets as JSON (provider, labels, size in dp, how it resizes:
    which ways and its resize limits, a preview PNG);
    `content call … --method delete --arg SLOT` lets go of a removed panel's
    widget. Only the shell and root may ask.
  - `WidgetActivity`: one widget filling a display of its own, started with
    `avo-widget://SLOT?provider=…` (`GuestWidgets.startCommand`, a task per
    panel). A slot keeps its Android widget id in the app's preferences, so a
    panel shows the same widget after a restart. One shared `AppWidgetHost`
    listens while any activity shows a widget. It ends with its display; a
    re-plug (a resize without Avo's composer) starts it again on the new
    display (`HostAgent.bringBack`). It is translucent and starts with
    NO_ANIMATION: no splash or opening animation that the panel would show
    as a flash.
- **The list:** the daemon keeps `widgets.json` (`PlacedWidget`: slot,
  provider, size, how it resizes) and sends `DaemonEvent.widgets` to Control
  Panels and the panels. Each Android start (and each listing) refreshes
  how placed widgets resize; lists saved before had none.
- **The panels** (`WidgetPanels`, in AvoWindowHost) run in the daemon's own
  process, which is there whenever Android is. They are an in-process client
  (`DaemonCore.registerInProcess`, role `shim(com.avodroid.widgets)`), so they need
  no XPC connection or shim hash. Each opens a display with
  `OpenDisplayRequest.widget`; `openDisplay` turns it into the activity's
  launch. The renderer draws them with `avo_keyed`: Android's empty, pure
  black display around the widget becomes transparent, so a panel has the
  widget's own shape. The panel sits just above the desktop's icons, or on
  top. It is the widget alone, so it goes as high as any window; its bar
  (move, keep on top, remove) is a child panel of its own that shows on
  hover over the widget's top edge, or under it at the top of the screen.
  The placeholder stays until a frame that is not all black
  (`MetalRenderer.whenContentShown`): Android's display is empty until the
  widget draws.
- **Taps:** widget views are made with `MainDisplayContext`, which starts
  a tapped widget's PendingIntent on Android's own screen
  (`setLaunchDisplayId(0)`), where an app Avo knows gets its window at the
  next look. Anything that still starts on a widget's display (an app the
  widget starts itself) is moved there by the look every 2 s; an app Avo has
  no window for just leaves the widget's display.
- **Settings:** a widget that asks for its settings first opens in a
  larger panel (`AndroidWidgets.setupSize`). The task watch reports each
  widget display's top activity (`displayContentChanged`); once the widget is
  back on top, the panel shrinks to the widget's size (a re-plug).
- **Size:** a new panel takes whole launcher cells (80 × 100 dp, as a 4 × 5
  home screen), as many as the widget wants or its minimum takes; widgets
  often draw past their minimum, and what they leave empty is transparent.
  Dragging an edge resizes the panel as the widget allows
  (`PlacedWidget.panelSizeLimits`): a widget that resizes lays out again
  for the new size (a re-plug at the end of the drag), within its resize
  limits and along the ways it resizes only; one that does not (many games')
  zooms in its own shape, 0.5–2.5 × (its display gets more pixels at a
  higher density, the same layout in dp). The panel keeps its last frame
  until Android has the new size.
- **Limits:** each panel takes one of the 15 scanouts, and an open panel
  keeps Android from pausing when idle. Pure black inside a widget shows
  through.

## Android's location (GPS)

Android's GNSS HAL reads real fixes from avo-vmm (`location` on the control
socket, gnss.rs), so apps see GPS, not a mock provider. What it reads is the
daemon's `LocationCenter` (AvoDaemonCore), which has one of three sources:

- **This Mac** (the default): CoreLocation in the daemon (`MacLocation`),
  while Android runs and Settings › Privacy & Security shares the Mac's
  location. Its fixes go through the center, which passes them on only in
  this mode.
- **A place**: a click on the map, an Apple Maps search result or typed
  coordinates; speed 0, accuracy 5 m.
- **A route**: points in order, drawn (stops clicked on the map, by road
  with Apple Maps directions or straight) or from a GPX, KML or KMZ file
  (`LocationRoute.parse`: a GPX track, route or waypoints; a KML gx:Track,
  LineStrings or Points; times kept when every point has one, in order;
  more than 20,000 points thinned). It plays at a pace (walk 5 km/h, run 10,
  cycle 18, drive 50, or as recorded), ×1 to ×20, once or in a loop
  (`RouteTracker`, pure: great-circle interpolation, the bearing from the
  current place to the segment's end, speed 0 while a recording stands
  still). Four times a second the center moves it on and sends the fix
  with its speed and bearing; the HAL reads the newest about once a second.
  It moves only while Android runs and is not paused (a suspending clock,
  so the Mac's sleep does not count, and never more than 2 s at a time):
  stopped or paused, the route waits where it is. A playing route keeps
  Pause When Idle from pausing (`AutoPauseReason.location`); starting or
  resuming one wakes a paused Android.

The center is the daemon's, so a route plays on with every window closed.
avo-vmm keeps the last fix and sends it again after every start.

**Every app's location and an app's own.** There is a location for every
app, and an app may have one of its own: the panel's **All Apps / This App**
(`LocationRequest.ownLocation`, `.followAllApps`; Settings › Devices ›
Location lists the apps with their own and gives each back to every app's,
`.removeApp`). An app's own starts where every app's is and changes on its
own, a route included, each route moving on its own clock. Android has one
GPS, so what it reports is the own location of the app whose window is in
front (`focusDisplay` → `LocationCenter.appFocused`), else every app's; the
app's last window closing gives Android every app's location again. Each
panel hears its app's location (`location(watch:)` is answered per client),
the Control Panel every app's with the list. Places, every app's and the
apps' own, are kept across starts in `location.json` next to the
configuration; a route is not (the place before it is kept).

**The Location panel** (an app window's Game Controls › Location…, ⌥⌘L, or Quick
Settings › Location; `LocationPanel.swift`) is one window per App Shim:
a MapKit map with Android's puck (an arrow while it moves, turned with the
map), the Mac, the route and the stops being drawn; a search field (Apple
Maps suggestions near the map); and a sidebar in the Quick Settings haze
with where Android is, the playing route (progress to seek, pause, resume,
start over, its pace while it plays), Place or Route, and Use My Mac's
Location. The panel never asks macOS where the Mac is (no location prompt
for an App Shim); the daemon says. XPC: `location(watch:)` returns
`LocationStatus` with the route's points and, while `watch`, sends that
client `DaemonEvent.location` at every change and once a second while a
route plays (without the points; a new route id makes the panel ask again);
`changeLocation(LocationRequest)` changes it. Both are for App Shims and
Control Panels.

## Android's cameras (Settings › Devices › Cameras)

Each of Android's cameras (`VMConfig.backCamera`, `frontCamera`) is
Emulated, None or one of this Mac's cameras (`CameraSource`; the picker
lists built-in, plugged-in and Continuity cameras, `AVCaptureDevice`'s
discovery, and keeps a chosen camera that is unplugged). While both are
Emulated, Android has the image's emulated cameras. Otherwise avo-vmm gets
`--cameras` and gives Android two virtio-media cameras read by the image's
external camera HAL (engine.md, "Cameras"), and the daemon feeds them
(`CameraFeed`, AvoDaemonCore): only while Android streams one, the source
chosen for it runs, the Mac's camera (AVFoundation, cropped to Android's
size, at most its rate) or a scene drawn on the Mac, as JPEG pictures on a
control connection of their own. macOS asks for camera access in Avo's name
the first time Android uses a Mac camera; without it Android sees a picture
that says how to allow it. Every boot with these cameras the host agent
patches the HAL so they face back and front (`GuestCamera`).

Which cameras Android has (and so which HAL) is fixed for a start
(`cameraFlags`): changing it needs a restart. Another source for a camera
Android has (one Mac camera for another, or the drawn scene) applies at
once (`DeviceSettingsEngine`).

## Boot configuration and images

Before each boot the daemon writes a small read-only disk, `avo_config`
(`BootConfig`, JSON padded to 4 KiB): the daemon's ADB public key (adbd stays
authenticated even though only the daemon can reach it), the device profile's
properties, root and GMS choices, locale, time zone and default density.
`avo_init` applies it early in boot (guest/device/avo).

Android images are downloaded at first setup, versioned separately, and live
in `~/Library/Application Support/Avo/images/<version>/` with a
`manifest.json` (SHA-256 and size per file) and an Ed25519 signature checked
against the key in the daemon's Info.plist (`AvoImagePublicKey`) before every
boot. `scripts/make-image-manifest.py` produces both. That is the image format
of the legacy crosvm contract (engine.md); avo-vmm boots AOSP Cuttlefish
builds (below).

## Android images (Cuttlefish)

Avo.app ships no Android. The Setup Assistant (first launch, no usable image,
or Help › Setup Assistant…) and Settings › System › Android version list,
download and import AOSP Cuttlefish images; the Control Panel does this
itself (`AndroidImageManager`), since a download needs no Android and the
daemon never reads files the user picks. Everything is in AvoPackages
(`AndroidBuildAPI`, `AndroidImageInstaller`, `AndroidImageStore`).

- **Catalog.** `AndroidBuildSource` holds the endpoint (Android Build API
  v4), the public API key Cuttlefish's `cvd` ships, the release branches
  (`aosp-android-latest-release`) and the target
  (`aosp_cf_arm64_only_phone-userdebug`); Control Panel defaults
  (`AvoBuildAPIEndpoint`, `…Key`, `…Branches`, `…Target`, `…MinimumSDK`)
  override them. Of a branch's successful builds (newest first) Avo offers
  the newest of each Android version at or above API 36 (spec: AOSP 16+).
  A build's version comes from its `build.prop` artifact; within a branch
  versions only go up, so Avo reads evenly spaced builds, then only between
  two that differ, a few at a time, and caches every answer
  (`~/Library/Caches/Avo/images/builds.json`; the last listing,
  `offers.json`, shows at once next time). The image zip's size and MD5
  come from its artifact entry.
- **Download.** Signed Cloud Storage links last minutes: one is asked for
  before each request, and an expired one (403) is renewed. The zip's
  directory (its last 64 KiB, a range request) says how big it unpacks,
  for the disk space check (download, unpacked files and Android's working
  copy of super.img). `RangeDownloader` continues a partial file with
  `Range` and `If-Range: <ETag>` (a changed file starts over), so Pause,
  Resume and a quit in the middle lose nothing; the partial file and its
  ETag are in `~/Library/Caches/Avo/images/downloads`. Then the zip's MD5
  must match the API's, and only the image files are unpacked (ZIP CRC
  checked), hashed with SHA-256 as they are written.
- **Import.** "Use an Image on This Mac…" takes an image zip, a folder with
  the `.img` files, or `fetch-cuttlefish.sh`'s build folder. The AVB
  properties of `vbmeta.img`/`vbmeta_system.img` (build fingerprint,
  security patch) say which build it is; arm64 Cuttlefish userdebug at
  Android 16+ only, with the right headers (boot, vendor_boot, AVB, sparse
  super). Folders are cloned (APFS: no extra space), zips unpacked.
- **Manifest.** `images/android-<version>-<build>/manifest.json`, schema 2,
  `"format": "cuttlefish"`, `"trust": "local"`: these are Google's builds,
  with no Avo signature, so the trust is what Avo checked when it installed
  them (the API's MD5 over HTTPS, or the user's own files), recorded as the
  size and SHA-256 of every file, with the release, build, fingerprint and
  origin. Images are staged in `images/.staging-…` and renamed into place.
- **Choosing.** `images/selection.json` names the image Android starts
  with and the previous one (kept for going back). The daemon's
  `CuttlefishImage.prepareStart` (VMManager's `loadImage`, at every start)
  takes, in order: the `AvoCuttlefishImages` developer setting, the
  selection, `images/cuttlefish`, else the newest image on the Mac (also
  `fetch-cuttlefish.sh`'s downloads, used where they are); none is "Android
  not installed". An installed image is checked against its manifest (the
  identities of files already checked are kept in `.verified.json`, so an
  unchanged image is not read again).
- **Switching.** avo-vmm keeps writable copies of super and vbmeta in
  the data folder's `cuttlefish/` (`vm/cuttlefish`, or `--disks` when
  Android's data is elsewhere; made once). When a start uses another image than they
  came from (`vm/cuttlefish/avo-image.json`), they go and avo-vmm copies
  the new image's; the data disk and the instance's metadata disk (the key
  to Android's encrypted data) and misc stay, so apps and data survive
  an upgrade. A new data disk starts without the old metadata, misc and
  frp disks (`DataDiskStore.ensure`), and every start clears frp: Avo has
  no factory reset protection, and a kept frp disk that does not match the
  data (erased, restored, copied) keeps FRP active, which this Android's
  system_server answers by stopping at every boot ("FRP is active").
  Android's own factory reset (Settings › System › Reset options) writes
  recovery's `--wipe_data` to misc and reboots; there is no recovery, so
  avo-vmm exits 76 instead (EXIT_FACTORY_RESET) and the daemon erases the
  data as Reset Android does and starts Android again. A recovery request
  left on misc is dropped before every boot: only one made during the boot
  counts, so a reset an older avo-vmm ignored never wipes at a later reboot.
  Any other reboot from inside Android (its Restart, `adb reboot`) ends
  avo-vmm too when the daemon runs it (`--exit-on-reboot`, exit 77,
  EXIT_GUEST_REBOOT): the daemon starts Android again through its usual
  start, so the new boot gets its displays, location, shared folder, audio
  policy and layers like every boot. avo-vmm run by hand still reboots in
  place. `avbctl disable-verity` (Google apps) set flags in the vbmeta
  copy: for another build of the same Android version the new copy gets
  them too and Google apps' overlay mounts again; for another version
  verified boot is back on and the overlay, which would not fit, stays
  unused. `android-data.json` (next to the data disk) keeps the newest Android that used the
  data disk: an older API level (or the same with an older security patch,
  which Keystore refuses) is offered only together with Reset Android.
- **Changing in the Control Panel.** Each Android version keeps its own
  data, and a change of version never erases any. Another build of the same
  Android keeps the data in use. Another Android version (an upgrade or an
  older one) asks which data it uses (`AndroidDataSheet`): the data that
  version used before (places the Control Panel remembers from the daemon's
  storage status, `AndroidDataMemory`, by API level), Android data in another
  folder (*use existing*), new data in an empty folder (*start fresh*), or,
  for an upgrade only, the current data taken along. The other choices are
  the storage changes above, so the data left behind stays where it is: in
  Avo's own storage it becomes the kept copy, elsewhere its folder stays as
  it is. The image is chosen before the data changes, so no start pairs the
  previous Android with the new data (an older Android's data would be
  upgraded), and a storage change that fails puts the previous image back. A
  version that must be downloaded changes its data once the download is in.
  Google apps for another version stop working (Settings › Google services
  goes back to None, and Settings › Google Apps asks for Reset Android
  before Google apps for the new version: `google-apps.json`, docs/engine.md).
  The choice applies at the next start; the section offers Restart Android
  while the running Android uses another image.

## Data on the Mac

```
~/Library/Application Support/Avo/   config.json, apps.json, icons/, keymaps/, adbkey, images/,
                                      vm/cuttlefish/ (data disks, console and logcat logs, frames/, audio/)
~/Library/Caches/Avo/images/          partial image downloads, the image catalog's caches
~/Library/Caches/Avo/gapps*/          Google apps packages being installed, the last MindTheGapps release lists
~/Library/Caches/Avo/gpu-cache/       GPU shader and pipeline caches
~/Applications/Android Apps/          App Shims
~/Library/Logs/Avo/                   avo-vmm.log (the engine's log, recreated at every start)
$TMPDIR/com.avodroid/                 vsock.sock, control.sock, console.sock (mode 0700)
```

## Where Android's data is (Settings › Storage › Location)

Android's data can live outside Avo's own storage, for example in a folder on
an external drive taken from Mac to Mac. `AvoPaths.data` is the data folder:
`vm/`, unless `data-location.json` (Application Support, written by the
daemon only) names another. That record keeps the folder's path, a bookmark,
the volume's name and UUID, the path inside the volume and the folder's id,
so a renamed or re-mounted volume is found again (`StorageLocations.resolve`).
Every holder of an `AvoPaths` sees a change at once (the path is read from
the record, cached by the file's identity).

- **What travels** (`AvoPaths.portableDataItems`, in a folder named
  `Avo Android Data`): `userdata.img`; `cuttlefish/` with metadata (the
  key to the encrypted data), misc, frp, super, vbmeta and `avo-image.json`;
  `android-data.json`, `data-disk.json`, `fingerprints.json`,
  `google-apps-commit.json`; and `avo-data.json` (`AndroidDataManifest`:
  format version, id, the newest Android and build that used it, disk size,
  whether Android created its storage and has Google apps, created and
  last-used dates, the last Mac, Avo's version; stamped at every start).
  Everything else is the Mac's: settings, the apps list and shims, key
  mappings, images, the ADB key, `identity.prop`, `avo_config.img`, the GPU
  fallback, and avo-vmm's frames, logs and lock (`--instance vm/cuttlefish`;
  the disks go to `--disks <data>/cuttlefish`).
- **Changing** (`changeStorageLocation`, Android stopped first): *move*
  copies into `.avo-moving` beside the destination (an APFS clone on one
  volume, else a copy that skips holes, F_NOCACHE, F_FULLFSYNC), reads every
  copied byte back and compares SHA-256 digests of the nonzero 1 MiB blocks,
  renames the items into place with the data disk last, switches, and only
  then removes the old copy unless it is kept; *use existing* adopts a folder
  Avo made (carried from another Mac); *start fresh* makes an empty folder
  with a new manifest. Starts wait meanwhile (`StorageProblem.changing`).
- **Checkpoints on a move** (`CheckpointsMove`): they come along as clones
  when the data stays on its volume, and as verified copies (each clone's
  blocks again) on another APFS volume when the free space holds them beside
  the data; each checkpoint folder is renamed into place whole, before the
  data disk. Off APFS (where none could be restored) or without room they
  stay with the old copy: the sheet says how many and why, keeps the old
  copy by default, and a move that keeps none deletes them only with
  `leavesCheckpoints` (the daemon refuses it otherwise, before anything
  changes). Replacing or removing the copy in Avo's own storage says how
  many checkpoints go with it.
- **Left behind.** A move notes the folder it copies into
  (`data-moves.json` in Application Support) until its copy is in place or
  gone. As the daemon starts, once a restore cut short is finished and while
  no move runs, the staging folders that work left go (`.avo-moving`, which
  on a drive without sparse files is as big as the data disk, with the
  folder the move made when it is empty; `.avo-restoring`), also those in
  Avo's own storage and the data's folder from before moves were noted. A
  noted drive that isn't connected is looked at again at the next start,
  for a month.
- **Checks** (`inspect`): FAT, network volumes, read-only volumes,
  cloud-synced folders and Avo's own folder are refused; exFAT and Mac OS
  Extended (no sparse files) and other formats warn; free space is checked
  against what a move copies. Data from a newer Android than every image on
  the Mac, in a newer format, or without its metadata disk is refused;
  `CuttlefishImage.prepareStart` never starts an older Android on newer data.
- **A drive that is gone.** Before every start (`VMManager`'s preflight) the
  folder must be found: else the start fails with "Android's storage is on
  “…”, which isn't connected", nothing is created where it was, and the
  Library and Settings › Storage offer Choose Another… and Use Avo's Own
  Storage (the copy kept there, or a fresh start). DiskArbitration
  (`DiskArbitrationWatcher`, `VolumeGuard`) refuses an unmount or eject of the
  data's volume while Android uses it or a move copies there; Android powers
  off cleanly and the user ejects again. A volume that goes without asking
  stops Android at once.
- **Room for Android's writes.** On a full volume avo-vmm holds Android's
  writes instead of failing them (engine.md, "A full Mac disk") and says
  `disk full on|off`; the daemon (`DiskSpaceEngine`, `watchStorageSpace`)
  puts that in `StorageLocationStatus.space`, and while Android runs it
  looks at the data's volume once a minute and says so below 2 GB free
  (`StorageSpace.lowBytes`). The Library's banner and Settings › Storage
  show it, with System Settings › Storage for the Mac's disk or the drive in
  Finder; a stopped Android shows nothing.
- **Reset Android** erases the data where it is, then Avo's side of it (the
  apps and shims, Google apps, the fingers in Android). It is refused while
  the data can't be reached (Avo would forget every app while the data stays
  on the drive) or its place changes (the data disk a move copies would come
  back at the new place), before and again after Android stops. The data
  disk goes first, and a reset that can't remove it changes nothing; the
  snapshots, checkpoints and records that stay are named in its error.
- **macOS's permission.** The daemon (and avo-vmm, which it starts) reads
  and writes the folder; on a removable volume macOS asks once whether
  "Avo" may (`NSRemovableVolumesUsageDescription` in Avo.app's and the
  daemon's Info.plist). The Control Panel explains it just before the daemon
  first looks at a drive. Don't Allow, or the permission turned off later,
  is `StorageProblem.notPermitted` (also when avo-vmm is the one refused),
  with a button to System Settings › Privacy & Security › Files & Folders;
  the panes look again when Avo becomes active.
- **A new Mac.** The Setup Assistant's Welcome offers Use Android Data from
  Another Mac…: the daemon looks at the folder, the Mac switches to it
  before Android's first start (so no fresh data is made in Avo's own
  storage), and the Android step chooses a version that can use the data
  (`rowFitting`: the same Android version, else the oldest newer one),
  downloading it when the Mac has none (`allowNewerAndroid` lets Setup adopt
  data whose Android is not on the Mac yet). `avoctl storage …` does the same
  from the command line.

## Checkpoints (Settings › Android › Checkpoints)

Restore points of Android's apps and data, beside the data wherever it is
(`CheckpointStore`, `DaemonCheckpoints.swift`):

```
<data>/checkpoints/<id>/checkpoint.json   Checkpoint: reason, date, the Android that used the data,
                                          and the settings that belong to it (root, Google apps,
                                          device profile and its hardware); written last
<data>/checkpoints/<id>/userdata.img …    AvoPaths.portableDataItems, without avo-data.json
```

- **Clones only.** Every item is an APFS clone (`clonefile`): a checkpoint is
  made in a moment and shares its blocks with the data until Android changes
  them. The list shows what only each one takes (`CheckpointStatus.ownBytes`,
  the blocks no clone shares, getattrlist's `ATTR_CMNEXT_PRIVATESIZE`): what
  deleting it frees. There is no copy fallback (a copy of the data disk takes minutes and
  as much space again): with the data on a drive that cannot clone, the pane
  says so (`CheckpointStatus.problem`) and Avo makes none.
- **While Android runs.** `makeCheckpoint` has Android `sync` over adb (at
  most 20 s; without it the checkpoint is as after a power loss), then
  `VMManager.holdingStill` stops its vCPUs for the clone and lets them go on,
  the guest clock adjusted as after a pause; the status does not change. A
  stopped or paused Android needs no hold. avo-vmm handles every virtio-blk
  request on the vCPU that notified it, and its retrier of writes that wait
  for room takes no try during a pause, so no write is half done while the
  vCPUs are stopped; each item is fsynced before it is cloned.
- **Automatic checkpoints** come before a change Android cannot take back:
  root turned on and another device profile or its hardware
  (`updateConfiguration`), Google apps installed or removed (after the
  checks, before the download), the first start of a newer Android than the
  data was last used with (`bootVM`, from `android-data.json` and the image
  that starts, which would upgrade the data for good), and a restore. None
  when Android has no data yet or the drive cannot clone; a failure is
  logged and the change goes ahead. The newest five automatic ones stay
  (`CheckpointStatus.automaticLimit`); the user's own stay until deleted.
- **Restore** (`restoreCheckpoint`): refused for data from a newer Android
  than the image that starts. Android stops; its data now becomes a `restore`
  checkpoint (so the restore can be undone); the checkpoint's items are
  cloned into `.avo-restoring` beside the data, then replace it with the data
  disk last, and items the checkpoint did not have (Google apps installed
  after it) go. The checkpoint stays. The settings it kept come back, the
  data disk's size follows what Android said of it, fingers reload, and
  Android starts again when it ran; the apps list follows at that start
  (`syncApps`). A restore that fails before it changed anything starts a
  running Android again.
- **A restore cut short** (Avo quit, the Mac stopped, the drive went) could
  pair one side's metadata disk, the key, with the other's data disk, which
  Android then cannot decrypt. `checkpoint-restore.json` beside the data
  (`RestoreJournal`: the checkpoint and the one made before) is written,
  fully synced, once the clones are made and before the first rename, and
  removed once the settings followed. The daemon finishes it as it starts,
  and every start does first (`prepareCheckpointsForStart`, before the
  settings the boot reads): the checkpoint is restored again (it is whole),
  else the one before undoes it. Until one works, `prepareForStart` refuses
  every start, a move refuses to carry the data, no checkpoint is made of it
  and neither checkpoint can be deleted; restoring a checkpoint again or
  Reset Android puts it right.
- **What erases them.** Reset Android and Android's own factory reset take
  the checkpoints with the data. Moving the data takes them along where they
  can be restored ("Checkpoints on a move" above); those that can't stay with
  a kept old copy, or go with one the user lets go. `avoctl checkpoints`
  lists, creates, restores and deletes them.
- **Quick boot** (a snapshot of the running VM's memory and devices) is not
  part of checkpoints; see engine.md, "Quick boot".

## The shared folder (Settings › Storage › Shared Folder)

A folder on the Mac that Android sees as “Avo Shared” in its storage
(`/sdcard/Avo Shared`), both ways and without copies. Off by default;
`VMConfig.shareFolder` and `sharedFolderPath`, which take effect when Android
next starts (the engine's devices are fixed for a start).

**Why virtio-fs.** The guest kernel (GKI 6.12) has `CONFIG_VIRTIO_FS=y`,
`CONFIG_FUSE_FS=y`, and neither 9p's virtio transport nor `CONFIG_9P_FS`.
avo-vmm therefore serves the folder itself as a virtio-fs device with a small
FUSE server (engine.md, "Shared folder"). The alternative, syncing copies over
adb driven by FSEvents and inotify, would keep every file twice, lag behind,
and need conflict rules; with virtio-fs there is one copy, Android's writes
are on the Mac when the call returns, and the Mac's appear in Android within
the one-second cache time (names and attributes; the page cache is dropped
at every open and whenever the size or modification time changes). There are
no conflicts to resolve: both sides change the same files, as two programs on
one Mac would. File sizes are the Mac volume's (one read or write moves up to
1 MiB; about 0.8 GB/s read and 0.3 GB/s written on the test VM for 32 MB).

**In Android** (`SharedFolderBridge`, run by HostAgent after every start):

- It waits for user 0's credential-encrypted storage
  (`sys.user.0.ce_available`; a screen lock not entered yet keeps it
  locked), then mounts the device (tag `avo_shared`) at `/mnt/avo_shared`
  with `context=u:object_r:media_rw_data_file:s0` (Android's own media
  storage label; the images run SELinux permissive in any case) and binds it
  over `/data/media/0/Avo Shared`, the lower file system MediaProvider serves
  as `/sdcard`. `/data` is a shared mount and the apps' namespaces are its
  slaves, so MediaProvider (and its FUSE passthrough path) sees the mount at
  once. A non-empty "Avo Shared" Android already had is kept as
  "Avo Shared (Android)". With sharing off, an empty leftover folder goes.
- **Permissions**: the server presents every file as media_rw's (1023),
  directories 0770 and files 0660, so MediaProvider (in that group) and root
  reach everything and the kernel's `default_permissions` check passes;
  chmod and chown from Android change nothing. What Android creates belongs
  to the Mac user (0644, 0755). Scoped storage is MediaProvider's as for any
  other folder: file pickers (DocumentsUI) and apps with media or all-files
  access see the files.
- **The media index**: files Android writes are indexed by MediaProvider
  as usual. The Mac's changes reach it through FSEvents on the folder:
  after a second's quiet the bridge asks MediaProvider to look at each
  changed folder again (`content call --uri content://media/ --method
  scan_file --arg <folder>`, which also drops what was renamed or removed;
  more than eight folders, or dropped events, scan the whole folder), and
  once after mounting for what changed while Android was off. A paused
  Android hears of them when it goes on.
- **Unmounting** is not done: MediaProvider keeps the folder open, so it
  stays until Android stops.
- **Limits**: a guest reboot from inside Android drops the mount until the
  next start; symlinks are shown as symlinks and resolved in Android, never
  on the Mac (so one pointing elsewhere on the Mac leads nowhere); macOS's own
  files (.DS_Store, "._" AppleDouble files, .Trashes, …) are left out of
  listings; APFS is usually case-insensitive, so "a.txt" and "A.txt" are one
  file, as on the Mac.

**Permission on the Mac.** The daemon looks at the chosen folder first
(`inspectSharedFolder`, `SharedFolderInspector`), which is what makes macOS
ask in Avo's name about Documents, Desktop, Downloads or a drive; the Control
Panel says so before it asks, as for Android's data. avo-vmm, the daemon's
child, then has the same access. Problems are `SharedFolderProblem`:
missing folder or volume (Android starts without it; avo-vmm leaves the
device out), not a folder, not permitted (with a button to Files & Folders),
or Avo's own folder or Android's data, which cannot be shared. The pane
shows what the running Android does with it (`SharedFolderStatus.mount`:
waiting for the screen lock, mounted, unavailable this start, failed).

## Testing

`swift test` in `host/AvoKit` runs the host's unit and integration tests
(about 850), including daemon integration
tests against a fake engine, a fake Bridge Agent speaking the real Control
protocol, a fake input sink and a fake adbd that verifies real RSA signatures:
boot → app sync → shims → displays → input routing → XAPK install with OBB →
uninstall → notifications → configuration rules → crash handling → version
mismatch. The Bridge Agent build runs a JVM test that decodes Input records
written by the Swift encoder (`proto/testdata/input-v1.bin`).
