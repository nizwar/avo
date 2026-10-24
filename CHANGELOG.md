# Changelog

All notable changes to Avo are listed here. Versions follow
[Semantic Versioning](https://semver.org), and every build carries a build
number (`CFBundleVersion`) that only goes up; see
[docs/versioning.md](docs/versioning.md). Releases up to build 113 were
named "Preview N".

## 0.3.1 Preview 4 (build 113)

OpenGL ES 3.2 for the games that need it, key mappings where one key does
several things, and an emulated phone that now names its own hardware,
memory and build. Frames also reach the window with less work, and Avo asks
Android about its notifications less often. Install it over Preview 3; your
Android data stays.

### New

- **OpenGL ES 3.2.** With the GPU renderer, apps now get OpenGL ES 3.2, so
  games that ask for it start. Everything 3.2 offers is there except
  geometry shaders, which Apple's GPUs have no stage for. Settings ›
  Graphics › OpenGL ES picks a lower version (3.1, 3.0 or 2.0) to try an app
  as on a weaker phone; it applies after Android restarts.
- **One key, several actions.** A control can also switch the key mapping to
  another mode and free, lock or toggle the mouse, in the order you list
  them: F can press the game's Enter Vehicle button and switch to the
  vehicle's controls. Select a control to see everything it does, reorder
  or remove its actions, or add one; they show as badges beside it on the
  game.
- **Hotkeys and click areas.** A hotkey is a key that only does its actions.
  A click area, sized on the game, does them when you click it with the
  mouse free, and its click can reach the game or not. The separate Switch
  Mode and Free/Lock the Mouse controls are gone: key mappings that had them
  keep working, their keys turned into actions or hotkeys.
- **Controls by kind of game.** The key mapping panel offers its controls as
  General, FPS and MOBA, and lists a mode's controls the same way.
- **The emulated phone's hardware name, memory and build.** With Emulate this
  phone's hardware on, Android reports the phone's hardware name (qcom on a
  Snapdragon), gets the phone's RAM as far as the Mac allows, and names the
  phone's whole build, partition by partition. The Infinix X6878 carries all
  of it, read from a real phone.

### Improved

- **Smoother frame delivery.** The GPU renderer copies each frame straight
  into the memory the window reads, on a thread of its own, instead of
  holding up Android's graphics commands for about a millisecond a frame and
  copying the frame twice on the CPU.
- **Fewer interruptions while Android draws.** Android no longer signals the
  GPU device for each command while that device is busy with the ones
  before (about a quarter fewer signals, each of which stops a processor).
- **Less polling.** A notification that stays in Android is read again every
  10 seconds instead of every 2; new ones still reach the Mac at once.

### Fixed

- Snapdragon 8 Gen 3 phones had their CPU clusters the wrong way round: they
  now have three Cortex-A720 at 3.15 GHz and two at 2.96 GHz, and the Galaxy
  S24 Ultra's Cortex-X4 runs at 3.39 GHz.

### Known issues

- Bluetooth headsets and other classic Bluetooth devices, Bluetooth pairing
  with the Mac's devices, and calls or SMS on the SIM don't work yet.
- Some apps with anti-tamper protection close right after opening while
  Settings › Privacy & Security › Emulate this phone's hardware is on; turn
  it off for them.
- Root access may not start Android once Google apps are installed in it;
  Avo then turns root back off.
- Delta Force draws its terrain flat at the Ultimate and MAX presets; at
  High and below it is textured (restart the game after changing the
  preset). With software rendering its 3D scenes show wrong colors.
- OpenGL ES 3.2 has no geometry shaders, and a texture border color other
  than black, white or transparent is drawn as the nearest of those.
- With Emulate this phone's hardware on, Android takes the phone's RAM
  (12 GB for many gaming phones). With other heavy apps running, macOS may
  start swapping and games stutter; Avo does not yet give memory Android no
  longer uses back to the Mac.
- With Android's data on an external drive, macOS asks again after an update
  whether Avo may use the drive, and Android starts only once you allow it.
- Apps that need hardware attestation (most banking apps, some DRM and
  anti-cheat systems) generally do not run.
- Each game loads more slowly the first time after the update: the Mac
  compiles its shaders again for Avo's updated GPU renderer.

## 0.3.1 Preview 3 (build 107)

A small fix on top of Preview 2: on an app's page, the Resolution in the
quick Graphics card now follows the preset — the 720p–4K picker only under
Games, and the phone's screen (Phone) or the window's (Apps) shown rather
than set — instead of always showing the picker and quietly switching the
app to a fixed resolution. Install it over Preview 2; your Android data stays.

### Fixed

- The app page's quick Resolution control no longer forces Fixed mode when
  the app is on the Phone or Apps preset; it matches All Graphics Settings.

## 0.3.1 Preview 2 (build 105)

The first notarized Avo: it opens like any app, with no "Open Anyway" in
System Settings. It also moves to new identifiers, learns to update itself
from GitHub, adds a Phone graphics preset, and fixes a batch of window and
daemon bugs. Install it over 0.3.0 Preview 1; your Android data stays.
Because the identifiers changed, macOS asks once more for the camera,
microphone, location and Bluetooth, and app widgets are re-created.

### New

- **Notarized, Developer ID signed.** No more confirming the first launch:
  Gatekeeper calls Avo "Notarized Developer ID", even offline.
- **Avo updates itself.** It checks its own GitHub releases (Avo › Check for
  Updates…, or on its own about once a day) and installs a newer build with
  Sparkle, offering to stop Android first so open games save.
- **Phone graphics preset.** Beside Apps and Games, a Phone preset gives an
  app the screen of the device profile under Settings › Privacy & Security,
  at its own density, and opens it in the orientation it asks for.
- **Android's own screen follows your settings.** The screen Android lays its
  resources out on (and that apps read) now takes its size and density from
  your graphics settings, or from the emulated phone, instead of a fixed one.
- **Infinix X6878** joins the device profiles.

### Changed

- **New identifiers (`com.avodroid`).** A one-time move from the old ones;
  Avo copies your settings over. Permissions are asked once more and widgets
  are re-created, as above.

### Fixed

- The menu bar no longer stays stuck below the notch over other apps' full
  screen after Avo quits.
- Game Controls (and the other title-bar menus) open again in full screen
  instead of hiding the bar.
- Resizing a phone-style window no longer jumps.
- The background service no longer crashes while installing an app, and the
  notarized build's service starts cleanly.
- Apps that refuse to run when they find a graphics layer in
  `/data/local/debug` (such as FLUJO) see none: the layer now rides inside
  the driver.

## 0.3.0 Preview 1 (build 79)

Bluetooth without the Android Emulator, checkpoints of Android's apps and
data, Run in Background, phone-style app windows, games recognized from
Android, a question before a game quits, and a key mapping editor that
leaves the game its whole window. Signed ad hoc and not notarized like the
earlier previews: macOS asks you to confirm the first launch (System
Settings › Privacy & Security › Open Anyway). Install it over 0.2.0
Preview 3; your Android data stays.

### New

- **Bluetooth built in.** Android's Bluetooth runs on Root Canal, the
  virtual controller Android's own emulators use, which Avo now ships (built
  from source): no Android Studio or Android Emulator needed. Android finds
  the Bluetooth LE devices your Mac sees, such as watches, sensors and
  beacons (Settings › Devices › Bluetooth).
