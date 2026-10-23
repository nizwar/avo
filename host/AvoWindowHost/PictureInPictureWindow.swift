import AppKit
import AvoKit

/// View ▸ Picture in Picture: an app window's content in a small borderless
/// panel that floats over every other window, on every Space and over
/// full-screen apps, in a corner of the screen (PictureInPicture in AvoKit
/// says where and how big). The app goes on as it is: Android keeps its
/// display's size and the picture is scaled down, clicks and typing still
/// reach it, and the window waits ordered out until it comes back.
///
/// Controls show while the pointer is over the panel: a capsule at the top
/// with Back to Window and Close, to drag the panel by (it then snaps to the
/// nearest corner; a double-click goes back). The panel resizes from its edges and
/// keeps the picture's shape; its corner and size are remembered per app.
/// It does not activate the app when clicked, as macOS's own
/// Picture in Picture does not.
@MainActor
final class PictureInPictureWindow: NSObject, NSWindowDelegate {
    let panel: PictureInPicturePanel
    private let root = PictureInPictureRoot()
    private let controls = PictureInPictureControls()
    private let settings: WindowModeSettings
    private var aspect: CGFloat
    private var hideControls: Task<Void, Never>?

    /// Back to Window (also a double-click on the controls).
    var onBack: () -> Void = {}
    /// Close: the window closes as ⌘W closes it (a game asks first).
    var onClose: () -> Void = {}
    /// Whether anyone can see the panel (it is covered, or on a hidden Space's display).
    var onVisible: (Bool) -> Void = { _ in }
    /// The panel became or stopped being the key window.
    var onKey: (Bool) -> Void = { _ in }
    /// A resize from the panel's edges began or ended.
    var onLiveResize: (Bool) -> Void = { _ in }

    /// `content` (the window's content view) moves into the panel. `aspect`:
    /// the picture's width per unit of height.
    init(content: NSView, aspect: CGFloat, screen: NSScreen?, settings: WindowModeSettings) {
        self.settings = settings
        self.aspect = aspect
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = PictureInPicture.size(aspect: aspect, longSide: settings.longSide, visible: visible)
        let frame = PictureInPicture.frame(size: size, corner: settings.corner, visible: visible)
        panel = PictureInPicturePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable],
                                      backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        // Clear around the rounded corners; the shadow follows them.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentAspectRatio = NSSize(width: max(aspect, 0.01), height: 1)
        panel.minSize = PictureInPicture.size(aspect: aspect, longSide: 0, visible: visible)
        panel.delegate = self

