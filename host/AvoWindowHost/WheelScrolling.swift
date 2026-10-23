import AppKit
import AvoKeymap
import AvoKit
import AvoProtocol
import IOSurface
import QuartzCore

/// The mouse wheel in one window, by the scroll mode (Controls ▸ Scrolling,
/// ScrollModeMenu): Android scroll events, a finger that swipes
/// (WheelSwipe), or in Automatic mode scroll events that are watched on
/// screen and replayed as a swipe where the app ignores them (WheelScroller;
/// the rules are in AvoKeymap's WheelScrolling.swift). In Mouse Wheel mode
/// the trackpad sends scroll events too; otherwise DisplayView turns it into
/// a finger, as before.
///
/// Watching is cheap: a band of the frame around the pointer, read in place
/// from the frame's IOSurface on the render queue and scaled down to a few
/// thousand gray cells (ScrollRegion), only while a burst is watched, at most
/// every 30 ms and only when Android drew a new frame.
///
/// The wheel's finger never overlaps another touch: it does not go down
/// while a click, a drag, a trackpad gesture or a pinch holds the touches,
/// or while the key mapping is in charge (Game Mode with a profile, whose
/// touches it would break: the wheel then sends scroll events, after the
/// key mapping had its turn). A click, a trackpad gesture, a pinch, a new
/// display size or focus leaving the window lifts it with ACTION_CANCEL.
@MainActor
final class WheelScrollController {
    /// Where the scroll mode is kept (ScrollModeSettings).
    static let settings = ScrollModeSettings(app: .standard, shared: UserDefaults(suiteName: AvoIdentifiers.windowHost) ?? .standard)
    /// Automatic mode found that this app ignores scroll events (for the menu).
    static var swipesLearned = false

    private weak var view: DisplayView?
    /// Android's density for the display, in pixels per dp (from the window).
    var density: () -> Double? = { nil }

    private var scroller = WheelScroller(width: 1080, height: 2340)
    private var finger: WheelSwipe?
    /// The axis the finger's burst scrolls along.
    private var fingerAxis = ScrollAxis.vertical
    /// The content under the finger's drag, while it has not followed yet.
    private var watch: SwipeWatch?
    /// Counts the watches, so a look judged off the main thread finds its own.
    private var watchNumber = 0
    private var watchRegion: ScrollRegion?
    private var probeRegion: ScrollRegion?
    /// The content followed the finger in this burst: its next drags lift
    /// with ACTION_UP without waiting to see it again.
    private var burstFollowed = false
    private var lastLift = -Double.infinity
    private var link: CADisplayLink?
    private var lookInFlight = false
    private var lastLook = -Double.infinity
    private var lastSequence: UInt64 = 0
    /// The screen as the last swipe left it (a later change re-tries scroll events).
    private var resting: ScreenSample?
    private var restingTask: Task<Void, Never>?
    /// Bumps when what is in progress ends, so late answers are dropped.
    private var generation = 0
    /// The trackpad's pixels not sent yet (Mouse Wheel mode).
    private var trackpadRest = (x: 0.0, y: 0.0)
    private var lastMode: ScrollMode?
    private weak var observedWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []

    static let lookInterval: TimeInterval = 0.03

    init(view: DisplayView) {
        self.view = view
    }

    private var displaySize: CGSize { view?.displaySize ?? CGSize(width: 1080, height: 2340) }

    /// The key mapping holds the touches (Game Mode with a profile, or the mouse locked for aiming).
    private var keymapHoldsTouches: Bool {
        guard let keymap = view?.keymap else { return false }
        return keymap.isPointerLocked || (keymap.gameMode && keymap.profile != nil)
    }

    // MARK: Input from DisplayView

    /// A scroll event the key mapping did not take, at `point` in display
    /// pixels. True when it was handled here: always for the mouse wheel,
    /// for the trackpad in Mouse Wheel mode. `touchesBusy`: a click, drag,
    /// trackpad gesture or pinch of the window's own is in progress.
    func handle(_ event: NSEvent, at point: (x: Double, y: Double), touchesBusy: Bool) -> Bool {
        observeWindow()
        let mode = Self.settings.mode
        if let lastMode, lastMode != mode { interrupt() }
        lastMode = mode
        if event.hasPreciseScrollingDeltas {
            guard mode == .mouseWheel else { return false }
            trackpad(event, at: point)
            return true
        }
        let lines = WheelNotch.lines(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                                     shift: event.modifierFlags.contains(.shift))
        let now = CACurrentMediaTime()
        let size = displaySize
        if scroller.width != size.width || scroller.height != size.height {
            scroller.resize(width: size.width, height: size.height)
        }
        run(scroller.notch(dx: lines.dx, dy: lines.dy, x: point.x, y: point.y, mode: mode,
                           touches: !touchesBusy && !keymapHoldsTouches, fingerDown: finger?.isActive == true, at: now))
        return true
    }

