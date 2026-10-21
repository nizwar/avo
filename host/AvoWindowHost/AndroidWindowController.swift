import AppKit
import AvoKeymap
import AvoKit
import AvoProtocol

/// One macOS window showing one Android VirtualDisplay (spec: "satu NSWindow
/// per VirtualDisplay").
@MainActor
final class AndroidWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private weak var app: ShimAppDelegate?
    private let frames: FrameRouter
    private let displayView: DisplayView
    private let placeholder = PlaceholderView()
    private let notice = NoticeView()
    /// Over the window while Android is locked, and the display that waits
    /// for the unlock to open (see "Screen lock" below).
    private let lockOverlay = ScreenLockOverlay()
    private var pendingAttach: (client: DaemonClient, notificationKey: String?)?
    /// The key mapping over the game while playing ("Show on game").
    private lazy var hints = KeymapHintsView(displayRect: { [weak self] in self?.displayView.displayRect ?? .zero })
    private var client: DaemonClient?
    private(set) var displayID: UInt32?
    private var keymap: KeymapController?
    private var resizeTask: Task<Void, Never>?
    private var closingFromGuest = false
    /// The window closed (or the app quits): a display that opens after
    /// that is closed again at once.
    private var detached = false
    /// What Android's display was last asked to be (size and density).
    private var lastSent: DisplayRequest?
    /// The app has a usable key mapping, which makes it a game unless the
    /// user chose otherwise (the same rule KeymapController loads with).
    private var hasKeyMapping: Bool
    /// The orientation of a locked shape (a fixed ratio, the phone's
    /// screen): the app's graphics orientation when the window opens or it
    /// changes, then rotating flips it. A locked shape never follows the window.
    private var fixedLandscape = false
    /// Entering or leaving full screen: the size settles when it ends.
    private var fullScreenTransition = false
    /// Full screen's bars are down (`showBars`), and the monitor following the pointer.
    private var barsShown = false
    private var fullScreenPointer: Any?
    /// A size change came while the window was hidden; done once it shows.
    private var pendingResize = false
    /// Makes only the newest resize end the frame hold.
    private var resizeGeneration = 0
    /// The next re-plug says nothing: a more important notice is up.
    private var quietNextSwitch = false
    /// ⌥⌘P for this window and session; nil follows the Control Panel.
    private var hudOverride: PerformanceHUDLevel?
    private let hud = PerformanceHUDView()
    private let backButton = TitlebarButton(symbol: "chevron.backward", label: String(localized: "Back", bundle: .windowHost),
                                            action: #selector(AndroidWindowController.sendBack))
    /// Game Mode, Edit Key Mapping and the key hints (filled while Game Mode is on).
    private let gameModeButton = TitlebarButton(symbol: "gamecontroller", label: String(localized: "Game Controls", bundle: .windowHost),
                                                action: nil)
    /// Translate Screen and Translate Into.
    private let translateButton = TitlebarButton(symbol: "translate", label: String(localized: "Translate Screen (⌘⇧T)", bundle: .windowHost),
                                                 action: nil)
    /// Take Screenshot, Record Screen and their folders (red while recording).
    private let captureButton = TitlebarButton(symbol: "camera", label: String(localized: "Screenshot and Screen Recording", bundle: .windowHost),
                                               action: nil)
    private var titlebarActions: [TitlebarButton] { [backButton, gameModeButton, translateButton, captureButton] }
    /// Keep on Top (also View › Keep on Top): a pin, filled while this app's
    /// windows float over other apps'. Not one of `titlebarActions`: it works
    /// without the display.
    private let keepOnTopButton = TitlebarButton(symbol: "pin", label: String(localized: "Keep on Top", bundle: .windowHost),
                                                 action: #selector(AndroidWindowController.toggleKeepOnTop))
    /// Touches Android's fingerprint sensor with a finger from Settings ›
    /// Fingerprints (FingerprintMenu.swift). Not one of `titlebarActions`: it
    /// works without the display, also on Android's lock screen.
    private lazy var fingerprintMenu = FingerprintMenu(package: app?.package ?? "", appName: app?.label ?? "",
                                                       notice: { [weak self] text in self?.notice.show(text) })
    /// The settings that apply at once, in an overlay under the title bar
    /// (QuickSettings.swift). Also before the display opens: graphics apply to it.
    private lazy var quickSettings = QuickSettingsOverlay(target: self)
    /// Translate Screen: the text on screen, translated, over the app
    /// (ScreenTranslation.swift). Esc is the game's while the key mapping has the keys.
    lazy var translation = ScreenTranslationController(displayView: displayView, button: translateButton,
                                                       notice: { [weak self] text in self?.notice.show(text) },
                                                       keysBelongToGame: { [weak self] in self?.keymapTakesClicks == true },
                                                       engine: { [weak self] in self?.client })
    /// Keeps a ProMotion or adaptive screen at Android's rate above 60 Hz.
    private lazy var frameRateHint = FrameRateHint(view: displayView, renderer: displayView.renderer)
    /// The screen recording in progress.
    private var recorder: ScreenRecorder?
    /// Notices a recording whose file can no longer be written.
    private var recordingCheck: Timer?
    private let recordingIndicator = RecordingIndicator(plate: false)
    /// The same over the game in full screen, where the title bar hides.
    private let recordingBadge = RecordingIndicator(plate: true)
    /// Picture in Picture while it is on (PictureInPictureWindow.swift).
    private var picture: PictureInPictureWindow?
    /// Picture in Picture was chosen in full screen: it opens once full screen has ended.
    private var pictureAfterFullScreen = false
    /// Record Android's Sound, for every app (CaptureSettings).
    static let captureSettings = CaptureSettings(store: UserDefaults(suiteName: AvoIdentifiers.windowHost) ?? .standard)
    /// Keep on Top and where Picture in Picture goes, for this app (WindowModeSettings).
    static let windowModes = WindowModeSettings(store: .standard)

    /// Back, then three icons that open menus of related actions (the same
    /// as the menu bar's): game controls, translation and capture; then the
    /// fingerprint, whose menu has no menu bar counterpart, Keep on Top, and
    /// last Quick Settings.
    private lazy var titlebarButtons: NSTitlebarAccessoryViewController = {
        backButton.target = self
        keepOnTopButton.target = self
        gameModeButton.popUpMenu = { [weak self] in self?.gameControlsMenu() }
        translateButton.popUpMenu = { [weak self] in self?.translationMenu() }
        captureButton.popUpMenu = { [weak self] in self?.captureMenu() }
        let stack = NSStackView(views: titlebarActions + [fingerprintMenu.button, keepOnTopButton, quickSettings.button])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Trailing accessories are laid out by their frame, not Auto Layout.
        let size = stack.fittingSize
        let container = NSView(frame: NSRect(x: 0, y: 0, width: size.width + 10, height: max(size.height, 28)))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        let controller = NSTitlebarAccessoryViewController()
        controller.layoutAttribute = .trailing
        controller.view = container
        // They act on the display, which exists once `openDisplay` returns.
        for button in titlebarActions { button.isEnabled = false }
        return controller
    }()

    /// The game controller's menu (also Controls in the menu bar).
    private func gameControlsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Game Mode", bundle: .windowHost), action: #selector(toggleGameMode), keyEquivalent: "g")
        menu.addItem(withTitle: String(localized: "Edit Key Mapping…", bundle: .windowHost), action: #selector(toggleKeymapEditor), keyEquivalent: "k")
            .keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: String(localized: "Show Key Mapping on Game", bundle: .windowHost), action: #selector(toggleKeymapHints),
                     keyEquivalent: "")
        for item in menu.items { item.target = self }
        // Its steps have their own target (KeymapHintsMenu).
        menu.addItem(KeymapHintsMenu.shared.makeItem())
        // How the mouse wheel scrolls this app (WheelScrolling.swift).
        menu.addItem(.separator())
        menu.addItem(ScrollModeMenu.shared.makeItem())
        return menu
    }

    /// Translate Screen and Translate Into, as in the View menu.
    private func translationMenu() -> NSMenu? {
        let menu = ScreenTranslationMenu.shared.makeViewMenuItem().submenu
        // Straight to this window, also before it becomes key.
        for item in menu?.items ?? [] where item.action == #selector(toggleScreenTranslation) { item.target = self }
        return menu
    }

    /// Take Screenshot, Record Screen (Stop Recording while recording),
    /// whether recordings take Android's sound, and the folders they save to
    /// (also in the File menu).
    private func captureMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Take Screenshot", bundle: .windowHost), action: #selector(takeScreenshot), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: String(localized: "Record Screen", bundle: .windowHost), action: #selector(toggleRecording), keyEquivalent: "r")
            .keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: String(localized: "Record Android’s Sound", bundle: .windowHost), action: #selector(toggleRecordAndroidSound),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Show Screenshots in Finder", bundle: .windowHost), action: #selector(showScreenshotsFolder),
                     keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Show Recordings in Finder", bundle: .windowHost), action: #selector(showRecordingsFolder),
                     keyEquivalent: "")
        for item in menu.items where !item.isSeparatorItem { item.target = self }
        return menu
    }

    @objc func toggleKeymapHints() {
        KeymapHints.visible.toggle()
    }

    @objc func showScreenshotsFolder() {
        showCaptureFolder(.picturesDirectory)
    }

    @objc func showRecordingsFolder() {
        showCaptureFolder(.moviesDirectory)
    }

    private func showCaptureFolder(_ directory: FileManager.SearchPathDirectory) {
        do {
            NSWorkspace.shared.open(try CaptureFiles.folder(directory))
        } catch {
            notice.show(error.localizedDescription)
        }
    }

    /// The red dot and time next to the icons while recording.
    private lazy var recordingAccessory: NSTitlebarAccessoryViewController = {
        let controller = NSTitlebarAccessoryViewController()
        controller.layoutAttribute = .trailing
        controller.view = recordingIndicator
        controller.isHidden = true
        return controller
    }()

    init(app: ShimAppDelegate, frames: FrameRouter) {
        self.app = app
        self.frames = frames
        guard let renderer = MetalRenderer() else { fatalError("Metal is unavailable") }
        displayView = DisplayView(renderer: renderer)
        hasKeyMapping = KeymapProfile.usable(for: app.package,
                                             bundledDirectory: KeymapController.bundledDirectory(hostApplication: Self.hostApplication)) != nil

        // The first window: the default size, turned to the app's orientation.
        let config = app.config
        let orientation = config.graphics(for: app.package, hasKeyMapping: hasKeyMapping).settings.orientation
        var size = config.defaultWindowSize
        if (orientation == .landscape) != (size.width > size.height) { size = size.rotated }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = app.label
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentMinSize = NSSize(width: 240, height: 240)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let container = NSView()
        displayView.translatesAutoresizingMaskIntoConstraints = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(displayView)
        hints.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hints)
        hud.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hud)
        container.addSubview(placeholder)
        notice.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(notice)
        recordingBadge.translatesAutoresizingMaskIntoConstraints = false
        recordingBadge.isHidden = true
        container.addSubview(recordingBadge)
        NSLayoutConstraint.activate([
            displayView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            displayView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            displayView.topAnchor.constraint(equalTo: container.topAnchor),
            displayView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            placeholder.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            placeholder.topAnchor.constraint(equalTo: container.topAnchor),
            placeholder.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hints.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hints.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hints.topAnchor.constraint(equalTo: container.topAnchor),
            hints.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hud.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            hud.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            notice.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            notice.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            notice.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 12),
            notice.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            recordingBadge.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            recordingBadge.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
        ])
        // Android locked: over the app and its placeholder, under the notices.
        lockOverlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(lockOverlay, positioned: .above, relativeTo: placeholder)
        NSLayoutConstraint.activate([
            lockOverlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            lockOverlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            lockOverlay.topAnchor.constraint(equalTo: container.topAnchor),
            lockOverlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        window.addTitlebarAccessoryViewController(titlebarButtons)
        window.addTitlebarAccessoryViewController(recordingAccessory)
        // The accessory's own isHidden does not hide it in the title bar
        // (macOS 27 still drew a red "0:00" without a recording); hiding its
        // view does. showRecording(_:) sets both.
        recordingAccessory.isHidden = true
        recordingIndicator.isHidden = true
        placeholder.show(icon: NSApp.applicationIconImage, message: String(localized: "Starting \(app.label)…", bundle: .windowHost), busy: true)
        displayView.onDropFiles = { [weak self] urls in self?.share(urls) }
        // The wheel's swipes are in dp: Android's density for the display.
        displayView.wheel.density = { [weak self] in self?.lastSent.map { Double($0.dpi) / 160 } }
        // A click aimed at the game never opens Finder instead.
        notice.acceptsClicks = { [weak self] in self?.keymapTakesClicks != true }

        // Remember each app's window frame separately; offset extra windows.
        window.setFrameAutosaveName("AvoWindow-\(app.package)")
        if window.frame.origin == .zero { window.center() }

        // A locked shape opens in the app's orientation (a restored frame
        // keeps its size and place); a free window opens as it was left.
        let content = window.contentLayoutRect.size
        fixedLandscape = lockedRatio != nil ? orientation == .landscape : content.width > content.height
        applyWindowConstraints()
        renderer.setOptions(renderOptions)
        hud.renderer = renderer
        hud.request = { [weak self] in self?.lastSent }
        applyHUDLevel()
        applyWindowLevel()
        frameRateHint.setCap(app.config.fpsLimit)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Display lifecycle

    func attach(client: DaemonClient, notificationKey: String?) {
        guard let app else { return }
        self.client = client
        // Android is locked: the window shows the lock and opens once it is unlocked.
        if let lock = app.screenLock {
            waitForUnlock(lock, client: client, notificationKey: notificationKey)
            return
        }
        let request = currentRequest()
        Task { [weak self] in
            guard let self else { return }
            do {
                let id = try await client.openDisplay(OpenDisplayRequest(package: app.package, width: request.width, height: request.height,
                                                                         dpi: request.dpi, notificationKey: notificationKey))
                // Closed while Android opened it: kept, the display would go on
                // drawing for no window (and keep Android from pausing).
                guard !detached else {
                    client.closeDisplay(id)
                    frames.unregister(id)
                    return
                }
                displayID = id
                lastSent = request
                displayView.displayID = id
                displayView.setDisplaySize(CGSize(width: Int(request.width), height: Int(request.height)))
                // A setting or the window may have changed while the display
                // opened; when nothing did, this does nothing.
                scheduleResize(delay: .zero)
                frames.register(displayView, for: id)
                let keymap = KeymapController(package: app.package, displayID: id, view: displayView,
                                              hostApplication: Self.hostApplication) { [weak self] record in
                    self?.sendInput(record)
                }
                self.keymap = keymap
                keymap.onNotice = { [weak self] text in self?.notice.show(text) }
                keymap.onProfile = { [weak self] profile in
                    self?.hints.profile = profile
                    self?.keyMappingChanged(profile != nil)
                    GamepadForwarder.shared.update()
                }
                keymap.onEditing = { [weak self] editing in self?.hints.editing = editing }
                keymap.onGameMode = { [weak self] on in
                    self?.showGameMode(on)
                    GamepadForwarder.shared.update()
                }
                hints.profile = keymap.profile
                showGameMode(keymap.gameMode)
                if keymap.profile != nil {
                    notice.show(keymap.gameMode
                        ? String(localized: "Game Mode is on: the key mapping is active. ⌘G turns it off.", bundle: .windowHost)
                        : String(localized: "This app has a key mapping: ⌘G turns on Game Mode.", bundle: .windowHost))
                }
                displayView.keymap = keymap
                displayView.send = { [weak self] record in self?.sendInput(record) }
                for button in titlebarActions { button.isEnabled = true }
                self.app?.displayAttached(self, displayID: id)
                if window?.isKeyWindow == true { focusGamepad() }
            } catch AvoError.androidLocked {
                // Locked as the app was about to start: the same as above.
                waitForUnlock(self.app?.screenLock, client: client, notificationKey: notificationKey)
            } catch {
                showProblem((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func sendInput(_ record: InputRecord) {
        guard let client, let bytes = try? InputWire.encode(record) else { return }
        client.sendInput(Data(bytes))
    }

    func displayReady() {
        displayView.renderer.whenFrameShown { [weak self] in self?.placeholder.hide() }
        // A display without frames yet (no engine attached) keeps a quiet placeholder.
        placeholder.show(icon: NSApp.applicationIconImage, message: nil, busy: true)
    }

    func showProblem(_ message: String) {
        placeholder.show(icon: NSApp.applicationIconImage, message: message, busy: false)
    }

    func closeFromGuest() {
        closingFromGuest = true
        close()
    }

    func detach() {
        detached = true
        // A display waiting for Android's unlock is no longer wanted.
        pendingAttach = nil
        // The window closes or the app quits: finish the movie with what it has.
        stopRecording()
        GamepadForwarder.shared.remove(self)
        guard let displayID else { return }
        // Closed by Android: the daemon has let go of it already. Either way the
        // router lets go of the view, or it would keep its renderer and surfaces.
        if !closingFromGuest { client?.closeDisplay(displayID) }
        frames.unregister(displayID)
        self.displayID = nil
    }

    func share(_ urls: [URL]) {
        guard let client, let displayID else { return }
        Task {
            do {
                try await client.shareFiles(urls, with: displayID)
            } catch {
                showProblem(error.localizedDescription)
            }
        }
    }

    /// Android's display size and density for the window's content now
    /// (DisplaySizing): the window's pixels × the render scale when
    /// following the window, the fixed resolution, or the phone's screen.
    private func currentRequest() -> DisplayRequest {
        guard let window else { return DisplayRequest(width: 1080, height: 2336, dpi: 320) }
        let content = window.contentLayoutRect.size
        return DisplaySizing.request(contentWidth: content.width, contentHeight: content.height,
                                     backingScale: window.backingScaleFactor, settings: graphics.settings, device: deviceDisplay,
                                     landscape: lockedRatio != nil ? fixedLandscape : nil)
    }

    static var hostApplication: URL? {
        (Bundle.main.object(forInfoDictionaryKey: AvoIdentifiers.shimHostAppInfoKey) as? String).map { URL(filePath: $0) }
    }

    // MARK: NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        // A free window's shape is where a later fixed ratio starts; only
        // rotating turns a fixed one.
        if let content = window?.contentLayoutRect.size, lockedRatio == nil {
            fixedLandscape = content.width > content.height
        }
        // Android re-plugs the display for a new size: once, when the drag ends.
        guard window?.inLiveResize != true, !fullScreenTransition else { return }
        scheduleResize(delay: .milliseconds(250))
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        displayView.renderer.setInteractiveResize(true)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        displayView.renderer.setInteractiveResize(false)
        scheduleResize(delay: .zero)
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        applyWindowConstraints()
        scheduleResize(delay: .zero)
    }

    private func scheduleResize(delay: Duration, announce: Bool = false) {
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.reconcileDisplaySize(announce: announce)
        }
    }

    /// Re-plugs Android's display when the window or the settings call for
    /// it (DisplaySizing.shouldReplug), never during a drag or a full-screen
    /// animation (their end handlers come back here) and not while nobody
    /// sees the window. The renderer keeps the last frame up until Android
    /// has the app back at the new size, so a re-plug never flashes black.
    private func reconcileDisplaySize(announce: Bool) {
        guard let displayID, let client, let window, !window.inLiveResize, !fullScreenTransition else { return }
        guard isOnScreen || recorder != nil else {
            pendingResize = true
            return
        }
        pendingResize = false
        let quiet = quietNextSwitch
        quietNextSwitch = false
        let proposed = currentRequest()
        let content = window.contentLayoutRect.size
        let renderer = displayView.renderer
        // A locked shape is the setting's, not the window's: in full screen
        // or a tile the window may still have the old ratio's shape, and
        // comparing with it would skip a 16:10 → 16:9 change.
        let aspect = lockedRatio != nil ? Double(proposed.width) / Double(max(proposed.height, 1))
                                        : content.width / max(content.height, 1)
        guard DisplaySizing.shouldReplug(current: lastSent, proposed: proposed, windowAspect: aspect,
                                         followsWindow: mode == .followWindow) else {
            // The picture is scaled to the new window instead.
            hints.needsDisplay = true
            renderer.redraw()
            return
        }
        let resizes = proposed.size != lastSent?.size
        if resizes { renderer.holdCurrentFrame(expecting: proposed.size) }
        lastSent = proposed
        picture?.setAspect(CGFloat(proposed.width) / CGFloat(max(proposed.height, 1)))
        displayView.setDisplaySize(CGSize(width: Int(proposed.width), height: Int(proposed.height)))
        hints.needsDisplay = true
        resizeGeneration += 1
        let generation = resizeGeneration
        Task { [weak self] in
            // Failed or not, the hold ends: it never outlives its re-plug. An
            // older reply leaves it to the newest resize, which may be a
            // density change only, so that one releases too (a no-op then).
            try? await client.resizeDisplayAndWait(displayID, width: proposed.width, height: proposed.height, dpi: proposed.dpi)
            guard self?.resizeGeneration == generation else { return }
            renderer.releaseHold()
        }
        if announce, !quiet { notice.show(String(localized: "Switching to \(switchLabel(proposed))…", bundle: .windowHost)) }
    }

    /// "1280 × 720", "67% render scale" or "the window’s resolution".
    private func switchLabel(_ request: DisplayRequest) -> String {
        guard let scale = request.effectiveRenderScale else { return "\(request.width) × \(request.height)" }
        return scale < 100 ? String(localized: "\(scale)% render scale", bundle: .windowHost)
                           : String(localized: "the window’s resolution", bundle: .windowHost)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        setOnScreen(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        setOnScreen(true)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        // In Picture in Picture the window is ordered out: the panel says.
        guard let window, !window.isMiniaturized, picture == nil else { return }
        setOnScreen(window.occlusionState.contains(.visible))
    }

    /// Android stops drawing a display nobody can see (the app keeps
    /// running), except while it is recorded: the movie goes on while the
    /// window is covered, minimized or on another Space.
    private func setOnScreen(_ onScreen: Bool) {
        displayView.renderer.isOnScreen = onScreen
        frameRateHint.setOnScreen(onScreen)
        if let displayID { client?.setDisplayVisible(displayID, visible: onScreen || recorder != nil) }
        if onScreen, pendingResize { scheduleResize(delay: .zero) }
    }

    /// Not minimized, covered or on another Space (in Picture in Picture: the panel).
    private var isOnScreen: Bool {
        if let picture { return picture.isVisible }
        guard let window else { return false }
        return !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    // Full screen: no re-plug during the animation, and the size settles
    // once at its end. A fixed ratio keeps Android's size there and shows
    // bars; Match window and follow mode take the screen's shape.

    // Full screen hides the menu bar and the title bar until the pointer
    // reaches the top of the screen, as in other apps; leaving the top hides
    // them again. AppKit does that only when macOS hides the menu bar in full
    // screen; with "show the menu bar" on, it keeps the menu bar and the title
    // bar (in a window of its own, NSToolbarFullScreenWindow) over the game for
    // good. So Avo does it itself: the menu bar through the presentation
    // options, the title bar's window by its alpha (AppKit sets that back after
    // its own animations, hence `keepBarsHidden`). While the mouse is locked
    // for aiming the pointer stays put, so nothing comes down.

    static let barsHidden: NSApplication.PresentationOptions = [.fullScreen, .hideDock, .hideMenuBar]
    static let barsShown: NSApplication.PresentationOptions = [.fullScreen, .autoHideDock, .autoHideMenuBar]
    /// How close to the top the pointer brings the bars, and how far below it
    /// takes them away again (the menu bar and the title bar are about 62 pt).
    static let revealEdge: CGFloat = 2
    static let concealDistance: CGFloat = 90

    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = [])
        -> NSApplication.PresentationOptions {
        Self.barsHidden
    }

    /// The title bar's own window while in full screen.
    private var fullScreenTitlebar: NSWindow? {
        guard let bar = window?.standardWindowButton(.closeButton)?.window, bar !== window else { return nil }
        return bar
    }

    private func showBars(_ shown: Bool) {
        guard let window, window.styleMask.contains(.fullScreen) else { return }
        barsShown = shown
        NSApp.presentationOptions = shown ? Self.barsShown : Self.barsHidden
        fullScreenTitlebar?.ignoresMouseEvents = !shown
        fullScreenTitlebar?.alphaValue = shown ? 1 : 0
        if !shown { keepBarsHidden() }
    }

    /// AppKit animates the title bar's window after a change and leaves it
    /// opaque: hide it again once that is over.
    private func keepBarsHidden() {
        for delay in [0.15, 0.4, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.barsShown, self.window?.styleMask.contains(.fullScreen) == true,
                      let bar = self.fullScreenTitlebar else { return }
                bar.alphaValue = 0
                bar.ignoresMouseEvents = true
            }
        }
    }

    /// Follows the pointer in full screen: the top edge brings the bars,
    /// moving back down into the game takes them away.
    private func watchFullScreenPointer(_ on: Bool) {
        if let monitor = fullScreenPointer { NSEvent.removeMonitor(monitor) }
        fullScreenPointer = nil
        guard on else { return }
        window?.acceptsMouseMovedEvents = true
        fullScreenPointer = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in
            guard let self, let screen = self.window?.screen, self.window?.styleMask.contains(.fullScreen) == true,
                  !self.fullScreenTransition, self.keymap?.isPointerLocked != true else { return event }
            let y = NSEvent.mouseLocation.y
            if !self.barsShown, y >= screen.frame.maxY - Self.revealEdge {
                self.showBars(true)
            } else if self.barsShown, y < screen.frame.maxY - Self.concealDistance {
                self.showBars(false)
            } else if !self.barsShown, self.fullScreenTitlebar.map({ $0.alphaValue != 0 }) == true {
                self.keepBarsHidden()
            }
            return event
        }
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        fullScreenTransitionBegan()
        // The scaler for the full-screen size is built during the animation,
        // so the first frame after it is upscaled already.
        if let screen = window?.screen {
            let b = screen.backingScaleFactor
            let size = CGSize(width: screen.frame.width * b, height: (screen.frame.height - screen.safeAreaInsets.top) * b)
            displayView.renderer.prepareScaler(destination: PixelSize(size))
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        fullScreenTransitionEnded()
        showBars(false)
        watchFullScreenPointer(true)
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        fullScreenTransitionBegan()
        watchFullScreenPointer(false)
        barsShown = true
        fullScreenTitlebar?.ignoresMouseEvents = false
        fullScreenTitlebar?.alphaValue = 1
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        fullScreenTransitionEnded()
        NSApp.presentationOptions = []
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        fullScreenTransitionEnded()
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        fullScreenTransitionEnded()
    }

    private func fullScreenTransitionBegan() {
        fullScreenTransition = true
        displayView.renderer.setInteractiveResize(true)
        applyWindowLevel()
    }

    private func fullScreenTransitionEnded() {
        fullScreenTransition = false
        displayView.renderer.setInteractiveResize(false)
        showRecordingBadge()
        applyWindowLevel()
        // Back in a window: its shape lock again (skipped in full screen).
        applyWindowConstraints()
        scheduleResize(delay: .zero)
        if pictureAfterFullScreen, window?.styleMask.contains(.fullScreen) == false {
            pictureAfterFullScreen = false
            enterPictureInPicture()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        becameKey()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Never keep keys or the pointer captured after focus leaves the game.
        keymap?.focusLost()
        GamepadForwarder.shared.resign(self)
    }

    /// The key window's app has Android's input focus, as the one app on a
    /// phone does (games pause their sound without it; a display opening
    /// takes it anyway).
    private func becameKey() {
        focusGamepad()
        if let displayID { client?.focusDisplay(displayID) }
    }

    /// The key window drives Android's gamepad, unless its key mapping takes it.
    private func focusGamepad() {
        guard let keymap else { return }
        GamepadForwarder.shared.focus(self, send: { [weak self] state in
            guard let self, let displayID = self.displayID else { return }
            var state = state
            state.displayID = displayID
            self.sendInput(.gamepad(state))
        }, mappingTakesGamepad: { [weak keymap] in keymap?.takesGamepad == true })
    }

    func windowWillClose(_ notification: Notification) {
        watchFullScreenPointer(false)
        if picture != nil { leavePictureInPicture(show: false) }
        keymap?.stop()
        frameRateHint.stop()
        detach()
        app?.windowClosed(self, byGuest: closingFromGuest)
    }

    // MARK: Orientation

    func applyOrientation(_ orientation: DisplayOrientation) {
        guard let window else { return }
        let size = window.contentLayoutRect.size
        let wantsLandscape: Bool
        switch orientation {
        case .landscape, .reverseLandscape: wantsLandscape = true
        case .portrait, .reversePortrait: wantsLandscape = false
        case .unspecified: return
        }
        // A locked shape has its own orientation (full screen keeps the screen's shape).
        let landscape = lockedRatio != nil ? fixedLandscape : size.width > size.height
        if landscape != wantsLandscape { rotateWindow() }
    }

    @objc func rotateWindow() {
        guard let window else { return }
        if let ratio = lockedRatio {
            // Android turns with the locked shape; the window follows it.
            fixedLandscape.toggle()
            guard !window.styleMask.contains(.fullScreen) else {
                scheduleResize(delay: .zero)
                return
            }
            window.contentAspectRatio = fixedLandscape ? NSSize(width: ratio, height: 1) : NSSize(width: 1, height: ratio)
        }
        let content = window.contentLayoutRect.size
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: content.height, height: content.width)))
        var origin = window.frame.origin
        origin.y += window.frame.height - frame.height // keep the title bar in place
        window.setFrame(NSRect(origin: origin, size: frame.size), display: true, animate: true)
    }

    @objc func sendBack() {
        displayView.sendBack()
    }

    @objc func toggleKeymapEditor() {
        keymap?.toggleEditor(over: window)
    }

    @objc func toggleGameMode() {
        guard let keymap else { return }
        keymap.setGameMode(!keymap.gameMode)
    }

    /// Game Mode with a key mapping: every click on the game is the game's,
    /// mapped or passed on as a touch, and none may land on a notice's button.
    private var keymapTakesClicks: Bool {
        guard let keymap else { return false }
        return keymap.isPointerLocked || (keymap.gameMode && keymap.profile != nil)
    }

    private func showGameMode(_ on: Bool) {
        gameModeButton.state = on ? .on : .off
        gameModeButton.contentTintColor = on ? .controlAccentColor : nil
        gameModeButton.image = NSImage(systemSymbolName: on ? "gamecontroller.fill" : "gamecontroller",
                                       accessibilityDescription: gameModeButton.toolTip)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        hints.gameMode = on
        quickSettings.refresh()
    }

    // MARK: Screenshots and screen recording

    /// Saves the frame on screen to ~/Pictures/Avo as a PNG, at the
    /// display's full resolution.
    @objc func takeScreenshot() {
        guard let app, displayID != nil else { return }
        let name = CaptureFiles.baseName(app: app.label, date: .now)
        Task {
            guard let image = await displayView.renderer.captureFrame() else {
                notice.show(CaptureFiles.Failure.noFrame.localizedDescription)
                return
            }
            // The window's content, in Picture in Picture too.
            if let container = displayView.superview {
                CaptureFeedback.flash(displayView.convert(displayView.displayRect, to: container), in: container)
            }
            CaptureFeedback.play(.screenshot)
            do {
                let url = try await CaptureFiles.saveScreenshot(image, name: name)
                notice.show(String(localized: "Screenshot saved to \(CaptureFiles.displayName(.picturesDirectory)).", bundle: .windowHost),
                            action: String(localized: "Show in Finder", bundle: .windowHost)) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                notice.show(String(localized: "Could not save the screenshot: \(error.localizedDescription)", bundle: .windowHost))
            }
        }
    }

    /// Record Screen, or Stop Recording while one is in progress.
    @objc func toggleRecording() {
        if recorder == nil { startRecording() } else { stopRecording() }
    }

    /// Records the window's frames to ~/Movies/Avo until Stop Recording, the
    /// window closes or the display changes size.
    private func startRecording() {
        guard let app, recorder == nil, displayID != nil else { return }
        guard let size = displayView.renderer.frameSize else {
            notice.show(CaptureFiles.Failure.noFrame.localizedDescription)
            return
        }
        do {
            let folder = try CaptureFiles.folder(.moviesDirectory)
            let url = CaptureFiles.unusedURL(in: folder, name: CaptureFiles.baseName(app: app.label, date: .now), pathExtension: "mov")
            let sound = Self.captureSettings.recordsAndroidSound ? app.audioTap : nil
            let recorder = try ScreenRecorder(url: url, frameWidth: Int(size.width), frameHeight: Int(size.height),
                                              device: displayView.renderer.device, sound: sound) { [weak self] recorder, outcome in
                self?.recordingFinished(recorder, outcome)
            }
            self.recorder = recorder
            displayView.renderer.startRecording(recorder)
            showRecording(true)
            recordingChangedVisibility()
            CaptureFeedback.play(.recordingStarted)
            notice.show(String(localized: "Recording the screen. ⌘⇧R stops it.", bundle: .windowHost))
        } catch {
            notice.show(String(localized: "Could not record the screen: \(error.localizedDescription)", bundle: .windowHost))
        }
    }

    /// Ends the recording in progress, if any; its file is finished in the background.
    func stopRecording() {
        guard recorder != nil else { return }
        recorder = nil
        displayView.renderer.stopRecording()
        showRecording(false)
        recordingChangedVisibility()
        CaptureFeedback.play(.recordingStopped)
    }

    /// A window nobody sees keeps Android drawing only for a recording.
    private func recordingChangedVisibility() {
        guard !isOnScreen, let displayID else { return }
        client?.setDisplayVisible(displayID, visible: recorder != nil)
    }

    private func recordingFinished(_ finished: ScreenRecorder, _ outcome: ScreenRecorder.Outcome) {
        if finished === recorder {
            // It ended by itself: the display changed size.
            recorder = nil
            showRecording(false)
            recordingChangedVisibility()
            CaptureFeedback.play(.recordingStopped)
        }
        switch outcome {
        case let .saved(url, reason):
            let folder = CaptureFiles.displayName(.moviesDirectory)
            let text = switch reason {
            case .stopped:
                String(localized: "Recording saved to \(folder).", bundle: .windowHost)
            case .resized:
                String(localized: "The screen turned, so the recording stopped. It is saved in \(folder).", bundle: .windowHost)
            case let .failed(message):
                String(localized: "The recording stopped early and is saved in \(folder) up to that point. \(message)", bundle: .windowHost)
            }
            notice.show(text, action: String(localized: "Show in Finder", bundle: .windowHost)) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case let .failed(message):
            notice.show(String(localized: "Could not record the screen: \(message)", bundle: .windowHost))
        }
    }

    private func showRecording(_ on: Bool) {
        recordingAccessory.isHidden = !on
        recordingIndicator.isHidden = !on
        let start: Date? = on ? .now : nil
        recordingIndicator.run(since: start)
        recordingBadge.run(since: start)
        showRecordingBadge()
        // The camera turns red; its menu then offers Stop Recording.
        let label = on ? String(localized: "Recording the screen. ⌘⇧R stops it.", bundle: .windowHost)
                       : String(localized: "Screenshot and Screen Recording", bundle: .windowHost)
        captureButton.image = NSImage(systemSymbolName: on ? "camera.fill" : "camera", accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        captureButton.contentTintColor = on ? .systemRed : nil
        captureButton.toolTip = label
        captureButton.setAccessibilityLabel(label)
        recordingCheck?.invalidate()
        recordingCheck = nil
        guard on else { return }
        // A full disk or an encoder error: stop, and say why.
        let check = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.recorder?.hasFailed == true { self?.stopRecording() }
            }
        }
        RunLoop.main.add(check, forMode: .common)
        recordingCheck = check
    }

    /// In full screen the title bar, and the indicator in it, hides until the
    /// pointer reaches the top: the badge over the game shows the recording.
    private func showRecordingBadge() {
        recordingBadge.isHidden = recorder == nil || window?.styleMask.contains(.fullScreen) != true
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleGameMode) {
            item.state = keymap?.gameMode == true ? .on : .off
            return keymap != nil
        }
        if item.action == #selector(toggleRecording) {
            item.title = recorder == nil ? String(localized: "Record Screen", bundle: .windowHost)
                                         : String(localized: "Stop Recording", bundle: .windowHost)
            return recorder != nil || displayID != nil
        }
        if item.action == #selector(takeScreenshot) { return displayID != nil }
        if item.action == #selector(toggleRecordAndroidSound) {
            item.state = Self.captureSettings.recordsAndroidSound ? .on : .off
            return true
        }
        if item.action == #selector(toggleKeepOnTop) {
            item.state = Self.windowModes.keepOnTop ? .on : .off
            return true
        }
        if item.action == #selector(togglePictureInPicture) {
            item.state = picture != nil ? .on : .off
            // Android's screen lock is entered in the window.
            return picture != nil || !lockOverlay.isShowing
        }
        // The editor is drawn over the window, which Picture in Picture hides.
        if item.action == #selector(toggleKeymapEditor) { return picture == nil }
        if item.action == #selector(toggleKeymapHints) {
            item.state = KeymapHints.visible ? .on : .off
            return keymap != nil
        }
        if let enabled = translation.validate(item, hasDisplay: displayID != nil) { return enabled }
        if let enabled = validateGraphicsItem(item) { return enabled }
        return true
    }

    @objc func toggleRecordAndroidSound() {
        Self.captureSettings.recordsAndroidSound.toggle()
    }

    // MARK: Keep on Top and Picture in Picture

    /// Keep on Top for every window of this app (ShimAppDelegate applies it).
    @objc func toggleKeepOnTop() {
        Self.windowModes.keepOnTop.toggle()
        app?.windowModesChanged()
    }

    /// Floats over other apps' windows while Keep on Top is on; full screen
    /// has its own Space. The pin shows the setting either way.
    func applyWindowLevel() {
        let on = Self.windowModes.keepOnTop
        keepOnTopButton.state = on ? .on : .off
        keepOnTopButton.contentTintColor = on ? .controlAccentColor : nil
        keepOnTopButton.image = NSImage(systemSymbolName: on ? "pin.fill" : "pin", accessibilityDescription: keepOnTopButton.toolTip)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        guard let window else { return }
        let floats = on && !fullScreenTransition && !window.styleMask.contains(.fullScreen)
        window.level = floats ? .floating : .normal
    }

    var isInPictureInPicture: Bool { picture != nil }

    @objc func togglePictureInPicture() {
        if picture == nil { enterPictureInPicture() } else { leavePictureInPicture(show: true) }
    }

    /// The window's content moves into the Picture in Picture panel and the
    /// window waits ordered out. Android's display keeps its size (the
    /// picture is scaled down); a rotation re-plugs it as in the window.
    private func enterPictureInPicture() {
        guard let window, picture == nil, let content = window.contentView else { return }
        if window.styleMask.contains(.fullScreen) {
            pictureAfterFullScreen = true
            window.toggleFullScreen(nil)
            return
        }
        if quickSettings.isShown { quickSettings.toggle() }
        keymap?.focusLost()
        let size = lastSent.map { CGSize(width: Int($0.width), height: Int($0.height)) } ?? displayView.renderer.frameSize ?? content.bounds.size
        // Out of the window first: the window would take it back out of the panel.
        window.contentView = NSView()
        let picture = PictureInPictureWindow(content: content, aspect: size.width / max(size.height, 1), screen: window.screen,
                                             settings: Self.windowModes)
        // The menus' actions reach this window from the panel.
        picture.panel.nextResponder = self
        picture.onBack = { [weak self] in self?.leavePictureInPicture(show: true) }
        picture.onClose = { [weak self] in
            self?.leavePictureInPicture(show: false)
            self?.window?.close()
        }
        picture.onVisible = { [weak self] visible in self?.setOnScreen(visible) }
        picture.onKey = { [weak self] key in
            guard let self else { return }
            if key {
                becameKey()
            } else {
                keymap?.focusLost()
                GamepadForwarder.shared.resign(self)
            }
        }
        picture.onLiveResize = { [weak self] resizing in self?.displayView.renderer.setInteractiveResize(resizing) }
        self.picture = picture
        window.orderOut(nil)
        picture.show()
        picture.panel.makeFirstResponder(lockOverlay.isShowing ? lockOverlay.focusTarget : displayView)
        setOnScreen(true)
    }

    /// Puts the content back into the window, and shows it (`show`) or not (it closes).
    private func leavePictureInPicture(show: Bool) {
        guard let window, let picture else { return }
        self.picture = nil
        if let content = picture.takeContent() { window.contentView = content }
        window.makeFirstResponder(lockOverlay.isShowing ? lockOverlay.focusTarget : displayView)
        guard show else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        setOnScreen(true)
    }

    // MARK: Graphics (resolution, scaling, View menu, performance HUD)

    /// The settings this app's windows use: its profile (Games when it has a
    /// key mapping) with its own changes on top.
    private var graphics: ResolvedGraphics {
        guard let app else { return ResolvedGraphics(settings: .appsDefault, profile: .apps, reason: .none, changes: .init()) }
        return app.config.graphics(for: app.package, hasKeyMapping: hasKeyMapping)
    }

    /// The device profile's screen, which the phone's-screen mode gives Android.
    private var deviceDisplay: DeviceProfile.Display? { app?.deviceDisplay }

    /// The mode in effect: the phone's screen needs a device profile with
    /// one, else Android follows the window.
    private var mode: GraphicsSettings.Mode { graphics.settings.effectiveMode(device: deviceDisplay) }

    /// Long over short side of the shape the window is locked to (a fixed
    /// ratio in follow or fixed mode, the phone's screen); nil when it
    /// resizes freely (Match window).
    private var lockedRatio: Double? { graphics.settings.lockedRatio(device: deviceDisplay) }

    private var renderOptions: RenderOptions {
        RenderOptions(filter: graphics.settings.filter, sharpness: graphics.settings.sharpness)
    }

    /// A message over the game (a failed save, from the app delegate).
    func showNotice(_ text: String) {
        notice.show(text)
    }

    /// The window's shape rules for the current mode. A locked shape (a
    /// ratio, the phone's screen) locks the window to it, so Android never
    /// lays out again for a drag (follow mode only re-renders). At 100%
    /// in follow mode the window moves in steps of 8 × 2 pixels, the
    /// display's alignment, so the picture stays exactly 1:1. Anything else
    /// resizes freely. Full screen has the screen's shape; this runs again
    /// when it ends.
    private func applyWindowConstraints() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let settings = graphics.settings
        let content = window.contentLayoutRect.size
        if let ratio = lockedRatio {
            window.contentAspectRatio = fixedLandscape ? NSSize(width: ratio, height: 1) : NSSize(width: 1, height: ratio)
            let long = max(content.width, content.height)
            setContentSize(fixedLandscape ? NSSize(width: long, height: long / ratio) : NSSize(width: long / ratio, height: long))
            return
        }
        // Rotating or dragging a free window decides a later fixed ratio's orientation.
        fixedLandscape = content.width > content.height
        // Setting increments also ends an aspect lock.
        window.contentResizeIncrements = NSSize(width: 1, height: 1)
        guard mode == .followWindow, settings.renderScale >= 100 else { return }
        let b = window.backingScaleFactor
        let step = (width: Double(DisplaySizing.widthAlignment), height: 2.0)
        window.contentResizeIncrements = NSSize(width: step.width / b, height: step.height / b)
        setContentSize(NSSize(width: ((content.width * b + 0.01) / step.width).rounded(.down) * step.width / b,
                              height: ((content.height * b + 0.01) / step.height).rounded(.down) * step.height / b))
    }

    /// Resizes the content keeping the top-left corner, within the screen's
    /// visible area (both sides shrink together, so a shape is kept).
    private func setContentSize(_ wanted: NSSize) {
        guard let window, wanted.width > 0, wanted.height > 0 else { return }
        var size = wanted
        let visible = window.screen?.visibleFrame
        if let visible {
            let room = window.contentRect(forFrameRect: visible).size
            let k = min(1, room.width / size.width, room.height / size.height)
            size = NSSize(width: size.width * k, height: size.height * k)
        }
        let current = window.contentLayoutRect.size
        guard abs(size.width - current.width) > 0.01 || abs(size.height - current.height) > 0.01 else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let visible {
            frame.origin.x = max(min(frame.minX, visible.maxX - frame.width), visible.minX)
            frame.origin.y = max(min(frame.minY, visible.maxY - frame.height), visible.minY)
        }
        window.setFrame(frame, display: true)
    }

    /// The daemon's configuration changed (`immediate`: from this window's
    /// View menu). Filter and sharpness apply on the next frame; a new size
    /// or density re-plugs once, after a short pause so a Control Panel
    /// slider does not re-plug on every step.
    func configurationChanged(from old: VMConfig, immediate: Bool) {
        guard let app else { return }
        defer { quickSettings.refresh() }
        if old.performanceHUD != app.config.performanceHUD {
            hudOverride = nil
            applyHUDLevel()
        }
        if old.fpsLimit != app.config.fpsLimit { frameRateHint.setCap(app.config.fpsLimit) }
        let before = old.graphics(for: app.package, hasKeyMapping: hasKeyMapping)
        // The phone's screen is the device profile's: choosing another one changes it.
        let phoneChanged = old.deviceDisplay(in: app.profiles) != deviceDisplay
            && (before.settings.mode == .deviceProfile || graphics.settings.mode == .deviceProfile)
        guard before != graphics || phoneChanged else {
            // No re-plug follows to use up the "saved" notice's silence.
            quietNextSwitch = false
            return
        }
        graphicsChanged(immediate: immediate, orientationBefore: before.settings.orientation)
    }

    /// `orientationBefore`: a new orientation turns the window now, as an
    /// app asking for it does.
    private func graphicsChanged(immediate: Bool, orientationBefore: VMConfig.Orientation? = nil) {
        displayView.renderer.setOptions(renderOptions)
        applyHUDLevel()
        let orientation = graphics.settings.orientation
        if let orientationBefore, orientationBefore != orientation {
            applyOrientation(orientation == .landscape ? .landscape : .portrait)
        }
        applyWindowConstraints()
        scheduleResize(delay: immediate ? .zero : .milliseconds(300), announce: true)
    }

    /// A key mapping was created or removed: the app may become a game, or stop being one.
    private func keyMappingChanged(_ has: Bool) {
        defer { quickSettings.refresh() }
        guard has != hasKeyMapping else { return }
        let before = graphics
        hasKeyMapping = has
        if graphics != before { graphicsChanged(immediate: true, orientationBefore: before.settings.orientation) }
    }

    /// The View menu's first line and which of its items apply (GraphicsMenu).
    var graphicsMenuMode: GraphicsMenuMode {
        let resolved = graphics
        let base = resolved.profile == .games ? String(localized: "Game Settings", bundle: .windowHost)
                                              : String(localized: "App Settings", bundle: .windowHost)
        let line = if !resolved.changes.isEmpty {
            String(localized: "\(base), changed for this app", bundle: .windowHost)
        } else if resolved.reason == .keyMapping {
            String(localized: "Game Settings (key mapping)", bundle: .windowHost)
        } else {
            base
        }
        return GraphicsMenuMode(profileLine: line, mode: mode, phoneRatio: deviceDisplay?.ratioName)
    }

    @objc func toggleGameSettings(_ sender: Any?) {
        guard let app else { return }
        let chosen: GraphicsProfile = graphics.profile == .games ? .apps : .games
        let automatic: GraphicsProfile = hasKeyMapping ? .games : .apps
        var override = app.config.graphicsOverrides[app.package] ?? AppGraphicsOverride()
        override.profile = chosen == automatic ? nil : chosen
        saveGraphics(override)
    }

    @objc func chooseResolutionMode(_ sender: NSMenuItem) {
        guard let mode = (sender.representedObject as? String).flatMap(GraphicsSettings.Mode.init(rawValue:)) else { return }
        changeGraphics { $0.mode = mode }
    }

    @objc func chooseRenderScale(_ sender: NSMenuItem) {
        let percent = sender.tag
        changeGraphics {
            $0.mode = .followWindow
            $0.renderScale = percent
        }
    }

    /// Tag: pixels on the short side; 0 is Custom….
    @objc func chooseResolution(_ sender: NSMenuItem) {
        let pixels = sender.tag
        guard pixels > 0 else { return askCustomResolution() }
        changeGraphics {
            $0.mode = .fixed
            $0.shortSide = pixels
        }
    }

    /// The current mode's shape: follow mode keeps following the window.
    @objc func chooseAspectRatio(_ sender: NSMenuItem) {
        guard let ratio = (sender.representedObject as? String).flatMap(GraphicsSettings.AspectRatio.init(rawValue:)) else { return }
        let mode = mode
        changeGraphics { $0.setAspectRatio(ratio, for: mode) }
    }

    @objc func chooseOrientation(_ sender: NSMenuItem) {
        guard let orientation = (sender.representedObject as? String).flatMap(VMConfig.Orientation.init(rawValue:)) else { return }
        changeGraphics { $0.orientation = orientation }
    }

    @objc func chooseScalingFilter(_ sender: NSMenuItem) {
        guard let filter = (sender.representedObject as? String).flatMap(GraphicsSettings.Filter.init(rawValue:)) else { return }
        changeGraphics { $0.filter = filter }
    }

    @objc func useDefaultGraphicsSettings(_ sender: Any?) {
        app?.applyLocalOverride(nil)
    }

    private func askCustomResolution() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Custom Resolution", bundle: .windowHost)
        let range = GraphicsSettings.shortSideRange
        // Strings: resolutions are never digit-grouped ("2.160").
        let (low, high) = (String(range.lowerBound), String(range.upperBound))
        alert.informativeText = String(localized: "Pixels on the short side (an even number from \(low) to \(high)):", bundle: .windowHost)
        let field = NSTextField(string: "\(graphics.settings.shortSide)")
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 22)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Use", bundle: .windowHost))
        alert.addButton(withTitle: String(localized: "Cancel", bundle: .windowHost))
        alert.window.initialFirstResponder = field
        Task { [weak self] in
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn,
                  let value = Int(field.stringValue.filter(\.isNumber)) else { return }
            // Android needs an even number in range.
            let pixels = GraphicsSettings.normalizedShortSide(value)
            self?.changeGraphics {
                $0.mode = .fixed
                $0.shortSide = pixels
            }
        }
    }

    /// Stores the change as this app's own: only the fields that differ
    /// from its profile, so it keeps following later edits of the rest.
    private func changeGraphics(_ change: (inout GraphicsSettings) -> Void) {
        guard let app else { return }
        let resolved = graphics
        var settings = resolved.settings
        change(&settings)
        var override = app.config.graphicsOverrides[app.package] ?? AppGraphicsOverride()
        override.changes = GraphicsSettingsPatch.difference(settings, from: app.config.settings(for: resolved.profile))
        saveGraphics(override)
    }

    private func saveGraphics(_ override: AppGraphicsOverride) {
        guard let app else { return }
        let stored = override.isEmpty ? nil : override
        guard stored != app.config.graphicsOverrides[app.package] else { return }
        // Once per app (the shim's defaults are the app's): say where the change went.
        let key = "AvoGraphicsOverrideNoticeShown"
        if stored != nil, !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            quietNextSwitch = true
            notice.show(String(localized: "Graphics settings saved for \(app.label). View ▸ Use Default Graphics Settings undoes this.",
                               bundle: .windowHost))
        }
        app.applyLocalOverride(stored)
    }

    /// The HUD for this session (⌥⌘P), else the Control Panel's level.
    private var hudLevel: PerformanceHUDLevel { hudOverride ?? app?.config.performanceHUD ?? .off }

    private func applyHUDLevel() {
        hud.currentSharpness = graphics.settings.sharpness
        hud.level = hudLevel
        quickSettings.refresh()
    }

    /// Hides the HUD, or shows it at the Control Panel's level (FPS Only when that is off).
    @objc func togglePerformanceHUD(_ sender: Any?) {
        let global = app?.config.performanceHUD ?? .off
        setHUDLevel(hudLevel != .off ? .off : global == .off ? .fps : global)
    }

    @objc func choosePerformanceHUDLevel(_ sender: NSMenuItem) {
        guard let level = (sender.representedObject as? String).flatMap(PerformanceHUDLevel.init(rawValue:)) else { return }
        setHUDLevel(level)
    }

    private func setHUDLevel(_ level: PerformanceHUDLevel) {
        let wasOff = hudLevel == .off
        hudOverride = level
        applyHUDLevel()
        if wasOff, level != .off { notice.show(String(localized: "Performance HUD on. ⌥⌘P hides it.", bundle: .windowHost)) }
    }

    /// Checkmarks and enabled state of the View menu's graphics items; nil
    /// for any other item.
    private func validateGraphicsItem(_ item: NSMenuItem) -> Bool? {
        let resolved = graphics
        let settings = resolved.settings
        func check(_ on: Bool) { item.state = on ? .on : .off }
        switch item.action {
        case #selector(toggleGameSettings(_:)):
            check(resolved.profile == .games)
        case #selector(chooseResolutionMode(_:)):
            let choice = (item.representedObject as? String).flatMap(GraphicsSettings.Mode.init(rawValue:))
            check(choice == mode)
            guard choice == .deviceProfile else { break }
            // The phone's screen needs a phone: Avo's own identity has none.
            if deviceDisplay != nil, let name = app?.deviceProfile?.name {
                item.title = String(localized: "Phone’s Screen (\(name))", bundle: .windowHost)
                item.toolTip = nil
            } else {
                item.title = String(localized: "Phone’s Screen", bundle: .windowHost)
                item.toolTip = String(localized: "Choose a phone in Avo’s Settings › Privacy & Security › Device profile.", bundle: .windowHost)
            }
            return deviceDisplay != nil
        case #selector(chooseRenderScale(_:)):
            // Android's density cannot go below 120 dpi, which sets a floor on this screen.
            let lowest = DisplaySizing.minimumRenderScale(backingScale: Double(window?.backingScaleFactor ?? 2), interfaceScale: settings.interfaceScale)
            let title = GraphicsSettings.RenderScalePreset(rawValue: item.tag).map(GraphicsMenu.title) ?? item.title
            item.title = item.tag < lowest ? String(localized: "\(title) — not on this display", bundle: .windowHost) : title
            check(mode == .followWindow && settings.renderScale == item.tag)
            return item.tag >= lowest
        case #selector(chooseResolution(_:)):
            let preset = GraphicsSettings.resolutionPresets.contains(settings.shortSide)
            check(mode == .fixed && (item.tag == 0 ? !preset : settings.shortSide == item.tag))
        case #selector(chooseAspectRatio(_:)):
            check(mode != .deviceProfile && item.representedObject as? String == settings.aspectRatio(for: mode).rawValue)
            return mode != .deviceProfile
        case #selector(chooseOrientation(_:)):
            check(item.representedObject as? String == settings.orientation.rawValue)
        case #selector(chooseScalingFilter(_:)):
            check(item.representedObject as? String == settings.filter.rawValue)
        case #selector(togglePerformanceHUD(_:)):
            item.title = hudLevel == .off ? String(localized: "Show Performance HUD", bundle: .windowHost)
                                          : String(localized: "Hide Performance HUD", bundle: .windowHost)
        case #selector(choosePerformanceHUDLevel(_:)):
            check(item.representedObject as? String == hudLevel.rawValue)
        case #selector(useDefaultGraphicsSettings(_:)):
            return app.map { $0.config.graphicsOverrides[$0.package] != nil } ?? false
        default:
            return nil
        }
        return true
    }
}