        root.wantsLayer = true
        root.layer?.cornerRadius = 10
        root.layer?.masksToBounds = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        // Sized by its frame here: in the window it is laid out with
        // constraints (WindowChrome), which would leave it as it was.
        content.translatesAutoresizingMaskIntoConstraints = true
        content.frame = root.bounds
        content.autoresizingMask = [.width, .height]
        root.addSubview(content)
        controls.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            controls.centerXAnchor.constraint(equalTo: root.centerXAnchor),
        ])
        panel.contentView = root
        content.frame = root.bounds
        controls.onBack = { [weak self] in self?.onBack() }
        controls.onClose = { [weak self] in self?.onClose() }
        controls.onDragged = { [weak self] in self?.snapToCorner() }
        root.onHover = { [weak self] inside in self?.showControls(inside) }
    }

    /// What the ✕ says it does ("Quit PUBG MOBILE").
    func setCloseLabel(_ label: String) {
        controls.setCloseLabel(label)
    }

    /// Shows the panel (its controls for a moment, to say they are there) and makes it key.
    func show() {
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        showControls(true)
        showControls(false, after: .seconds(2))
    }

    var isVisible: Bool { panel.isVisible && panel.occlusionState.contains(.visible) }

    /// The picture's shape changed (Android turned): the same long side in the same corner.
    func setAspect(_ aspect: CGFloat) {
        guard abs(aspect - self.aspect) > 0.001, let visible = panel.screen?.visibleFrame else { return }
        self.aspect = aspect
        panel.contentAspectRatio = NSSize(width: max(aspect, 0.01), height: 1)
        panel.minSize = PictureInPicture.size(aspect: aspect, longSide: 0, visible: visible)
        let size = PictureInPicture.size(aspect: aspect, longSide: max(panel.frame.width, panel.frame.height), visible: visible)
        panel.setFrame(PictureInPicture.frame(size: size, corner: settings.corner, visible: visible), display: true, animate: true)
    }

    /// Takes the content out and closes the panel; the content goes back into its window.
    func takeContent() -> NSView? {
        hideControls?.cancel()
        let content = root.subviews.first { $0 !== controls }
        content?.removeFromSuperview()
        panel.delegate = nil
        panel.orderOut(nil)
        panel.close()
        return content
    }

    /// After a drag: the nearest corner of the screen it is on takes it.
    private func snapToCorner() {
        guard let visible = panel.screen?.visibleFrame else { return }
        let corner = PictureInPicture.nearestCorner(to: panel.frame, in: visible)
        settings.corner = corner
        let size = PictureInPicture.size(aspect: aspect, longSide: max(panel.frame.width, panel.frame.height), visible: visible)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().setFrame(PictureInPicture.frame(size: size, corner: corner, visible: visible), display: true)
        }
    }

    private func showControls(_ visible: Bool, after delay: Duration = .zero) {
        hideControls?.cancel()
        hideControls = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            // The pointer may be over it still once the first moment is over.
            let shown = visible || (delay > .zero && root.isHovered)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                controls.animator().alphaValue = shown ? 1 : 0
            }, completionHandler: nil)
        }
    }

    // MARK: NSWindowDelegate

    func windowDidChangeOcclusionState(_ notification: Notification) {
        onVisible(isVisible)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onKey(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        onKey(false)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        onLiveResize(true)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        onLiveResize(false)
        settings.longSide = max(panel.frame.width, panel.frame.height)
        snapToCorner()
    }
}

/// A borderless panel that takes the keyboard (typing reaches the app).
final class PictureInPicturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The panel's content: says when the pointer comes and goes.
final class PictureInPictureRoot: NSView {
    var onHover: (Bool) -> Void = { _ in }
    private(set) var isHovered = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHover(false)
    }
}

/// The capsule at the top of the panel: drag it to move the panel, Back to
/// Window, Close.
final class PictureInPictureControls: NSVisualEffectView {
    var onBack: () -> Void = {}
    var onClose: () -> Void = {}
    private var closeButton = NSButton()
    /// A drag moved the panel.
    var onDragged: () -> Void = {}

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.masksToBounds = true
        let back = Self.button(symbol: "pip.exit", label: String(localized: "Back to Window", bundle: .windowHost),
                               action: #selector(back))
        closeButton = Self.button(symbol: "xmark", label: String(localized: "Close", bundle: .windowHost), action: #selector(close))
        let close = closeButton
        for button in [back, close] { button.target = self }
        let stack = NSStackView(views: [back, close])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 3, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 26),
        ])
        setAccessibilityLabel(String(localized: "Picture in Picture", bundle: .windowHost))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func button(symbol: String, label: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: action)
        button.isBordered = false
        button.contentTintColor = .white
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.refusesFirstResponder = true
        return button
    }

    func setCloseLabel(_ label: String) {
        closeButton.toolTip = label
        closeButton.setAccessibilityLabel(label)
    }

    @objc private func back() { onBack() }
    @objc private func close() { onClose() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onBack()
            return
        }
        guard let window else { return }
        // Moves the panel with the pointer until the button comes up.
        let start = NSEvent.mouseLocation
        let origin = window.frame.origin
        var moved = false
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event, event.type == .leftMouseDragged else {
                stop.pointee = true
                return
            }
            let now = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(x: origin.x + now.x - start.x, y: origin.y + now.y - start.y))
            moved = true
        }
        if moved { onDragged() }
    }
}
