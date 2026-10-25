import AppKit
import AvoKeymap
import AvoKit

/// The key mapping editor over a game (spec §5: "Tekan Cmd+Shift+K di
/// jendela game untuk membuka editor overlay transparan"). It is a view on
/// top of the game inside the game's own window, not a window of its own,
/// so it always has the window's size and place, and other apps' windows
/// cover it like they cover the game. The editing itself is KeymapEditorView.
///
/// Its panel stands beside the window, in a window of its own
/// (KeymapSidePanel), so the game keeps its whole size while controls are
/// placed on it: on the right when the screen has room there, else on the
/// left, else the window moves over a little as the editor opens (and back
/// as it closes, unless it was moved meanwhile). In full screen, or on a
/// screen too narrow even then, it is inside, beside the game, which moves
/// over for it.
@MainActor
final class KeymapOverlay {
    private let editor: KeymapEditorView
    private weak var window: NSWindow?
    /// The app's screen, which the editor covers (not the Phone app bar
    /// style's frame around it).
    private weak var screen: NSView?
    private weak var focusBefore: NSResponder?
    /// The panel's window, while the panel stands outside.
    private let side = KeymapSidePanel()
    private var observers: [NSObjectProtocol] = []
    /// The window moved over to make room for the panel: from where, to where.
    private var moved: (from: NSRect, to: NSRect)?
    /// Its own move is under way: not one by the user.
    private var moving = false
    var onClose: (() -> Void)?
    /// The panel went inside the window (true: the game moves over for it)
    /// or outside (false).
    var onPanelInside: ((Bool) -> Void)?

    /// Between the window and the panel beside it.
    private static let gap: CGFloat = 8
    /// The panel is at least this tall beside a short window, when the screen has room.
    private static let minimumHeight: CGFloat = 560

    var isEditing: Bool { editor.superview != nil }

    init(window: NSWindow, view: any KeymapDisplay, package: String, profile: KeymapProfile?,
         onSave: @escaping (KeymapProfile) -> String?) {
        editor = KeymapEditorView(displayRect: { [weak view] in view?.displayRect ?? .zero },
                                  profile: profile ?? KeymapProfile(package: package, name: String(localized: "My layout", bundle: .avoKit), controls: []),
                                  onSave: onSave)
        self.window = window
        screen = view.superview
        editor.onClose = { [weak self] in self?.close() }
    }

