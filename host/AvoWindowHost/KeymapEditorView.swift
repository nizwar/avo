import AppKit
import AvoKeymap
import SwiftUI
import UniformTypeIdentifiers

/// The key mapping editor drawn over the game (KeymapOverlayWindow).
///
/// Every control is an object on the game: drag its body to move it, drag
/// its ↘ handle to resize it, click × to remove it. With an object selected
/// the next key is its trigger, any key at all (Delete, Esc and the
/// modifiers included, a modifier once it is let go on its own); right-click
/// for mouse buttons and the wheel. ⌥ + arrow keys move the selected object
/// and ⌥⇧ + arrow keys resize it. The eye is a swipe area with a point (where
/// its finger touches down), and an anchor tap may have an area too: drag
/// the area to move it, its edges and corners (shown while selected) to
/// resize it, the point to move it within. Positions and sizes are fractions
/// of the display, so the layout follows the window at any size. With MOBA
/// controls in the layout, a hero marker shows (and is dragged to) where
/// they aim from.
///
/// The controller panel (ControllerPanel.swift, the toolbar's Controller
/// button) draws the controller: drag a button or stick from it onto the
/// game to place a control for it there (a menu offers the kinds that fit),
/// or onto a control to bind it. With a control selected, pressing a button
/// on the controller, pushing a stick or clicking one in the panel binds it;
/// a control keeps one key and one controller button.
@MainActor
final class KeymapEditorView: NSView {
    private enum Drag {
        case move(id: String, offset: CGVector)
        /// `offset` leads from the pointer to the corner the handle belongs
        /// on, which differs when the handle was kept on the display.
        case resize(id: String, offset: CGVector)
        case swipeEnd(id: String)
        case hero(offset: CGVector)
        /// An eye's or anchor tap's area by `edges` (a corner: two), or as a
        /// whole when there are none: the control as the drag began, changed
        /// by how far the pointer is from where it took hold (`grab`).
        case area(id: String, edges: NormalizedRect.Edges, start: Control, grab: NormalizedPoint)
    }

    private enum Hit {
        case remove(String)
        case resize(String)
        case dpadSlot(String, Int)
        case swipeEnd(String)
        case body(String)
        /// An edge or corner of the selected control's area.
        case areaEdge(String, NormalizedRect.Edges)
        /// Inside an area, where no control is.
        case area(String)
        /// The hero marker, which belongs to no control.
        case hero

        var controlID: String? {
            switch self {
            case .remove(let id), .resize(let id), .dpadSlot(let id, _), .swipeEnd(let id), .body(let id), .areaEdge(let id, _),
                 .area(let id): id
            case .hero: nil
            }
        }
    }

    private var profile: KeymapProfile { didSet { refreshPanel() } }
    private var selected: String? { didSet { refreshPanel() } }
    /// The D-pad direction the next key sets: 0 up, 1 left, 2 down, 3 right.
    private var dpadSlot = 0
    private var drag: Drag?
    /// Where the pointer is during an area drag (its size shows beside it).
    private var dragPoint: CGPoint?
    private var hovered: Hit?
    /// A modifier key pressed on its own: the selected object's trigger once
    /// it is let go without another key, so ⌥ + arrow keys can move it.
    private var pendingModifier: KeyName?
    private let displayRect: () -> CGRect
    private let onSave: (KeymapProfile) -> String?
    var onClose: (() -> Void)?
    private let toolbar = NSStackView()
    private let status = NSTextField(labelWithString: "")
    /// The status line's own dark plate: the game shows through the editor.
    private let statusPlate = StatusPlate()
    private let showOnGame = NSButton()
    private let opacity = NSSlider()
    private let opacityValue = NSTextField(labelWithString: "")
    /// Editor Opacity: how solid the objects and the dimming are.
    private let editorOpacity = NSSlider()
    private let editorOpacityValue = NSTextField(labelWithString: "")
    private var seeThrough = KeymapEditorView.savedOpacity
    private var hintsObserver: (any NSObjectProtocol)?
    private let controllerToggle = NSButton()
    private let controllerPanel = ControllerPanelModel()
    private var panelHost: NSHostingView<ControllerPanelView>?
    private var panelLeading: NSLayoutConstraint?
    private var panelTop: NSLayoutConstraint?
    /// Where the panel sat when its header began to move.
    private var panelMoveStart: (x: CGFloat, y: CGFloat)?
    /// A part of the controller being dragged from the panel, and where the pointer is (in this view).
    private var padDrag: (element: GamepadElement, at: CGPoint)?
    /// The part under the pointer in the panel: the controls it drives light up.
    private var padHover: GamepadElement?
    private var gamepadListener: UUID?
    /// How far each stick leaned at the last report: a push past halfway binds it once.
    private var stickLean: [GamepadStick: Double] = [:]

    private static let handleRadius = KeymapPainter.handleRadius
    /// How close the pointer must be to an area's edge to take it, and how
    /// close to the display's edge or the area's centre an edge or point
    /// snaps to it, in points.
    private static let edgeReach: CGFloat = 6
    private static let snapDistance: CGFloat = 8
    /// One press of ⌥ + an arrow key, as a fraction of the display.
    private static let keyStep = 0.01

    /// Editor Opacity, remembered per app (the shim's defaults). Lower shows
    /// more of the game under the objects while placing them on its buttons;
    /// their outlines and keys stay readable.
    static let opacityRange = 0.2...1.0
    private static var savedOpacity: Double {
        get { UserDefaults.standard.object(forKey: "AvoKeymapEditorOpacity") as? Double ?? 0.6 }
        set { UserDefaults.standard.set(min(max(newValue, opacityRange.lowerBound), opacityRange.upperBound), forKey: "AvoKeymapEditorOpacity") }
    }

    init(displayRect: @escaping () -> CGRect, profile: KeymapProfile, onSave: @escaping (KeymapProfile) -> String?) {
        self.displayRect = displayRect
        self.profile = profile
        self.onSave = onSave
        super.init(frame: .zero)
        // Composited over the game's Metal layer.
        wantsLayer = true
        buildToolbar()
        connectPanel()
        // Out by default while a controller is connected or the layout uses one; then as the player left it.
        let shown = UserDefaults.standard.object(forKey: Self.panelShownKey) as? Bool
            ?? (GamepadHub.shared.info != nil || profile.usesGamepad)
        if shown { showPanel(true) }
        if let warning = Self.newerControlsWarning(profile) { setStatus(warning, problem: true) }
    }