/// An icon-only title bar button, outlined only under the pointer.
final class TitlebarButton: NSButton {
    /// Set: a click opens this menu under the button instead of sending an action.
    var popUpMenu: (() -> NSMenu?)? {
        didSet {
            target = self
            action = #selector(showPopUpMenu)
        }
    }

    convenience init(symbol: String, label: String, action: Selector?) {
        self.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        imagePosition = .imageOnly
        bezelStyle = .toolbar
        showsBorderOnlyWhileMouseInside = true
        // Typing stays with the Android display.
        refusesFirstResponder = true
        toolTip = label
        setAccessibilityLabel(label)
        self.action = action
    }

    @objc private func showPopUpMenu() {
        guard let menu = popUpMenu?() else { return }
        // Its top-left corner just under the button.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.height + 4 : -4), in: self)
    }
}

/// Icon, spinner and message shown until the first frame (or on errors).
final class PlaceholderView: NSView {
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        spinner.style = .spinning
        spinner.controlSize = .small
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let stack = NSStackView(views: [icon, spinner, label])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(icon image: NSImage?, message: String?, busy: Bool) {
        isHidden = false
        icon.image = image
        label.stringValue = message ?? ""
        label.isHidden = message == nil
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        spinner.isHidden = !busy
    }

    func hide() {
        spinner.stopAnimation(nil)
        isHidden = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden ? nil : super.hitTest(point)
    }
}

