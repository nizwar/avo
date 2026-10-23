import AppKit
import AvoKit
import AvoProtocol
import IOSurface
import os

/// What the widget panels ask of the daemon they run in (AvoDaemon's
/// DaemonApp wires these to DaemonCore for its in-process client).
public struct WidgetPanelsBackend: Sendable {
    public var openDisplay: @Sendable (OpenDisplayRequest) async throws -> UInt32
    /// Display, width, height (pixels) and density.
    public var resizeDisplay: @Sendable (UInt32, UInt32, UInt32, UInt32) async throws -> Void
    public var closeDisplay: @Sendable (UInt32) async -> Void
    /// Input channel records for the panels' displays.
    public var sendInput: @Sendable (Data) async -> Void
    public var removeWidget: @Sendable (String) async throws -> Void

    public init(openDisplay: @escaping @Sendable (OpenDisplayRequest) async throws -> UInt32,
                resizeDisplay: @escaping @Sendable (UInt32, UInt32, UInt32, UInt32) async throws -> Void,
                closeDisplay: @escaping @Sendable (UInt32) async -> Void,
                sendInput: @escaping @Sendable (Data) async -> Void,
                removeWidget: @escaping @Sendable (String) async throws -> Void) {
        self.openDisplay = openDisplay
        self.resizeDisplay = resizeDisplay
        self.closeDisplay = closeDisplay
        self.sendInput = sendInput
        self.removeWidget = removeWidget
    }
}

/// Android widgets on the Mac: one floating panel per `PlacedWidget`, each
/// showing a display on which Avo Widgets (in Android) shows the widget, live
/// and clickable. The panels run in the daemon's process, which is there
/// whenever Android is: `client` is their in-process client of the daemon
/// (events and frames come to it as to an App Shim's connection).
@MainActor
public final class WidgetPanels {
    /// Give it to the daemon as the client's proxy.
    public let client: AvoClientXPC
    private let frames = FrameRouter()
    private var backend: WidgetPanelsBackend?
    private var panels: [String: WidgetPanel] = [:]
    private var widgets: [PlacedWidget] = []
    fileprivate(set) var status = VMStatus.stopped

    public init() {
        let receiver = InProcessClient(frames: frames)
        client = receiver
        receiver.panels = self
    }

    /// Once the daemon registered `client`.
    public func connect(_ backend: WidgetPanelsBackend) {
        self.backend = backend
        reconcile()
    }

    fileprivate func handle(_ event: DaemonEvent) {
        switch event {
        case .widgets(let widgets):
            self.widgets = widgets
            reconcile()
        case .vmStatus(let status):
            self.status = status
            for panel in panels.values { panel.androidChanged() }
        case .displayReady(let id):
            panels.values.first { $0.displayID == id }?.displayReady()
        case .displayClosed(let id):
            panels.values.first { $0.displayID == id }?.displayClosed()
        case .displayTitle(let id, let top):
            panels.values.first { $0.displayID == id }?.showing(top: top)
        default:
            break
        }
    }

    /// A panel for every widget, none for removed ones.
    private func reconcile() {
        guard let backend else { return }
        for (id, panel) in panels where !widgets.contains(where: { $0.id == id }) {
            panel.forget()
            panel.close()
            panels[id] = nil
        }
        for (index, widget) in widgets.enumerated() {
            if let panel = panels[widget.id] {
                panel.update(widget)
                continue
            }
            let panel = WidgetPanel(widget: widget, index: index, owner: self, backend: backend, frames: frames)
            panels[widget.id] = panel
            panel.show()
        }
    }

    /// Android can show a widget now: running and not locked.
    var androidReady: Bool { status.state == .running && status.screenLock == nil }
}

/// The daemon's events and frames, delivered in-process.
private final class InProcessClient: NSObject, AvoClientXPC, @unchecked Sendable {
    let frames: FrameRouter
    weak var panels: WidgetPanels?

    init(frames: FrameRouter) {
        self.frames = frames
    }

    func handleEvent(_ event: Data) {
        guard let decoded = try? AvoXPC.decode(DaemonEvent.self, from: event) else { return }
        // In the order the daemon sent them.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.panels?.handle(decoded) }
        }
    }

    func setSurfaces(_ displayID: UInt32, surfaces: [IOSurface]) {
        frames.setSurfaces(displayID, surfaces: surfaces)
    }

    func present(_ displayID: UInt32, surfaceIndex: Int, sequence: UInt64) {
        frames.present(displayID, surfaceIndex: surfaceIndex, sequence: sequence)
    }
}