    /// A gesture of the window's own takes the touches (a click, the
    /// trackpad, a pinch): the wheel's finger lets go first.
    func interrupt() {
        generation += 1
        scroller.cancel()
        probeRegion = nil
        endWatch()
        if var finger, finger.isActive {
            send(finger.cancel())
            self.finger = finger
        }
        burstFollowed = false
        stopTickingIfIdle()
    }

    /// Android's display changed size: nothing in progress fits it.
    func displayChanged() {
        interrupt()
        resting = nil
        let size = displaySize
        scroller.resize(width: size.width, height: size.height)
    }

    // MARK: Commands

    private func run(_ commands: [WheelScroller.Command]) {
        for command in commands {
            switch command {
            case let .scroll(x, y, dx, dy):
                guard let view else { continue }
                view.send?(.scroll(WheelNotch.scrollEvent(displayID: view.displayID, x: x, y: y, dx: dx, dy: dy)))
            case let .swipe(x, y, dx, dy):
                swipe(x: x, y: y, dx: dx, dy: dy)
            case let .samplePicture(x, y, axis):
                let size = displaySize
                let region = ScrollRegion(around: x, y, axis: axis, width: size.width, height: size.height)
                probeRegion = region
                answer { [weak self] in
                    let look = await self?.sample(region, newerThan: nil)
                    if let sequence = look?.sequence { self?.lastSequence = sequence }
                    return { $0.pictureBefore(look?.sample, at: CACurrentMediaTime()) }
                }
            case .checkScreen:
                answer { [weak self] in
                    let changed = await self?.screenChanged() ?? false
                    return { $0.screenChecked(changed, at: CACurrentMediaTime()) }
                }
            }
        }
        startTickingIfNeeded()
    }

    /// Gets the answer to a command off the main actor and hands it to the
    /// scroller, unless what it was for ended meanwhile.
    private func answer(_ work: @escaping @MainActor () async -> (inout WheelScroller) -> [WheelScroller.Command]) {
        let generation = self.generation
        Task { [weak self] in
            let reply = await work()
            guard let self, generation == self.generation else { return }
            run(reply(&scroller))
        }
    }

    // MARK: The finger

    private func swipe(x: Double, y: Double, dx: Double, dy: Double) {
        guard let view else { return }
        let now = CACurrentMediaTime()
        if finger?.isActive != true {
            let size = displaySize
            finger = WheelSwipe(displayID: view.displayID, width: size.width, height: size.height, density: density() ?? 2)
            fingerAxis = WheelNotch.axis(dx: dx, dy: dy)
            // A new burst sees again whether the content follows.
            if now - lastLift >= WheelScroller.burstGap { burstFollowed = false }
        }
        guard var finger else { return }
        let events = finger.add(dx: dx, dy: dy, x: x, y: y, at: now)
        self.finger = finger
        fingerMoved(events, at: now)
        startTickingIfNeeded()
    }

    /// Sends the finger's events and follows its drags: a drag that begins
    /// is watched (unless the content followed already in this burst), and
    /// one that ends tells the scroller whether the content followed.
    private func fingerMoved(_ events: [TouchEvent], at time: TimeInterval) {
        guard !events.isEmpty else { return }
        send(events)
        for event in events {
            switch event.action {
            case .down:
                beginWatch(axis: fingerAxis)
            case .up, .cancel:
                let followed = finger?.contentFollows == true
                if followed {
                    burstFollowed = true
                }
                lastLift = time
                endWatch()
                scroller.swipeEnded(followed: followed, at: time)
                noteRoute()
                if finger?.isActive != true { scheduleRestingLook() }
            default:
                break
            }
        }
    }

    private func beginWatch(axis: ScrollAxis) {
        guard var finger else { return }
        endWatch()
        // Followed already in this burst: the same view under the same place.
        finger.contentFollows = burstFollowed ? true : nil
        self.finger = finger
        guard !burstFollowed else { return }
        let size = displaySize
        let region = ScrollRegion(around: finger.start.x, finger.start.y, axis: axis, width: size.width, height: size.height)
        watchRegion = region
        let since = CACurrentMediaTime()
        let generation = self.generation
        Task { [weak self] in
            let look = await self?.sample(region, newerThan: nil)
            guard let self, generation == self.generation, watchRegion == region, self.finger?.isDown == true,
                  let look else { return }
            lastSequence = look.sequence
            // From now on it lifts with ACTION_UP only if the content follows (SwipeWatch.verdict).
            watch = SwipeWatch(axis: axis, before: look.sample, since: since)
            watchNumber += 1
        }
    }

