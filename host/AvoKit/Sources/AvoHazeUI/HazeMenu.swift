import AppKit
import SwiftUI

// A menu in the haze, in place of macOS's own wherever Avo pops one up: an
// app window's title bar menus and its key mapping editor, the Control
// Panel's app menus and choices (HazePicker), the menu bar item's menu. Near
// black with a breath of Avo's green, icons, check marks, section titles,
// the item under the pointer or the keyboard lit (in the haze's red for a
// destructive one), and a small spring as it opens. A submenu opens in
// place, under its item. It is a borderless panel at the pointer or under
// the control that opened it, which takes the keyboard: arrows (→ and ←
// open and close a submenu), Return and Space, Escape, and typing an item's
// first letters. A click elsewhere, another app, or scrolling closes it, as
// with a menu, and the window that had the keyboard gets it back.
//
// `popUp(_:…)` shows an NSMenu this way: its delegate and validation update
// it as for macOS's menu, and an item sends its action as it would there.

/// One row of a haze menu.
public struct HazeMenuItem: Identifiable {
    public enum Role: Sendable {
        case normal
        case destructive
    }

    public let id = UUID()
    public var title: String
    /// A smaller line under the title.
    public var subtitle: String?
    public var symbol: String?
    /// Instead of a symbol: an image (an app's icon). A template image is
    /// tinted as a symbol is.
    public var image: NSImage?
    public var role: Role
    /// A check mark (`.on`) or a dash (`.mixed`) before the title.
    public var state: NSControl.StateValue
    public var isEnabled: Bool
    /// A key hint shown at the trailing edge ("⌘I").
    public var shortcut: String?
    public var toolTip: String?
    /// The items it opens under itself, instead of an action.
    public var submenu: (@MainActor () -> [HazeMenuEntry])?
    public var action: @MainActor () -> Void

    /// A trailing closure is the action (a submenu is passed by its label).
    public init(title: String, subtitle: String? = nil, symbol: String? = nil, image: NSImage? = nil, role: Role = .normal,
                state: NSControl.StateValue = .off, isEnabled: Bool = true, shortcut: String? = nil, toolTip: String? = nil,
                action: @escaping @MainActor () -> Void = {}, submenu: (@MainActor () -> [HazeMenuEntry])? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.image = image
        self.role = role
        self.state = state
        self.isEnabled = isEnabled
        self.shortcut = shortcut
        self.toolTip = toolTip
        self.submenu = submenu
        self.action = action
    }
}

public enum HazeMenuEntry: Identifiable {
    case item(HazeMenuItem)
    case separator(UUID = UUID())
    /// A section's title, over its items.
    case section(String, UUID = UUID())
    /// A line that is not an action ("No fingers registered").
    case note(String, UUID = UUID())
    /// A line that is not an action, with its icon in the items' icon column
    /// ("35 ms latency" beside a gauge).
    case info(String, symbol: String, UUID = UUID())

    public var id: UUID {
        switch self {
        case .item(let item): item.id
        case .separator(let id), .section(_, let id), .note(_, let id), .info(_, _, let id): id
        }
    }

    var menuItem: HazeMenuItem? {
        if case .item(let item) = self { item } else { nil }
    }
}

/// What sits above the items: an icon and a name (the app the menu is for).
public struct HazeMenuHeader {
    public var title: String
    public var icon: NSImage?

    public init(title: String, icon: NSImage? = nil) {
        self.title = title
        self.icon = icon
    }
}

// MARK: - The presenter

/// Shows one haze menu at a time.
@MainActor
public final class HazeMenuPresenter {
    public static let shared = HazeMenuPresenter()
    /// Posted just before a menu takes the keyboard, and once it has gone: a
    /// transient popover it opens from holds still meanwhile (the Window Host's Quick Settings).
    public nonisolated static let willShowNotification = Notification.Name("com.avodroid.HazeMenu.willShow")
    public nonisolated static let didCloseNotification = Notification.Name("com.avodroid.HazeMenu.didClose")

    /// Where a menu goes: its top-left corner at a point, or under (or over)
    /// a control, in screen coordinates.
    private enum Placement {
        case point(NSPoint)
        case below(NSRect)
    }