// MARK: - Screen lock (Android locked: VMStatus.screenLock, ScreenLockViews.swift)

extension AndroidWindowController {
    /// Android's status (ShimAppDelegate): the lock over the window comes and
    /// goes with it, and a window waiting for its display opens once Android
    /// runs unlocked, from wherever it was unlocked.
    func androidStatusChanged(_ status: VMStatus) {
        if status.state == .running, let lock = status.screenLock {
            showLock(lock)
            return
        }
        hideLock()
        guard status.state == .running, let pending = pendingAttach else { return }
        pendingAttach = nil
        attach(client: pending.client, notificationKey: pending.notificationKey)
    }

    /// Shows the lock until Android is unlocked, then opens the display.
    /// `lock` nil: Android refused the app for its lock before its status
    /// said so; that status is on its way, and the window asks again shortly.
    func waitForUnlock(_ lock: AndroidScreenLock?, client: DaemonClient, notificationKey: String?) {
        pendingAttach = (client, notificationKey)
        showLock(lock)
        guard lock == nil else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, let pending = pendingAttach, app?.screenLock == nil, app?.androidRunning == true else { return }
            pendingAttach = nil
            attach(client: pending.client, notificationKey: pending.notificationKey)
        }
    }

    private func showLock(_ lock: AndroidScreenLock?) {
        guard let app else { return }
        // The lock is entered in the window.
        if picture != nil { leavePictureInPicture(show: true) }
        let changed = lockOverlay.show(lock: lock, appName: app.label, icon: NSApp.applicationIconImage) { [weak app] credential in
            guard let app else { throw AvoError.daemonUnreachable("") }
            try await app.unlockAndroid(credential)
        }
        // Typing goes to the lock, not to Android.
        if changed { window?.makeFirstResponder(lockOverlay.focusTarget) }
    }

    private func hideLock() {
        guard lockOverlay.isShowing else { return }
        lockOverlay.hide()
        window?.makeFirstResponder(displayView)
    }
}