    private func endWatch() {
        watch = nil
        watchRegion = nil
    }

    // MARK: Time and looks

    private var needsTicks: Bool {
        finger?.isActive == true || scroller.isBusy || watch != nil || watchRegion != nil
    }

    private func startTickingIfNeeded() {
        guard link == nil, needsTicks, let view else { return }
        let link = view.displayLink(target: WheelTickTarget { [weak self] in self?.tick() }, selector: #selector(WheelTickTarget.fire))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopTickingIfIdle() {
        guard !needsTicks else { return }
        link?.invalidate()
        link = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        if var finger, finger.isActive {
            if let watch { finger.contentFollows = watch.verdict(at: now) }
            let events = finger.tick(at: now)
            self.finger = finger
            fingerMoved(events, at: now)
        }
        run(scroller.tick(at: now))
        noteRoute()
        lookIfDue(at: now)
        stopTickingIfIdle()
    }

    /// Samples the watched region when Android drew a new frame: the
    /// probe's while it watches scroll events, else the finger's drag. The
    /// comparison runs off the main thread; what it says is applied here,
    /// unless what it was for ended meanwhile.
    private func lookIfDue(at time: TimeInterval) {
        guard !lookInFlight, time - lastLook >= Self.lookInterval else { return }
        let forProbe = scroller.isWatching
        guard let region = forProbe ? probeRegion : (watch != nil ? watchRegion : nil) else { return }
        lookInFlight = true
        lastLook = time
        let generation = self.generation
        Task { [weak self] in
            defer { self?.lookInFlight = false }
            guard let look = await self?.sample(region, newerThan: self?.lastSequence),
                  let self, generation == self.generation else { return }
            lastSequence = look.sequence
            if forProbe {
                guard let probe = scroller.probe, probeRegion == region else { return }
                let number = scroller.probeNumber
                let slid = await Self.judge { probe.slid(look.sample) }
                guard generation == self.generation else { return }
                scroller.look(look.sample, slid: slid, probe: number, at: CACurrentMediaTime())
                noteRoute()
            } else if let watch, watchRegion == region, let finger, finger.isDown {
                let number = watchNumber
                let moved = watch.axis == .vertical ? finger.displacement.dy : finger.displacement.dx
                let follows = await Self.judge { watch.follows(look.sample, displacement: moved) }
                guard generation == self.generation, number == watchNumber, var current = self.watch else { return }
                if current.look(look.sample, displacement: moved, follows: follows), var finger = self.finger, finger.isDown {
                    finger.contentFollows = true
                    self.finger = finger
                    burstFollowed = true
                    endWatch()
                } else {
                    self.watch = current
                }
            }
        }
    }

    /// Compares looks off the main thread: it takes milliseconds in a debug build.
    private static func judge(_ work: @escaping @Sendable () -> Bool) async -> Bool {
        await Task.detached(priority: .userInitiated) { work() }.value
    }

    /// The region of the frame on screen, if Android drew one since
    /// `newerThan` (nil: whatever is on screen).
    private func sample(_ region: ScrollRegion, newerThan: UInt64?) async -> (sample: ScreenSample, sequence: UInt64)? {
        guard let renderer = view?.renderer else { return nil }
        return await renderer.withShownFrame { surface, sequence in
            guard let surface, newerThan.map({ sequence > $0 }) ?? true,
                  let sample = surface.graySample(of: region.rect, columns: region.columns, rows: region.rows) else { return nil }
            return (sample, sequence)
        }
    }

    /// The whole frame on the grid Translate Screen uses.
    private func sampleScreen() async -> ScreenSample? {
        guard let renderer = view?.renderer else { return nil }
        return await renderer.withShownFrame { surface, _ in
            guard let surface else { return nil }
            let grid = ScreenSample.grid(width: surface.width, height: surface.height)
            return surface.graySample(of: CGRect(x: 0, y: 0, width: surface.width, height: surface.height),
                                      columns: grid.columns, rows: grid.rows)
        }
    }

    /// After the last drag of a burst, once the screen holds still: the
    /// screen as the swipe left it.
    private func scheduleRestingLook() {
        restingTask?.cancel()
        guard scroller.route.way == .swipes else { return }
        restingTask = Task { [weak self] in
            var previous: ScreenSample?
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let self, self.finger?.isActive != true else { return }
                let now = await sampleScreen()
                if let now, let previous, previous.matches(now, tolerance: 3) { break }
                previous = now
            }
            self?.resting = previous
        }
    }