    private var panel: HazeMenuPanel?
    private var state: HazeMenuState?
    private var host: NSHostingView<HazeMenuView>?
    private var header: HazeMenuHeader?
    private var minWidth: CGFloat = 0
    /// The items scroll at this size (a menu taller than its screen).
    private var scrollSize: CGSize?
    private var visible = NSRect.zero
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    /// The event that opened the menu: the outside-click watch lets it pass.
    private var openingEvent: TimeInterval?
    /// The window that had the keyboard: it gets it back.
    private weak var previousKey: NSWindow?
    private var onClose: (@MainActor () -> Void)?
    /// Makes only the newest resize count (a submenu closing shrinks the panel once its rows have gone).
    private var resizes = 0

    public var isShown: Bool { panel != nil }

    /// Whether `window` is a haze menu's (a click there is the menu's).
    public func isMenu(_ window: NSWindow?) -> Bool {
        window is HazeMenuPanel
    }

    /// Shows `entries` with its top-leading corner at `point` (screen
    /// coordinates), turned to fit on its screen. `event`: the click that
    /// opened it, if any; `byKeyboard`: the first item starts lit.
    public func show(_ entries: [HazeMenuEntry], header: HazeMenuHeader? = nil, at point: NSPoint, for event: NSEvent? = nil,
                     byKeyboard: Bool = false, onClose: (@MainActor () -> Void)? = nil) {
        present(entries, header: header, placement: .point(point), minWidth: 0, event: event, byKeyboard: byKeyboard, onClose: onClose)
    }

    /// Shows `entries` under `view` (over it where the screen ends below),
    /// its leading edge on the view's: a button's pull-down menu, a
    /// picker's choices. `minWidth`: at least this wide (the picker's).
    public func show(_ entries: [HazeMenuEntry], header: HazeMenuHeader? = nil, below view: NSView, minWidth: CGFloat = 0,
                     byKeyboard: Bool = false, onClose: (@MainActor () -> Void)? = nil) {
        guard let window = view.window else {
            onClose?()
            return
        }
        let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
        present(entries, header: header, placement: .below(frame), minWidth: minWidth, event: nil, byKeyboard: byKeyboard,
                onClose: onClose)
    }

    /// Shows `menu` in the haze under `view`, as a pull-down menu.
    public func popUp(_ menu: NSMenu, below view: NSView, onClose: (@MainActor () -> Void)? = nil) {
        let entries = HazeMenuEntry.entries(from: menu)
        menu.delegate?.menuWillOpen?(menu)
        show(entries, below: view) {
            menu.delegate?.menuDidClose?(menu)
            onClose?()
        }
    }

    /// Shows `menu` in the haze with its top-left corner at `location` in
    /// `view` (NSMenu's popUp(positioning:at:in:)).
    public func popUp(_ menu: NSMenu, at location: NSPoint, in view: NSView) {
        guard let window = view.window else { return }
        let entries = HazeMenuEntry.entries(from: menu)
        menu.delegate?.menuWillOpen?(menu)
        show(entries, at: window.convertPoint(toScreen: view.convert(location, to: nil))) {
            menu.delegate?.menuDidClose?(menu)
        }
    }

    /// Shows `menu` in the haze at the pointer, as a context menu (NSMenu's
    /// popUpContextMenu(_:with:for:)).
    public func popUpContextMenu(_ menu: NSMenu, with event: NSEvent, for view: NSView) {
        guard let window = event.window ?? view.window else { return }
        let entries = HazeMenuEntry.entries(from: menu)
        menu.delegate?.menuWillOpen?(menu)
        show(entries, at: window.convertPoint(toScreen: event.locationInWindow), for: event) {
            menu.delegate?.menuDidClose?(menu)
        }
    }

