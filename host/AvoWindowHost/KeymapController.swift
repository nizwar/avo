import AppKit
import AvoKeymap
import AvoKit
import AvoProtocol
import GameController

/// Runs the keymapping profile for one window (spec §5 and §5a): keys,
/// mouse buttons and gamepads become touches, FPS mode captures the pointer
/// and reads raw mouse movement, MOBA controls aim at the free cursor.
@MainActor
final class KeymapController {
    private let package: String
    private let displayID: UInt32
    private weak var view: DisplayView?
    private let send: (InputRecord) -> Void
    private let userProfileURL: URL
    /// The community profiles shipped with Avo.
    private let bundledDirectory: URL?
    private(set) var profile: KeymapProfile?
    private var engine: KeymapEngine?
    private var displayLink: CADisplayLink?
    /// The controllers' changes, from GamepadHub.
    private var gamepadListener: UUID?
    private var overlay: KeymapOverlay?
    private(set) var isPointerLocked = false
    /// While the pointer is locked: GameController's mouse notifications.
    private var mouseObservers: [any NSObjectProtocol] = []
    /// When raw motion last came from a mouse GameController sees.
    private var rawMotionAt: CFTimeInterval = 0
    /// This lock, the mouse moved without raw motion: its events count at once.
    private var eventMotionOnly = false
    /// A locked mouse's event motion, held until raw motion would have come
    /// (then it was the same movement, counted once).
    private var heldMotion: (dx: Double, dy: Double, since: CFTimeInterval)?
    /// The profile has MOBA controls, which need to know where the cursor is.
    private var aimsAtCursor = false
    /// Short messages for the window (mouse locked or freed).
    var onNotice: ((String) -> Void)?
    /// The layout's mode changed (a Switch Mode control, a new layout): its id.
    var onMode: ((String?) -> Void)?
    /// The mode the layout is in now; nil without modes.
    var mode: String? { engine?.mode }
    /// The profile in use changed (loaded, saved, imported).
    var onProfile: ((KeymapProfile?) -> Void)?
    /// The editor opened (true) or closed (false).
    var onEditing: ((Bool) -> Void)?
    /// The editor's panel went inside the window (true: the game moves over
    /// for it) or beside it, outside (false). KeymapOverlay decides.
    var onPanelInside: ((Bool) -> Void)?
    /// Game Mode turned on or off.
    var onGameMode: ((Bool) -> Void)?

    /// Game Mode (⌘G): the key mapping is in charge. Off, every key and
    /// click reaches the app as it is. Remembered per app.
    private(set) var gameMode = UserDefaults.standard.bool(forKey: "AvoGameMode")

    func setGameMode(_ on: Bool) {
        guard on != gameMode else { return }
        gameMode = on
        UserDefaults.standard.set(on, forKey: "AvoGameMode")
        // Nothing stays pressed or locked when the mapping lets go.
        if !on { focusLost() }
        updateTicking()
        onGameMode?(on)
        guard profile != nil else {
            // Nothing to map yet: the button alone would light up and do nothing.
            if on { onNotice?(String(localized: "This app has no key mapping yet. Press ⇧⌘K to set one up.", bundle: .windowHost)) }
            return
        }
        onNotice?(on ? String(localized: "Game Mode on: the key mapping is active. ⌘G turns it off.", bundle: .windowHost)
                     : String(localized: "Game Mode off: keys and clicks go to the app. ⌘G turns it on.", bundle: .windowHost))
    }

    /// The mapping takes input only in Game Mode and outside the editor.
    private var mapping: Bool { gameMode && engine != nil && overlay?.isEditing != true }

    /// Game Mode with a profile that binds the gamepad: its buttons and
    /// sticks become touches, and Android gets no gamepad (GamepadForwarder).
    /// The editor holds it too, while its buttons are being bound.
    var takesGamepad: Bool { (gameMode && profile?.usesGamepad == true) || overlay?.isEditing == true }

    /// The key that locks the mouse for the eye, when the profile has one.
    var mouseLockKey: String? { profile?.fps?.cursorToggle.shortLabel }