- **Run in Background.** A blue light beside the window's own three (also
  Window › Run in Background) closes the app's windows and its Dock icon
  while the app keeps running in Android. Open it again from the Library,
  the menu bar item or a notification; both say it runs in the background.
- **Phone style.** An app window can show the app's screen alone, with a
  phone's rounded corners; its title bar grows out above it when the pointer
  leaves the screen at the top. Choose it for every app in Settings ›
  Graphics › App windows, or for one app with Phone Style in its Device or
  View menu, or in Quick Settings. Thanks to Gabriel Momoh (@TheGemDev).
- **A question before a game quits.** The red button, Close Window (⌘W) and
  Picture in Picture's ✕ end the game in Android, so Avo asks first: Quit,
  Run in Background or Cancel, with Don't Ask Again (Settings › Graphics ›
  App windows › Ask before quitting a game).
- **Create Key Mapping from the app's page.** The Library's Create Key
  Mapping… (or Edit) opens the game with the key mapping editor over it.
- **Reply from notifications, and Now Playing.** Android's notifications
  bring their buttons to Notification Center: Reply is a text field with
  Send, and the others do what tapping them in Android does. What Android
  plays shows in Control Center and answers the media keys and AirPods.
  Thanks to Gabriel Momoh (@TheGemDev).