    private func present(_ entries: [HazeMenuEntry], header: HazeMenuHeader?, placement: Placement, minWidth: CGFloat,
                         event: NSEvent?, byKeyboard: Bool, onClose: (@MainActor () -> Void)?) {
        close(animated: false)
        guard entries.contains(where: { $0.menuItem != nil }) else {
            onClose?()
            return
        }
        let anchorPoint = switch placement {
        case .point(let point): point
        case .below(let frame): NSPoint(x: frame.midX, y: frame.midY)
        }
        let screen = NSScreen.screens.first { $0.frame.contains(anchorPoint) } ?? NSScreen.main
        visible = screen?.visibleFrame ?? .zero

        let state = HazeMenuState(entries: entries)
        state.onClose = { [weak self] restoreKey in self?.close(restoringKey: restoreKey) }
        state.onResize = { [weak self] grew in self?.resize(grew: grew) }
        if byKeyboard { state.highlightFirst() }
        self.state = state
        self.header = header
        self.minWidth = minWidth
        scrollSize = nil
        let menu = measure()
        // The presenter sizes and places the panel, keeping the corner it opened from.
        let host = NSHostingView(rootView: view())
        host.sizingOptions = []
        var x: CGFloat
        var top: CGFloat
        switch placement {
        case .point(let point):
            // Down and to the right of the pointer, like a menu; up or to
            // the left where the screen ends.
            let flipsUp = point.y - menu.height < visible.minY
            let flipsLeft = point.x + menu.width > visible.maxX
            x = flipsLeft ? point.x - menu.width : point.x
            top = flipsUp ? point.y + menu.height : point.y
            state.anchor = UnitPoint(x: flipsLeft ? 1 : 0, y: flipsUp ? 1 : 0)
        case .below(let control):
            let gap: CGFloat = 4
            let flipsUp = control.minY - gap - menu.height < visible.minY && control.maxY + gap + menu.height <= visible.maxY
            let flipsLeft = control.minX + menu.width > visible.maxX
            x = flipsLeft ? control.maxX - menu.width : control.minX
            top = flipsUp ? control.maxY + gap + menu.height : control.minY - gap
            state.anchor = UnitPoint(x: flipsLeft ? 1 : 0, y: flipsUp ? 1 : 0)
        }

        let panel = HazeMenuPanel(contentRect: NSRect(origin: .zero, size: menu))
        panel.contentView = host
        panel.onKey = { [weak state] event in state?.handle(event) ?? false }
        panel.onResignKey = { [weak self] in self?.close(restoringKey: false) }
        self.panel = panel
        self.host = host
        self.onClose = onClose
        previousKey = NSApp.keyWindow
        openingEvent = event?.timestamp
        place(menu: menu, x: x, top: top)
        NotificationCenter.default.post(name: Self.willShowNotification, object: self)
        panel.makeKeyAndOrderFront(nil)
        // After its first frame, so it springs open.
        Task { @MainActor in state.shown = true }
        watchForDismissal()
    }

    private func view() -> HazeMenuView {
        HazeMenuView(state: state ?? HazeMenuState(entries: []), header: header, minWidth: minWidth, scrollSize: scrollSize)
    }

    /// The menu's size (without the room for its shadow), from a probe of
    /// it as it is now. Taller than its screen, its items scroll; again
    /// shorter (a submenu closed), they all show again.
    private func measure() -> NSSize {
        let margin = HazeMenuView.margin
        func size() -> NSSize {
            let fitting = NSHostingView(rootView: view()).fittingSize
            return NSSize(width: fitting.width - margin * 2, height: fitting.height - margin * 2)
        }
        scrollSize = nil
        let menu = size()
        let tallest = visible.height - 24
        guard menu.height > tallest else { return menu }
        // The rows' width as they are; the header (about 40 points) stays above.
        scrollSize = CGSize(width: menu.width - 10, height: max(120, tallest - 10 - (header == nil ? 0 : 44)))
        return size()
    }

    /// Puts the menu (`menu`: its size without the room for its shadow) with
    /// its top-left corner at `x`, `top`, kept on the screen. `glides`: kept
    /// on the screen by moving, it moves there smoothly.
    private func place(menu: NSSize, x wantedX: CGFloat, top wantedTop: CGFloat, glides: Bool = false) {
        guard let panel else { return }
        let margin = HazeMenuView.margin
        let x = min(max(wantedX, visible.minX + 4), max(visible.minX + 4, visible.maxX - menu.width - 4))
        let top = max(min(wantedTop, visible.maxY - 4), min(visible.maxY - 4, visible.minY + 4 + menu.height))
        let frame = NSRect(x: x - margin, y: top - menu.height - margin, width: menu.width + margin * 2, height: menu.height + margin * 2)
        let moves = abs(x - wantedX) > 0.5 || abs(top - wantedTop) > 0.5
        guard glides, moves, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// A submenu opened or closed: the panel takes the menu's new size,
    /// keeping the corner it opened from. Opening, the room is there at
    /// once, before the submenu's rows spring open inside the menu (made
    /// later, they ran past its edge and showed only once the panel caught
    /// up); closing, it shrinks once their rows have gone.
    private func resize(grew: Bool) {
        resizes += 1
        let resize = resizes
        guard !grew else { return fit() }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard let self, resize == self.resizes else { return }
            self.fit()
        }
    }