    init(package: String, displayID: UInt32, view: DisplayView, hostApplication: URL?, send: @escaping (InputRecord) -> Void) {
        self.package = package
        self.displayID = displayID
        self.view = view
        self.send = send
        userProfileURL = AvoPaths().keymap(for: package)
        bundledDirectory = Self.bundledDirectory(hostApplication: hostApplication)
        load()
        gamepadListener = GamepadHub.shared.addListener { [weak self] inputs, _ in self?.gamepad(inputs) }
    }

    /// Where Avo.app keeps the community profiles.
    static func bundledDirectory(hostApplication: URL?) -> URL? {
        hostApplication?.appending(path: "Contents/Resources/profiles/keymaps")
    }

    /// The user's profile wins over the community profile shipped with Avo.
    /// The window decides whether the app is a game by the same lookup, so
    /// its graphics profile and the key mapping always agree.
    private func load() {
        if let usable = KeymapProfile.usable(for: package, bundledDirectory: bundledDirectory) { apply(usable.profile) }
    }

    func apply(_ profile: KeymapProfile?) {
        if var engine { emit(engine.reset()); self.engine = engine }
        unlockPointer()
        self.profile = profile
        aimsAtCursor = profile?.controls.contains(where: \.followsCursor) == true
        guard let profile, let view else {
            engine = nil
            updateTicking()
            onProfile?(nil)
            onMode?(nil)
            return
        }
        let size = view.displaySize
        engine = KeymapEngine(profile: profile, displayID: displayID, width: size.width, height: size.height)
        updateTicking()
        onProfile?(profile)
        onMode?(engine?.mode)
    }

