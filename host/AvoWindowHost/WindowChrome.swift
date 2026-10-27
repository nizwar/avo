import AppKit
import AvoHazeUI
import AvoKit

/// An app window's frame for the Phone app bar style (AppBarStyle.phone:
/// Settings › Graphics › App windows › App bar style, or the app's own).
///
/// In the phone style the window shows the app's screen alone, with a
/// phone's rounded corners. As the pointer leaves the screen through its
/// top, a frame grows out around it, as iPhone Mirroring's: a border on every
/// side and, at the top, a header with a Mac window's corners to meet the
/// pointer, on which the traffic lights, the app's name and its buttons fade
/// in. Moving back down into the app, or away, they fade and the frame
/// shrinks back behind the screen. Around the screen the window is
/// see-through and lets clicks through to what is behind it.
///
/// The window's frame keeps its size either way (the header's room is there,
/// see-through, while it is shrunk), so nothing re-plugs Android's display
/// for it. `screenInsets` says where the screen is in the window; the window
/// controller sizes Android's display, and the window, from it.
///
/// Full screen and Picture in Picture have their own looks: the style waits
/// while they are on. From Gabriel Momoh's phone-style windows (pull request
/// #6), as one of the app bar styles.
@MainActor
final class WindowChrome: NSResponder {
    private weak var window: NSWindow?
    /// The window's content view: the frame, with the screen in it.
    let root = NSView()
    private let frameView = FrameView()
    private weak var screen: NSView?
    private var screenEdges: (top: NSLayoutConstraint, leading: NSLayoutConstraint, trailing: NSLayoutConstraint,
                              bottom: NSLayoutConstraint)?
    /// Keeps the window's shadow on the frame while it grows or shrinks.
    private var shadowFollower: Timer?

    /// The Phone app bar style (else a Mac window, its title bar always shown).
    private(set) var phone = false
    /// Full screen, or Picture in Picture (which takes the screen away).
    var fullScreen = false { didSet { if fullScreen != oldValue { refresh() } } }
    var pictureInPicture = false { didSet { if pictureInPicture != oldValue { refresh() } } }
    /// The header stays while this says so (Quick Settings is open under it).
    var keepsBar: () -> Bool = { false }
    /// The window is on screen: not minimized, covered, run in the background
    /// or closed. Only then is the pointer watched over other windows.
    var onScreen = true { didSet { if onScreen != oldValue { updateOutsideWatch() } } }
    /// The phone style was turned on or off: the screen's place in the window changed.
    var onInsetsChange: () -> Void = {}

    private var tracking: NSTrackingArea?
    /// The pointer's moves over other windows, while the header is hidden
    /// (`updateOutsideWatch`): above the shrunk frame the window lets the
    /// pointer through, so it would not hear it go out through the top.
    private var outsideWatch: Any?
    private var hideTimer: Timer?
    /// Menus from the header's buttons being open: the header stays.
    private var openMenus = 0
    private var barShown = true

    /// The frame around the screen, and the header's corners (a Mac window's).
    static let border: CGFloat = 8
    static let headerRadius: CGFloat = 16
    /// The header: the frame grows, then its contents fade in; they fade, then it shrinks.
    private static let growing: TimeInterval = 0.3
    private static let shrinking: TimeInterval = 0.26
    /// How long the header stays after the pointer left its zone, and after the window opened.
    private static let lingering: TimeInterval = 0.5
    private static let introduction: TimeInterval = 1.6