    /// The panel at the menu's size now, the corner it opened from where it
    /// was: a menu that must move to stay on its screen glides there.
    private func fit() {
        guard let panel, let host, let state else { return }
        let scrolled = scrollSize
        let menu = measure()
        if scrollSize != scrolled { host.rootView = view() }
        let current = panel.frame.insetBy(dx: HazeMenuView.margin, dy: HazeMenuView.margin)
        place(menu: menu, x: state.anchor.x == 0 ? current.minX : current.maxX - menu.width,
              top: state.anchor.y == 0 ? current.maxY : current.minY + menu.height, glides: true)
    }

    public func close(animated: Bool = true) {
        close(animated: animated, restoringKey: false)
    }

    private func close(animated: Bool = true, restoringKey: Bool) {
        guard let panel else { return }
        self.panel = nil
        host = nil
        header = nil
        state?.onClose = nil
        state?.onResize = nil
        state = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        panel.onResignKey = nil
        panel.onKey = nil
        if restoringKey, let previousKey, previousKey.isVisible { previousKey.makeKey() }
        previousKey = nil
        let onClose = self.onClose
        self.onClose = nil
        NotificationCenter.default.post(name: Self.didCloseNotification, object: self)
        onClose?()
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    private func watchForDismissal() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.scrollWheel), handler: { [weak self] event in
            self?.outside(event) ?? event
        }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            self?.close(restoringKey: false)
        }) {
            monitors.append(global)
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(restoringKey: false) }
        })
    }

    /// A click in another window closes the menu. A left click is used up by
    /// it, as with a menu; a right click goes on (it may open another menu).
    private func outside(_ event: NSEvent) -> NSEvent? {
        guard let panel, event.window !== panel, event.timestamp != openingEvent else { return event }
        close(restoringKey: true)
        return event.type == .leftMouseDown ? nil : event
    }
}

// MARK: - NSMenu in the haze

extension NSMenuItem {
    /// An illustration before the title (an SF Symbol), in a haze menu's
    /// top level and in macOS's menus.
    @discardableResult
    public func symbol(_ name: String) -> NSMenuItem {
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        return self
    }
}

extension HazeMenuEntry {
    /// The items `menu` shows now: its delegate updates it and its items
    /// are validated, as before macOS shows it. Choosing one sends its
    /// action to its target (one without is found now, from the window that
    /// has the keyboard); a submenu is read when it opens.
    @MainActor
    public static func entries(from menu: NSMenu) -> [HazeMenuEntry] {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        var entries: [HazeMenuEntry] = []
        for item in menu.items where !item.isHidden && !item.isAlternate {
            if item.isSeparatorItem {
                // None first, last or twice.
                if let last = entries.last, !last.isSeparator { entries.append(.separator()) }
                continue
            }
            if item.isSectionHeader {
                entries.append(.section(item.title))
                continue
            }
            let image = item.image
            if let submenu = item.submenu {
                entries.append(.item(HazeMenuItem(title: item.title, subtitle: item.subtitle, image: image, isEnabled: item.isEnabled,
                                                  toolTip: item.toolTip, submenu: { Self.entries(from: submenu) })))
                continue
            }
            guard let action = item.action else {
                entries.append(.note(item.title))
                continue
            }
            let target: AnyObject? = item.target ?? NSApp.target(forAction: action, to: nil, from: item).map { $0 as AnyObject }
            entries.append(.item(HazeMenuItem(title: item.title, subtitle: item.subtitle, image: image, state: item.state,
                                              isEnabled: item.isEnabled, shortcut: shortcut(of: item), toolTip: item.toolTip) {
                NSApp.sendAction(action, to: target, from: item)
            }))
        }
        if entries.last?.isSeparator == true { entries.removeLast() }
        return entries
    }

    private var isSeparator: Bool {
        if case .separator = self { true } else { false }
    }

    /// An item's key equivalent as macOS's menus show it ("⌃⌘Z", "⇧⌘S").
    @MainActor
    static func shortcut(of item: NSMenuItem) -> String? {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return nil }
        var modifiers = item.keyEquivalentModifierMask
        // An upper-case letter is the key with Shift.
        if key.count == 1, let letter = key.first, letter.isUppercase { modifiers.insert(.shift) }
        let names: [String: String] = [
            "\r": "↩", "\u{1b}": "⎋", " ": "Space", "\t": "⇥", "\u{8}": "⌫", "\u{7f}": "⌫",
            String(UnicodeScalar(UInt8(0x03))): "⌤",
            "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→", "\u{F728}": "⌦",
            "\u{F729}": "↖", "\u{F72B}": "↘", "\u{F72C}": "⇞", "\u{F72D}": "⇟",
        ]
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (names[key] ?? key.uppercased())
    }
}