- **Checkpoints.** Settings › Android › Checkpoints keeps restore points of
  Android's apps and data: made in a moment, also while a game runs, and
  taking space only as Android changes its data afterwards. Avo makes one by
  itself before turning on root, installing or removing Google apps,
  another device profile, and the first start of a newer Android. Restoring
  one puts back its apps, data and those settings, and keeps what Android
  had as a checkpoint too. Android's data must be on an APFS drive. Thanks to
  Gabriel Momoh (@TheGemDev).
- **Games recognized from Android.** An app whose manifest says it is a
  game uses the Games preset without a key mapping, and opens in the
  orientation it asks for, so portrait puzzle and card games stay upright.
  Thanks to Gabriel Momoh (@TheGemDev).

### Improved

- **The key mapping editor's panel** stands beside the window, so the game
  keeps its whole size while you place controls (in full screen it stays
  inside). Cancel asks before throwing changes away, and Done explains a
  problem in plain words.
- **The title bar** shows the app's name in full after Back, and the blue
  light looks just like the window's own lights.
- **One name for each setting** in Quick Settings, the menus and Settings:
  Preset, Screen size (Window, Fixed, Phone), Upscaling (Sharp, Smooth,
  Pixel art), Show keys on game and Game controls.
- **Every app's settings are in Settings too:** Translate into (General ›
  Translate Screen), Record Android's sound (Devices › Sound) and the
  scrolling default (Devices › Mouse and trackpad). Settings search also
  finds Max FPS, Smooth edges, Preset and more.
- **Quick Settings** has an App bar style card, and a Create Key Mapping
  card for a game without one.
- **Menus** have an icon on every item, and submenus open smoothly in place.
- **The status pill** under the Library always shows Android's state, also
  on an app's page.

### Fixed

- **Recording through Android's audio** (voice recorders, voice chat in
  games such as Call of Duty: Mobile) lost about an eighth of the sound in
  short holes: teammates heard little or nothing. Thanks to Gabriel Momoh
  (@TheGemDev).
- **Some games got only OpenGL ES 2.0** (fewer effects, or none of their
  newer graphics) when Android's own interface or the game's Vulkan started
  before its OpenGL. Every app now gets OpenGL ES 3.1.
- **Apps with strong anti-tamper protection** that closed as they opened in
  GPU mode now start: Avo's graphics helpers left Android's /data/local
  folder.
- **Picture in Picture** showed a black screen.
- **App window titles** were cut short ("F…") while there was room.
- **The status pill** disappeared after the Library window was closed and
  opened again.
- **The menu bar item** offered Start while Android was starting or
  stopping, and Quit Avo did not stick while the Control Panel was open.
- **A game you made a key mapping for** stayed under Apps in the Library
  until Avo restarted.
- **⌥⌘L in a full-screen game** switched to the desktop to show the
  Location window.

### Known issues

- Bluetooth headsets and other classic Bluetooth devices, Bluetooth pairing
  with the Mac's devices, and calls or SMS on the SIM don't work yet.
- Some apps with anti-tamper protection close right after opening while
  Settings › Privacy & Security › Emulate this phone's hardware is on; turn
  it off for them.
- Root access may not start Android once Google apps are installed in it;
  Avo then turns root back off.
- Delta Force draws its terrain flat at the Ultimate and MAX presets; at
  High and below it is textured (restart the game after changing the
  preset). With software rendering its 3D scenes show wrong colors.
- With Android's data on an external drive, macOS asks again after an update
  whether Avo may use the drive, and Android starts only once you allow it.
- Apps that need hardware attestation (most banking apps, some DRM and
  anti-cheat systems) generally do not run.