    func save(_ profile: KeymapProfile) throws {
        try FileManager.default.createDirectory(at: userProfileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try profile.encoded()
        try data.write(to: userProfileURL, options: .atomic)
        // Use what is on disk now: saving dropped any controls from a newer
        // Avo, and the editor must not warn about them when it opens again.
        apply(try KeymapProfile.decode(data))
        // Just set up: ready to play.
        setGameMode(true)
    }

    // MARK: Input from DisplayView (returns true when consumed)

    func key(_ key: KeyName, down: Bool, isRepeat: Bool) -> Bool {
        if overlay?.isEditing == true { return overlay?.assign(.key(key), down: down) ?? false }
        guard mapping else { return false }
        guard !isRepeat else { return engine?.profile.controls.contains { $0.allTriggers.contains(.key(key)) } == true }
        if down { reportCursor() }
        return handle(down ? .keyDown(key) : .keyUp(key))
    }

    func mouse(_ button: MouseButton, down: Bool) -> Bool {
        // The mouse locks only with the eye's key: a click is a click.
        guard mapping else { return false }
        if down { reportCursor() }
        if handle(down ? .mouseDown(button) : .mouseUp(button)) { return true }
        // A left click no control takes is a touch where it happens. It goes
        // in with the engine's touches: sent on its own (DisplayView's
        // PointerTranslator) it would also claim pointer 0, and Android would
        // drop a touch a key is holding, such as the MOBA joystick.
        guard button == .left, let p = clickLocation() else { return false }
        return handle(down ? .fingerDown(x: p.x, y: p.y) : .fingerUp(x: p.x, y: p.y))
    }

    /// Cursor movement in display pixels; true when an anchor tap took it.
    func pointerMoved(dx: Double, dy: Double) -> Bool {
        guard mapping else { return false }
        return handle(.pointerMoved(dx: dx, dy: dy))
    }

    func scroll(_ deltaY: Double) -> Bool {
        guard mapping, deltaY != 0 else { return false }
        return handle(.scroll(dy: deltaY))
    }

    func resize(width: Double, height: Double) {
        guard var engine else { return }
        emit(engine.resize(width: width, height: height))
        self.engine = engine
    }

    func focusLost() {
        unlockPointer()
        guard var engine else { return }
        emit(engine.reset())
        self.engine = engine
    }

    func stop() {
        focusLost()
        stopTicking()
        if let gamepadListener { GamepadHub.shared.removeListener(gamepadListener) }
        gamepadListener = nil
        overlay?.close()
    }

    private func handle(_ input: KeymapEngine.Input) -> Bool {
        guard var engine else { return false }
        let output = engine.handle(input, at: CACurrentMediaTime())
        self.engine = engine
        emit(output.events)
        if let mode = output.mode {
            onMode?(mode)
            if let name = profile?.modes.first(where: { $0.id == mode })?.name {
                onNotice?(String(localized: "Mode: \(name)", bundle: .windowHost))
            }
        }
        if let lock = output.pointerLock {
            if lock { lockPointer() } else { unlockPointer() }
        }
        return output.consumed
    }

    private func emit(_ events: [TouchEvent]) {
        for event in events { send(.touch(event)) }
    }

    // MARK: Cursor (MOBA controls)

    /// Tells the engine where the cursor is before a press, so a MOBA
    /// control aims the right way from its first frame.
    private func reportCursor() {
        guard aimsAtCursor, !isPointerLocked, let cursor = cursorInDisplay() else { return }
        _ = handle(.cursor(x: cursor.x, y: cursor.y))
    }

    /// The cursor in display pixels, not clamped to the display: beyond the
    /// game's edge it still gives a direction.
    private func cursorInDisplay() -> (x: Double, y: Double)? {
        guard let window = view?.window else { return nil }
        return inDisplay(window.mouseLocationOutsideOfEventStream)
    }

    /// Where the left click being handled happened, in display pixels (the
    /// cursor may have moved on since), else where the cursor is now.
    private func clickLocation() -> (x: Double, y: Double)? {
        guard let window = view?.window else { return nil }
        if let event = NSApp.currentEvent, event.window === window, [.leftMouseDown, .leftMouseUp].contains(event.type) {
            return inDisplay(event.locationInWindow)
        }
        return cursorInDisplay()
    }

    private func inDisplay(_ locationInWindow: NSPoint) -> (x: Double, y: Double)? {
        guard let view else { return nil }
        let rect = view.displayRect, size = view.displaySize
        guard rect.width > 0, rect.height > 0 else { return nil }
        let point = view.convert(locationInWindow, from: nil)
        return ((point.x - rect.minX) / rect.width * size.width, (rect.maxY - point.y) / rect.height * size.height)
    }

    // MARK: Timing

    /// The engine ticks on every display refresh only while it can act:
    /// Game Mode on with a profile. Off, the engine is reset (nothing held,
    /// nothing scheduled) and the main thread has nothing to do per frame.
    /// The controller editor's live view does not need it (GamepadHub).
    private func updateTicking() {
        if gameMode && engine != nil { startTicking() } else { stopTicking() }
    }

    private func startTicking() {
        guard displayLink == nil, let view else { return }
        let link = view.displayLink(target: TickTarget { [weak self] in self?.tick() }, selector: #selector(TickTarget.fire))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopTicking() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        if isPointerLocked { flushHeldMotion(at: now) }
        guard var engine else { return }
        // A held MOBA control or click reads the cursor on every frame: while
        // a mouse button is down macOS sends drags, which never reach pointerMoved.
        if engine.isFollowingCursor, mapping, !isPointerLocked, let cursor = cursorInDisplay() {
            emit(engine.handle(.cursor(x: cursor.x, y: cursor.y), at: now).events)
        }
        emit(engine.tick(at: now))
        self.engine = engine
    }

    // MARK: Pointer lock (FPS mode)

    private func lockPointer() {
        guard !isPointerLocked, let view, let window = view.window else { return }
        isPointerLocked = true
        if let toggle = engine?.profile.fps?.cursorToggle.shortLabel {
            onNotice?(String(localized: "Mouse locked for aiming. Press \(toggle) to free it.", bundle: .windowHost))
        }
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        // Park the hidden cursor over the window so clicks keep landing here.
        let center = window.convertPoint(toScreen: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
        if let screen = window.screen {
            CGWarpMouseCursorPosition(CGPoint(x: center.x, y: screen.frame.maxY - center.y))
        }
        // Raw, unaccelerated deltas (spec §5a: "gerakan mouse mentah").
        listenToMice()
        if var engine {
            emit(engine.setPointerLocked(true))
            self.engine = engine
        }
    }

    private func unlockPointer() {
        guard isPointerLocked else { return }
        isPointerLocked = false
        if let toggle = engine?.profile.fps?.cursorToggle.shortLabel {
            onNotice?(String(localized: "Mouse free. Press \(toggle) to aim with it.", bundle: .windowHost))
        }
        stopListeningToMice()
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        if var engine {
            emit(engine.setPointerLocked(false))
            self.engine = engine
        }
    }

    // Raw motion while the pointer is locked: from every mouse GameController
    // sees (GCMouse.current is only the one that moved last, so a second
    // mouse, or a trackpad used before it, went unheard), and for a mouse it
    // does not see (some wireless receivers) from the window's mouse events,
    // which stand in while no raw motion comes.

    private func listenToMice() {
        for mouse in GCMouse.mice() { listen(to: mouse) }
        mouseObservers = [Notification.Name.GCMouseDidConnect, .GCMouseDidBecomeCurrent].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isPointerLocked else { return }
                    for mouse in GCMouse.mice() { self.listen(to: mouse) }
                }
            }
        }
    }