    init(window: NSWindow) {
        self.window = window
        super.init()
        root.wantsLayer = true
        frameView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(frameView)
        NSLayoutConstraint.activate([
            frameView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            frameView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            frameView.topAnchor.constraint(equalTo: root.topAnchor),
            frameView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window.contentView = root
        // The header's menus are haze menus (HazeMenu.swift), whose panels
        // take the pointer away from the window; AppKit's own count too.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(menuBegan), name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(menuEnded), name: NSMenu.didEndTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(menuBegan), name: HazeMenuPresenter.willShowNotification, object: nil)
        center.addObserver(self, selector: #selector(menuEnded), name: HazeMenuPresenter.didCloseNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: The screen in the frame

    /// Puts the app's screen in the frame (again, after Picture in Picture).
    func attach(_ screen: NSView) {
        guard let window, let guide = window.contentLayoutGuide as? NSLayoutGuide else { return }
        self.screen = screen
        screen.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(screen, positioned: .above, relativeTo: frameView)
        let edges = (top: screen.topAnchor.constraint(equalTo: guide.topAnchor),
                     leading: screen.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                     trailing: root.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
                     bottom: root.bottomAnchor.constraint(equalTo: screen.bottomAnchor))
        NSLayoutConstraint.activate([edges.top, edges.leading, edges.trailing, edges.bottom])
        screenEdges = edges
        refresh()
    }

    /// Takes the screen out for Picture in Picture.
    func detachScreen() {
        screen?.removeFromSuperview()
        screenEdges = nil
    }

    private var isPhone: Bool { phone && !fullScreen && !pictureInPicture }

    /// The frame on each side of the screen; on top, below the title bar.
    private var border: CGFloat { isPhone ? Self.border : 0 }

    /// Where the screen is in the window's frame: the title bar's room on top
    /// (see-through in the phone style), and the frame around it.
    var screenInsets: NSEdgeInsets {
        guard let window else { return NSEdgeInsets() }
        let layout = window.contentLayoutRect
        let bounds = NSRect(origin: .zero, size: window.frame.size)
        return NSEdgeInsets(top: bounds.maxY - layout.maxY + border, left: layout.minX + border,
                            bottom: layout.minY + border, right: bounds.maxX - layout.maxX + border)
    }

    func apply(phone: Bool) {
        guard phone != self.phone else { return }
        self.phone = phone
        refresh()
        onInsetsChange()
        // A new phone window shows its header for a moment, so it is found.
        if isPhone {
            setBar(shown: true, animated: false)
            scheduleHide(after: Self.introduction)
        }
    }

    /// The traffic lights' view, with the title and the buttons. Its
    /// container's alpha is AppKit's, which sets it again as the window comes
    /// to the front, so this one fades.
    private var titlebarView: NSView? { window?.standardWindowButton(.closeButton)?.superview }

    private func refresh() {
        guard let window else { return }
        let phone = isPhone
        // The phone style's frame reaches up under the title bar.
        if phone != window.styleMask.contains(.fullSizeContentView), !fullScreen {
            if phone { window.styleMask.insert(.fullSizeContentView) } else { window.styleMask.remove(.fullSizeContentView) }
        }
        window.titlebarAppearsTransparent = phone
        window.isOpaque = !phone
        window.backgroundColor = phone ? .clear : .black
        frameView.isHidden = !phone
        if let screenEdges {
            screenEdges.top.constant = border
            screenEdges.leading.constant = border
            screenEdges.trailing.constant = border
            screenEdges.bottom.constant = border
        }
        if let screen, !pictureInPicture {
            screen.wantsLayer = true
            screen.layer?.backgroundColor = NSColor.black.cgColor
            screen.layer?.cornerCurve = .continuous
            screen.layer?.masksToBounds = phone
            screen.layer?.borderWidth = phone ? 0.5 : 0
            screen.layer?.borderColor = NSColor.separatorColor.cgColor
        }
        root.layoutSubtreeIfNeeded()
        updateCorners()
        installTracking()
        updateOutsideWatch()
        hideTimer?.invalidate()
        hideTimer = nil
        // Full screen's bars are the controller's (FullScreenBars); a standard window's always show.
        if !fullScreen { setBar(shown: !phone || pointerAboveScreen, animated: false) }
    }

    /// A phone's screen corners, in proportion to the screen: about 30 points
    /// on the default 412-point-wide window.
    static func cornerRadius(for size: NSSize) -> CGFloat {
        min(32, max(12, min(size.width, size.height) * 0.075))
    }

    private func updateCorners() {
        guard isPhone, let screen else { return }
        let radius = Self.cornerRadius(for: screen.bounds.size)
        screen.layer?.cornerRadius = radius
        frameView.phoneRadius = radius + Self.border
        frameView.place(animated: false)
        window?.invalidateShadow()
    }

    /// The window changed size: the corners and the shadow follow.
    func windowResized() {
        root.layoutSubtreeIfNeeded()
        updateCorners()
    }

    // MARK: The header

    private func installTracking() {
        if let tracking { root.removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        root.addTrackingArea(area)
        tracking = area
    }

    /// How far above the window the pointer may go and keep the header.
    private static let reach: CGFloat = 24

    /// The pointer is over the screen's top edge or above it, over the
    /// window's width: in the frame's top border, the header's room, or a
    /// little above the window.
    private var pointerAboveScreen: Bool {
        guard let window, window.isVisible else { return false }
        let point = NSEvent.mouseLocation
        let frame = window.frame
        let screenTop = frame.maxY - screenInsets.top
        return point.x >= frame.minX && point.x <= frame.maxX
            && point.y >= screenTop && point.y <= frame.maxY + Self.reach
    }

    override func mouseEntered(with event: NSEvent) {
        pointerMoved()
    }

    override func mouseMoved(with event: NSEvent) {
        pointerMoved()
    }

    /// Watches the pointer over other windows only while the phone style's
    /// header is hidden on a window on screen: the watch wakes the app at
    /// every move of the mouse, anywhere.
    private func updateOutsideWatch() {
        let wanted = isPhone && !barShown && onScreen
        guard wanted != (outsideWatch != nil) else { return }
        if let outsideWatch { NSEvent.removeMonitor(outsideWatch) }
        outsideWatch = nil
        guard wanted else { return }
        outsideWatch = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPhone, !self.barShown, self.pointerAboveScreen else { return }
                self.setBar(shown: true, animated: true)
                self.scheduleHide(after: Self.lingering)
            }
        }
    }

    /// Out through the top: the header grows to meet the pointer. Out
    /// anywhere else: it goes.
    override func mouseExited(with event: NSEvent) {
        guard isPhone else { return }
        if pointerAboveScreen {
            hideTimer?.invalidate()
            hideTimer = nil
            setBar(shown: true, animated: true)
        }
        scheduleHide(after: Self.lingering)
    }

    /// Over the frame's top border the header comes; back down over the app
    /// it goes.
    private func pointerMoved() {
        guard isPhone else { return }
        if pointerAboveScreen {
            hideTimer?.invalidate()
            hideTimer = nil
            setBar(shown: true, animated: true)
        } else if barShown, hideTimer == nil {
            scheduleHide(after: Self.lingering)
        }
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideIfLeft() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    /// The pointer is back at the top, a menu of the header's is open or
    /// Quick Settings is: it asks again later.
    private func hideIfLeft() {
        hideTimer = nil
        guard isPhone else { return }
        if pointerAboveScreen || openMenus > 0 || keepsBar() {
            scheduleHide(after: Self.lingering)
            return
        }
        setBar(shown: false, animated: true)
    }

    /// The window came to the front or went back: AppKit may have shown the
    /// title bar again, so it is set again as it should be.
    func windowStateChanged() {
        guard isPhone, let titlebarView else { return }
        titlebarView.alphaValue = barShown ? 1 : 0
        if !barShown, pointerAboveScreen { setBar(shown: true, animated: true) }
    }

    /// Grows the frame up into the header, then fades the title bar's
    /// contents in on it; or fades them, then shrinks the frame back.
    private func setBar(shown: Bool, animated: Bool) {
        guard let window, let titlebarView else { return }
        let phone = isPhone
        // The header's room: the title bar's, and the border under it.
        let headerRoom = window.frame.height - window.contentLayoutRect.maxY
        let grown = !phone || shown
        guard shown != barShown || frameView.grown != grown || titlebarView.alphaValue != (shown ? 1 : 0) else { return }
        barShown = shown
        updateOutsideWatch()
        frameView.headerRoom = headerRoom
        frameView.grown = grown
        guard animated else {
            titlebarView.alphaValue = shown ? 1 : 0
            frameView.place(animated: false)
            window.invalidateShadow()
            return
        }
        let fade = { (duration: TimeInterval) in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                titlebarView.animator().alphaValue = shown ? 1 : 0
            }
        }
        if shown {
            frameView.place(animated: true, duration: Self.growing, timing: CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1))
            followShadow(for: Self.growing)
            // The contents come once the frame has made room for them.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.growing * 0.35) { [weak self] in
                guard let self, self.barShown else { return }
                fade(0.18)
            }
        } else {
            fade(0.12)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self, !self.barShown else { return }
                self.frameView.place(animated: true, duration: Self.shrinking, timing: CAMediaTimingFunction(name: .easeInEaseOut))
                self.followShadow(for: Self.shrinking)
            }
        }
    }

