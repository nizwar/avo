# Changelog

All notable changes to Avo are listed here. Versions follow
[Semantic Versioning](https://semver.org); preview builds carry a build
number (`CFBundleVersion`) that only goes up.

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