    private func listen(to mouse: GCMouse) {
        mouse.mouseInput?.mouseMovedHandler = { [weak self] _, dx, dy in
            MainActor.assumeIsolated { self?.rawMotion(dx: Double(dx), dy: Double(-dy)) }
        }
    }

    private func stopListeningToMice() {
        for mouse in GCMouse.mice() { mouse.mouseInput?.mouseMovedHandler = nil }
        for observer in mouseObservers { NotificationCenter.default.removeObserver(observer) }
        mouseObservers = []
        heldMotion = nil
        eventMotionOnly = false
    }

    private func rawMotion(dx: Double, dy: Double) {
        rawMotionAt = CACurrentMediaTime()
        // What the window's events said meanwhile was this same movement.
        heldMotion = nil
        eventMotionOnly = false
        _ = handle(.mouseMoved(dx: dx, dy: dy))
    }

    /// The window's mouse motion while the pointer is locked (DisplayView):
    /// it counts for a mouse GameController does not see.
    func lockedMotion(dx: Double, dy: Double) {
        guard isPointerLocked, mapping, dx != 0 || dy != 0 else { return }
        let now = CACurrentMediaTime()
        // Raw motion is coming: this is the same movement.
        if now - rawMotionAt < 0.5 { return }
        if eventMotionOnly {
            _ = handle(.mouseMoved(dx: dx, dy: dy))
            return
        }
        let held = heldMotion
        heldMotion = (dx + (held?.dx ?? 0), dy + (held?.dy ?? 0), held?.since ?? now)
    }

    /// Event motion no raw motion followed: a mouse GameController does not
    /// see. It moves the eye, and from now on (this lock) its events at once.
    private func flushHeldMotion(at now: CFTimeInterval) {
        guard let held = heldMotion, now - held.since >= 0.05 else { return }
        heldMotion = nil
        eventMotionOnly = true
        _ = handle(.mouseMoved(dx: held.dx, dy: held.dy))
    }

    // MARK: Gamepads (GameController.framework, through GamepadHub)

    /// The controller's buttons and sticks, for the key window's mapping.
    /// With vibration on, a button that touches the screen gives a short
    /// pulse (on controllers that can).
    private func gamepad(_ inputs: [KeymapEngine.Input]) {
        guard mapping, view?.window?.isKeyWindow == true else { return }
        var touched = false
        for input in inputs {
            if case .gamepadButton(_, true) = input {
                reportCursor()
                touched = handle(input) || touched
            } else {
                _ = handle(input)
            }
        }
        if touched, profile?.gamepadSettings.vibration == true { GamepadHub.shared.pulse() }
    }

    // MARK: Editor (Cmd+Shift+K)

    /// Opens the editor, or closes it. Its bar's Controller button brings
    /// the controller panel out (ControllerPanel.swift).
    func toggleEditor(over window: NSWindow?) {
        guard let window, let view else { return }
        if let overlay, overlay.isEditing {
            overlay.cancel()
            return
        }
        focusLost()
        let overlay = KeymapOverlay(window: window, view: view, package: package, profile: profile) { [weak self] profile in
            do {
                try self?.save(profile)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        overlay.onClose = { [weak self] in
            self?.overlay = nil
            self?.onEditing?(false)
            GamepadForwarder.shared.update()
        }
        overlay.onPanelInside = { [weak self] inside in self?.onPanelInside?(inside) }
        self.overlay = overlay
        onEditing?(true)
        overlay.show()
        // The controller is the editor's now, not Android's.
        GamepadForwarder.shared.update()
    }
}

/// CADisplayLink needs an Objective-C target.
private final class TickTarget: NSObject {
    let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @MainActor @objc func fire() { action() }
}