// MARK: - One panel

/// A widget display's size in pixels, and its density.
private struct WidgetDisplayMode: Equatable {
    var width: UInt32
    var height: UInt32
    var dpi: UInt32
}

/// A borderless panel that is the widget alone, with rounded corners, so it
/// goes wherever a window goes (up to the menu bar too). It sits on the
/// desktop under other windows, or on top of them. Its bar (drag to move,
/// keep on top, remove) is a small panel of its own that shows on hover,
/// over the widget's top edge, or under it at the top of the screen.
///
/// Dragging an edge resizes the panel as the widget allows: Android lays out
/// a widget that resizes again for the new size (within its limits, along
/// the ways it resizes), and zooms one that does not (its display gets more
/// pixels at a higher density, the same layout in dp).
@MainActor
final class WidgetPanel: NSObject, NSWindowDelegate {
    private(set) var widget: PlacedWidget
    private weak var owner: WidgetPanels?
    private let backend: WidgetPanelsBackend
    private let frames: FrameRouter
    private let panel: NSPanel
    private let displayView: DisplayView
    private let widgetFrame = NSView()
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    private let bar = WidgetBar()
    private let barWindow: NSPanel
    private(set) var displayID: UInt32?
    /// What the display was last asked to be.
    private var sentMode: WidgetDisplayMode?
    private var resizeGeneration = 0
    private var opening = false
    private var retries = 0
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Widgets")

    static let barHeight: CGFloat = 22
    /// Between the widget and its bar.
    static let barGap: CGFloat = 4
    /// The haze's base (QuickHaze), behind the placeholder.
    static let loadingBackground = QuickHaze.nsRGB(0x0A1108, 0.88).cgColor
    static let cornerRadius: CGFloat = 18

    /// The widget's settings are on screen: the panel is `setupSize`.
    private var settingUp: Bool
    /// Its settings were seen this time (a widget top after them ends the setup).
    private var sawSettings = false
    private var openedAt: Date?

    /// The pointer is over the widget, or over its bar; the bar is being
    /// dragged (from where the pointer and the panel were).
    private var overPanel = false
    private var overBar = false
    private var drag: (pointer: NSPoint, origin: NSPoint)?
    private var barShown = false
    private var hidingBar: Task<Void, Never>?

    private var frameName: String { "AvoWidget-\(widget.id)" }
    private var setUpKey: String { "AvoWidgetSetUp-\(widget.id)" }
    /// The user resized the panel: its saved frame's size wins over the widget's.
    private var resizedKey: String { "AvoWidgetResized-\(widget.id)" }
    private var onTopKey: String { "AvoWidgetOnTop-\(widget.id)" }
    /// Its saved frame has no bar in it (builds before kept the bar above the widget, in the panel).
    private var barApartKey: String { "AvoWidgetBarApart-\(widget.id)" }
    private var onTop: Bool {
        get { UserDefaults.standard.bool(forKey: onTopKey) }
        set { UserDefaults.standard.set(newValue, forKey: onTopKey) }
    }

    init(widget: PlacedWidget, index: Int, owner: WidgetPanels, backend: WidgetPanelsBackend, frames: FrameRouter) {
        self.widget = widget
        self.owner = owner
        self.backend = backend
        self.frames = frames
        guard let renderer = MetalRenderer() else { fatalError("Metal is unavailable") }
        renderer.keysOutBlack = true
        displayView = DisplayView(renderer: renderer)
        // A widget with settings shows them, larger, the first time.
        settingUp = widget.configurable == true && !UserDefaults.standard.bool(forKey: "AvoWidgetSetUp-\(widget.id)")
        let size = settingUp ? Self.setupSize : Self.contentSize(widget)
        panel = WidgetWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        barWindow = BarWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: Self.barHeight),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.delegate = self
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The widget's own shape, no window shadow around a rectangle.
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        panel.title = widget.label