    func show() {
        guard let window, let content = screen ?? window.contentView, !isEditing else { return }
        editor.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(editor, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            editor.topAnchor.constraint(equalTo: content.topAnchor),
            editor.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        focusBefore = window.firstResponder
        window.makeFirstResponder(editor)
        let center = NotificationCenter.default
        // The panel follows the window: its size, its screen, full screen.
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowChanged(name) }
            })
        }
        // Out of the window's way before full screen's animation.
        observers.append(center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.putPanelInside() }
        })
        // Into the Dock with the window, and back beside it after.
        observers.append(center.addObserver(forName: NSWindow.willMiniaturizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideSide() }
        })
        observers.append(center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placePanel(opening: false) }
        })
        placePanel(opening: true)
    }

    func close() {
        guard isEditing else { return }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        hideSide()
        editor.movePanel(into: nil)
        editor.removeFromSuperview()
        // Back where it was, unless it was moved meanwhile.
        if let moved, let window, window.frame == moved.to, !window.styleMask.contains(.fullScreen) {
            window.setFrame(moved.from, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
        moved = nil
        if let window, let focusBefore { window.makeFirstResponder(focusBefore) }
        onClose?()
    }

    /// Cancel, as ⇧⌘K again asks: changes go only once the player says so.
    func cancel() {
        editor.cancel()
    }

    /// Key presses routed here while the editor is open.
    func assign(_ trigger: Trigger, down: Bool) -> Bool {
        if down { editor.assign(trigger) }
        return true
    }

    // MARK: The panel beside the window

    private func windowChanged(_ name: Notification.Name) {
        guard !moving, let window else { return }
        if name == NSWindow.didMoveNotification {
            // Moved by the user: it stays where they put it.
            if let moved, window.frame != moved.to { self.moved = nil }
            // The panel moves with it, as a child window; it changes sides only once it leaves the screen.
            if side.parent != nil, let visible = window.screen?.visibleFrame, visible.contains(side.frame) { return }
        }
        placePanel(opening: false)
    }

    /// Beside the window when its screen has room: on the right, else on the
    /// left, else (`opening`) the window moves over so it fits on the right.
    /// Inside, beside the game, in full screen or without room even then.
    private func placePanel(opening: Bool) {
        guard let window, isEditing else { return }
        guard !window.styleMask.contains(.fullScreen), let visible = (window.screen ?? NSScreen.main)?.visibleFrame else {
            putPanelInside()
            return
        }
        let width = KeymapEditorView.panelWidth
        if let frame = sideFrame(beside: window.frame, right: true, visible: visible) {
            showSide(at: frame)
        } else if let frame = sideFrame(beside: window.frame, right: false, visible: visible) {
            showSide(at: frame)
        } else if opening, window.frame.width + Self.gap + width <= visible.width {
            var frame = window.frame
            let from = frame
            frame.origin.x = visible.maxX - width - Self.gap - frame.width
            moving = true
            window.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            moving = false
            moved = (from, window.frame)
            if let beside = sideFrame(beside: window.frame, right: true, visible: visible) {
                showSide(at: beside)
            } else {
                putPanelInside()
            }
        } else {
            putPanelInside()
        }
    }

    /// The panel's frame beside `frame` on one side, if it fits on the
    /// screen: from the window's top, as tall as the window (or as
    /// `minimumHeight`, beside a short one).
    private func sideFrame(beside frame: NSRect, right: Bool, visible: NSRect) -> NSRect? {
        let width = KeymapEditorView.panelWidth
        let x = right ? frame.maxX + Self.gap : frame.minX - Self.gap - width
        guard x >= visible.minX, x + width <= visible.maxX else { return nil }
        let top = min(frame.maxY, visible.maxY)
        let height = min(max(frame.height, Self.minimumHeight), visible.height)
        let bottom = max(top - height, visible.minY)
        return NSRect(x: x, y: bottom, width: width, height: top - bottom)
    }

    private func showSide(at frame: NSRect) {
        guard let window else { return }
        if side.parent == nil {
            editor.movePanel(into: side.host)
            onPanelInside?(false)
            // It slides out from behind the window's edge.
            let fromRight = frame.minX >= window.frame.maxX
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            side.alphaValue = 0
            side.setFrame(reduceMotion ? frame : frame.offsetBy(dx: fromRight ? -16 : 16, dy: 0), display: false)
            window.addChildWindow(side, ordered: .above)
            side.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                side.animator().alphaValue = 1
                side.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.side.invalidateShadow() }
            }
        } else if side.frame != frame {
            side.setFrame(frame, display: true)
            side.invalidateShadow()
        }
    }

    private func putPanelInside() {
        hideSide()
        editor.movePanel(into: nil)
        onPanelInside?(true)
    }

    private func hideSide() {
        side.parent?.removeChildWindow(side)
        side.orderOut(nil)
    }
}

/// The key mapping editor's panel in a window of its own, beside the game's
/// window and a child of it: it moves with the window, and minimizes and
/// goes to the back with it. It takes the keyboard only for a field (a
/// mode's name), so keys otherwise stay with the editor over the game.
final class KeymapSidePanel: NSPanel {
    /// The editor's panel goes in here (it draws its rounded card itself).
    let host = NSView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: KeymapEditorView.panelWidth, height: 560),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        // The shadow follows the card's rounded corners.
        hasShadow = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = host
    }

    // A mode's name is typed here.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