// MARK: - SwiftUI

/// Where a SwiftUI control is, for a haze menu under it: the view of a
/// `HazeMenuAnchor` behind it.
public final class HazeMenuAnchorBox {
    public weak var view: NSView?

    public init() {}
}

/// Put behind a control (`.background(HazeMenuAnchor(box))`): `box.view`
/// is then where the control is.
public struct HazeMenuAnchor: NSViewRepresentable {
    private let box: HazeMenuAnchorBox

    public init(_ box: HazeMenuAnchorBox) {
        self.box = box
    }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    public func updateNSView(_ view: NSView, context: Context) {
        box.view = view
    }
}

/// A button that shows a haze menu under itself: a pull-down menu, or a
/// picker's choices (`matchesWidth`: the menu is at least as wide).
public struct HazeMenuButton<Label: View>: View {
    private let matchesWidth: Bool
    private let entries: @MainActor () -> [HazeMenuEntry]
    private let label: Label
    @State private var anchor = HazeMenuAnchorBox()

    public init(matchesWidth: Bool = false, entries: @escaping @MainActor () -> [HazeMenuEntry], @ViewBuilder label: () -> Label) {
        self.matchesWidth = matchesWidth
        self.entries = entries
        self.label = label()
    }

    public var body: some View {
        Button {
            guard let view = anchor.view else { return }
            HazeMenuPresenter.shared.show(entries(), below: view, minWidth: matchesWidth ? view.bounds.width : 0)
        } label: {
            label
        }
        .background(HazeMenuAnchor(anchor))
    }
}

extension View {
    /// A right click (or a Control-click) on this view shows `entries` in a
    /// haze menu at the pointer, instead of macOS's context menu.
    public func hazeContextMenu(_ entries: @escaping @MainActor () -> [HazeMenuEntry]) -> some View {
        modifier(HazeContextMenuModifier(entries: entries))
    }
}

private struct HazeContextMenuModifier: ViewModifier {
    let entries: @MainActor () -> [HazeMenuEntry]
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside {
                    HazeContextMenus.shared.hover(id) { point, event in
                        HazeMenuPresenter.shared.show(entries(), at: point, for: event)
                    }
                } else {
                    HazeContextMenus.shared.leave(id)
                }
            }
            .onDisappear { HazeContextMenus.shared.leave(id) }
    }
}

/// The view under the pointer that has a haze context menu, and the watch
/// for right clicks that shows it.
@MainActor
private final class HazeContextMenus {
    static let shared = HazeContextMenus()

    private var hovered: (id: UUID, show: (NSPoint, NSEvent) -> Void)?
    private var monitor: Any?

    func hover(_ id: UUID, show: @escaping (NSPoint, NSEvent) -> Void) {
        hovered = (id, show)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            HazeContextMenus.shared.click(event)
        }
    }

    func leave(_ id: UUID) {
        if hovered?.id == id { hovered = nil }
    }

    private func click(_ event: NSEvent) -> NSEvent? {
        guard event.type == .rightMouseDown || event.modifierFlags.contains(.control), let hovered,
              let window = event.window, !(window is HazeMenuPanel) else { return event }
        hovered.show(window.convertPoint(toScreen: event.locationInWindow), event)
        return nil
    }
}

// MARK: - The menu

/// What the menu shows, which submenus are open and which item is lit.
@MainActor
@Observable
final class HazeMenuState {
    /// A row as it shows: an entry, and how deep in open submenus it is.
    struct Row: Identifiable {
        let entry: HazeMenuEntry
        let depth: Int
        /// The item whose submenu it is in.
        let parent: UUID?

        var id: UUID { entry.id }
    }

    let entries: [HazeMenuEntry]
    var highlighted: UUID?
    /// The item that was chosen, lit for a moment before the menu goes.
    var chosen: UUID?
    var shown = false
    /// The corner the menu opens from.
    var anchor = UnitPoint.topLeading
    /// Open submenus, by their item, with what they list.
    var expanded: [UUID: [HazeMenuEntry]] = [:]
    /// `restoreKey`: the window that had the keyboard gets it back.
    @ObservationIgnored var onClose: ((_ restoreKey: Bool) -> Void)?
    @ObservationIgnored var onResize: ((_ grew: Bool) -> Void)?
    @ObservationIgnored private var typed = ""
    @ObservationIgnored private var typedAt = Date.distantPast

    init(entries: [HazeMenuEntry]) {
        self.entries = entries
    }