        let content = NSView()
        widgetFrame.wantsLayer = true
        widgetFrame.layer?.cornerRadius = Self.cornerRadius
        widgetFrame.layer?.cornerCurve = .continuous
        widgetFrame.layer?.masksToBounds = true
        // Behind the placeholder only: the widget itself brings its shape.
        widgetFrame.layer?.backgroundColor = Self.loadingBackground
        for view in [displayView, placeholder] {
            view.translatesAutoresizingMaskIntoConstraints = false
            widgetFrame.addSubview(view)
        }
        placeholder.alignment = .center
        placeholder.textColor = QuickHaze.nsRGB(0xC5CDB9)
        placeholder.font = QuickHaze.monaFont(12)
        widgetFrame.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(widgetFrame)
        let tracking = HoverView { [weak self] inside in
            self?.overPanel = inside
            self?.hoverChanged()
        }
        tracking.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tracking, positioned: .below, relativeTo: widgetFrame)
        NSLayoutConstraint.activate([
            widgetFrame.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            widgetFrame.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            widgetFrame.topAnchor.constraint(equalTo: content.topAnchor),
            widgetFrame.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            tracking.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tracking.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tracking.topAnchor.constraint(equalTo: content.topAnchor),
            tracking.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            displayView.leadingAnchor.constraint(equalTo: widgetFrame.leadingAnchor),
            displayView.trailingAnchor.constraint(equalTo: widgetFrame.trailingAnchor),
            displayView.topAnchor.constraint(equalTo: widgetFrame.topAnchor),
            displayView.bottomAnchor.constraint(equalTo: widgetFrame.bottomAnchor),
            placeholder.centerYAnchor.constraint(equalTo: widgetFrame.centerYAnchor),
            placeholder.leadingAnchor.constraint(equalTo: widgetFrame.leadingAnchor, constant: 10),
            placeholder.trailingAnchor.constraint(equalTo: widgetFrame.trailingAnchor, constant: -10),
        ])
        panel.contentView = content

        barWindow.backgroundColor = .clear
        barWindow.isOpaque = false
        barWindow.hasShadow = false
        barWindow.hidesOnDeactivate = false
        barWindow.isReleasedWhenClosed = false
        barWindow.isMovable = false
        barWindow.collectionBehavior = panel.collectionBehavior
        barWindow.contentView = bar
        bar.title = settingUp ? String(localized: "Set Up \(widget.label)", bundle: .windowHost) : widget.label
        bar.onTop = { [weak self] in self?.toggleOnTop() }
        bar.onRemove = { [weak self] in self?.remove() }
        bar.onHover = { [weak self] inside in
            self?.overBar = inside
            self?.hoverChanged()
        }
        bar.onDrag = { [weak self] phase in self?.dragged(phase) }

        // Each panel keeps its place; a new one lines up under the screen's top right.
        let placed = UserDefaults.standard.object(forKey: "NSWindow Frame \(frameName)") != nil
        panel.setFrameAutosaveName(frameName)
        if !placed, let screen = NSScreen.main?.visibleFrame {
            let offset = CGFloat(index % 6) * 40
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - panel.frame.width - 24 - offset,
                                               y: screen.maxY - 24 - Self.barHeight - Self.barGap - offset))
        } else if !UserDefaults.standard.bool(forKey: barApartKey) {
            // The widget stays where it was, without the bar's 26 points above it.
            var frame = panel.frame
            frame.size.height = max(frame.height - 26, 1)
            panel.setFrame(frame, display: false)
        }
        UserDefaults.standard.set(true, forKey: barApartKey)
        // A saved place keeps the widget's own size unless the user resized it.
        if !settingUp {
            setPanelSize(UserDefaults.standard.bool(forKey: resizedKey) ? fitted(panelSize) : Self.contentSize(widget))
        }
        applySizeLimits()
        displayView.send = { [backend] record in
            guard let bytes = try? InputWire.encode(record) else { return }
            Task { await backend.sendInput(Data(bytes)) }
        }
        applyLevel()
    }

    /// The widget's size in points, so its display is whole 8-pixel steps wide (virtio-gpu modes are).
    private static func contentSize(_ widget: PlacedWidget) -> NSSize {
        aligned(NSSize(width: widget.width, height: widget.height))
    }

    private static var setupSize: NSSize {
        aligned(NSSize(width: AndroidWidgets.setupSize.width, height: AndroidWidgets.setupSize.height))
    }

    private static func aligned(_ size: NSSize) -> NSSize {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return NSSize(width: (size.width * scale / 8).rounded() * 8 / scale, height: size.height)
    }

    /// The panel size the widget allows nearest `size`, whole 8-pixel steps
    /// wide (a zoomed widget in its own shape at that width).
    private func fitted(_ size: NSSize) -> NSSize {
        let allowed = widget.allowedPanelSize(size)
        let width = Self.aligned(allowed).width
        guard widget.zooms else { return NSSize(width: width, height: allowed.height) }
        return NSSize(width: width, height: width * CGFloat(widget.height) / CGFloat(max(widget.width, 1)))
    }

    /// The panel's size now (points): the widget's.
    private var panelSize: NSSize { panel.contentLayoutRect.size }

    /// What dragging an edge may make of the panel: what the widget allows,
    /// in its own shape when it zooms; its settings keep their size.
    private func applySizeLimits() {
        if settingUp {
            panel.contentMinSize = Self.setupSize
            panel.contentMaxSize = Self.setupSize
            return
        }
        let limits = widget.panelSizeLimits
        panel.contentMinSize = limits.min
        panel.contentMaxSize = limits.max
        if widget.zooms {
            panel.contentAspectRatio = NSSize(width: widget.width, height: widget.height)
        } else {
            // Clears the aspect ratio.
            panel.contentResizeIncrements = NSSize(width: 1, height: 1)
        }
    }

    /// The daemon's newest word on the widget: how it resizes, once Android said.
    func update(_ widget: PlacedWidget) {
        guard widget != self.widget else { return }
        let rulesChanged = widget.resizing != self.widget.resizing, rulesWereUnknown = self.widget.resizing == nil
        self.widget = widget
        guard rulesChanged, !settingUp else { return }
        applySizeLimits()
        let fit = fitted(panelSize)
        let fits = abs(fit.width - panelSize.width) < 1 && abs(fit.height - panelSize.height) < 1
        // A size picked before the rules were known that they do not allow: the widget's own.
        if rulesWereUnknown, !fits {
            UserDefaults.standard.removeObject(forKey: resizedKey)
            resize(to: Self.contentSize(widget))
        } else {
            resize(to: fit)
        }
    }

    /// What the display shows on top: the widget, or its settings while it is set up.
    func showing(top: String) {
        guard settingUp else { return }
        if !AndroidWidgets.showsWidget(top: top) {
            sawSettings = true
            return
        }
        // Done (or no settings came after all, as for a widget Android had set up before).
        guard sawSettings || (openedAt.map { Date().timeIntervalSince($0) > 6 } ?? false) else { return }
        settingUp = false
        UserDefaults.standard.set(true, forKey: setUpKey)
        bar.title = widget.label
        if barShown { placeBar() }
        applySizeLimits()
        resize(to: Self.contentSize(widget))
    }

    /// The panel takes `size` (points), its top left staying.
    private func setPanelSize(_ size: NSSize, animate: Bool = false) {
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true, animate: animate)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard !settingUp else { return }
        UserDefaults.standard.set(true, forKey: resizedKey)
        resize(to: fitted(panelSize))
    }

    /// On a screen of another scale, the display takes that many pixels.
    func windowDidChangeBackingProperties(_ notification: Notification) {
        resize(to: settingUp ? Self.setupSize : panelSize)
    }

    func windowDidMove(_ notification: Notification) {
        if barShown, drag == nil { placeBar() }
    }

    func windowDidResize(_ notification: Notification) {
        if barShown { placeBar() }
    }

    /// The display for a panel `size` points large: that many pixels, at the
    /// density that keeps a zoomed widget's layout (dp) as it is.
    private func displayMode(_ size: NSSize) -> WidgetDisplayMode {
        let scale = panel.backingScaleFactor
        let zoom = settingUp ? 1 : widget.zoom(panelWidth: size.width)
        return WidgetDisplayMode(width: UInt32((size.width * scale).rounded()), height: UInt32((size.height * scale).rounded()),
                                 dpi: UInt32((160 * scale * zoom).rounded()))
    }

    /// The panel and its display take `size` (points), its top left staying.
    private func resize(to size: NSSize) {
        setPanelSize(size, animate: true)
        let mode = displayMode(size)
        guard let displayID, mode != sentMode else { return }
        sentMode = mode
        displayView.setDisplaySize(CGSize(width: Int(mode.width), height: Int(mode.height)))
        // The widget stays on screen until Android has it at the new size (a
        // re-plug leaves the display empty meanwhile). HostAgent's alignment.
        displayView.renderer.holdCurrentFrame(expecting: PixelSize(width: max(64, Int(mode.width) / 8 * 8), height: max(64, Int(mode.height))))
        resizeGeneration += 1
        let generation = resizeGeneration
        Task { [weak self, backend, logger] in
            do {
                try await backend.resizeDisplay(displayID, mode.width, mode.height, mode.dpi)
            } catch {
                logger.error("widget resize: \(error.localizedDescription, privacy: .public)")
            }
            // Failed or not, the hold ends; an older reply leaves it to the newest resize.
            guard let self, self.resizeGeneration == generation else { return }
            self.displayView.renderer.releaseHold()
        }
    }

    func show() {
        panel.orderFront(nil)
        androidChanged()
    }

    func close() {
        detach()
        hidingBar?.cancel()
        panel.removeChildWindow(barWindow)
        barWindow.close()
        panel.close()
    }

    /// The widget was removed: nothing of its panel stays in the defaults.
    func forget() {
        panel.setFrameAutosaveName("")
        for key in [setUpKey, resizedKey, onTopKey, barApartKey, "NSWindow Frame \(frameName)"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func applyLevel() {
        // Desktop widgets sit right above the desktop's icons, under every window.
        panel.level = onTop ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        barWindow.level = panel.level
        bar.pinned = onTop
    }

    private func toggleOnTop() {
        onTop.toggle()
        applyLevel()
    }

    private func remove() {
        let id = widget.id
        Task {
            do {
                try await backend.removeWidget(id)
            } catch {
                logger.error("cannot remove widget: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Bar

    /// The bar shows while the pointer is over the widget or the bar, or the
    /// bar is dragged, and fades a moment after (time to get from one to the other).
    private func hoverChanged() {
        hidingBar?.cancel()
        hidingBar = nil
        guard !overPanel, !overBar, drag == nil else {
            showBar()
            return
        }
        hidingBar = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.hideBar()
        }
    }

    private func showBar() {
        guard panel.isVisible else { return }
        if !barShown {
            barShown = true
            barWindow.alphaValue = 0
            placeBar()
            panel.addChildWindow(barWindow, ordered: .above)
            barWindow.level = panel.level
        }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; barWindow.animator().alphaValue = 1 }
    }

    private func hideBar() {
        guard barShown else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            barWindow.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Shown again meanwhile: it stays.
                guard let self, self.barShown, !self.overPanel, !self.overBar, self.drag == nil else { return }
                self.barShown = false
                self.panel.removeChildWindow(self.barWindow)
                self.barWindow.orderOut(nil)
            }
        })
    }

    /// The bar over the widget's top edge, or under its bottom one when the
    /// widget is at the top of the screen; within the screen's sides.
    private func placeBar() {
        let size = NSSize(width: ceil(bar.fittingSize.width), height: Self.barHeight)
        let frame = panel.frame
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? frame
        let x = min(max(frame.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let above = frame.maxY + Self.barGap + size.height <= visible.maxY
        let y = above ? frame.maxY + Self.barGap : frame.minY - Self.barGap - size.height
        barWindow.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
    }

    /// Dragging the bar moves the widget, up to the menu bar; the bar finds
    /// its side once it is let go.
    private func dragged(_ phase: WidgetBar.Drag) {
        switch phase {
        case .began:
            drag = (NSEvent.mouseLocation, panel.frame.origin)
        case .moved:
            guard let drag else { return }
            let pointer = NSEvent.mouseLocation
            var origin = NSPoint(x: drag.origin.x + pointer.x - drag.pointer.x, y: drag.origin.y + pointer.y - drag.pointer.y)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? panel.screen {
                origin.y = min(origin.y, screen.visibleFrame.maxY - panel.frame.height)
            }
            panel.setFrameOrigin(origin)
        case .ended:
            drag = nil
            placeBar()
            hoverChanged()
        }
    }

    // MARK: Display

    func androidChanged() {
        guard let owner else { return }
        if owner.androidReady {
            open()
        } else if displayID == nil {
            say(owner.status.state == .running
                ? String(localized: "Unlock Android to see this widget.", bundle: .windowHost)
                : String(localized: "\(widget.label) shows when Android is running.", bundle: .windowHost))
        }
    }

    private func open() {
        guard displayID == nil, !opening else { return }
        opening = true
        say(String(localized: "Loading \(widget.label)…", bundle: .windowHost))
        let mode = displayMode(settingUp ? Self.setupSize : Self.aligned(panelSize))
        openedAt = Date()
        let request = OpenDisplayRequest(package: AndroidWidgets.package, width: mode.width, height: mode.height,
                                         dpi: mode.dpi, widget: widget.id)
        Task { [weak self, backend] in
            do {
                let id = try await backend.openDisplay(request)
                guard let self, self.opening else {
                    await backend.closeDisplay(id)
                    return
                }
                self.opening = false
                self.displayID = id
                self.sentMode = mode
                self.displayView.displayID = id
                self.displayView.setDisplaySize(CGSize(width: Int(request.width), height: Int(request.height)))
                self.frames.register(self.displayView, for: id)
                // The widget ends the placeholder: Android's display is empty (all
                // black) until it draws it, and showing that would blink. One that
                // draws nothing the check sees ends it with any frame, a moment later.
                self.displayView.renderer.whenContentShown { [weak self] in self?.frameShown() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.displayID == id else { return }
                        self.displayView.renderer.whenFrameShown { [weak self] in self?.frameShown() }
                    }
                }
            } catch {
                guard let self else { return }
                self.opening = false
                self.logger.error("widget display: \(error.localizedDescription, privacy: .public)")
                self.say((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                // Android came up a moment ago, or was locked meanwhile: a few tries more.
                self.retryLater()
            }
        }
    }

    private func retryLater() {
        guard retries < 3 else { return }
        retries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { self?.androidChanged() }
        }
    }

    func displayReady() {
        retries = 0
    }

    private func frameShown() {
        retries = 0
        placeholder.isHidden = true
        widgetFrame.layer?.backgroundColor = .clear
    }

    /// Android ended the widget's display: the widget went away (its app was
    /// removed), or Android stopped.
    func displayClosed() {
        if let displayID { frames.unregister(displayID) }
        displayID = nil
        sentMode = nil
        placeholder.isHidden = false
        say(String(localized: "\(widget.label) closed.", bundle: .windowHost))
        retryLater()
    }

    private func detach() {
        opening = false
        guard let displayID else { return }
        frames.unregister(displayID)
        self.displayID = nil
        sentMode = nil
        Task { [backend] in await backend.closeDisplay(displayID) }
    }

    private func say(_ text: String) {
        placeholder.stringValue = text
        placeholder.isHidden = false
        widgetFrame.layer?.backgroundColor = Self.loadingBackground
    }
}

/// A borderless panel that takes typing (search widgets) without making the
/// daemon the active app.
private final class WidgetWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The bar's own panel, a child of the widget's: it never takes the typing.
private final class BarWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Tells while the pointer is over the panel.
private final class HoverView: NSView {
    let onHover: (Bool) -> Void

    init(onHover: @escaping (Bool) -> Void) {
        self.onHover = onHover
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}

/// The bar of a widget: its name (drag it to move the widget), keep on top
/// and remove, on a plate in the haze look (QuickHaze).
private final class WidgetBar: NSView {
    enum Drag { case began, moved, ended }

    var onTop: (() -> Void)?
    var onRemove: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onDrag: ((Drag) -> Void)?
    var title = "" { didSet { label.stringValue = title } }
    var pinned = false {
        didSet {
            pin.contentTintColor = pinned ? QuickHaze.nsRGB(0xD8E8A7) : Self.iconColor
            pin.toolTip = pinned ? String(localized: "Keep on Desktop", bundle: .windowHost)
                : String(localized: "Keep on Top", bundle: .windowHost)
        }
    }

    private static let iconColor = QuickHaze.nsRGB(0x9AA58E)
    private let label = NSTextField(labelWithString: "")
    private lazy var pin = button("pin.fill", String(localized: "Keep on Top", bundle: .windowHost), #selector(pinTapped))
    private lazy var remove = button("xmark", String(localized: "Remove Widget", bundle: .windowHost), #selector(removeTapped))

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = QuickHaze.nsRGB(0x0A1108, 0.92).cgColor
        layer?.borderColor = QuickHaze.nsRGB(0xF3F1E8, 0.08).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        label.font = QuickHaze.monaFont(11, 560)
        label.textColor = QuickHaze.nsRGB(0xC5CDB9)
        label.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [remove, label, pin])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
        ])
        pinned = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    // The plate and the name move the widget (the bar's own panel stays
    // with it); the buttons are buttons.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onDrag?(.began) }
    override func mouseDragged(with event: NSEvent) { onDrag?(.moved) }
    override func mouseUp(with event: NSEvent) { onDrag?(.ended) }

    private func button(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.contentTintColor = Self.iconColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    @objc private func pinTapped() { onTop?() }
    @objc private func removeTapped() { onRemove?() }
}