    /// The window's shadow is worked out from what it draws: while the frame
    /// moves, it is worked out again each frame.
    private func followShadow(for duration: TimeInterval) {
        shadowFollower?.invalidate()
        let end = Date.now.addingTimeInterval(duration + 0.05)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.window?.invalidateShadow()
                if Date.now >= end {
                    self.shadowFollower?.invalidate()
                    self.shadowFollower = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        shadowFollower = timer
    }

    @objc private func menuBegan(_ notification: Notification) {
        guard window?.isKeyWindow == true else { return }
        openMenus += 1
    }

    @objc private func menuEnded(_ notification: Notification) {
        openMenus = max(openMenus - 1, 0)
    }
}

/// The phone style's frame: one color, in two parts that overlap in the
/// middle. Grown, it fills the window: the bottom part with the phone's
/// corners, the top part with the header's. Shrunk, both sit on the screen's
/// own rect behind it, so only the screen shows. Core Animation moves them.
private final class FrameView: NSView {
    private let top = CALayer()
    private let bottom = CALayer()
    /// The screen's corners and the border: the frame's own outside the header.
    var phoneRadius: CGFloat = 38
    /// The frame around the screen, and the title bar's room above it.
    var border: CGFloat = WindowChrome.border
    var headerRoom: CGFloat = 28
    var grown = true

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for part in [bottom, top] {
            part.cornerCurve = .continuous
            // Moved by hand: no implicit animations, which a layout pass
            // (inside Core Animation's commit) must not start.
            part.actions = ["position": NSNull(), "bounds": NSNull(), "cornerRadius": NSNull(), "backgroundColor": NSNull()]
            layer?.addSublayer(part)
        }
        // Layers count y up: max Y is the top.
        top.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        bottom.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        colorParts()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        place(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        colorParts()
    }

