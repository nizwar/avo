import AppKit
import AvoHazeUI
import AvoKeymapUI
import AvoKit
import os

/// Entry point called by the App Shim loader (AvoShim/main.swift) after it
/// loads this framework from Avo.app.
@_cdecl("AvoShimMain")
public func AvoShimMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    MainActor.assumeIsolated {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let package = info[AvoIdentifiers.shimPackageInfoKey] as? String else {
            NSLog("Avo: this shim has no \(AvoIdentifiers.shimPackageInfoKey); recreate shortcuts in Avo")
            exit(2)
        }
        let label = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? package
        let arguments = Array(CommandLine.arguments.dropFirst())
        let notificationKey = arguments.firstIndex(of: "--notification-key").flatMap {
            arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
        }
        let app = NSApplication.shared
        let delegate = ShimAppDelegate(package: package, label: label, notificationKey: notificationKey,
                                       editKeyMapping: arguments.contains(ShimRequest.editKeyMappingArgument))
        ShimAppDelegate.retained = delegate
        app.delegate = delegate
        // No setActivationPolicy(.regular): the bundle is a regular app
        // already, and the call brings it to the front even when it was
        // opened in the background (a notification, `open -g`).
        app.run()
    }
    return 0
}

/// One App Shim process = one Android app in the Dock (spec §4). Each window
/// of the app is an Android VirtualDisplay.
@MainActor
final class ShimAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    static var retained: ShimAppDelegate?

    let package: String
    let label: String
    private var pendingNotificationKey: String?
    /// The Control Panel asked for the key mapping editor before the daemon
    /// answered (ShimRequest): the first window opens it.
    private var pendingEditKeyMapping: Bool
    private let frames = FrameRouter()
    private var client: DaemonClient?
    /// The daemon answered `hello`: a window may open its display. Until
    /// then the launch's window is on its way, and a reopen (a Dock click, or
    /// a second request to open the app while it starts) must not open
    /// another: its display would be asked for before the daemon knows the
    /// shim, and refused ("The caller is not allowed…").
    private var connected = false
    private(set) var config = VMConfig()
    /// Android lists this app as a game: its windows use the Games profile by default.
    private(set) var isGame = false
    /// The orientation such a game asks for, which its windows open in.
    private(set) var orientation: VMConfig.Orientation?
    /// The device profiles (they never change while the daemon runs): the
    /// chosen one's screen is what "Phone's screen" gives Android.
    private(set) var profiles: [DeviceProfile] = []
    private var windows: [AndroidWindowController] = []
    /// The app is quitting, which may wait for screen recordings to finish
    /// (`applicationShouldTerminate`). Meanwhile the app's windows close and
    /// Android stops it, and asking to quit again then would make AppKit
    /// quit at once, cutting a recording short; nor does a window open again.
    private var quitting = false
    /// Events for displays whose window is still waiting for `openDisplay`
    /// to return: the guest reports a display ready before the call ends.
    private var earlyEvents: [UInt32: [DaemonEvent]] = [:]
    /// Files dropped on the Dock icon before the app had a window (it was
    /// just starting): the first window takes them.
    private var filesToShare: [URL] = []
    /// Android's status as the daemon last said (see "Screen lock").
    private(set) var androidStatus = VMStatus.stopped
    /// Where the engine keeps what Android plays: recordings take their sound from it.
    private(set) var audioTap: AudioTapLocation?
    /// How many notifications the app has in Android (its Dock badge).
    private var notificationCount = 0
    /// Avo's appearance on this app's windows, changed in the Control Panel.
    private var appearance: HazeAppearanceFollower?
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Shim")

    init(package: String, label: String, notificationKey: String?, editKeyMapping: Bool) {
        self.package = package
        self.label = label
        self.pendingNotificationKey = notificationKey
        pendingEditKeyMapping = editKeyMapping
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The haze's typefaces are in Avo.app, wherever this shim runs from.
        QuickHaze.fontDirectories = [AndroidWindowController.hostApplication?.appending(path: "Contents/Resources")].compactMap { $0 }
        // Light, dark, or as the Mac (Settings › General › Appearance).
        appearance = HazeAppearanceSetting.avo.followInApp()
        buildMenu()
        // What the Control Panel asks of this app while it runs (ShimRequest).
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(editKeyMappingRequested), name: ShimRequest.editKeyMapping, object: package)
        distributed.addObserver(self, selector: #selector(preferencesChanged), name: ShimRequest.preferencesChanged, object: package)
        let version = Bundle(for: ShimAppDelegate.self).object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let client = DaemonClient(role: .shim(package: package), version: "avo-shim \(version)", frameReceiver: frames)
        self.client = client
        Task {
            do {
                androidStatus = try await client.hello().status
                if let snapshot = try? await client.configuration() {
                    config = snapshot.config
                    profiles = snapshot.profiles
                    isGame = snapshot.games?.contains(package) == true
                    orientation = snapshot.gameOrientations?[package]
                }
                ShimFingerprints.shared.connect(client)
                LocationModel.shared.connect(client)
                connected = true
                let window = openWindow(notificationKey: pendingNotificationKey)
                pendingNotificationKey = nil
                if pendingEditKeyMapping {
                    pendingEditKeyMapping = false
                    window.editKeyMappingWhenReady()
                }
                for await event in client.events { handle(event) }
                daemonGone()
            } catch {
                logger.error("cannot reach the daemon: \(error.localizedDescription, privacy: .public)")
                let window = openWindow(notificationKey: nil, connect: false)
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                window.showProblem(message)
                // Files dropped on the Dock icon as the app started go nowhere either.
                if !filesToShare.isEmpty {
                    filesToShare = []
                    window.showNotice(String(localized: "Could not share the files: \(message)", bundle: .windowHost))
                }
            }
        }
    }

    /// The daemon went away (it restarted, or crashed), and the engine with
    /// it: Android and this app in it are gone, and this connection does not
    /// come back. Run in the background, the app quits at once, as nobody
    /// sees it; otherwise its windows say so, with nothing left in them that
    /// acts on the app, and closing them quits.
    private func daemonGone() {
        connected = false
        notificationCount = 0
        updateDockBadge()
        guard !quitting else { return }
        if inBackground {
            NSApp.terminate(nil)
            return
        }
        for window in windows { window.daemonGone() }
    }

    @discardableResult
    func openWindow(notificationKey: String?, connect: Bool = true) -> AndroidWindowController {
        let controller = AndroidWindowController(app: self, frames: frames)
        windows.append(controller)
        controller.showWindow(nil)
        if connect, let client {
            controller.attach(client: client, notificationKey: notificationKey)
            if !filesToShare.isEmpty {
                controller.share(filesToShare)
                filesToShare = []
            }
        }
        return controller
    }

    /// A window closed (its `windowWillClose`).
    func windowClosed(_ controller: AndroidWindowController) {
        windows.removeAll { $0 === controller }
        // The last window closing ends the app, by Android or by the user
        // (Close, ⌘W): it quits, and the daemon force-stops it in Android
        // (DaemonCore.closeDisplay).
        guard windows.isEmpty else { return }
        // Left to itself, macOS activates whichever app it last saw active,
        // which is often not the one whose window was right behind (a window
        // Android opened in the background never was): every other window
        // would drop behind it.
        if NSApp.isActive { Self.activateWindowBehind() }
        guard !quitting else { return }
        // Once the window has gone: asked from its `windowWillClose`, a quit
        // that waits for a recording held the window on screen, frozen.
        quitting = true
        Task { NSApp.terminate(nil) }
    }

    /// Hands activation to the app owning the frontmost window of another
    /// process, as closing a window within one app brings up the next.
    private static func activateWindowBehind() {
        let own = ProcessInfo.processInfo.processIdentifier
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        for info in windows {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Double],
                  (bounds["Width"] ?? 0) > 1, (bounds["Height"] ?? 0) > 1,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { continue }
            _ = app.activate(from: .current)
            return
        }
    }

    private func handle(_ event: DaemonEvent) {
        if case .vmStatus(let status) = event { androidStatusChanged(status) }
        switch event {
        case .displayReady(let id), .displayClosed(let id), .displayTitle(let id, _), .orientationRequest(let id, _):
            if let window = window(for: id) {
                deliver(event, to: window)
            } else {
                earlyEvents[id, default: []].append(event)
            }
        case .vmStatus(let status) where status.state == .failed || status.state == .stopped:
            for window in windows {
                window.stopRecording()
                window.showProblem(status.detail ?? String(localized: "Android stopped.", bundle: .windowHost))
            }
        case .configurationChanged(let config):
            let old = self.config
            self.config = config
            for window in windows { window.configurationChanged(from: old, immediate: false) }
            updateDockBadge()
        case .appStopped(let stopped) where stopped == package:
            // Force stopped in the Control Panel: Android already ended it.
            if !quitting { NSApp.terminate(nil) }
        case .fingerprints(let status):
            // The windows' fingerprint menus (FingerprintMenu.swift).
            ShimFingerprints.shared.update(status)
        case .audioTap(let location):
            audioTap = location
        case .notificationCount(let counted, let count) where counted == package:
            notificationCount = count
            updateDockBadge()
        case .location(let status):
            // The Location panel and Quick Settings (LocationPanel.swift).
            LocationModel.shared.update(status)
        default:
            break
        }
    }

    private func deliver(_ event: DaemonEvent, to window: AndroidWindowController) {
        switch event {
        case .displayReady:
            window.displayReady()
        case .displayClosed:
            // The Android task finished (e.g. the app called finish()).
            window.closeFromGuest()
        case let .displayTitle(_, title):
            window.showActivityTitle(title)
        case let .orientationRequest(_, orientation):
            window.applyOrientation(orientation)
        default:
            break
        }
    }

    /// Sets (nil removes) this app's own graphics settings from a window's
    /// View menu or Quick Settings. Every window adjusts right away; the daemon then saves it
    /// and broadcasts it back, which changes nothing more. When saving fails
    /// the windows go back to what the daemon has.
    func applyLocalOverride(_ override: AppGraphicsOverride?) {
        let old = config
        config.graphicsOverrides[package] = override
        guard config != old else { return }
        for window in windows { window.configurationChanged(from: old, immediate: true) }
        guard let client else { return }
        let package = package
        save(failure: { String(localized: "Couldn't save the graphics settings: \($0)", bundle: .windowHost) }) {
            try await client.setAppGraphics(override, for: package)
        }
    }

    /// Sets Android's frame rate cap, for every app, from a window's Quick
    /// Settings: the same way as an override above. A cap that needs
    /// Android at another display rate says it waits for a restart.
    func applyFrameRateLimit(_ fps: Int) {
        let old = config
        config.fpsLimit = fps
        guard config != old else { return }
        for window in windows { window.configurationChanged(from: old, immediate: true) }
        guard let client else { return }
        save(failure: { String(localized: "Couldn't save the frame rate cap: \($0)", bundle: .windowHost) }) { [weak self] in
            let result = try await client.setFrameRateLimit(fps)
            if result.effect == .restartRequired, let self {
                let target = windows.first { $0.window?.isKeyWindow == true } ?? windows.first
                target?.showNotice(String(localized: "Android runs at \(fps) fps after it restarts.", bundle: .windowHost))
            }
            return result
        }
    }

    /// Has the daemon save a change the windows show already. When it
    /// cannot, says why and goes back to what the daemon has.
    private func save(failure: @escaping (String) -> String, _ call: @escaping () async throws -> ConfigUpdateResult) {
        Task {
            let problem: String?
            do {
                problem = try await call().issues.first { $0.severity == .error }?.message
            } catch {
                problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            guard let problem else { return }
            logger.error("cannot save settings: \(problem, privacy: .public)")
            let target = windows.first { $0.window?.isKeyWindow == true } ?? windows.first
            target?.showNotice(failure(problem))
            guard let snapshot = try? await client?.configuration() else { return }
            let before = config
            let wasGame = (isGame: isGame, orientation: orientation)
            config = snapshot.config
            profiles = snapshot.profiles
            isGame = snapshot.games?.contains(package) == true
            orientation = snapshot.gameOrientations?[package]
            for window in windows { window.configurationChanged(from: before, immediate: true, wasGame: wasGame) }
        }
    }

    /// The device profile chosen in the Control Panel; its screen sizes
    /// windows in the phone's-screen mode (nil for Avo's own identity).
    var deviceProfile: DeviceProfile? { profiles.first { $0.id == config.deviceProfileID } }
    var deviceDisplay: DeviceProfile.Display? { config.deviceDisplay(in: profiles) }

    /// The number on the Dock icon, as a phone's launcher shows it (Settings › Notifications).
    private func updateDockBadge() {
        let label = config.dockBadges && notificationCount > 0 ? notificationCount.formatted() : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }

    /// Keep on Top changed in one window: every window of the app follows.
    func windowModesChanged() {
        for window in windows { window.applyWindowLevel() }
    }

    /// Run in Background (a window's blue light): every window goes, and the
    /// Dock icon and menu bar with them (an accessory app), while the app runs
    /// on in Android: its displays stay open, so Android neither stops it nor
    /// pauses, and draws nothing nobody sees. Opening the app again (the
    /// Library, the menu bar item, a notification, a tile kept in the Dock)
    /// brings them back as they were.
    private(set) var inBackground = false

    func runInBackground() {
        // An open key mapping editor would go out of sight with its window.
        guard !inBackground, !windows.isEmpty, !windows.contains(where: \.isEditingKeymap) else { return }
        inBackground = true
        for window in windows { window.sendToBackground() }
        NSApp.setActivationPolicy(.accessory)
        if NSApp.isActive { Self.activateWindowBehind() }
    }

    private func bringBack() {
        // Quitting, its windows stay out of sight.
        guard inBackground, !quitting else { return }
        inBackground = false
        NSApp.setActivationPolicy(.regular)
        for window in windows { window.returnFromBackground() }
        NSApp.activate()
    }

    /// The app page's Create Key Mapping… while the app runs: the editor
    /// over the game in its front window (one opens if none is).
    @objc private func editKeyMappingRequested() {
        guard !quitting else { return }
        guard connected else {
            pendingEditKeyMapping = true
            return
        }
        if inBackground { bringBack() }
        let window = windows.first { $0.window?.isKeyWindow == true }
            ?? windows.first { $0.window?.isVisible == true || $0.isInPictureInPicture }
            ?? windows.first ?? openWindow(notificationKey: nil)
        // A minimized one comes back first: the editor goes over the game.
        if window.window?.isMiniaturized == true { window.window?.deminiaturize(nil) }
        window.editKeyMappingWhenReady()
        NSApp.activate()
    }

    /// The Control Panel changed this app's settings in its defaults (Show
    /// key hints on its page): the windows show them now.
    @objc private func preferencesChanged() {
        NotificationCenter.default.post(name: KeymapHints.changed, object: nil)
    }

    /// This app's own app bar style changed (a window's menu): every window takes it.
    func appBarStyleChanged() {
        for window in windows { window.applyAppBarStyle() }
    }

    /// Called by a window once `openDisplay` returned its display id.
    func displayAttached(_ window: AndroidWindowController, displayID: UInt32) {
        for event in earlyEvents.removeValue(forKey: displayID) ?? [] { deliver(event, to: window) }
    }

    private func window(for displayID: UInt32) -> AndroidWindowController? {
        windows.first { $0.displayID == displayID }
    }

    // MARK: App behaviour

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Quitting: its windows are going, and a new one would start the app again.
        guard !quitting else { return false }
        // Opened again while it ran in the background: its windows come back.
        if inBackground {
            bringBack()
            return true
        }
        // The Dock icon brings windows back from Picture in Picture.
        let pictures = windows.filter(\.isInPictureInPicture)
        if !pictures.isEmpty {
            for window in pictures { window.togglePictureInPicture() }
            return true
        }
        // Every window minimized, which macOS counts as none visible: one
        // comes back, as in other apps (also when the Library, the menu bar
        // item or a notification opens the app). A new window opens only
        // when the app has none.
        if !flag, let minimized = windows.first(where: { $0.window?.isMiniaturized == true }) {
            minimized.window?.deminiaturize(nil)
            return false
        }
        if windows.isEmpty, connected { openWindow(notificationKey: nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Made active while it ran in the background (the menu bar item, a
    /// notification): its windows come back. A full-screen one takes the bars
    /// back over the game by itself, and hands them back to the system while
    /// another app is in front, even while this shim runs on in the
    /// background (FullScreenBars, #11).
    func applicationDidBecomeActive(_ notification: Notification) {
        bringBack()
    }

    /// Quit (⌘Q, Dock › Quit) closes the app completely, like swiping it
    /// away on a phone: its windows and its Android process, which the
    /// daemon force-stops as the app's last display closes, or as this
    /// shim's connection goes when it quits first (DaemonCore.closeDisplay,
    /// .disconnect). Nothing waits for Android: only an unfinished screen
    /// recording holds the quit up, for a few seconds at most.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A key mapping editor open with changes asks first; quitting goes on once it agrees.
        for window in windows where !window.keymapMayClose(answer: { quit in if quit { NSApp.terminate(nil) } }) {
            return .terminateCancel
        }
        quitting = true
        // Detaching also stops screen recordings; their movie files are finished before the app quits.
        for window in windows { window.detach() }
        guard ScreenRecorder.anyUnfinished else { return .terminateNow }
        Task {
            await ScreenRecorder.waitForUnfinished(timeout: 10)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Files dropped on the app's Dock icon are shared with it (spec: drag and
    /// drop), through its front window. Dropped as it starts, before it has a
    /// window, they go to the first one, which shares them once its display
    /// has opened.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !quitting else { return }
        let target = windows.first { $0.window?.isKeyWindow == true }
            ?? windows.first { $0.window?.isVisible == true || $0.isInPictureInPicture } ?? windows.first
        guard let target else {
            filesToShare += urls
            return
        }
        target.share(urls)
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "About \(label)", bundle: .windowHost), action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide \(label)", bundle: .windowHost), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: String(localized: "Hide Others", bundle: .windowHost), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: String(localized: "Show All", bundle: .windowHost), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Quit \(label)", bundle: .windowHost), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: String(localized: "File", bundle: .windowHost))
        fileMenu.addItem(withTitle: String(localized: "New Window", bundle: .windowHost), action: #selector(newWindow), keyEquivalent: "n").target = self
        fileMenu.addItem(withTitle: String(localized: "Close Window", bundle: .windowHost), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        // ⌘⇧S and ⌘⇧R stay with the window (MacShortcuts.windowShiftKeys); ⌘S is the app's.
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: String(localized: "Take Screenshot", bundle: .windowHost), action: #selector(AndroidWindowController.takeScreenshot),
                         keyEquivalent: "s").keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: String(localized: "Record Screen", bundle: .windowHost), action: #selector(AndroidWindowController.toggleRecording),
                         keyEquivalent: "r").keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: String(localized: "Record Android’s Sound", bundle: .windowHost),
                         action: #selector(AndroidWindowController.toggleRecordAndroidSound), keyEquivalent: "")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        // The usual Edit menu: Android gets Ctrl+Z, Ctrl+X, Ctrl+C, … (DisplayView).
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: String(localized: "Edit", bundle: .windowHost))
        editMenu.addItem(withTitle: String(localized: "Undo", bundle: .windowHost), action: #selector(DisplayView.undo(_:)), keyEquivalent: "z")
        editMenu.addItem(withTitle: String(localized: "Redo", bundle: .windowHost), action: #selector(DisplayView.redo(_:)), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: String(localized: "Cut", bundle: .windowHost), action: #selector(DisplayView.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: String(localized: "Copy", bundle: .windowHost), action: #selector(DisplayView.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "Paste", bundle: .windowHost), action: #selector(DisplayView.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: String(localized: "Select All", bundle: .windowHost), action: #selector(DisplayView.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: String(localized: "Find", bundle: .windowHost), action: #selector(DisplayView.performFindPanelAction(_:)), keyEquivalent: "f")
        editItem.submenu = editMenu
        main.addItem(editItem)

        // Translate Screen (⌘⇧T) and Translate Into, then resolution,
        // scaling and the performance HUD (GraphicsMenu).
        let viewItem = ScreenTranslationMenu.shared.makeViewMenuItem()
        if let viewMenu = viewItem.submenu {
            GraphicsMenu.shared.addItems(to: viewMenu)
            // Next to Enter Full Screen, the window's other ways to show.
            viewMenu.addItem(withTitle: String(localized: "Keep on Top", bundle: .windowHost),
                             action: #selector(AndroidWindowController.toggleKeepOnTop), keyEquivalent: "")
            viewMenu.addItem(withTitle: String(localized: "Picture in Picture", bundle: .windowHost),
                             action: #selector(AndroidWindowController.togglePictureInPicture), keyEquivalent: "")
        }
        main.addItem(viewItem)

        let gameItem = NSMenuItem()
        let gameMenu = NSMenu(title: String(localized: "Game Controls", bundle: .windowHost))
        let editor = gameMenu.addItem(withTitle: String(localized: "Edit Key Mapping…", bundle: .windowHost), action: #selector(AndroidWindowController.toggleKeymapEditor),
                                      keyEquivalent: "k")
        editor.keyEquivalentModifierMask = [.command, .shift]
        gameMenu.addItem(withTitle: String(localized: "Game Mode", bundle: .windowHost), action: #selector(AndroidWindowController.toggleGameMode),
                         keyEquivalent: "g")
        gameMenu.addItem(withTitle: String(localized: "Show Keys on Game", bundle: .windowHost), action: #selector(toggleKeymapHints(_:)),
                         keyEquivalent: "").target = self
        gameMenu.addItem(KeymapHintsMenu.shared.makeItem())
        // How the mouse wheel scrolls this app (WheelScrolling.swift).
        gameMenu.addItem(.separator())
        gameMenu.addItem(ScrollModeMenu.shared.makeItem())
        gameMenu.addItem(withTitle: String(localized: "Back", bundle: .windowHost), action: #selector(AndroidWindowController.sendBack), keyEquivalent: "[")
        // The phone itself, as in the title bar's Device menu: a shake of
        // its accelerometer, and where Android's GPS says it is (LocationPanel.swift).
        gameMenu.addItem(.separator())
        gameMenu.addItem(withTitle: String(localized: "Shake", bundle: .windowHost), action: #selector(AndroidWindowController.shakeDevice),
                         keyEquivalent: "z").keyEquivalentModifierMask = [.control, .command]
        gameMenu.addItem(withTitle: String(localized: "Location…", bundle: .windowHost), action: #selector(showLocation),
                         keyEquivalent: "l").keyEquivalentModifierMask = [.command, .option]
        gameMenu.items.last?.target = self
        gameItem.submenu = gameMenu
        main.addItem(gameItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: String(localized: "Window", bundle: .windowHost))
        windowMenu.addItem(withTitle: String(localized: "Minimize", bundle: .windowHost), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        // The blue light: the windows go, the app runs on in Android.
        windowMenu.addItem(withTitle: String(localized: "Run in Background", bundle: .windowHost),
                           action: #selector(AndroidWindowController.runInBackground), keyEquivalent: "")
        windowMenu.addItem(withTitle: String(localized: "Rotate", bundle: .windowHost), action: #selector(AndroidWindowController.rotateWindow), keyEquivalent: "r")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    @objc private func toggleKeymapHints(_ sender: NSMenuItem) {
        KeymapHints.visible.toggle()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleKeymapHints(_:)) { item.state = KeymapHints.visible ? .on : .off }
        return true
    }

    @objc func showLocation() {
        LocationPanel.shared.show()
    }

    @objc private func newWindow() {
        guard connected, !quitting else { return }
        openWindow(notificationKey: nil)
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: label,
            .credits: NSAttributedString(string: String(localized: "Android app \(package), running in Avo.", bundle: .windowHost)),
        ])
    }
}

// MARK: - Screen lock (Android locked: VMStatus.screenLock)

extension ShimAppDelegate {
    /// Android's screen lock while it keeps Android locked: windows show a
    /// lock in place of the app until it is unlocked, here or anywhere else.
    var screenLock: AndroidScreenLock? { androidRunning ? androidStatus.screenLock : nil }
    var androidRunning: Bool { androidStatus.state == .running }

    private func androidStatusChanged(_ status: VMStatus) {
        androidStatus = status
        for window in windows { window.androidStatusChanged(status) }
    }

    /// The credential typed into a window's lock, passed to the daemon (never kept).
    func unlockAndroid(_ credential: String) async throws {
        guard let client else { throw AvoError.daemonUnreachable(String(localized: "not connected", bundle: .windowHost)) }
        try await client.unlockAndroid(credential: credential)
    }
}
