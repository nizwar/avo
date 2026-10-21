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
            panel.close()
            panels[id] = nil
        }
        for (index, widget) in widgets.enumerated() where panels[widget.id] == nil {
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

/// A borderless panel: the widget with rounded corners, and above it a bar
/// that shows on hover (drag to move, keep on top, remove). It sits on the
/// desktop under other windows, or on top of them.
@MainActor
final class WidgetPanel: NSObject, NSWindowDelegate {
    let widget: PlacedWidget
    private weak var owner: WidgetPanels?
    private let backend: WidgetPanelsBackend
    private let frames: FrameRouter
    private let panel: NSPanel
    private let displayView: DisplayView
    private let widgetFrame = NSView()
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    private let bar = WidgetBar()
    private(set) var displayID: UInt32?
    private var opening = false
    private var retries = 0
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Widgets")

    static let barHeight: CGFloat = 26
    static let loadingBackground = NSColor(white: 0.12, alpha: 0.85).cgColor
    static let cornerRadius: CGFloat = 18

    /// The widget's settings are on screen: the panel is `setupSize`.
    private var settingUp: Bool
    /// Its settings were seen this time (a widget top after them ends the setup).
    private var sawSettings = false
    private var openedAt: Date?

    private var setUpKey: String { "AvoWidgetSetUp-\(widget.id)" }
    /// The user resized the panel: its saved frame's size wins over the widget's.
    private var resizedKey: String { "AvoWidgetResized-\(widget.id)" }
    private var onTopKey: String { "AvoWidgetOnTop-\(widget.id)" }
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
        panel = WidgetWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height + Self.barHeight),
                             styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
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
        // Dragging an edge resizes: the widget lays out again for the new size.
        panel.minSize = NSSize(width: 72, height: 72 + Self.barHeight)
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
        placeholder.textColor = .secondaryLabelColor
        placeholder.font = .systemFont(ofSize: 12)
        widgetFrame.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(widgetFrame)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.barHeight - 4),
            widgetFrame.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.barHeight),
            widgetFrame.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            widgetFrame.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            widgetFrame.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            displayView.leadingAnchor.constraint(equalTo: widgetFrame.leadingAnchor),
            displayView.trailingAnchor.constraint(equalTo: widgetFrame.trailingAnchor),
            displayView.topAnchor.constraint(equalTo: widgetFrame.topAnchor),
            displayView.bottomAnchor.constraint(equalTo: widgetFrame.bottomAnchor),
            placeholder.centerYAnchor.constraint(equalTo: widgetFrame.centerYAnchor),
            placeholder.leadingAnchor.constraint(equalTo: widgetFrame.leadingAnchor, constant: 10),
            placeholder.trailingAnchor.constraint(equalTo: widgetFrame.trailingAnchor, constant: -10),
        ])
        panel.contentView = content
        bar.title = settingUp ? String(localized: "Set Up \(widget.label)", bundle: .windowHost) : widget.label
        bar.onTop = { [weak self] in self?.toggleOnTop() }
        bar.onRemove = { [weak self] in self?.remove() }
        let tracking = HoverView(bar: bar)
        tracking.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tracking, positioned: .below, relativeTo: widgetFrame)
        NSLayoutConstraint.activate([
            tracking.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tracking.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tracking.topAnchor.constraint(equalTo: content.topAnchor),
            tracking.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        // Each panel keeps its place; a new one lines up under the screen's top right.
        panel.setFrameAutosaveName("AvoWidget-\(widget.id)")
        if !UserDefaults.standard.dictionaryRepresentation().keys.contains("NSWindow Frame AvoWidget-\(widget.id)"),
           let screen = NSScreen.main?.visibleFrame {
            let offset = CGFloat(index % 6) * 40
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - panel.frame.width - 24 - offset, y: screen.maxY - 24 - offset))
        }
        // A saved place keeps the widget's own size unless the user resized it.
        if !settingUp, !UserDefaults.standard.bool(forKey: resizedKey) {
            setPanelSize(Self.contentSize(widget))
        }
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
        resize(to: Self.contentSize(widget))
    }

    /// The widget's part of the panel now, in whole 8-pixel steps wide.
    private var widgetSize: NSSize {
        let content = panel.contentLayoutRect.size
        return Self.aligned(NSSize(width: content.width, height: max(content.height - Self.barHeight, 1)))
    }

    /// The panel takes `size` (points) for its widget, its top left staying.
    private func setPanelSize(_ size: NSSize, animate: Bool = false) {
        var frame = panel.frame
        let height = size.height + Self.barHeight
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: size.width, height: height)
        panel.setFrame(frame, display: true, animate: animate)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard !settingUp else { return }
        UserDefaults.standard.set(true, forKey: resizedKey)
        resize(to: widgetSize)
    }

    /// The panel and its display take `size` (points), its top left staying.
    private func resize(to size: NSSize) {
        setPanelSize(size, animate: true)
        guard let displayID else { return }
        let scale = panel.backingScaleFactor
        let width = UInt32((size.width * scale).rounded()), pixels = UInt32((size.height * scale).rounded())
        displayView.setDisplaySize(CGSize(width: Int(width), height: Int(pixels)))
        Task { [backend, logger] in
            do {
                try await backend.resizeDisplay(displayID, width, pixels, UInt32(160 * scale))
            } catch {
                logger.error("widget resize: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func show() {
        panel.orderFront(nil)
        androidChanged()
    }

    func close() {
        detach()
        panel.close()
    }

    private func applyLevel() {
        // Desktop widgets sit right above the desktop's icons, under every window.
        panel.level = onTop ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
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
        let scale = panel.backingScaleFactor
        let size = settingUp ? Self.setupSize : widgetSize
        openedAt = Date()
        let request = OpenDisplayRequest(package: AndroidWidgets.package,
                                         width: UInt32((size.width * scale).rounded()), height: UInt32((size.height * scale).rounded()),
                                         dpi: UInt32(160 * scale), widget: widget.id)
        Task { [weak self, backend] in
            do {
                let id = try await backend.openDisplay(request)
                guard let self, self.opening else {
                    await backend.closeDisplay(id)
                    return
                }
                self.opening = false
                self.displayID = id
                self.displayView.displayID = id
                self.displayView.setDisplaySize(CGSize(width: Int(request.width), height: Int(request.height)))
                self.frames.register(self.displayView, for: id)
                // The first frame ends the placeholder (Android's ready may come before the id).
                self.displayView.renderer.whenFrameShown { [weak self] in self?.frameShown() }
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
        placeholder.isHidden = false
        say(String(localized: "\(widget.label) closed.", bundle: .windowHost))
        retryLater()
    }

    private func detach() {
        opening = false
        guard let displayID else { return }
        frames.unregister(displayID)
        self.displayID = nil
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

/// Shows the bar while the pointer is over the panel.
private final class HoverView: NSView {
    let bar: WidgetBar

    init(bar: WidgetBar) {
        self.bar = bar
        super.init(frame: .zero)
        bar.alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; bar.animator().alphaValue = 1 }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { $0.duration = 0.3; bar.animator().alphaValue = 0 }
    }
}

/// The bar above a widget: its name (drag it to move the panel), keep on
/// top and remove.
private final class WidgetBar: NSVisualEffectView {
    var onTop: (() -> Void)?
    var onRemove: (() -> Void)?
    var title = "" { didSet { label.stringValue = title } }
    var pinned = false {
        didSet {
            pin.contentTintColor = pinned ? .controlAccentColor : .secondaryLabelColor
            pin.toolTip = pinned ? String(localized: "Keep on Desktop", bundle: .windowHost)
                : String(localized: "Keep on Top", bundle: .windowHost)
        }
    }

    private let label = NSTextField(labelWithString: "")
    private lazy var pin = button("pin.fill", String(localized: "Keep on Top", bundle: .windowHost), #selector(pinTapped))
    private lazy var remove = button("xmark", String(localized: "Remove Widget", bundle: .windowHost), #selector(removeTapped))

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
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

    // Dragging the bar (not its buttons) moves the panel.
    override var mouseDownCanMoveWindow: Bool { true }

    private func button(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    @objc private func pinTapped() { onTop?() }
    @objc private func removeTapped() { onRemove?() }
}