    /// Whether the screen changed by more than half since the last swipe
    /// left it: another screen of the app.
    private func screenChanged() async -> Bool {
        guard let resting else { return false }
        guard let now = await sampleScreen() else { return false }
        guard let changes = resting.changes(to: now) else { return true }
        return changes.fraction >= 0.5
    }

    private func noteRoute() {
        Self.swipesLearned = scroller.route.way == .swipes
    }

    // MARK: Trackpad in Mouse Wheel mode

    /// The trackpad's pixels as Android scroll events, momentum included
    /// (Android does not fling a scroll event by itself). Android scrolls
    /// whole pixels for each event, so the rest waits for the next one.
    private func trackpad(_ event: NSEvent, at point: (x: Double, y: Double)) {
        guard let view else { return }
        if event.phase.contains(.began) {
            interrupt()
            trackpadRest = (0, 0)
        }
        let rect = view.displayRect, size = view.displaySize
        trackpadRest.x += event.scrollingDeltaX * size.width / max(rect.width, 1)
        trackpadRest.y += event.scrollingDeltaY * size.height / max(rect.height, 1)
        let whole = (x: trackpadRest.x.rounded(.towardZero), y: trackpadRest.y.rounded(.towardZero))
        guard whole.x != 0 || whole.y != 0 else { return }
        trackpadRest.x -= whole.x
        trackpadRest.y -= whole.y
        let line = WheelNotch.androidLineDP * (density() ?? 2)
        // A quarter pixel over: views truncate or round lines × their factor.
        func lines(_ pixels: Double) -> Double { pixels == 0 ? 0 : (pixels + (pixels < 0 ? -0.25 : 0.25)) / line }
        view.send?(.scroll(WheelNotch.scrollEvent(displayID: view.displayID, x: point.x, y: point.y,
                                                  dx: lines(whole.x), dy: lines(whole.y))))
    }

    // MARK: Plumbing

    private func send(_ events: [TouchEvent]) {
        for event in events { view?.send?(.touch(event)) }
    }

    /// Focus leaving the window lifts the finger (the window's own handler
    /// lets go of the key mapping's touches).
    private func observeWindow() {
        guard let window = view?.window, window !== observedWindow else { return }
        stopObserving()
        observedWindow = window
        observers = [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                let closing = note.name == NSWindow.willCloseNotification
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.interrupt()
                    if closing { self.stopObserving() }
                }
            }
        }
    }

    private func stopObserving() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        observedWindow = nil
    }
}

/// CADisplayLink needs an Objective-C target.
private final class WheelTickTarget: NSObject {
    let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @MainActor @objc func fire() { action() }
}

extension IOSurface {
    /// The part of the frame in `rect` (pixels, origin at the top left) as
    /// `columns` × `rows` gray cells, each the average of the pixels it
    /// covers. Reads those pixels in place, without copying the frame: call
    /// it where the surface holds a whole frame (MetalRenderer.withShownFrame).
    func graySample(of rect: CGRect, columns: Int, rows: Int) -> ScreenSample? {
        guard let format = FramePixelFormat(pixelFormat), columns > 0, rows > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let area = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !area.isNull, area.width >= 1, area.height >= 1 else { return nil }
        let x = Int(area.minX), y = Int(area.minY), w = Int(area.width), h = Int(area.height)
        lock(options: .readOnly, seed: nil)
        defer { unlock(options: .readOnly, seed: nil) }
        var cells = [UInt8](repeating: 0, count: columns * rows)
        let drawn = cells.withUnsafeMutableBytes { buffer -> Bool in
            let first = baseAddress.advanced(by: y * bytesPerRow + x * 4)
            // The image lives only for this draw, inside the lock.
            guard let provider = CGDataProvider(dataInfo: nil, data: first, size: (h - 1) * bytesPerRow + w * 4,
                                                releaseData: { _, _, _ in }),
                  let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                      space: space, bitmapInfo: format.bitmapInfo, provider: provider, decode: nil,
                                      shouldInterpolate: false, intent: .defaultIntent),
                  let context = CGContext(data: buffer.baseAddress, width: columns, height: rows, bitsPerComponent: 8,
                                          bytesPerRow: columns, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            // Medium is Core Graphics' box filter: each cell the true average.
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
            return true
        }
        guard drawn else { return nil }
        return ScreenSample(width: w, height: h, columns: columns, rows: rows, cells: cells)
    }
}