- Each game loads more slowly the first time after the update: the Mac
  compiles its shaders again for Avo's updated GPU renderer.

## 0.2.0 Preview 3 (build 72)

GPU rendering without Android Studio, modes and running for key mapping,
smoother edges, Android's volume and a shake in every app window, and menus
and settings in Avo's own look. Signed ad hoc and not notarized like the
earlier previews: macOS asks you to confirm the first launch (System
Settings › Privacy & Security › Open Anyway). Install it over Preview 2;
your Android data stays.

### New

- **GPU rendering built in.** Avo ships its own GPU renderer (gfxstream, the
  Vulkan loader and MoltenVK, built from source), so Android draws on your
  Mac's graphics chip without Android Studio or the Android Emulator.
- **Key mapping modes.** A layout can have modes for the game's situations,
  such as on foot and in a vehicle: a Switch control changes the mode with
  its key or controller button, and only that mode's controls answer. One
  key may press several buttons (F gets in the vehicle and switches to its
  mode at once), keys can free the mouse for a map or an inventory and lock
  it again, and the controller follows the modes too.
- **Running with the joystick.** A joystick can have a run key (Shift, for
  example): while it is held, the joystick is pushed further, for games that
  run when it is pushed all the way.
- **Smooth edges.** Anti-aliasing for Android's picture: Fast (FXAA, almost
  free) or High and Ultra (2× and 4× supersampling, the smoothest), in Quick
  Settings, View › Smooth Edges, Settings › Graphics and each app's
  graphics.
- **Android's volume.** A Sound card in Quick Settings and Settings › Sound
  set Android's media volume, under your Mac's.
- **Shake.** Device › Shake (⌃⌘Z) shakes the phone for apps that listen for
  a shake.
- **Android widgets.** Library › Widgets lists the widgets Android's apps
  offer, and each one you add shows live in a panel on your Mac. An open
  app's Dock icon also shows how many notifications it has in Android
  (Settings › Notifications). Thanks to Gabriel Momoh (@TheGemDev).

### Improved

- **The key mapping editor** is a panel beside the game: click the game's
  button and press its key, or drag a control onto the game. The selected
  control's settings are in the panel, among them the eye's sensitivity,
  its aiming sensitivity and vertical look, and an anchor tap reaches within
  a circle you size.
- **The title bar** has fewer buttons: Back, Game Controls, Translate,
  Device (Shake, Rotate, Location, Fingerprint, screenshots and recording,
  Keep on Top) and Quick Settings.
- **Every menu** has Avo's look: in app windows, Quick Settings, the Control
  Panel and the menu bar item.
- **The Library** keeps your games and apps in one place, with All, Games
  and Apps tabs.
- **Settings are easier to read:** a line between settings, the title above
  its choices, explanations behind (?), and plainer names (Max FPS, Smooth
  edges, Sharp upscaling, Preset).

### Fixed

- **PUBG MOBILE's Club pages and end-of-match screen** drew garbage (large
  blue shapes, a black sky, stripes): Android's multisampled images got no
  graphics memory on the Mac. They now get ordinary graphics memory, which
  also fixes antialiased web graphics (WebGL) in other apps.
- **Mouse look with some wireless mice** (with a USB receiver) did nothing:
  Avo listened only to the mouse moved last. Every mouse now turns the
  camera.

### Known issues

- Android's Bluetooth still needs Google's Android Emulator (installed with
  Android Studio).
- Bluetooth headsets and other classic Bluetooth devices, Bluetooth pairing
  with the Mac's devices, and calls or SMS on the SIM don't work yet.
- Root access may not start Android once Google apps are installed in it;
  Avo then turns root back off.
- Delta Force draws its terrain flat at the Ultimate and MAX presets; at
  High and below it is textured (restart the game after changing the
  preset).
- With Android's data on an external drive, macOS asks again after an update
  whether Avo may use the drive, and Android starts only once you allow it.
- Apps that need hardware attestation (most banking apps, some DRM and
  anti-cheat systems) generally do not run.

## 0.2.0 Preview 2 (build 59)