    private func colorParts() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = NSColor.windowBackgroundColor.cgColor
            top.backgroundColor = color
            bottom.backgroundColor = color
        }
    }

    /// Puts both parts where `grown` has them: around the screen with the
    /// header, or shrunk onto the screen itself (hidden behind it). Animated,
    /// they move from where they show now.
    func place(animated: Bool, duration: TimeInterval = 0, timing: CAMediaTimingFunction? = nil) {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let middle = size.height / 2
        // Grown: the whole window. Shrunk: the screen's rect and corners.
        let inset: CGFloat = grown ? 0 : border
        let topEdge = grown ? size.height : size.height - headerRoom - border
        let radius = grown ? phoneRadius : phoneRadius - border
        let width = size.width - inset * 2
        let start = middle - radius
        let targets: [(CALayer, CGRect, CGFloat)] = [
            (bottom, CGRect(x: inset, y: inset, width: width, height: max(middle + radius - inset, 0)), radius),
            (top, CGRect(x: inset, y: start, width: width, height: max(topEdge - start, 0)), grown ? WindowChrome.headerRadius : radius),
        ]
        for (part, frame, corner) in targets {
            let shown = part.presentation() ?? part
            let from = (bounds: shown.bounds, position: shown.position, radius: shown.cornerRadius)
            part.frame = frame
            part.cornerRadius = corner
            guard animated, duration > 0 else {
                part.removeAllAnimations()
                continue
            }
            for (key, value) in [("bounds", NSValue(rect: from.bounds)), ("position", NSValue(point: from.position)),
                                 ("cornerRadius", NSNumber(value: Double(from.radius)))] as [(String, Any)] {
                let animation = CABasicAnimation(keyPath: key)
                animation.fromValue = value
                animation.duration = duration
                animation.timingFunction = timing
                part.add(animation, forKey: key)
            }
        }
    }
}