    var rows: [Row] {
        var rows: [Row] = []
        func add(_ entries: [HazeMenuEntry], depth: Int, parent: UUID?) {
            for entry in entries {
                rows.append(Row(entry: entry, depth: depth, parent: parent))
                if let item = entry.menuItem, let children = expanded[item.id] {
                    add(children, depth: depth + 1, parent: item.id)
                }
            }
        }
        add(entries, depth: 0, parent: nil)
        return rows
    }

    /// The items the keyboard moves through.
    private var items: [(item: HazeMenuItem, row: Row)] {
        rows.compactMap { row in
            guard let item = row.entry.menuItem, item.isEnabled else { return nil }
            return (item, row)
        }
    }

    func highlightFirst() {
        highlighted = items.first?.item.id
    }

    /// Arrows (→ and ← open and close a submenu), Return and Space, Escape,
    /// and the first letters of an item.
    func handle(_ event: NSEvent) -> Bool {
        let items = items
        let index = items.firstIndex { $0.item.id == highlighted }
        switch event.keyCode {
        case 125: // down
            highlighted = items.isEmpty ? nil : items[index.map { ($0 + 1) % items.count } ?? 0].item.id
        case 126: // up
            highlighted = items.isEmpty ? nil : items[index.map { ($0 + items.count - 1) % items.count } ?? items.count - 1].item.id
        case 115: // home
            highlighted = items.first?.item.id
        case 119: // end
            highlighted = items.last?.item.id
        case 124: // right
            guard let index, items[index].item.submenu != nil else { break }
            let item = items[index].item
            if expanded[item.id] == nil { toggle(item) }
            highlighted = expanded[item.id]?.first { $0.menuItem?.isEnabled == true }?.id ?? item.id
        case 123: // left
            guard let index else { break }
            let (item, row) = items[index]
            if expanded[item.id] != nil {
                collapse(item.id)
            } else if let parent = row.parent {
                collapse(parent)
                highlighted = parent
            }
        case 36, 76, 49: // return, enter, space
            if let index { choose(items[index].item) }
        case 53: // escape
            onClose?(true)
        default:
            guard event.modifierFlags.isDisjoint(with: [.command, .control]),
                  let characters = event.charactersIgnoringModifiers?.lowercased(), characters.allSatisfy({ $0.isLetter || $0.isNumber })
            else { return false }
            typed = Date().timeIntervalSince(typedAt) < 0.9 ? typed + characters : characters
            typedAt = Date()
            if let match = items.first(where: { $0.item.title.lowercased().hasPrefix(typed) }) { highlighted = match.item.id }
        }
        return true
    }

    func choose(_ item: HazeMenuItem) {
        guard item.isEnabled, chosen == nil else { return }
        if item.submenu != nil {
            highlighted = item.id
            toggle(item)
            return
        }
        chosen = item.id
        highlighted = item.id
        // Lit a moment, like a menu item, then the menu goes and the action runs.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(90))
            self.onClose?(true)
            item.action()
        }
    }

    /// Opens or closes `item`'s submenu, under it.
    func toggle(_ item: HazeMenuItem) {
        if expanded[item.id] != nil {
            collapse(item.id)
        } else if let submenu = item.submenu {
            expanded[item.id] = submenu()
            onResize?(true)
        }
    }

    private func collapse(_ id: UUID) {
        func remove(_ id: UUID) {
            for child in expanded.removeValue(forKey: id) ?? [] {
                if let item = child.menuItem { remove(item.id) }
            }
        }
        remove(id)
        if let highlighted, !rows.contains(where: { $0.id == highlighted }) { self.highlighted = id }
        onResize?(false)
    }
}

/// A borderless panel that takes the keyboard and hands its keys to the menu.
final class HazeMenuPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onResignKey: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
        setAccessibilityRole(.menu)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// The menu itself.
struct HazeMenuView: View {
    /// Room around the menu for its shadow (inside the panel).
    static let margin: CGFloat = 22