Mobile network and saved-location fixes for Preview 1, and the phone's CPU
when Avo emulates a phone's hardware. Signed ad hoc and not notarized like
the earlier previews: macOS asks you to confirm the first launch (System
Settings › Privacy & Security › Open Anyway). Install it over Preview 1;
your Android data stays.

### New

- **The phone's CPU.** With Emulate this phone's hardware (Settings ›
  Privacy & Security › Device profile), Android also gets the phone's CPU:
  its cores in /proc/cpuinfo, and a cpufreq policy per cluster with the
  phone's frequencies, so apps and games that check the CPU see that phone.
  With fewer Android cores than the phone has (Settings › Performance), its
  fastest are kept. Every core still runs at your Mac's speed.

### Improved

- **Device profiles.** The OnePlus 13 has its Snapdragon 8 Elite CPU (six
  Oryon cores up to 3.53 GHz, two up to 4.32 GHz), and the Redmi Note 11 and
  Redmi A3 report their cores as those phones do.

### Fixed

- **The mobile network** did not work in Preview 1: the SIM never loaded, so
  Android showed no service and had no mobile data. The SIM now loads on the
  network Avo, the status bar shows its type (4G for LTE) and signal, and
  mobile data works.
- **The saved location** reached Android only once it changed: until then,
  apps saw Google's offices in Mountain View. Android now has it from its
  start.
- **Shutting down Android** could, rarely, leave Avo's engine running: a
  virtual processor busy with a device at that moment missed the stop.
- **Root access that did not start Android** made it restart over and over,
  and Avo waited minutes before starting it again. Avo now turns root back
  off, says so in a notification and starts Android without it.
- **The controller panel** opened in the top left corner of the key mapping
  editor and jumped to its place once dragged. It opens in its place.

### Known issues

- Bluetooth headsets and other classic Bluetooth devices, Bluetooth pairing
  with the Mac's devices, and calls or SMS on the SIM don't work yet.
- Root access may not start Android once Google apps are installed in it;
  Avo then turns root back off.
- Delta Force draws its terrain flat at the Ultimate and MAX presets; at
  High and below it is textured (restart the game after changing the
  preset).
- With Android's data on an external drive, macOS asks again after an update
  whether Avo may use the drive, and Android starts only once you allow it.
- Apps that need hardware attestation (most banking apps, some DRM and
  anti-cheat systems) generally do not run.

## 0.2.0 Preview 1 (build 54)

A preview for testers: Android's cameras, Bluetooth, a SIM with mobile data
and root access. Signed ad hoc and not notarized like the 0.1.0 previews:
macOS asks you to confirm the first launch (System Settings › Privacy &
Security › Open Anyway). Install it over 0.1.0; your Android data stays.

### New

- **Cameras.** Settings › Devices › Cameras gives Android a back and a front
  camera, each one emulated, one of your Mac's cameras (built in, USB or
  Continuity Camera) or none. Apps find them as on a phone, and the Mac's
  camera is on only while an Android app uses it. macOS asks for permission
  the first time.
- **Bluetooth.** With Google's Android Emulator installed, Android's
  Bluetooth turns on, and its apps find and use the Bluetooth LE devices your
  Mac sees, like watches, sensors and beacons (Settings › Devices ›
  Bluetooth).
- **Mobile network.** A test SIM in Settings › Devices › Mobile network: the
  status bar shows the network type (5G, 4G, 3G, E or G) and the signal you
  choose, apps read them, and with Wi-Fi off, mobile data reaches the
  internet through your Mac.
- **Network speed and Wi-Fi.** Settings › Devices › Network slows Android's
  connection down to a mobile network's speed and delay, from 5G to GPRS, to
  try an app on a slow connection, and turns Android's Wi-Fi off and on.
- **Root access (Magisk).** Settings › System › Developer › Root access
  downloads Magisk from its GitHub page and starts Android with it: apps can
  ask for root, and Magisk asks you about each one. Android's data stays as
  it is.
- **A location for each app.** Settings › Devices › Location sets the
  location for all apps (Choose… opens the map), kept for the next start. An
  app window's Location panel, with This App, sets one for that app alone,
  which Android reports while its window is in front.