// MARK: - Quick Settings (the title bar's overlay, QuickSettings.swift)

extension AndroidWindowController: QuickSettingsTarget {
    var quickSettingsState: QuickSettingsState {
        var state = QuickSettingsState()
        guard let app else { return state }
        state.graphics = graphics
        if let profile = app.deviceProfile, let display = profile.display {
            state.phone = .init(name: profile.name, display: display)
        }
        state.hasOwnGraphics = app.config.graphicsOverrides[app.package] != nil
        state.lowestRenderScale = DisplaySizing.minimumRenderScale(backingScale: Double(window?.backingScaleFactor ?? 2),
                                                                   interfaceScale: state.graphics.settings.interfaceScale)
        state.fpsLimit = app.config.fpsLimit
        let screens = ScreenRefresh.attached
        state.fpsChoices = FrameRates.choices(for: screens, keeping: app.config.fpsLimit)
        state.fpsNote = FrameRates.screenNote(cap: app.config.fpsLimit, screens: screens)
        state.hudLevel = hudLevel
        if let keymap, keymap.profile != nil {
            state.keyMapping = .init(gameMode: keymap.gameMode, hintsVisible: KeymapHints.visible, hintsOpacity: KeymapHints.opacity)
        }
        state.scrollMode = WheelScrollController.settings.mode
        state.translating = translation.isActive
        state.canTranslate = displayID != nil
        state.translationTarget = ScreenTranslationSettings.target
        return state
    }