    let state: HazeMenuState
    let header: HazeMenuHeader?
    var minWidth: CGFloat = 0
    /// The items scroll at this size (nil: they all show).
    var scrollSize: CGSize?
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        let rows = state.rows
        let items = rows.compactMap(\.entry.menuItem)
        let marks = items.contains { $0.state != .off }
        // Illustrations are the top level's; a submenu's rows keep their room.
        let icons = rows.contains { row in
            guard row.depth == 0 else { return false }
            if case .info = row.entry { return true }
            return row.entry.menuItem.map { $0.symbol != nil || $0.image != nil } ?? false
        }
        VStack(alignment: .leading, spacing: 1) {
            if let header {
                HStack(spacing: 8) {
                    if let icon = header.icon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                            .frame(width: 18, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    Text(verbatim: header.title)
                        .font(QuickHaze.mona(12, 600))
                        .foregroundStyle(QuickHaze.textSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
                divider
            }
            let list = VStack(alignment: .leading, spacing: 1) {
                ForEach(rows) { row in
                    self.row(row, marks: marks, icons: icons)
                        // A submenu's rows come out from under their item.
                        .transition(row.depth > 0 ? .asymmetric(insertion: .opacity.combined(with: .offset(y: -6)), removal: .opacity)
                                                  : .identity)
                }
            }
            if let scrollSize {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) { list }
                        .frame(width: scrollSize.width, height: scrollSize.height)
                        // The choice (or the keyboard's item) comes into view.
                        .onAppear {
                            if let id = state.highlighted ?? items.first(where: { $0.state == .on })?.id { proxy.scrollTo(id, anchor: .center) }
                        }
                        .onChange(of: state.highlighted) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                }
            } else {
                list
            }
        }
        .padding(5)
        .frame(minWidth: max(214, minWidth), alignment: .leading)
        .fixedSize()
        .background {
            ZStack {
                shape.fill(QuickHaze.rgb(0x121810, 0.97))
                MenuGlow().clipShape(shape)
            }
        }
        .overlay { shape.strokeBorder(QuickHaze.text.opacity(0.09)) }
        .shadow(color: .black.opacity(0.55), radius: 18, y: 10)
        .scaleEffect(state.shown || reduceMotion ? 1 : 0.94, anchor: state.anchor)
        .opacity(state.shown ? 1 : 0)
        .offset(y: state.shown || reduceMotion ? 0 : (state.anchor.y == 0 ? -4 : 4))
        .animation(motion(.spring(response: 0.26, dampingFraction: 0.84)), value: state.shown)
        .animation(motion(.spring(response: 0.2, dampingFraction: 0.9)), value: state.highlighted)
        .animation(motion(.spring(response: 0.3, dampingFraction: 0.86)), value: state.expanded.count)
        .padding(Self.margin)
        // The menu keeps to the corner it opened from while a submenu opens or closes.
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: Alignment(horizontal: state.anchor.x == 0 ? .leading : .trailing, vertical: state.anchor.y == 0 ? .top : .bottom))
        // A click around the menu (its shadow is in the panel) closes it.
        .background { Color.clear.contentShape(Rectangle()).onTapGesture { state.onClose?(true) } }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
    }

    /// The haze's springs, or a plain fade with Reduce Motion.
    private func motion(_ animation: Animation) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : animation
    }

    private var divider: some View {
        Rectangle()
            .fill(QuickHaze.text.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func row(_ row: HazeMenuState.Row, marks: Bool, icons: Bool) -> some View {
        let indent = CGFloat(row.depth) * 14
        switch row.entry {
        case .item(let item):
            // In a submenu only a real picture shows (an app's icon), no illustration.
            self.item(item, indent: indent, marks: marks, icons: icons,
                      showsIcon: row.depth == 0 || (item.symbol == nil && item.image?.isTemplate == false))
        case .separator:
            divider.padding(.leading, indent)
        case .section(let title, _):
            Text(verbatim: title)
                .font(QuickHaze.mona(11, 600))
                .foregroundStyle(QuickHaze.sectionLabel)
                .lineLimit(1)
                .padding(.leading, 9 + indent)
                .padding(.top, 6)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
        case .note(let text, _):
            NoteWidth(limit: 300) {
                Text(verbatim: text)
                    .font(QuickHaze.mona(12))
                    .foregroundStyle(QuickHaze.textTertiary)
            }
            .padding(.leading, 9 + indent)
            .padding(.trailing, 9)
            .padding(.vertical, 5)
        case .info(let text, let symbol, _):
            HStack(spacing: 10) {
                if marks { Color.clear.frame(width: 12).padding(.trailing, -4) }
                if icons {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(QuickHaze.textTertiary)
                        .frame(width: 18)
                }
                Text(verbatim: text)
                    .font(QuickHaze.mona(12.5))
                    .foregroundStyle(QuickHaze.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 9 + indent)
            .padding(.trailing, 9)
            .frame(minHeight: 26)
            .accessibilityElement(children: .combine)
        }
    }

    private func item(_ item: HazeMenuItem, indent: CGFloat, marks: Bool, icons: Bool, showsIcon: Bool) -> some View {
        let lit = state.highlighted == item.id && item.isEnabled
        let destructive = item.role == .destructive
        let open = state.expanded[item.id] != nil
        let tint = destructive ? QuickHaze.danger : (lit ? QuickHaze.accentText : QuickHaze.text)
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button { state.choose(item) } label: {
            HStack(spacing: 10) {
                if marks {
                    Group {
                        if item.state != .off {
                            Image(systemName: item.state == .on ? "checkmark" : "minus")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(QuickHaze.accent)
                        }
                    }
                    .frame(width: 12)
                    .padding(.trailing, -4)
                }
                if icons {
                    Group {
                        if !showsIcon {
                            EmptyView()
                        } else if let symbol = item.symbol {
                            Image(systemName: symbol)
                                .font(.system(size: 13, weight: .medium))
                                .symbolEffect(.bounce, value: state.chosen == item.id)
                        } else if let image = item.image {
                            Image(nsImage: image)
                                .renderingMode(image.isTemplate ? .template : .original)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 16, height: 16)
                        }
                    }
                    .frame(width: 18)
                    .foregroundStyle(destructive ? QuickHaze.danger : (lit ? QuickHaze.accent : QuickHaze.textSecondary))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: item.title)
                        .font(QuickHaze.mona(13, lit ? 600 : 500))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(verbatim: subtitle)
                            .font(QuickHaze.mona(11.5))
                            .foregroundStyle(QuickHaze.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 18)
                if item.submenu != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(lit ? QuickHaze.accent : QuickHaze.textTertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .accessibilityHidden(true)
                } else if let shortcut = item.shortcut {
                    Text(verbatim: shortcut)
                        .font(QuickHaze.mona(11.5))
                        .foregroundStyle(QuickHaze.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, 9 + indent)
            .padding(.trailing, 9)
            .padding(.vertical, item.subtitle == nil ? 0 : 5)
            .frame(minHeight: 30)
            .background {
                if lit {
                    shape.fill(destructive ? QuickHaze.dangerFill : QuickHaze.selection)
                        .overlay { shape.strokeBorder((destructive ? QuickHaze.danger : QuickHaze.accent).opacity(0.12)) }
                        .matchedGeometryEffect(id: reduceMotion ? AnyHashable(item.id) : AnyHashable("highlight"), in: highlight)
                }
            }
            .contentShape(shape)
            .opacity(item.isEnabled ? 1 : 0.38)
        }
        .buttonStyle(HazeMenuRowStyle())
        .disabled(!item.isEnabled)
        .onHover { inside in
            if inside, item.isEnabled { state.highlighted = item.id } else if !inside, state.highlighted == item.id { state.highlighted = nil }
        }
        .help(Text(verbatim: item.toolTip ?? ""))
        .accessibilityLabel(Text(verbatim: item.title))
        .accessibilityAddTraits(item.state == .on ? .isSelected : [])
    }
}

/// A menu row gives a touch under a click.
private struct HazeMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// Avo's green glowing into the menu's top right corner (the Library's
/// `radial-gradient(180px 110px at 100% -10%, …)`).
/// A note's text as wide as it is up to `limit`, wrapping beyond it, the
/// same whatever width it is offered. The panel is sized from the menu's
/// ideal size: a note measured on one line that wrapped once laid out ran
/// the menu's last item past its bottom.
private struct NoteWidth: Layout {
    var limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        return text.sizeThatFits(ProposedViewSize(width: width(of: text), height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let text = subviews.first else { return }
        text.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: width(of: text), height: nil))
    }

    private func width(of text: LayoutSubview) -> CGFloat {
        min(text.sizeThatFits(.unspecified).width, limit)
    }
}

private struct MenuGlow: View {
    var body: some View {
        let gradient = Gradient(stops: [
            .init(color: QuickHaze.rgb(0xD8E8A7, 0.13), location: 0),
            .init(color: QuickHaze.rgb(0xD8E8A7, 0), location: 0.7),
        ])
        Canvas { context, size in
            var layer = context
            layer.translateBy(x: size.width, y: size.height * -0.1)
            layer.scaleBy(x: 1, y: 110.0 / 180)
            let reach: CGFloat = 180 * 0.7
            layer.fill(Path(ellipseIn: CGRect(x: -reach, y: -reach, width: reach * 2, height: reach * 2)),
                       with: .radialGradient(gradient, center: .zero, startRadius: 0, endRadius: 180))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