- **A switch for each of the Mac's devices.** Settings › Devices turns
  Bluetooth, the cameras, the microphone and the clipboard on or off for
  Android, next to sharing the Mac's location. Off, Android has no such
  hardware, and Avo never asks macOS for it.
- **Keep on Top button.** A pin in an app window's title bar keeps the app's
  windows above other apps (also View › Keep on Top).

### Improved

- **Resizing a window** keeps Android's display, and a blurred copy of the
  app fills the window around it instead of black bars until the new size
  fades in.
- **Controller mapping** opens from the Controller button of the key mapping
  editor (the title bar's menu no longer has it). Its panel can be resized,
  and clicking a button or stick places its control where touch games
  usually have it.
- **Games that accept only controllers they know,** like Call of Duty:
  Mobile, now take the Mac's controller: Android sees an Xbox Wireless
  Controller.
- **Settings › Devices** puts Wi-Fi, the mobile network, Bluetooth, cameras
  and location in one pane.
- **Translate Screen** is ready at once in every app: one engine in Avo's
  background service reads and translates the screen for all of them. It
  gets ready as Avo starts (Settings › General › Translate Screen), instead
  of each app preparing text recognition for most of a minute. Translations
  move with their text while you scroll, and text translated once, in any
  app, shows translated at once afterwards.

### Fixed

- **Typing in Flutter apps** stopped working after their window was resized:
  Android gave the resized display a new ID. Windows now resize in place.
- **Opening an app** sometimes opened a second window that said “The caller
  is not allowed to talk to the Avo daemon.”
- **Clicking the controller** in the key mapping editor did nothing; only its
  Menu button answered.
- **Ejecting a disk image** stopped Android when its data was on an external
  drive: Avo took the image for the drive.

### Known issues

- Bluetooth headsets and other classic Bluetooth devices, Bluetooth pairing
  with the Mac's devices, and calls or SMS on the SIM don't work yet.
- Some games rate the VM as a low-end device. Delta Force, for example, draws
  flat terrain at its MAX preset; a lower preset looks right.
- Apps that need hardware attestation (most banking apps, some DRM and
  anti-cheat systems) generally do not run.

### Requirements

- A Mac with Apple silicon, macOS 15 or newer.
- For GPU rendering and Bluetooth: Google's Android Emulator (from Android
  Studio or the SDK command-line tools).

## 0.1.0 Preview 2 (build 40)

A preview for testers, signed ad hoc and not notarized like Preview 1: macOS
asks you to confirm the first launch (System Settings › Privacy & Security ›
Open Anyway).

### New

- **Remove Google apps.** Settings › Google Apps › Remove takes Google apps
  out again without Reset Android, keeping your other apps and their data,
  so you can install them again, for example when Google sign-in stopped
  working. It also cleans up when only Google Play's updates of them are
  left, which the pane now points out.

### Fixed

- **Location in apps that use Google Play services.** Most maps, delivery
  and ride apps got no location at all, neither the Mac's nor a place you
  chose: Android never gave Play services location when Google apps were
  added after setup. Avo now grants it, unless you changed it yourself.
- **Closing an app's last window** no longer sends Avo's other windows behind
  other apps: the window behind it comes forward.
- **`flutter run` and Android Studio:** an app they restart over adb opens in
  its window again, instead of staying on Android's own screen.
- **The Setup Assistant** opens at the first launch (it appeared only once
  Settings was opened), and each step fits its window.

### Known issues

- Some games rate the VM as a low-end device. Delta Force, for example, draws
  flat terrain at its MAX preset; a lower preset looks right.
- Camera and Bluetooth are not supported.
- Apps that need hardware attestation (most banking apps, some DRM and
  anti-cheat systems) generally do not run.

## 0.1.0 Preview 1 (build 35)

The first public preview, for testers. It is signed ad hoc and not
notarized, so macOS asks you to confirm the first launch (System Settings ›
Privacy & Security › Open Anyway).

### Highlights