    /// As on the app's page in the Control Panel: the app keeps what it
    /// changed, minus what the new profile already has.
    func quickSettingsChooseProfile(_ choice: GraphicsProfile) {
        guard let app else { return }
        let automatic: GraphicsProfile = hasKeyMapping ? .games : .apps
        let base = app.config.settings(for: choice)
        saveGraphics(AppGraphicsOverride(profile: choice == automatic ? nil : choice,
                                         changes: .difference(graphics.changes.applied(to: base), from: base)))
    }

    func quickSettingsChangeGraphics(_ change: (inout GraphicsSettings) -> Void) {
        changeGraphics(change)
    }

    func quickSettingsUseDefaultGraphics() {
        app?.applyLocalOverride(nil)
    }

    func quickSettingsPreviewSharpness(_ sharpness: Int?) {
        let settings = graphics.settings
        displayView.renderer.setOptions(RenderOptions(filter: settings.filter, sharpness: sharpness ?? settings.sharpness))
    }

    func quickSettingsSetFrameRateLimit(_ fps: Int) {
        app?.applyFrameRateLimit(fps)
    }

    func quickSettingsSetHUDLevel(_ level: PerformanceHUDLevel) {
        setHUDLevel(level)
    }

    func quickSettingsSetGameMode(_ on: Bool) {
        keymap?.setGameMode(on)
    }

    func quickSettingsSetTranslating(_ on: Bool) {
        if translation.isActive != on { translation.toggle() }
    }
}