// MARK: - Menu

/// Controls ▸ Scrolling, also in the title bar's game controller menu: how
/// the mouse wheel (and the trackpad) scroll this app, and the default for
/// every app. The app's choice is kept in its App Shim's defaults, the
/// default in the Window Host's (ScrollModeSettings); choosing the default's
/// mode for the app follows the default again.
@MainActor
final class ScrollModeMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
    static let shared = ScrollModeMenu()

    /// A new item with the submenu (each menu needs its own).
    func makeItem() -> NSMenuItem {
        let menu = NSMenu(title: String(localized: "Scrolling", bundle: .windowHost))
        menu.delegate = self
        for mode in ScrollMode.allCases {
            let item = menu.addItem(withTitle: Self.name(of: mode), action: #selector(chooseAppMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
        }
        menu.addItem(.separator())
        let defaults = NSMenu(title: String(localized: "Default for All Apps", bundle: .windowHost))
        for mode in ScrollMode.allCases {
            let item = defaults.addItem(withTitle: Self.name(of: mode), action: #selector(chooseDefaultMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
        }
        menu.addItem(withTitle: defaults.title, action: nil, keyEquivalent: "").submenu = defaults
        menuNeedsUpdate(menu)
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        item.symbol("scroll")
        return item
    }

    /// The default's mode says so; each mode says what it does (and
    /// Automatic what it found out).
    func menuNeedsUpdate(_ menu: NSMenu) {
        let settings = WheelScrollController.settings
        for item in menu.items where item.action == #selector(chooseAppMode(_:)) {
            guard let mode = (item.representedObject as? String).flatMap(ScrollMode.init(rawValue:)) else { continue }
            let name = Self.name(of: mode)
            item.title = mode == settings.defaultMode ? String(localized: "\(name) (Default)", bundle: .windowHost) : name
            item.subtitle = Self.explanation(of: mode)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let settings = WheelScrollController.settings
        let mode = (item.representedObject as? String).flatMap(ScrollMode.init(rawValue:))
        if item.action == #selector(chooseAppMode(_:)) { item.state = mode == settings.mode ? .on : .off }
        if item.action == #selector(chooseDefaultMode(_:)) { item.state = mode == settings.defaultMode ? .on : .off }
        return true
    }

    @objc private func chooseAppMode(_ item: NSMenuItem) {
        guard let mode = (item.representedObject as? String).flatMap(ScrollMode.init(rawValue:)) else { return }
        WheelScrollController.settings.setAppMode(mode)
    }

    @objc private func chooseDefaultMode(_ item: NSMenuItem) {
        guard let mode = (item.representedObject as? String).flatMap(ScrollMode.init(rawValue:)) else { return }
        WheelScrollController.settings.setDefaultMode(mode)
    }

    static func name(of mode: ScrollMode) -> String {
        switch mode {
        case .automatic: String(localized: "Automatic", bundle: .windowHost)
        case .mouseWheel: String(localized: "Mouse Wheel", bundle: .windowHost)
        case .swipe: String(localized: "Swipe", bundle: .windowHost)
        }
    }

    /// Also under the Quick Settings overlay's scrolling choice.
    static func explanation(of mode: ScrollMode) -> String {
        switch mode {
        case .automatic:
            WheelScrollController.swipesLearned
                ? String(localized: "Swiping now: this app ignores mouse wheel scrolling", bundle: .windowHost)
                : String(localized: "Mouse wheel scrolling, or swiping where the app ignores it", bundle: .windowHost)
        case .mouseWheel: String(localized: "Mouse wheel scrolling only, from the trackpad too", bundle: .windowHost)
        case .swipe: String(localized: "Swiping like a finger, from the mouse wheel too", bundle: .windowHost)
        }
    }
}

/// The scrolling every app starts with, for the Control Panel's Settings
/// (Avo.app): the same choice as Game Controls › Scrolling › Default for All
/// Apps in an app window. Apps with a choice of their own keep it.
@MainActor
public enum ScrollingDefaultChoice {
    public static func name(of mode: ScrollMode) -> String { ScrollModeMenu.name(of: mode) }

    /// What `mode` does (Automatic as it starts in an app).
    public static func explanation(of mode: ScrollMode) -> String { ScrollModeMenu.explanation(of: mode) }

    public static var mode: ScrollMode {
        get { settings.defaultMode }
        set { settings.setDefaultMode(newValue) }
    }

    private static var settings: ScrollModeSettings {
        ScrollModeSettings(app: .standard, shared: UserDefaults(suiteName: AvoIdentifiers.windowHost) ?? .standard)
    }
}