- **Android apps as Mac apps.** Every Android app opens in its own window
  with its own Dock icon, Launchpad and Spotlight entries and ⌘Tab. Full
  screen hides the menu bar and title bar until the pointer reaches the top of
  the screen.
- **Android 17 in its own VM.** Avo boots an unmodified AOSP Cuttlefish image
  on Hypervisor.framework with avo-vmm, Avo's own engine. The Setup Assistant
  downloads the image; Settings › System switches Android versions and keeps
  the previous one to go back to.
- **Older Android versions** (15, 14 and 13) are listed under Older Versions;
  they may not start on Apple silicon.
- **Each Android version keeps its own data.** Changing versions never erases
  anything: you choose the data the new version uses (the data it had
  before, Android data in another folder, or new data in an empty folder),
  and an upgrade can also take the current data along.
- **GPU rendering.** Android draws on the Mac's GPU through gfxstream and
  MoltenVK (from the Android Emulator), with native ASTC textures, a
  persistent shader cache, frame-rate caps of 30, 60, 90 and 120 fps or the
  display's own rate, render scale, sharpening, and per-app graphics settings.
  Without the Android Emulator, Android renders in software.
- **Games.** Key mapping on a game's touch controls with templates for
  shooters, MOBAs and racing games, shooter mode with mouse-look, game
  controllers with a visual editor, and shareable profiles.
- **Mac integration.** Notifications in Notification Center, a shared
  clipboard, links in the Mac's browser, drag and drop, screen translation
  (⌘⇧T), screenshots and recordings with sound, Keep on Top and Picture in
  Picture, and Android following the Mac's appearance, time zone, clock,
  language and battery.
- **Devices for apps.** Location from the Mac or a place or route you pick, the
  Mac's microphone, mock fingerprints, a shared folder between the Mac and
  Android, device profiles, and Android's data on an external drive if you
  like.
- **Control Panel.** App library, Settings in one window, System Status (CPU,
  memory and GPU per app), install from `.apk`, `.xapk`, `.apkm` and `.apks`
  files, optional Google Play (MindTheGapps), ADB support for `adb` and
  Android Studio, and Help › Report a Problem.
- **Menu bar and power.** A compact menu bar panel; Android pauses itself when
  idle (Settings › Performance) and resumes the moment anything uses it.

### Fixed since the internal builds

- Sound: playback runs on the device's own clock in 20 ms periods, so games no
  longer sound robotic or delayed, and it no longer stays silent after the
  Mac's audio queue runs dry (opening a second app, switching apps, or the
  first sound of a game).
- Sound: apps in different windows keep playing at the same time (Android's
  multi audio focus), and an app's window becoming key on the Mac moves
  Android's focus to it, so games that mute when unfocused play again.
- Sound: games that ask for 8-channel output (Call of Duty: Mobile, Delta
  Force's voice chat) get stereo instead of failing.
- Android's own factory reset and reboot work and bring Android back up;
  factory reset protection never locks Android after a reset.
- The first boot of a new Android image no longer reports a false GPU failure.
- A display re-plug no longer crashes SurfaceFlinger.
- Android's Thread radio service no longer restarts every few seconds (the
  VM has no Thread radio).
- Closing an app's last window ends the app (like a force stop), and its
  window no longer opens again by itself (Google Play, Settings).
- The Google apps install shows one realistic progress bar across its steps.
- Menus and pop-up buttons in Settings, and the menu bar panel's position.

### Notes for testers of internal builds

- Avo.app's bundle identifier is now `com.avodroid.emulator` (it was `dev.avo.Avo`).
  Its preferences move over at the first launch; macOS may ask again for
  permissions the Control Panel had.

### Known issues

- Preview builds do not update themselves; install a newer DMG over this one.
- Some games rate the VM as a low-end device. Delta Force, for example, draws
  flat terrain at its MAX preset; a lower preset looks right.
- Camera and Bluetooth are not supported.
- Apps that need hardware attestation (most banking apps, some DRM and
  anti-cheat systems) generally do not run.

### Requirements

- A Mac with Apple silicon, macOS 15 or newer.
- For GPU rendering: Google's Android Emulator (from Android Studio or the SDK
  command-line tools).