    /// While open, Show Key Mapping on Game and its visibility can also
    /// change from the menus: the toolbar follows them.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let hintsObserver { NotificationCenter.default.removeObserver(hintsObserver) }
            hintsObserver = nil
            if let gamepadListener { GamepadHub.shared.removeListener(gamepadListener) }
            gamepadListener = nil
            controllerPanel.stop()
        } else if hintsObserver == nil {
            hintsObserver = NotificationCenter.default.addObserver(forName: KeymapHints.changed, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.showHintSettings() }
            }
            showHintSettings()
            gamepadListener = GamepadHub.shared.addListener { [weak self] inputs, _ in self?.gamepadChanged(inputs) }
            if showsController { controllerPanel.start() }
        }
    }

    /// Said when a layout came with controls this version cannot show: Done
    /// saves the layout without them.
    private static func newerControlsWarning(_ profile: KeymapProfile) -> String? {
        guard !profile.unsupportedControls.isEmpty else { return nil }
        let types = Array(Set(profile.unsupportedControls)).sorted().joined(separator: ", ")
        return String(localized: "This layout has controls from a newer version of Avo (\(types)). They are not shown here, and saving leaves them out.",
                      bundle: .windowHost)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    // MARK: Toolbar

    private func buildToolbar() {
        func button(_ title: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.controlSize = .small
            return button
        }
        func menu(_ title: String, symbol: String, items: [(String, String?, Selector)]) -> NSPopUpButton {
            let popup = NSPopUpButton(frame: .zero, pullsDown: true)
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            let label = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            label.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            popup.menu?.addItem(label)
            for (name, symbol, action) in items {
                let item = NSMenuItem(title: name, action: action, keyEquivalent: "")
                item.target = self
                if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
                popup.menu?.addItem(item)
            }
            return popup
        }
        let add = menu(String(localized: "Add Control", bundle: .windowHost), symbol: "plus", items: [
            (String(localized: "Tap", bundle: .windowHost), "hand.tap", #selector(addTap)),
            (String(localized: "Repeat Tap", bundle: .windowHost), "repeat", #selector(addRepeatTap)),
            (String(localized: "Anchor Tap", bundle: .windowHost), "arrow.up.and.down.and.arrow.left.and.right", #selector(addAnchor)),
            (String(localized: "D-pad", bundle: .windowHost), "dpad", #selector(addDPad)),
            (String(localized: "Swipe", bundle: .windowHost), "hand.draw", #selector(addSwipe)),
            (String(localized: "Eye (Mouse Look)", bundle: .windowHost), "eye", #selector(addEye)),
            (String(localized: "Aim Down Sights", bundle: .windowHost), "scope", #selector(addADS)),
            (String(localized: "Move by Mouse (MOBA)", bundle: .windowHost), "cursorarrow.motionlines", #selector(addMobaMove)),
            (String(localized: "Smart Cast (MOBA)", bundle: .windowHost), "sparkles", #selector(addSmartCast)),
        ])
        let templates = menu(String(localized: "Templates", bundle: .windowHost), symbol: "square.grid.2x2", items: [])
        let note = NSMenuItem(title: String(localized: "Starting layouts: move each control onto the game's button afterwards", bundle: .windowHost),
                              action: nil, keyEquivalent: "")
        note.isEnabled = false
        templates.menu?.addItem(note)
        for template in KeymapTemplate.allCases {
            let item = NSMenuItem(title: Self.title(of: template), action: #selector(insertTemplate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = template.rawValue
            item.image = NSImage(systemSymbolName: Self.symbol(of: template), accessibilityDescription: nil)
            templates.menu?.addItem(item)
        }
        templates.autoenablesItems = false
        let more = menu("", symbol: "ellipsis.circle", items: [
            (String(localized: "Import…", bundle: .windowHost), nil, #selector(importProfile)),
            (String(localized: "Export…", bundle: .windowHost), nil, #selector(exportProfile)),
            (String(localized: "Remove All Controls", bundle: .windowHost), nil, #selector(removeAll)),
        ])
        more.setAccessibilityLabel(String(localized: "More", bundle: .windowHost))
        controllerToggle.title = String(localized: "Controller", bundle: .windowHost)
        controllerToggle.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: nil)
        controllerToggle.imagePosition = .imageLeading
        controllerToggle.setButtonType(.pushOnPushOff)
        controllerToggle.bezelStyle = .rounded
        controllerToggle.controlSize = .small
        controllerToggle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        controllerToggle.target = self
        controllerToggle.action = #selector(toggleControllerPanel)
        controllerToggle.toolTip = String(localized: "Show the controller, to map its buttons and sticks", bundle: .windowHost)
        let actions = NSStackView(views: [add, templates, controllerToggle, more,
                                          button(String(localized: "Cancel", bundle: .windowHost), #selector(close)),
                                          button(String(localized: "Done", bundle: .windowHost), #selector(saveAndClose))])
        actions.orientation = .horizontal
        actions.spacing = 6
        // Second row: the key mapping drawn over the game while playing.
        showOnGame.title = String(localized: "Show on game", bundle: .windowHost)
        showOnGame.setButtonType(.switch)
        showOnGame.controlSize = .small
        showOnGame.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        showOnGame.target = self
        showOnGame.action = #selector(toggleShowOnGame)
        func slider(_ slider: NSSlider, range: ClosedRange<Double>, action: Selector, label: String) {
            slider.minValue = range.lowerBound
            slider.maxValue = range.upperBound
            slider.controlSize = .small
            slider.isContinuous = true
            slider.target = self
            slider.action = action
            slider.setAccessibilityLabel(label)
            // Shorter rather than off the toolbar in a narrow window.
            let width = slider.widthAnchor.constraint(equalToConstant: 80)
            width.priority = NSLayoutConstraint.Priority(700)
            width.isActive = true
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        slider(opacity, range: KeymapHints.opacityRange, action: #selector(opacityChanged),
               label: String(localized: "Opacity", bundle: .windowHost))
        opacity.toolTip = String(localized: "How clearly the key mapping shows on the game while you play", bundle: .windowHost)
        let editorLabel = NSTextField(labelWithString: String(localized: "Editor opacity", bundle: .windowHost))
        editorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        slider(editorOpacity, range: Self.opacityRange, action: #selector(editorOpacityChanged),
               label: editorLabel.stringValue)
        editorOpacity.toolTip = String(localized: "Lower it to see the game through the editor while you place controls on its buttons", bundle: .windowHost)
        editorLabel.toolTip = editorOpacity.toolTip
        for value in [opacityValue, editorOpacityValue] {
            value.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            value.textColor = .secondaryLabelColor
            // "100%" fits: the row does not jump while dragging.
            value.widthAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        }
        let hints = NSStackView(views: [showOnGame, opacity, opacityValue, editorLabel, editorOpacity, editorOpacityValue])
        hints.orientation = .horizontal
        hints.spacing = 6
        hints.setCustomSpacing(14, after: opacityValue)
        showHintSettings()
        for row in [actions, hints] { toolbar.addArrangedSubview(row) }
        toolbar.orientation = .vertical
        toolbar.alignment = .centerX
        toolbar.spacing = 4
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        // Dark like the other overlays on the game: it stays readable while
        // the game shows through it.
        toolbar.appearance = NSAppearance(named: .darkAqua)
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 10
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        status.textColor = .white
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.alignment = .center
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 3
        // A label does not wrap by itself (see layout()), and a long message
        // must never make the window wider.
        status.cell?.wraps = true
        status.cell?.isScrollable = false
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.translatesAutoresizingMaskIntoConstraints = false
        statusPlate.wantsLayer = true
        statusPlate.layer?.cornerRadius = 8
        statusPlate.translatesAutoresizingMaskIntoConstraints = false
        statusPlate.addSubview(status)
        addSubview(toolbar)
        addSubview(statusPlate)
        let centered = toolbar.centerXAnchor.constraint(equalTo: centerXAnchor)
        centered.priority = .defaultHigh
        NSLayoutConstraint.activate([
            centered,
            toolbar.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            status.leadingAnchor.constraint(equalTo: statusPlate.leadingAnchor, constant: 10),
            status.trailingAnchor.constraint(equalTo: statusPlate.trailingAnchor, constant: -10),
            status.topAnchor.constraint(equalTo: statusPlate.topAnchor, constant: 5),
            status.bottomAnchor.constraint(equalTo: statusPlate.bottomAnchor, constant: -5),
            statusPlate.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusPlate.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            statusPlate.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            statusPlate.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        showEditorOpacity()
        showHelp()
    }

    override func layout() {
        // Long messages wrap within the window instead of running off it
        // (set first, so this pass already uses it).
        status.preferredMaxLayoutWidth = max(bounds.width - 44, 120)
        let room = max(bounds.width - 2 * Self.panelMargin, ControllerPanelModel.minWidth)
        if abs(controllerPanel.maxWidth - room) > 0.5 { controllerPanel.maxWidth = room }
        super.layout()
        // The panel's place needs its size, known only now. A place set after
        // the layout waits for the next pass, so lay out again: else a panel
        // just opened stays in the top left corner until it is dragged.
        if placePanel() { super.layout() }
    }

    private func showHintSettings() {
        showOnGame.state = KeymapHints.visible ? .on : .off
        opacity.doubleValue = KeymapHints.opacity
        opacity.isEnabled = KeymapHints.visible
        opacityValue.stringValue = KeymapHints.opacity.formatted(.percent.precision(.fractionLength(0)))
    }

    @objc private func toggleShowOnGame() {
        KeymapHints.visible = showOnGame.state == .on
        showHintSettings()
    }

    @objc private func opacityChanged() {
        // 5% steps, which include the menus' Key Mapping Visibility steps.
        KeymapHints.opacity = (opacity.doubleValue * 20).rounded() / 20
        showHintSettings()
    }

    /// The slider, the toolbar's and status line's plates (never so faint
    /// that their text gets hard to read) and the objects.
    private func showEditorOpacity() {
        editorOpacity.doubleValue = seeThrough
        editorOpacityValue.stringValue = seeThrough.formatted(.percent.precision(.fractionLength(0)))
        toolbar.layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.62 + 0.3 * seeThrough).cgColor
        statusPlate.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5 + 0.2 * seeThrough).cgColor
        needsDisplay = true
    }

    @objc private func editorOpacityChanged() {
        seeThrough = min(max((editorOpacity.doubleValue * 20).rounded() / 20, Self.opacityRange.lowerBound), Self.opacityRange.upperBound)
        Self.savedOpacity = seeThrough
        showEditorOpacity()
    }

    private func setStatus(_ text: String, problem: Bool = false) {
        status.stringValue = text
        status.textColor = problem ? .systemYellow : .white
    }

    private func showHelp() {
        setStatus(String(localized: "Select an object, then press the key for it. Drag to move (or ⌥ + arrow keys), ↘ to resize, × to remove. Right-click for mouse buttons.",
                         bundle: .windowHost))
    }

    // MARK: Geometry

    private var painter: KeymapPainter { KeymapPainter(displayRect: displayRect()) }
    private func point(_ p: NormalizedPoint) -> CGPoint { painter.point(p) }
    private func normalized(_ p: CGPoint) -> NormalizedPoint { painter.normalized(p) }
    private func anchor(of control: Control) -> NormalizedPoint { painter.anchor(of: control) }
    private func bubbleRadius(_ control: Control) -> CGFloat { painter.bubbleRadius(control) }
    private func dpadRadius(_ radius: Double) -> CGFloat { painter.dpadRadius(radius) }
    private func frame(of control: Control) -> CGRect { painter.frame(of: control) }
    private func removeHandle(_ control: Control) -> CGPoint { painter.removeHandle(control) }
    private func resizeHandle(_ control: Control) -> CGPoint? { painter.resizeHandle(control) }
    private func resizeCorner(_ control: Control) -> CGPoint? { painter.resizeCorner(control) }
    private func dpadSlots(center: CGPoint, radius: CGFloat) -> [CGPoint] { painter.dpadSlots(center: center, radius: radius) }

    private func hit(at p: CGPoint) -> Hit? {
        func near(_ a: CGPoint, _ r: CGFloat) -> Bool { hypot(a.x - p.x, a.y - p.y) <= r }
        let newestFirst = Array(profile.controls.reversed())
        // Handles sit on top of everything.
        for control in newestFirst {
            if near(removeHandle(control), Self.handleRadius + 3) { return .remove(control.id) }
            if let handle = resizeHandle(control), near(handle, Self.handleRadius + 3) { return .resize(control.id) }
        }
        // Then the selected area's corner and edge handles.
        let selectedArea = selected.flatMap { id in profile.controls.first { $0.id == id } }.flatMap { control in
            painter.areaRect(of: control).map { (id: control.id, rect: $0, movable: hasOwnArea(control)) }
        }
        if let selectedArea,
           let handle = painter.areaHandles(selectedArea.rect).first(where: { near($0.at, KeymapPainter.areaHandleSide / 2 + 5) }) {
            return .areaEdge(selectedArea.id, handle.edges)
        }
        // Then the hero marker, which is drawn over the controls.
        if showsHero, near(point(hero), KeymapPainter.heroRadius + 4) { return .hero }
        for control in newestFirst {
            switch control.kind {
            case .aim:
                if near(point(anchor(of: control)), KeymapPainter.eyeRadius) { return .body(control.id) }
            case let .dpad(center, radius, _, _, _, _, _):
                let c = point(center), r = dpadRadius(radius)
                for (slot, at) in dpadSlots(center: c, radius: r).enumerated() where near(at, max(r * 0.24, 12)) {
                    return .dpadSlot(control.id, slot)
                }
                if near(c, r) { return .body(control.id) }
            case let .mobaMove(center, radius):
                if near(point(center), dpadRadius(radius)) { return .body(control.id) }
            case let .swipe(from, to, _):
                if near(point(to), 12) { return .swipeEnd(control.id) }
                if near(point(from), bubbleRadius(control)) || distance(from: p, to: point(from), point(to)) <= 8 { return .body(control.id) }
            default:
                if near(point(anchor(of: control)), bubbleRadius(control)) { return .body(control.id) }
            }
        }
        // Under the controls: the rest of the selected area's edges, then
        // inside an area, which drags it (the selected one first).
        if let selectedArea {
            if let edges = edges(of: selectedArea.rect, near: p) { return .areaEdge(selectedArea.id, edges) }
            if selectedArea.movable, selectedArea.rect.contains(p) { return .area(selectedArea.id) }
        }
        for control in newestFirst where hasOwnArea(control) {
            if let rect = painter.areaRect(of: control), rect.contains(p) { return .area(control.id) }
        }
        return nil
    }

    /// The edges of `r` within reach of `p`: two at a corner, nil away from them.
    private func edges(of r: CGRect, near p: CGPoint) -> NormalizedRect.Edges? {
        let reach = Self.edgeReach
        guard r.insetBy(dx: -reach, dy: -reach).contains(p) else { return nil }
        var edges: NormalizedRect.Edges = []
        if abs(p.x - r.minX) <= reach { edges.insert(.left) } else if abs(p.x - r.maxX) <= reach { edges.insert(.right) }
        // y up in the view: the top of the screen is the rectangle's maxY.
        if abs(p.y - r.maxY) <= reach { edges.insert(.top) } else if abs(p.y - r.minY) <= reach { edges.insert(.bottom) }
        return edges.isEmpty ? nil : edges
    }

    /// An eye's swipe area, or an anchor tap's own: shown, and dragged by
    /// its inside, all the time (an anchor tap without one uses the whole
    /// screen, framed only while it is selected).
    private func hasOwnArea(_ control: Control) -> Bool {
        switch control.kind {
        case .aim, .anchor(_, _?): true
        default: false
        }
    }

    /// The smallest area the editor makes: a square of Control.minimumAreaSide on screen.
    private var minimumAreaSize: (width: Double, height: Double) {
        let rect = displayRect()
        let aspect = rect.height > 0 && rect.width > 0 ? rect.width / rect.height : 16.0 / 9.0
        return (Control.minimumAreaSide / aspect, Control.minimumAreaSide)
    }

    private func distance(from p: CGPoint, to a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    private func index(of id: String) -> Int? { profile.controls.firstIndex { $0.id == id } }

    private func isEye(_ control: Control) -> Bool { KeymapPainter.isEye(control) }

    /// Where MOBA controls aim from; shown while the layout has any.
    private var hero: NormalizedPoint { profile.hero ?? KeymapProfile.defaultHero }
    private var showsHero: Bool { profile.controls.contains(where: \.followsCursor) }

    // MARK: Editing

    private func move(_ control: inout Control, to p: NormalizedPoint) {
        switch control.kind {
        case .tap: control.kind = .tap(p)
        case .hold: control.kind = .hold(p)
        case .anchor:
            // Within its area, when it has one.
            control.setTouchPoint(p)
        case .ads(_, let toggle): control.kind = .ads(p, toggle: toggle)
        case .repeatTap(_, let interval): control.kind = .repeatTap(p, intervalMilliseconds: interval)
        case let .dpad(_, radius, up, down, left, right, stick):
            control.kind = .dpad(center: p, radius: radius, up: up, down: down, left: left, right: right, stick: stick)
        case .aim:
            // The eye's point, where its finger touches down: within its
            // area, and its centre again when let go close to it.
            if let center = control.fingerArea?.center, hypot(point(center).x - point(p).x, point(center).y - point(p).y) <= Self.snapDistance {
                control.setTouchPoint(nil)
            } else {
                control.setTouchPoint(p)
            }
        case let .swipe(from, to, ms):
            let dx = to.x - from.x, dy = to.y - from.y
            control.kind = .swipe(from: p, to: NormalizedPoint(min(max(p.x + dx, 0), 1), min(max(p.y + dy, 0), 1)), milliseconds: ms)
        case .mobaMove(_, let radius): control.kind = .mobaMove(center: p, radius: radius)
        case let .smartCast(_, radius, reach): control.kind = .smartCast(p, radius: radius, reach: reach)
        case .macro: break
        }
    }

    /// Follows the ↘ handle: a bubble's size, a D-pad's or MOBA joystick's
    /// radius, a smart cast's drag radius.
    private func resize(_ control: inout Control, to p: CGPoint) {
        let height = max(displayRect().height, 1)
        // The handle sits on the corner of the control's box, radius·√2 out.
        let c = point(anchor(of: control))
        let radius = Double(hypot(p.x - c.x, p.y - c.y) / 2.squareRoot() / height)
        switch control.kind {
        case let .dpad(center, _, up, down, left, right, stick):
            control.kind = .dpad(center: center, radius: min(max(radius, 0.04), 0.45), up: up, down: down, left: left, right: right, stick: stick)
        case .mobaMove(let center, _):
            control.kind = .mobaMove(center: center, radius: min(max(radius, 0.04), 0.45))
        case let .smartCast(button, _, reach):
            control.kind = .smartCast(button, radius: min(max(radius, 0.03), 0.45), reach: reach)
        case .aim, .swipe, .macro:
            break
        default:
            control.size = min(max(radius, Control.sizeRange.lowerBound), Control.sizeRange.upperBound)
        }
    }

    /// Follows an area drag: `edges` moved by the pointer (kept on the
    /// display, no smaller than the minimum, snapped to the display's edge
    /// when close), or with no edges the whole area and its point.
    private func dragArea(_ control: inout Control, edges: NormalizedRect.Edges, from grab: NormalizedPoint, to p: NormalizedPoint) {
        let dx = p.x - grab.x, dy = p.y - grab.y
        guard !edges.isEmpty else {
            control.moveFinger(dx: dx, dy: dy)
            return
        }
        guard let area = control.fingerArea else { return }
        let minimum = minimumAreaSize
        var r = area.resized(edges, dx: dx, dy: dy, minWidth: minimum.width, minHeight: minimum.height)
        let rect = displayRect()
        if rect.width > 0, rect.height > 0 {
            let sx = Self.snapDistance / rect.width, sy = Self.snapDistance / rect.height
            if edges.contains(.left), r.minX < sx { r.minX = 0 }
            if edges.contains(.right), r.maxX > 1 - sx { r.maxX = 1 }
            if edges.contains(.top), r.minY < sy { r.minY = 0 }
            if edges.contains(.bottom), r.maxY > 1 - sy { r.maxY = 1 }
        }
        control.setFingerArea(r)
    }

    /// ⌥ + arrow keys: the selected object a step that way (an area with
    /// its point). ⌥⇧ + arrow keys: its size, an area's around its centre
    /// (↑ taller, ↓ shorter, → wider, ← narrower), the others' ↑ and → bigger.
    /// For placing controls without dragging; these never become triggers.
    private func nudge(_ key: KeyName, flags: NSEvent.ModifierFlags) -> Bool {
        let held = flags.intersection([.option, .shift, .command, .control])
        guard held == [.option] || held == [.option, .shift] else { return false }
        let direction: (x: Double, y: Double)
        switch key {
        case .left: direction = (-1, 0)
        case .right: direction = (1, 0)
        case .up: direction = (0, -1)
        case .down: direction = (0, 1)
        default: return false
        }
        guard let id = selected, let i = index(of: id) else { return true }
        var control = profile.controls[i]
        if held == [.option] {
            if control.fingerArea != nil {
                control.moveFinger(dx: direction.x * Self.keyStep, dy: direction.y * Self.keyStep)
            } else {
                let a = anchor(of: control)
                move(&control, to: NormalizedPoint(min(max(a.x + direction.x * Self.keyStep, 0), 1),
                                                   min(max(a.y + direction.y * Self.keyStep, 0), 1)))
            }
        } else if let area = control.fingerArea {
            let minimum = minimumAreaSize
            control.setFingerArea(area.grown(dw: direction.x * 2 * Self.keyStep, dh: -direction.y * 2 * Self.keyStep,
                                             minWidth: minimum.width, minHeight: minimum.height))
        } else {
            step(&control, bigger: direction.x > 0 || direction.y < 0)
        }
        profile.controls[i] = control
        if let area = control.fingerArea { setStatus(KeymapPainter.sizeText(area)) }
        needsDisplay = true
        return true
    }

    /// A size step from the keyboard: a bubble's size, a joystick's or smart cast's radius.
    private func step(_ control: inout Control, bigger: Bool) {
        let factor = bigger ? 1.1 : 1 / 1.1
        switch control.kind {
        case let .dpad(center, radius, up, down, left, right, stick):
            control.kind = .dpad(center: center, radius: min(max(radius * factor, 0.04), 0.45), up: up, down: down, left: left,
                                 right: right, stick: stick)
        case let .mobaMove(center, radius):
            control.kind = .mobaMove(center: center, radius: min(max(radius * factor, 0.04), 0.45))
        case let .smartCast(button, radius, reach):
            control.kind = .smartCast(button, radius: min(max(radius * factor, 0.03), 0.45), reach: reach)
        case .aim, .anchor, .swipe, .macro:
            break
        default:
            control.size = min(max((control.size ?? Control.defaultSize) * factor, Control.sizeRange.lowerBound),
                               Control.sizeRange.upperBound)
        }
    }

    private func remove(_ id: String) {
        guard let index = index(of: id) else { return }
        let control = profile.controls.remove(at: index)
        if profile.fps?.aimControl == id { profile.fps = nil }
        if selected == id { selected = nil }
        setStatus(String(localized: "Removed “\(name(of: control))”.", bundle: .windowHost))
        needsDisplay = true
    }

    /// Binds `trigger` to the selected object. A trigger does one thing, so
    /// it moves off any other button; D-pad keys and the eye's key are kept
    /// (they cannot be left empty) and the press is refused instead.
    func assign(_ trigger: Trigger) {
        guard let id = selected, let index = index(of: id) else { return }
        if let owner = profile.controls.first(where: { $0.id != id && keepsTrigger($0, trigger) }) {
            setStatus(String(localized: "\(short(trigger)) is already used by “\(name(of: owner))”.", bundle: .windowHost), problem: true)
            return
        }
        if profile.fps?.cursorToggle == trigger, !isEye(profile.controls[index]) {
            setStatus(String(localized: "\(short(trigger)) locks the mouse for the eye; choose another key.", bundle: .windowHost), problem: true)
            return
        }
        for i in profile.controls.indices where i != index { profile.controls[i].triggers.removeAll { $0 == trigger } }
        let control = profile.controls[index]
        switch control.kind {
        case let .dpad(center, radius, up, down, left, right, stick):
            var keys = [up, left, down, right]
            if let other = keys.firstIndex(of: trigger), other != dpadSlot {
                keys[other] = keys[dpadSlot] // swap rather than bind one key twice
            }
            keys[dpadSlot] = trigger
            profile.controls[index].kind = .dpad(center: center, radius: radius, up: keys[0], down: keys[2],
                                                 left: keys[1], right: keys[3], stick: stick)
            let set = dpadSlot
            dpadSlot = (dpadSlot + 1) % 4
            setStatus(String(localized: "D-pad \(direction(set)): \(short(trigger)). Next key sets \(direction(dpadSlot)).", bundle: .windowHost))
        case .aim:
            if profile.fps == nil {
                profile.fps = FPSSettings(cursorToggle: trigger, aimControl: id)
            } else {
                profile.fps?.cursorToggle = trigger
                profile.fps?.aimControl = id
            }
            setStatus(String(localized: "\(short(trigger)) locks the mouse to aim with the eye, and frees it again.", bundle: .windowHost))
        default:
            if trigger.isMomentary {
                switch control.kind {
                case .tap, .swipe, .macro: break
                default:
                    setStatus(String(localized: "The wheel works with Tap and Swipe only.", bundle: .windowHost), problem: true)
                    return
                }
            }
            // A key replaces its key, and the controller button stays.
            profile.controls[index].setTrigger(trigger)
            setStatus(String(localized: "“\(name(of: control))” responds to \(short(trigger)).", bundle: .windowHost))
        }
        needsDisplay = true
    }

    /// Triggers that cannot simply be taken away from a control.
    private func keepsTrigger(_ control: Control, _ trigger: Trigger) -> Bool {
        if case .dpad = control.kind { return control.allTriggers.contains(trigger) }
        return false
    }

    private func direction(_ slot: Int) -> String {
        [String(localized: "up", bundle: .windowHost), String(localized: "left", bundle: .windowHost),
         String(localized: "down", bundle: .windowHost), String(localized: "right", bundle: .windowHost)][slot]
    }

    private func prompt(for control: Control) {
        switch control.kind {
        case .dpad:
            setStatus(String(localized: "D-pad: press four keys in turn (\(direction(dpadSlot)) first), or click a direction to change one.",
                             bundle: .windowHost))
        case .aim:
            setStatus(String(localized: "Eye: with the mouse locked, a finger swipes from the eye across its area and starts over at the edge (a taller area looks further up and down). Drag the area, its edges or the eye (⌥ + arrow keys move it, ⌥⇧ + arrow keys resize it). Press the key that locks and frees the mouse (for example F8).",
                             bundle: .windowHost))
        case .anchor:
            setStatus(String(localized: "Anchor tap: while its key is held, the mouse moves the finger from here (emote wheels), never out of its area. Drag the dashed frame’s edges in to make the area smaller; ⌥⇧ + arrow keys resize it. Press its key.",
                             bundle: .windowHost))
        case .mobaMove:
            setStatus(String(localized: "Move by mouse: while its button is held, the joystick is pushed towards the cursor, as seen from the hero marker. Right-click to pick a mouse button, or press a key.",
                             bundle: .windowHost))
        case .smartCast:
            setStatus(String(localized: "Smart cast: its key drags the skill towards the cursor, as seen from the hero marker, and letting go casts. ↘ sets how far it drags. Press its key.",
                             bundle: .windowHost))
        default:
            if showsController || GamepadHub.shared.info != nil {
                setStatus(String(localized: "Press the key or controller button for “\(name(of: control))”, or right-click for a mouse button.",
                                 bundle: .windowHost))
            } else {
                setStatus(String(localized: "Press the key for “\(name(of: control))”, or right-click for a mouse button.", bundle: .windowHost))
            }
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // A modifier held through a click is not a key for the object.
        pendingModifier = nil
        let p = convert(event.locationInWindow, from: nil)
        let target = hit(at: p)
        switch target {
        case let .areaEdge(id, edges)?:
            select(id)
            drag = areaDrag(id, edges: edges, from: p)
        case .area(let id)?:
            select(id)
            drag = areaDrag(id, edges: [], from: p)
        case .remove(let id)?:
            remove(id)
            drag = nil
            return
        case .resize(let id)?:
            select(id)
            let corner = profile.controls.first { $0.id == id }.flatMap(resizeCorner) ?? p
            drag = .resize(id: id, offset: CGVector(dx: corner.x - p.x, dy: corner.y - p.y))
        case let .dpadSlot(id, slot)?:
            select(id)
            dpadSlot = slot
            if let control = profile.controls.first(where: { $0.id == id }) { prompt(for: control) }
            drag = moveDrag(id, from: p)
        case .swipeEnd(let id)?:
            select(id)
            drag = .swipeEnd(id: id)
        case .body(let id)?:
            select(id)
            drag = moveDrag(id, from: p)
        case .hero?:
            selected = nil
            let h = point(hero)
            drag = .hero(offset: CGVector(dx: h.x - p.x, dy: h.y - p.y))
            setStatus(String(localized: "Hero: where your character stands on the screen. Move by mouse and smart cast aim from here towards the cursor.",
                             bundle: .windowHost))
        case nil:
            selected = nil
            drag = nil
            showHelp()
        }
        needsDisplay = true
    }

    private func select(_ id: String) {
        if selected != id {
            selected = id
            dpadSlot = 0
            if let control = profile.controls.first(where: { $0.id == id }) { prompt(for: control) }
        }
    }

    private func moveDrag(_ id: String, from p: CGPoint) -> Drag? {
        guard let control = profile.controls.first(where: { $0.id == id }) else { return nil }
        let a = point(anchor(of: control))
        return .move(id: id, offset: CGVector(dx: a.x - p.x, dy: a.y - p.y))
    }

    private func areaDrag(_ id: String, edges: NormalizedRect.Edges, from p: CGPoint) -> Drag? {
        guard let control = profile.controls.first(where: { $0.id == id }) else { return nil }
        dragPoint = p
        return .area(id: id, edges: edges, start: control, grab: normalized(p))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case let .area(id, edges, start, grab):
            guard let i = index(of: id) else { return }
            // From the area as the drag began, so nothing drifts.
            var control = start
            dragArea(&control, edges: edges, from: grab, to: normalized(p))
            profile.controls[i].kind = control.kind
            dragPoint = p
        case let .move(id, offset):
            guard let i = index(of: id) else { return }
            move(&profile.controls[i], to: normalized(CGPoint(x: p.x + offset.dx, y: p.y + offset.dy)))
        case let .resize(id, offset):
            guard let i = index(of: id) else { return }
            resize(&profile.controls[i], to: CGPoint(x: p.x + offset.dx, y: p.y + offset.dy))
        case .swipeEnd(let id):
            guard let i = index(of: id), case let .swipe(from, _, ms) = profile.controls[i].kind else { return }
            profile.controls[i].kind = .swipe(from: from, to: normalized(p), milliseconds: ms)
        case .hero(let offset):
            profile.hero = normalized(CGPoint(x: p.x + offset.dx, y: p.y + offset.dy))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        // After a resize the status line says the new size (the pointer's label goes).
        if case let .area(id, edges, _, _)? = drag, !edges.isEmpty,
           let area = profile.controls.first(where: { $0.id == id })?.fingerArea {
            setStatus(KeymapPainter.sizeText(area))
        }
        drag = nil
        dragPoint = nil
        needsDisplay = true
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func updateCursor(at p: CGPoint) {
        // Over the controller panel: the panel's own.
        let target = panelHost?.frame.contains(p) == true ? nil : hit(at: p)
        switch target {
        case .remove?, .dpadSlot?: NSCursor.pointingHand.set()
        case .resize?, .swipeEnd?: NSCursor.crosshair.set()
        case .body?, .hero?, .area?: NSCursor.openHand.set()
        case .areaEdge(_, let edges)?: NSCursor.frameResize(position: Self.resizePosition(edges), directions: .all).set()
        case nil: NSCursor.arrow.set()
        }
        if target?.controlID != hovered?.controlID || !sameKind(target, hovered) {
            hovered = target
            needsDisplay = true
        }
    }

    private static func resizePosition(_ edges: NormalizedRect.Edges) -> NSCursor.FrameResizePosition {
        switch edges {
        case [.top, .left]: .topLeft
        case [.top, .right]: .topRight
        case [.bottom, .left]: .bottomLeft
        case [.bottom, .right]: .bottomRight
        case .top: .top
        case .bottom: .bottom
        case .left: .left
        default: .right
        }
    }

    private func sameKind(_ a: Hit?, _ b: Hit?) -> Bool {
        switch (a, b) {
        case (.remove?, .remove?), (.resize?, .resize?), (.dpadSlot?, .dpadSlot?), (.swipeEnd?, .swipeEnd?), (.body?, .body?),
             (.area?, .area?), (.hero?, .hero?), (nil, nil): true
        case let (.areaEdge(_, x)?, .areaEdge(_, y)?): x == y
        default: false
        }
    }

    /// Right-click: mouse buttons and the wheel as triggers, and removal.
    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let id = hit(at: p)?.controlID else { return }
        select(id)
        needsDisplay = true
        let menu = NSMenu()
        let choices: [(String, Trigger)] = [
            (String(localized: "Left Click", bundle: .windowHost), .mouse(.left)),
            (String(localized: "Right Click", bundle: .windowHost), .mouse(.right)),
            (String(localized: "Middle Click", bundle: .windowHost), .mouse(.middle)),
            (String(localized: "Mouse Button 4", bundle: .windowHost), .mouse(.button4)),
            (String(localized: "Mouse Button 5", bundle: .windowHost), .mouse(.button5)),
            (String(localized: "Wheel Up", bundle: .windowHost), .scrollUp),
            (String(localized: "Wheel Down", bundle: .windowHost), .scrollDown),
        ]
        for (title, trigger) in choices {
            let item = NSMenuItem(title: title, action: #selector(assignFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = trigger.description
            menu.addItem(item)
        }
        if let control = profile.controls.first(where: { $0.id == id }) {
            let items = areaChoices(for: control)
            if !items.isEmpty { menu.addItem(.separator()) }
            for (title, action) in items {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let remove = NSMenuItem(title: String(localized: "Remove", bundle: .windowHost), action: #selector(removeSelected), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func assignFromMenu(_ item: NSMenuItem) {
        guard let text = item.representedObject as? String, let trigger = Trigger(string: text) else { return }
        assign(trigger)
    }

    @objc private func removeSelected() {
        if let selected { remove(selected) }
    }

    /// One-click areas: an eye's at full height or the default one (the
    /// right side), its point back at the centre, an anchor tap's whole screen.
    private func areaChoices(for control: Control) -> [(String, Selector)] {
        switch control.kind {
        case let .aim(_, _, _, _, _, _, _, origin):
            var choices = [(String(localized: "Full-Height Swipe Area", bundle: .windowHost), #selector(useFullHeightArea)),
                           (String(localized: "Default Swipe Area (Right Side)", bundle: .windowHost), #selector(useDefaultArea))]
            if origin != nil {
                choices.append((String(localized: "Touch Down at the Area’s Centre", bundle: .windowHost), #selector(touchDownAtCentre)))
            }
            return choices
        case .anchor(_, _?):
            return [(String(localized: "Let the Finger Use the Whole Screen", bundle: .windowHost), #selector(useWholeScreen))]
        default:
            return []
        }
    }

    private func changeSelectedArea(_ change: (inout Control) -> Void) {
        guard let id = selected, let i = index(of: id) else { return }
        change(&profile.controls[i])
        if let area = profile.controls[i].fingerArea { setStatus(KeymapPainter.sizeText(area)) }
        needsDisplay = true
    }

    @objc private func useFullHeightArea() {
        changeSelectedArea { control in
            guard let area = control.fingerArea else { return }
            let full = Control.defaultEyeArea
            control.setFingerArea(NormalizedRect(area.minX, full.minY, area.maxX, full.maxY))
        }
    }

    @objc private func useDefaultArea() {
        changeSelectedArea { $0.setFingerArea(Control.defaultEyeArea) }
    }

    @objc private func touchDownAtCentre() {
        changeSelectedArea { $0.setTouchPoint(nil) }
    }

    @objc private func useWholeScreen() {
        changeSelectedArea { $0.setFingerArea(.screen) }
    }

    override func otherMouseDown(with event: NSEvent) {
        if selected != nil, let button = MouseButton(buttonNumber: event.buttonNumber) { assign(.mouse(button)) }
    }

    override func scrollWheel(with event: NSEvent) {
        // Wheel notches only: trackpad scrolling is not a wheel.
        guard selected != nil, !event.hasPreciseScrollingDeltas, event.scrollingDeltaY != 0 else { return }
        assign(event.scrollingDeltaY > 0 ? .scrollUp : .scrollDown)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        guard let key = KeyboardMapping.key(forMacKeyCode: event.keyCode) else { return }
        // A modifier held for this key is part of it, not a key of its own.
        pendingModifier = nil
        guard selected != nil else {
            // Nothing selected: Esc leaves, like Cancel.
            if key == .escape { close() }
            return
        }
        if nudge(key, flags: event.modifierFlags) { return }
        if !event.isARepeat { assign(.key(key)) }
    }

    override func flagsChanged(with event: NSEvent) {
        guard selected != nil, let key = KeyboardMapping.key(forMacKeyCode: event.keyCode) else {
            pendingModifier = nil
            return
        }
        let pressed = Self.isPressed(key, in: event.modifierFlags)
        if key == .capsLock {
            // It locks on one press and unlocks on the next: bound as it locks.
            if pressed { assign(.key(key)) }
        } else if pressed {
            // Bound once let go on its own: ⌥ + arrow keys move the object instead.
            pendingModifier = key
        } else if pendingModifier == key {
            pendingModifier = nil
            assign(.key(key))
        }
    }

    private static func isPressed(_ key: KeyName, in flags: NSEvent.ModifierFlags) -> Bool {
        switch key {
        case .shift, .rightShift: flags.contains(.shift)
        case .control, .rightControl: flags.contains(.control)
        case .option, .rightOption: flags.contains(.option)
        case .command, .rightCommand: flags.contains(.command)
        case .capsLock: flags.contains(.capsLock)
        default: false
        }
    }

    // MARK: Adding

    private func add(_ kind: Control.Kind, prefix: String, trigger: Trigger? = nil) {
        var n = 1
        while profile.controls.contains(where: { $0.id == "\(prefix)-\(n)" }) { n += 1 }
        var control = Control(id: "\(prefix)-\(n)", kind: kind)
        // A suggested trigger only while nothing else uses it.
        if let trigger, profile.fps?.cursorToggle != trigger, !profile.controls.contains(where: { $0.allTriggers.contains(trigger) }) {
            control.triggers = [trigger]
        }
        // Do not hide a new control exactly under an older one, or under the
        // hero marker, which is drawn over the controls and takes their clicks.
        var taken = profile.controls.map(anchor(of:))
        if showsHero || control.followsCursor { taken.append(hero) }
        let start = anchor(of: control)
        var spot = start, step = 0
        while step < 12, taken.contains(where: { abs($0.x - spot.x) < 0.02 && abs($0.y - spot.y) < 0.02 }) {
            step += 1
            spot = NormalizedPoint(min(start.x + 0.05 * Double(step), 0.95), min(start.y + 0.05 * Double(step), 0.95))
        }
        if spot != start { move(&control, to: spot) }
        profile.controls.append(control)
        selected = nil
        select(control.id)
        needsDisplay = true
    }

    @objc private func addTap() { add(.tap(NormalizedPoint(0.5, 0.5)), prefix: "tap") }
    @objc private func addRepeatTap() { add(.repeatTap(NormalizedPoint(0.4, 0.5), intervalMilliseconds: 150), prefix: "repeat") }
    @objc private func addAnchor() { add(.anchor(NormalizedPoint(0.5, 0.65)), prefix: "anchor") }
    @objc private func addSwipe() {
        add(.swipe(from: NormalizedPoint(0.5, 0.6), to: NormalizedPoint(0.5, 0.4), milliseconds: 150), prefix: "swipe")
    }

    @objc private func addDPad() {
        add(.dpad(center: NormalizedPoint(0.15, 0.7), radius: 0.12, up: .key(.w), down: .key(.s), left: .key(.a), right: .key(.d),
                  stick: .left), prefix: "move")
    }

    @objc private func addADS() { add(.ads(NormalizedPoint(0.9, 0.45), toggle: false), prefix: "ads") }

    /// Right-click to walk, as in desktop MOBAs.
    @objc private func addMobaMove() {
        add(.mobaMove(center: NormalizedPoint(0.14, 0.72), radius: Control.defaultJoystickRadius), prefix: "move", trigger: .mouse(.right))
    }

    @objc private func addSmartCast() {
        add(.smartCast(NormalizedPoint(0.8, 0.75), radius: Control.defaultCastRadius, reach: Control.defaultCastReach), prefix: "skill")
    }

    @objc private func addEye() {
        if let eye = profile.controls.first(where: isEye) {
            select(eye.id)
            setStatus(String(localized: "There is one eye per layout; this is it.", bundle: .windowHost))
            needsDisplay = true
            return
        }
        // Most of the right side at full height: the finger swipes far before it starts over.
        add(.aim(area: Control.defaultEyeArea, sensitivity: AxisPair(x: 1, y: 1),
                 adsSensitivity: AxisPair(x: 0.6, y: 0.6), exponent: 1, deadzone: 0, invertY: false, stick: .right), prefix: "eye")
        guard let eye = profile.controls.last else { return }
        let toggle = FPSSettings.defaultCursorToggle
        let taken = profile.controls.contains { $0.id != eye.id && $0.allTriggers.contains(toggle) }
        profile.fps = FPSSettings(cursorToggle: taken ? .key(.grave) : toggle, aimControl: eye.id)
        prompt(for: eye)
    }

    @objc private func removeAll() {
        profile.controls.removeAll()
        profile.fps = nil
        selected = nil
        showHelp()
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // A little dimming sets the editor apart from playing; less as the
        // editor gets more see-through.
        NSColor.black.withAlphaComponent(0.35 * seeThrough).setFill()
        bounds.fill()
        var painter = self.painter
        painter.opacity = CGFloat(seeThrough)
        painter.obstacles = [toolbar.frame, statusPlate.frame]
        let eyeKey = profile.fps?.cursorToggle.shortLabel
        // Lit as if selected: where a dragged part of the controller would
        // bind, and what the part under the pointer in the panel drives.
        let dropTarget = padDrag.flatMap { dropTarget(for: $0.element, at: $0.at) }
        let lit = Set(padHover.map { profile.controls(boundTo: $0).map(\.id) } ?? []).union(dropTarget.map { [$0] } ?? [])
        // Areas under everything: the eye's swipe area and anchor taps' own
        // areas (an anchor tap's whole screen only while it is selected).
        for control in profile.controls where hasOwnArea(control) || control.id == selected {
            painter.drawArea(control, selected: control.id == selected || lit.contains(control.id), hovered: control.id == hovered?.controlID)
        }
        // Eyes first: buttons are drawn over their area.
        for control in profile.controls where isEye(control) {
            painter.draw(control, selected: control.id == selected || lit.contains(control.id), eyeKey: eyeKey)
        }
        for control in profile.controls where !isEye(control) {
            painter.draw(control, selected: control.id == selected || lit.contains(control.id),
                         activeSlot: control.id == selected ? dpadSlot : nil)
        }
        if showsHero {
            let active = { if case .hero? = drag { true } else if case .hero? = hovered { true } else { false } }()
            painter.drawHero(at: hero, selected: active)
        }
        for control in profile.controls {
            let hotRemove = { if case .remove(control.id)? = hovered { true } else { false } }()
            let hotResize = { if case .resize(control.id)? = hovered { true } else { false } }()
            painter.drawHandles(control, emphasized: control.id == selected || control.id == hovered?.controlID,
                                hotRemove: hotRemove, hotResize: hotResize)
        }
        // The selected area's edge and corner handles, and its size beside the pointer while it is dragged.
        if let id = selected, let control = profile.controls.first(where: { $0.id == id }), control.fingerArea != nil {
            let hot: NormalizedRect.Edges? = {
                if case let .area(_, edges, _, _)? = drag, !edges.isEmpty { return edges }
                if case let .areaEdge(hoveredID, edges)? = hovered, hoveredID == id { return edges }
                return nil
            }()
            painter.drawAreaHandles(control, hot: hot)
            if case .area(id, _, _, _)? = drag, let dragPoint { painter.drawAreaSize(control, near: dragPoint) }
        }
        // The part of the controller being dragged from the panel, over the game.
        if let padDrag, displayRect().contains(padDrag.at), panelHost?.frame.contains(padDrag.at) != true {
            let caption = dropTarget.flatMap { id in profile.controls.first { $0.id == id } }
                .map { String(localized: "Bind to “\(name(of: $0))”", bundle: .windowHost) }
                ?? String(localized: "Let go to choose a control", bundle: .windowHost)
            painter.drawGhost(symbol: padSymbol(padDrag.element), caption: caption, at: padDrag.at, binding: dropTarget != nil)
        }
    }

    // MARK: Controller (ControllerPanel.swift)

    private static let panelShownKey = "AvoControllerPanelShown"
    private static let panelPlaceKey = "AvoControllerPanelPlace"
    /// How far the panel keeps from the editor's edges.
    private static let panelMargin: CGFloat = 8
    /// Every part of a controller, in GamepadButton's order, then the sticks and the d-pad.
    private static let gamepadElements: [GamepadElement] = GamepadButton.allCases.map(GamepadElement.button)
        + GamepadStick.allCases.map(GamepadElement.stick) + [.dpad]

    var showsController: Bool { panelHost != nil }

    /// The Controller button and the panel's ×: remembered per app.
    func setShowsController(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.panelShownKey)
        showPanel(on)
    }

    @objc private func toggleControllerPanel() {
        setShowsController(!showsController)
    }

    private func connectPanel() {
        let panel = controllerPanel
        panel.drag = { [weak self] element, phase, location in self?.panelDragged(element, phase, location) }
        panel.click = { [weak self] element in self?.controllerPressed(element, inPanel: true) }
        panel.hover = { [weak self] element in
            guard let self, self.padHover != element else { return }
            self.padHover = element
            self.needsDisplay = true
        }
        panel.changeSettings = { [weak self] settings in self?.changeGamepadSettings(settings) }
        panel.applyTemplate = { [weak self] template in self?.applyControllerTemplate(template) }
        panel.applyPreset = { [weak self] name in self?.applyPreset(named: name) }
        panel.deletePreset = { [weak self] name in self?.deletePreset(named: name) }
        panel.savePreset = { [weak self] in self?.askToSavePreset() }
        panel.reset = { [weak self] in self?.confirmControllerReset() }
        panel.close = { [weak self] in self?.setShowsController(false) }
        panel.move = { [weak self] translation, ended in self?.movePanel(by: translation, ended: ended) }
        panel.resize = { [weak self] ended in self?.panelResized(ended: ended) }
    }

    private func showPanel(_ on: Bool) {
        controllerToggle.state = on ? .on : .off
        guard on != showsController else { return }
        // A move or resize the panel never heard the end of starts over.
        panelMoveStart = nil
        guard on else {
            panelHost?.removeFromSuperview()
            panelHost = nil
            panelLeading = nil
            panelTop = nil
            padDrag = nil
            padHover = nil
            controllerPanel.stop()
            needsDisplay = true
            return
        }
        let host = NSHostingView(rootView: ControllerPanelView(model: controllerPanel))
        host.translatesAutoresizingMaskIntoConstraints = false
        // Under the toolbar and the status line, over the game's objects.
        addSubview(host, positioned: .below, relativeTo: toolbar)
        let leading = host.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.panelMargin)
        let top = host.topAnchor.constraint(equalTo: topAnchor, constant: Self.panelMargin)
        NSLayoutConstraint.activate([leading, top])
        panelHost = host
        panelLeading = leading
        panelTop = top
        refreshPanel()
        if window != nil { controllerPanel.start() }
        needsLayout = true
    }

    /// Where the panel sits, as fractions of the room it has to move in
    /// (remembered per app): above the middle at first, where games put
    /// fewer buttons than along the edges.
    private var panelPlace: CGPoint {
        get {
            let saved = UserDefaults.standard.array(forKey: Self.panelPlaceKey) as? [Double]
            guard let saved, saved.count == 2 else { return CGPoint(x: 0.5, y: 0.42) }
            return CGPoint(x: min(max(saved[0], 0), 1), y: min(max(saved[1], 0), 1))
        }
        set { UserDefaults.standard.set([Double(newValue.x), Double(newValue.y)], forKey: Self.panelPlaceKey) }
    }

    /// The room the panel has to move in, from the margin.
    private func panelRoom(_ host: NSView) -> CGSize {
        let size = host.frame.size == .zero ? host.fittingSize : host.frame.size
        return CGSize(width: max(bounds.width - size.width - 2 * Self.panelMargin, 0),
                      height: max(bounds.height - size.height - 2 * Self.panelMargin, 0))
    }

    /// Keeps the panel in its place as the window and the panel change size.
    /// Whether it moved it.
    private func placePanel() -> Bool {
        guard panelMoveStart == nil, let host = panelHost, let leading = panelLeading, let top = panelTop else { return false }
        let room = panelRoom(host), place = panelPlace
        let x = (Self.panelMargin + room.width * place.x).rounded(), y = (Self.panelMargin + room.height * place.y).rounded()
        var moved = false
        if abs(leading.constant - x) > 0.5 { leading.constant = x; moved = true }
        if abs(top.constant - y) > 0.5 { top.constant = y; moved = true }
        return moved
    }

    /// The header dragged: the panel follows the pointer, never off the editor.
    private func movePanel(by translation: CGSize, ended: Bool) {
        guard let host = panelHost, let leading = panelLeading, let top = panelTop else { return }
        let start = panelMoveStart ?? (leading.constant, top.constant)
        let room = panelRoom(host)
        let x = min(max(start.x + translation.width, Self.panelMargin), Self.panelMargin + room.width)
        let y = min(max(start.y + translation.height, Self.panelMargin), Self.panelMargin + room.height)
        leading.constant = x.rounded()
        top.constant = y.rounded()
        panelMoveStart = ended ? nil : start
        if ended {
            panelPlace = CGPoint(x: room.width > 0 ? (x - Self.panelMargin) / room.width : 0.5,
                                 y: room.height > 0 ? (y - Self.panelMargin) / room.height : 0)
        }
    }

    /// The panel's corner dragged: it grows from where it is (kept there
    /// meanwhile, as during a move), then stays inside the editor, and its
    /// width is remembered.
    private func panelResized(ended: Bool) {
        guard let host = panelHost, let leading = panelLeading, let top = panelTop else { return }
        guard ended else {
            if panelMoveStart == nil { panelMoveStart = (leading.constant, top.constant) }
            return
        }
        panelMoveStart = nil
        UserDefaults.standard.set(Double(controllerPanel.width), forKey: ControllerPanelModel.widthKey)
        layoutSubtreeIfNeeded()
        let room = panelRoom(host)
        let x = min(max(leading.constant, Self.panelMargin), Self.panelMargin + room.width)
        let y = min(max(top.constant, Self.panelMargin), Self.panelMargin + room.height)
        leading.constant = x.rounded()
        top.constant = y.rounded()
        panelPlace = CGPoint(x: room.width > 0 ? (x - Self.panelMargin) / room.width : 0.5,
                             y: room.height > 0 ? (y - Self.panelMargin) / room.height : 0)
    }

    /// What the panel shows of the layout: what each part drives, what drives the selected control, the settings.
    private func refreshPanel() {
        guard showsController else { return }
        var bindings: [GamepadElement: [String]] = [:]
        for element in Self.gamepadElements {
            let names = profile.controls(boundTo: element).map(displayName)
            if !names.isEmpty { bindings[element] = names }
        }
        if case .gamepad(let button)? = profile.fps?.cursorToggle {
            bindings[.button(button), default: []].append(String(localized: "Mouse lock for the eye", bundle: .windowHost))
        }
        let control = selected.flatMap { id in profile.controls.first { $0.id == id } }
        let selection = control.map { control in Set(Self.gamepadElements.filter(control.uses)) } ?? []
        let panel = controllerPanel
        if panel.bindings != bindings { panel.bindings = bindings }
        if panel.selection != selection { panel.selection = selection }
        if panel.settings != profile.gamepadSettings { panel.settings = profile.gamepadSettings }
    }

    /// A control's name with its keys, for the panel: "Tap (Space)", "D-pad (W A S D)".
    private func displayName(_ control: Control) -> String {
        let keys = control.allTriggers.filter { !$0.isGamepad }.map { $0.shortLabel }
        return keys.isEmpty ? name(of: control) : "\(name(of: control)) (\(keys.joined(separator: " ")))"
    }

    /// The part's legend on the controller in use: "A", "✕", "LS", "D-pad".
    private func padLabel(_ element: GamepadElement) -> String {
        let layout = GamepadHub.shared.layout
        switch element {
        case .button(let button): return layout.label(button)
        case .stick(.left): return String(localized: "the left stick", bundle: .windowHost)
        case .stick(.right): return String(localized: "the right stick", bundle: .windowHost)
        case .dpad: return String(localized: "the d-pad", bundle: .windowHost)
        }
    }

    private func padSymbol(_ element: GamepadElement) -> String {
        let layout = GamepadHub.shared.layout
        switch element {
        case .button(let button): return layout.symbol(button)
        case .stick(let stick): return layout.symbol(stick)
        case .dpad: return "dpad"
        }
    }

    // A part dragged from the panel and let go over the game.

    private func panelDragged(_ element: GamepadElement, _ phase: ControllerPanelModel.DragPhase, _ location: CGPoint) {
        guard let host = panelHost else { return }
        let p = convert(location, from: host)
        switch phase {
        case .moved:
            padDrag = (element, p)
        case .ended:
            padDrag = nil
            dropped(element, at: p)
        }
        needsDisplay = true
    }

    /// On a control that it can drive, `element` binds to it; elsewhere on
    /// the game a menu offers the controls to place for it there. Let go
    /// over the panel or beside the game, it does nothing.
    private func dropped(_ element: GamepadElement, at p: CGPoint) {
        guard displayRect().contains(p), panelHost?.frame.contains(p) != true else { return }
        if let id = dropTarget(for: element, at: p), let control = profile.controls.first(where: { $0.id == id }),
           let part = drivingPart(element, for: control, press: true) {
            selected = nil
            select(id)
            bind(part, to: id)
            return
        }
        showPlacements(for: element, at: p)
    }

    /// The control under `p` that `element` (or a part of it) can drive.
    private func dropTarget(for element: GamepadElement, at p: CGPoint) -> String? {
        guard let id = hit(at: p)?.controlID, let control = profile.controls.first(where: { $0.id == id }),
              drivingPart(element, for: control, press: true) != nil else { return nil }
        return id
    }

    /// What of `element` can drive `control`: the element itself; on a
    /// joystick, the whole d-pad for one of its buttons or the stick for its
    /// press; on the eye, the stick for its press; with `press`, a stick's
    /// press for a control that takes a button.
    private func drivingPart(_ element: GamepadElement, for control: Control, press: Bool) -> GamepadElement? {
        if control.accepts(element) { return element }
        switch element {
        case .button(let button):
            if GamepadElement.dpadButtons.contains(button), control.accepts(.dpad) { return .dpad }
            if let stick = GamepadElement.stick(pressedBy: button), control.accepts(.stick(stick)) { return .stick(stick) }
        case .stick(let stick):
            let button = GamepadElement.button(GamepadElement.pressButton(of: stick))
            if press, control.accepts(button) { return button }
        case .dpad:
            break
        }
        return nil
    }

    /// Where a part of the controller clicked in the panel places its
    /// control: where touch games usually have it (the movement joystick
    /// bottom left, the camera right, the face buttons bottom right as the
    /// controller has them, shoulders and triggers at the top corners).
    static func usualSpot(for element: GamepadElement) -> NormalizedPoint {
        switch element {
        case .stick(.left), .dpad: NormalizedPoint(0.16, 0.72)
        case .stick(.right): NormalizedPoint(0.72, 0.5)
        case .button(let button):
            switch button {
            case .a: NormalizedPoint(0.86, 0.80)
            case .b: NormalizedPoint(0.93, 0.68)
            case .x: NormalizedPoint(0.79, 0.68)
            case .y: NormalizedPoint(0.86, 0.56)
            case .leftShoulder: NormalizedPoint(0.10, 0.36)
            case .leftTrigger: NormalizedPoint(0.10, 0.24)
            case .rightShoulder: NormalizedPoint(0.90, 0.36)
            case .rightTrigger: NormalizedPoint(0.90, 0.24)
            case .dpadUp: NormalizedPoint(0.16, 0.60)
            case .dpadDown: NormalizedPoint(0.16, 0.84)
            case .dpadLeft: NormalizedPoint(0.08, 0.72)
            case .dpadRight: NormalizedPoint(0.24, 0.72)
            case .leftThumbstick: NormalizedPoint(0.26, 0.86)
            case .rightThumbstick: NormalizedPoint(0.62, 0.86)
            case .menu: NormalizedPoint(0.56, 0.08)
            case .options: NormalizedPoint(0.44, 0.08)
            }
        }
    }

    /// The menu of controls that `element` can place at `p`; a stick's also has its press's.
    private func showPlacements(for element: GamepadElement, at p: CGPoint) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let point = normalized(p)
        func header(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        func add(_ placement: GamepadPlacement, for element: GamepadElement) {
            let item = NSMenuItem(title: Self.title(of: placement), action: #selector(placeFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: Self.symbol(of: placement), accessibilityDescription: nil)
            item.representedObject = PendingPlacement(element: element, placement: placement, point: point)
            item.indentationLevel = 1
            menu.addItem(item)
        }
        header(String(localized: "Place for \(padLabel(element)):", bundle: .windowHost))
        for placement in GamepadPlacement.choices(for: element) { add(placement, for: element) }
        if case .stick(let stick) = element {
            let press = GamepadElement.button(GamepadElement.pressButton(of: stick))
            menu.addItem(.separator())
            header(String(localized: "For pressing the stick down (\(padLabel(press))):", bundle: .windowHost))
            for placement in GamepadPlacement.choices(for: press) { add(placement, for: press) }
        }
        menu.popUp(positioning: nil, at: p, in: self)
    }

    @objc private func placeFromMenu(_ item: NSMenuItem) {
        guard let pending = item.representedObject as? PendingPlacement else { return }
        let element = pending.element
        let hadEye = profile.controls.contains(where: isEye)
        guard let id = profile.place(element, as: pending.placement, at: pending.point),
              let control = profile.controls.first(where: { $0.id == id }) else {
            setStatus(whyNot(element), problem: true)
            return
        }
        selected = nil
        select(id)
        if pending.placement == .camera, hadEye {
            setStatus(String(localized: "\(padLabel(element)) turns the eye now. Drag its area over the part of the game that turns the camera.",
                             bundle: .windowHost))
        } else {
            setStatus(String(localized: "Placed “\(name(of: control))” for \(padLabel(element)). Drag it onto the game’s own button.",
                             bundle: .windowHost))
        }
        needsDisplay = true
    }

    /// Why `element` could not be placed or bound: what holds it.
    private func whyNot(_ element: GamepadElement) -> String {
        let label = padLabel(element)
        if case .button(let button) = element, profile.fps?.cursorToggle == .gamepad(button) {
            return String(localized: "\(label) locks the mouse for the eye; choose another button.", bundle: .windowHost)
        }
        let buttons: [GamepadButton] = switch element {
        case .button(let button): [button]
        case .dpad: GamepadElement.dpadButtons
        case .stick: []
        }
        if let holder = profile.controls.first(where: { control in
            guard case let .dpad(_, _, up, down, left, right, _) = control.kind else { return false }
            return [up, down, left, right].contains { trigger in buttons.contains { trigger == .gamepad($0) } }
        }) {
            return String(localized: "\(label) is a direction of “\(name(of: holder))”.", bundle: .windowHost)
        }
        return String(localized: "\(label) cannot drive that.", bundle: .windowHost)
    }

    // Pressed on the controller, or clicked in the panel, with a control selected.

    private func gamepadChanged(_ inputs: [KeymapEngine.Input]) {
        guard window?.isKeyWindow == true else { return }
        for input in inputs {
            switch input {
            case let .gamepadButton(button, true):
                controllerPressed(.button(button), inPanel: false)
            case let .gamepadStick(stick, x, y):
                let lean = hypot(x, y), before = stickLean[stick] ?? 0
                stickLean[stick] = lean
                if lean >= 0.6, before < 0.6 { controllerPressed(.stick(stick), inPanel: false) }
            default:
                break
            }
        }
    }

    /// Binds `element` to the selected control, if it can drive it (on a
    /// control that takes a button, a stick clicked in the panel binds its
    /// press; one pushed on the controller says so instead).
    private func controllerPressed(_ element: GamepadElement, inPanel: Bool) {
        guard let id = selected, let control = profile.controls.first(where: { $0.id == id }) else {
            // Clicked in the panel: its controls to place, where games usually have them.
            if inPanel {
                showPlacements(for: element, at: painter.point(Self.usualSpot(for: element)))
            } else if case .button = element {
                setStatus(String(localized: "\(padLabel(element)): select a control on the game first, or drag \(padLabel(element)) onto the game.",
                                 bundle: .windowHost))
            }
            return
        }
        guard let part = drivingPart(element, for: control, press: inPanel) else {
            switch element {
            case .stick(let stick) where control.accepts(.button(.a)):
                let press = padLabel(.button(GamepadElement.pressButton(of: stick)))
                setStatus(String(localized: "A stick drives a joystick or the eye. To use pressing it down (\(press)) here, press the stick down.",
                                 bundle: .windowHost))
            default:
                setStatus(unsuitableText(element, control), problem: true)
            }
            return
        }
        bind(part, to: id)
    }

    private func bind(_ element: GamepadElement, to id: String) {
        guard let control = profile.controls.first(where: { $0.id == id }) else { return }
        do {
            try profile.bind(element, to: id)
        } catch .unsuitable {
            setStatus(unsuitableText(element, control), problem: true)
            return
        } catch {
            setStatus(whyNot(element), problem: true)
            return
        }
        switch element {
        case .button(let button):
            setStatus(String(localized: "“\(name(of: control))” responds to \(short(.gamepad(button))).", bundle: .windowHost))
        case .stick:
            setStatus(String(localized: "“\(name(of: control))” follows \(padLabel(element)).", bundle: .windowHost))
        case .dpad:
            setStatus(String(localized: "The d-pad pushes “\(name(of: control))” too.", bundle: .windowHost))
        }
        needsDisplay = true
    }

    private func unsuitableText(_ element: GamepadElement, _ control: Control) -> String {
        switch (element, control.kind) {
        case (.stick, _):
            String(localized: "A stick drives a joystick or the eye; drop it on the game to place one.", bundle: .windowHost)
        case (_, .aim):
            String(localized: "The eye follows a stick: drop one on it.", bundle: .windowHost)
        case (_, .dpad):
            String(localized: "A joystick follows a stick or the d-pad.", bundle: .windowHost)
        default:
            String(localized: "The d-pad pushes a joystick; drop it on the game to place one.", bundle: .windowHost)
        }
    }

    // The panel's settings, presets and reset.

    private func changeGamepadSettings(_ settings: GamepadSettings) {
        // The standard settings with nothing saved are none, as in profiles from before them.
        profile.gamepad = settings == .standard ? nil : settings
    }

    private func applyControllerTemplate(_ template: KeymapTemplate) {
        let preset = template.gamepadPreset(for: profile)
        profile.apply(preset)
        let kind = ControllerPanelView.title(of: template)
        setStatus(String(localized: "The controller is laid out as in \(kind) games: \(preset.bindings.count) controls. Cancel undoes it.",
                         bundle: .windowHost))
        needsDisplay = true
    }

    private func applyPreset(named name: String) {
        guard let preset = profile.gamepad?.presets.first(where: { $0.name == name }) else { return }
        let skipped = profile.apply(preset)
        var text = String(localized: "Using the preset “\(name)”.", bundle: .windowHost)
        if skipped > 0 {
            text += " " + String(localized: "Left out: \(skipped) of its bindings, for controls that changed or are gone.", bundle: .windowHost)
        }
        setStatus(text, problem: skipped > 0)
        needsDisplay = true
    }

    private func deletePreset(named name: String) {
        profile.deletePreset(named: name)
        if profile.gamepad == .standard { profile.gamepad = nil }
        setStatus(String(localized: "Deleted the preset “\(name)”. Cancel undoes it.", bundle: .windowHost))
    }

    private func askToSavePreset() {
        guard let window else { return }
        let taken = Set(profile.gamepad?.presets.map(\.name) ?? [])
        let base = GamepadHub.shared.info?.name ?? String(localized: "My controller layout", bundle: .windowHost)
        var suggestion = base, n = 1
        while taken.contains(suggestion) {
            n += 1
            suggestion = "\(base) \(n)"
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Save the controller layout as a preset", bundle: .windowHost)
        alert.informativeText = String(localized: "Presets are kept with this game’s key mapping; Done saves them. A name already in use replaces that preset.",
                                       bundle: .windowHost)
        let field = NSTextField(string: suggestion)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Save Preset", bundle: .windowHost))
        alert.addButton(withTitle: String(localized: "Cancel", bundle: .windowHost))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.window?.makeFirstResponder(self)
                let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard response == .alertFirstButtonReturn, !name.isEmpty else { return }
                self.profile.savePreset(named: name)
                self.setStatus(String(localized: "Saved the preset “\(name)”.", bundle: .windowHost))
            }
        }
    }

    private func confirmControllerReset() {
        guard let window else { return }
        let only = profile.controllerOnlyControls
        let alert = NSAlert()
        alert.messageText = String(localized: "Reset the controller mapping?", bundle: .windowHost)
        alert.informativeText = only.isEmpty
            ? String(localized: "Every button and stick comes off its controls, and the sticks go back to their standard settings. Saved presets stay, and Cancel in the editor still undoes it.",
                     bundle: .windowHost)
            : String(localized: "Every button and stick comes off its controls, the sticks go back to their standard settings, and the controls only the controller worked are removed (\(only.count)). Saved presets stay, and Cancel in the editor still undoes it.",
                     bundle: .windowHost)
        alert.addButton(withTitle: String(localized: "Reset", bundle: .windowHost))
        alert.addButton(withTitle: String(localized: "Cancel", bundle: .windowHost))
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .alertFirstButtonReturn else { return }
                self.profile.removeGamepadMapping()
                if let id = self.selected, !self.profile.controls.contains(where: { $0.id == id }) { self.selected = nil }
                self.setStatus(String(localized: "The controller mapping is reset.", bundle: .windowHost))
                self.needsDisplay = true
            }
        }
    }

    private static func title(of placement: GamepadPlacement) -> String {
        switch placement {
        case .tap: String(localized: "Tap", bundle: .windowHost)
        case .repeatTap: String(localized: "Repeat Tap", bundle: .windowHost)
        case .swipe: String(localized: "Swipe", bundle: .windowHost)
        case .anchor: String(localized: "Anchor Tap", bundle: .windowHost)
        case .ads: String(localized: "Aim Down Sights", bundle: .windowHost)
        case .joystick: String(localized: "Joystick", bundle: .windowHost)
        case .camera: String(localized: "Eye (Camera)", bundle: .windowHost)
        }
    }

    private static func symbol(of placement: GamepadPlacement) -> String {
        switch placement {
        case .tap: "hand.tap"
        case .repeatTap: "repeat"
        case .swipe: "hand.draw"
        case .anchor: "arrow.up.and.down.and.arrow.left.and.right"
        case .ads: "scope"
        case .joystick: "dpad"
        case .camera: "eye"
        }
    }

    // MARK: Names

    private func name(of control: Control) -> String {
        switch control.kind {
        case .tap, .hold: String(localized: "Tap", bundle: .windowHost)
        case .repeatTap: String(localized: "Repeat Tap", bundle: .windowHost)
        case .anchor: String(localized: "Anchor Tap", bundle: .windowHost)
        case .dpad: String(localized: "D-pad", bundle: .windowHost)
        case .swipe: String(localized: "Swipe", bundle: .windowHost)
        case .aim: String(localized: "Eye", bundle: .windowHost)
        case .ads: String(localized: "Aim Down Sights", bundle: .windowHost)
        case .macro: String(localized: "Macro", bundle: .windowHost)
        case .mobaMove: String(localized: "Move by Mouse", bundle: .windowHost)
        case .smartCast: String(localized: "Smart Cast", bundle: .windowHost)
        }
    }

    private static func title(of template: KeymapTemplate) -> String {
        switch template {
        case .fps: String(localized: "FPS Shooter", bundle: .windowHost)
        case .moba: String(localized: "MOBA", bundle: .windowHost)
        case .racing: String(localized: "Racing", bundle: .windowHost)
        case .platformer: String(localized: "Platformer", bundle: .windowHost)
        }
    }

    private static func symbol(of template: KeymapTemplate) -> String {
        switch template {
        case .fps: "scope"
        case .moba: "cursorarrow.rays"
        case .racing: "car"
        case .platformer: "figure.run"
        }
    }

    // MARK: Templates

    @objc private func insertTemplate(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let template = KeymapTemplate(rawValue: raw) else { return }
        guard !profile.controls.isEmpty, let window else {
            insert(template, replacing: true)
            return
        }
        // Never throw the player's work away without asking.
        let alert = NSAlert()
        alert.messageText = String(localized: "Insert the \(Self.title(of: template)) template?", bundle: .windowHost)
        alert.informativeText = String(localized: "This layout already has controls. Add the template's controls next to them (keys you already use stay with your controls), or replace the layout with the template. Its positions are only a starting point, and Cancel in the editor still undoes everything.",
                                       bundle: .windowHost)
        alert.addButton(withTitle: String(localized: "Add to Layout", bundle: .windowHost))
        alert.addButton(withTitle: String(localized: "Replace Layout", bundle: .windowHost))
        alert.addButton(withTitle: String(localized: "Cancel", bundle: .windowHost))
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                switch response {
                case .alertFirstButtonReturn: self?.insert(template, replacing: false)
                case .alertSecondButtonReturn: self?.insert(template, replacing: true)
                default: break
                }
            }
        }
    }

    private func insert(_ template: KeymapTemplate, replacing: Bool) {
        let rect = displayRect()
        let insertion = template.insert(into: profile, replacing: replacing, aspect: rect.height > 0 ? rect.width / rect.height : 16.0 / 9.0)
        profile = insertion.profile
        selected = nil
        hovered = nil
        drag = nil
        var text = String(localized: "Inserted the \(Self.title(of: template)) template. Its positions are a starting point: drag each control onto the game's own button.",
                          bundle: .windowHost)
        if !insertion.unbound.isEmpty {
            text += " " + String(localized: "Still without a key: \(insertion.unbound.count), because your controls already use theirs. Select each “?” and press a key.",
                                 bundle: .windowHost)
        }
        if !insertion.skipped.isEmpty {
            text += " " + String(localized: "Left out: \(insertion.skipped.count) (the layout already has an eye, or the D-pad keys are in use).",
                                 bundle: .windowHost)
        }
        setStatus(text, problem: !insertion.unbound.isEmpty || !insertion.skipped.isEmpty)
        needsDisplay = true
    }

    private func short(_ trigger: Trigger) -> String { trigger.shortLabel }

    // MARK: Profile

    /// Saves the profile and closes the editor; stays open on problems.
    @objc private func saveAndClose() {
        let problems = profile.validate()
        guard problems.isEmpty else {
            setStatus(problems.first ?? String(localized: "This profile has problems.", bundle: .windowHost), problem: true)
            return
        }
        if let error = onSave(profile) {
            setStatus(String(localized: "Could not save: \(error)", bundle: .windowHost), problem: true)
        } else {
            close()
        }
    }

    @objc private func exportProfile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(profile.package).json"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? profile.encoded() else { return }
        try? data.write(to: url)
    }

    @objc private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        do {
            var imported = try KeymapProfile.decode(data)
            imported.package = profile.package
            let problems = imported.validate()
            guard problems.isEmpty else {
                setStatus(problems.first ?? String(localized: "This profile has problems.", bundle: .windowHost), problem: true)
                return
            }
            profile = imported
            selected = nil
            needsDisplay = true
            let text = String(localized: "Imported “\(imported.name)”. Press Done to use it.", bundle: .windowHost)
            if let warning = Self.newerControlsWarning(imported) {
                setStatus(text + " " + warning, problem: true)
            } else {
                setStatus(text)
            }
        } catch {
            setStatus(String(localized: "Not a keymap profile: \(error.localizedDescription)", bundle: .windowHost), problem: true)
        }
    }

    @objc private func close() { onClose?() }
}

/// The status line's plate only shows text: clicks go through it to the
/// editor, so an area's edge under it can still be dragged.
private final class StatusPlate: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A control the placement menu would place: for which part of the
/// controller, of which kind, where on the game.
private final class PendingPlacement: NSObject {
    let element: GamepadElement
    let placement: GamepadPlacement
    let point: NormalizedPoint

    init(element: GamepadElement, placement: GamepadPlacement, point: NormalizedPoint) {
        self.element = element
        self.placement = placement
        self.point = point
    }
}

extension Trigger {
    /// How the editor and hints write a trigger: W, Space, ⇧, L-Click,
    /// Wheel↑, and a controller button as the controller in use prints it
    /// (A, ✕, LB, R2).
    @MainActor var shortLabel: String {
        switch self {
        case .key(let key): Self.keyLabel(key)
        case .mouse(.left): String(localized: "L-Click", bundle: .windowHost)
        case .mouse(.right): String(localized: "R-Click", bundle: .windowHost)
        case .mouse(.middle): String(localized: "M-Click", bundle: .windowHost)
        case .mouse(.button4): "M4"
        case .mouse(.button5): "M5"
        case .scrollUp: String(localized: "Wheel↑", bundle: .windowHost)
        case .scrollDown: String(localized: "Wheel↓", bundle: .windowHost)
        case .gamepad(let button): GamepadHub.shared.layout.label(button)
        }
    }

    static func keyLabel(_ key: KeyName) -> String {
        switch key {
        case .space: "Space"
        case .returnKey: "↩"
        case .tab: "⇥"
        case .escape: "Esc"
        case .delete: "⌫"
        case .forwardDelete: "⌦"
        case .capsLock: "⇪"
        case .shift: "⇧"
        case .rightShift: "R⇧"
        case .control: "⌃"
        case .rightControl: "R⌃"
        case .option: "⌥"
        case .rightOption: "R⌥"
        case .command: "⌘"
        case .rightCommand: "R⌘"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        case .minus: "-"
        case .equal: "="
        case .leftBracket: "["
        case .rightBracket: "]"
        case .backslash: "\\"
        case .semicolon: ";"
        case .quote: "'"
        case .comma: ","
        case .period: "."
        case .slash: "/"
        case .grave: "`"
        case .pageUp: "PgUp"
        case .pageDown: "PgDn"
        default: key.rawValue
        }
    }
}
