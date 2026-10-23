import AppKit
import AvoKeymap
import SwiftUI
import UniformTypeIdentifiers

/// The key mapping editor drawn over the game (KeymapOverlayWindow).
///
/// Every control is an object on the game. The quickest way to add one:
/// click the game's own button, then press its key (a tap, made there; a
/// click on it again cancels). The panel beside the game
/// (KeymapEditorPanel.swift) adds the other kinds, by a click or by a drag
/// onto the game where one goes, and has the layout's modes and the
/// selected control's keys, modes and settings. On the game: drag an
/// object's body to move it, its ↘ handle to set how far it reaches, × to
/// remove it. With an object selected the next key is its trigger, any key
/// at all (Delete, Esc and the modifiers included, a modifier once it is
/// let go on its own); right-click
/// for mouse buttons and the wheel. ⌥ + arrow keys move the selected object
/// and ⌥⇧ + arrow keys resize it. The eye is a swipe area with a point
/// (where its finger touches down): while it is selected, drag the area to
/// move it, its edges and corners to resize it, the point to move it within.
/// Positions and sizes are fractions of the display, so the layout follows
/// the window at any size. With MOBA controls in the layout, a hero marker
/// shows (and is dragged to) where they aim from.
///
/// The controller panel (ControllerPanel.swift, the bar's Controller
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

    private var profile: KeymapProfile {
        didSet {
            refreshPanel()
            refreshBar()
        }
    }
    /// The layout as the editor opened with it: Cancel asks before changes go.
    private let original: KeymapProfile
    private var selected: String? {
        didSet {
            refreshPanel()
            refreshBar()
        }
    }
    /// The mode being edited (KeymapProfile.modes): its controls show, and
    /// new ones go in it. nil while the layout has no modes.
    private var editingMode: String? {
        didSet {
            refreshPanel()
            refreshBar()
        }
    }
    /// The D-pad direction the next key sets: 0 up, 1 left, 2 down, 3 right.
    private var dpadSlot = 0 { didSet { refreshBar() } }
    /// Where a click on the game put a tap that waits for its key.
    private var pendingTap: NormalizedPoint? { didSet { needsDisplay = true } }
    /// What the waiting tap measures like on the game.
    private var pendingControl: Control { Control(id: "", kind: .tap(pendingTap ?? NormalizedPoint(0.5, 0.5))) }
    /// A control dragged from the bar, and where the pointer is (in this view).
    private var paletteDrag: (item: KeymapPaletteItem, at: CGPoint)?
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
    /// What the panel beside the game shows and asks (KeymapEditorPanel.swift).
    private let barModel: KeymapEditorModel
    private let panel: NSHostingView<KeymapEditorPanel>
    /// The panel stands in a window of its own beside the game's
    /// (KeymapOverlay puts it there): the game keeps its whole size.
    private(set) var panelOutside = false
    /// The panel's place inside this view, at its trailing edge.
    private var panelInside: [NSLayoutConstraint] = []
    /// Editor Opacity: how solid the objects and the dimming are.
    private var seeThrough = KeymapEditorView.savedOpacity
    private var hintsObserver: (any NSObjectProtocol)?
    /// The panel's Controller tab (ControllerPanel.swift).
    private let controllerPanel: ControllerPanelModel
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
        original = profile
        self.onSave = onSave
        editingMode = profile.firstMode
        let model = KeymapEditorModel(), controller = ControllerPanelModel()
        barModel = model
        controllerPanel = controller
        panel = NSHostingView(rootView: KeymapEditorPanel(model: model, controller: controller))
        super.init(frame: .zero)
        // Composited over the game's Metal layer.
        wantsLayer = true
        buildPanel()
        connectPanel()
        // The tab the player left the panel on.
        model.tab = UserDefaults.standard.string(forKey: Self.panelTabKey).flatMap(KeymapEditorModel.Tab.init) ?? .controls
        if let warning = Self.newerControlsWarning(profile) { setStatus(warning, problem: true) }
    }

    /// While open, Show Keys on Game and Key Visibility can also
    /// change from the menus: the panel follows them.
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

    // After typing in the panel's own window, the first click on the game places or picks.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    // MARK: The panel beside the game (KeymapEditorPanel.swift)

    /// The panel's width: inside the window, the game's picture moves over
    /// for it (AndroidWindowController).
    static let panelWidth: CGFloat = 348

    private func buildPanel() {
        connectBar()
        panel.sizingOptions = []
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        panelInside = [
            panel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.widthAnchor.constraint(equalToConstant: Self.panelWidth),
        ]
        NSLayoutConstraint.activate(panelInside)
        showHintSettings()
        showEditorOpacity()
        showHelp()
        refreshBar()
    }

    /// Moves the panel into `host`, the content of its own window beside the
    /// game's, or back inside this view, at its edge, for nil.
    func movePanel(into host: NSView?) {
        let outside = host != nil
        guard outside != panelOutside || panel.superview == nil else { return }
        NSLayoutConstraint.deactivate(panelInside)
        panel.removeFromSuperview()
        panelOutside = outside
        barModel.outside = outside
        if let host {
            panel.translatesAutoresizingMaskIntoConstraints = true
            panel.frame = host.bounds
            panel.autoresizingMask = [.width, .height]
            host.addSubview(panel)
        } else {
            panel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(panel)
            NSLayoutConstraint.activate(panelInside)
        }
        needsDisplay = true
        refocus()
    }

    /// Where the panel covers this view: nowhere while it is outside.
    private var panelFrame: CGRect { panelOutside ? .zero : panel.frame }

    /// A point in the panel's coordinates, in this view's: by way of the
    /// screen while the panel is in its own window.
    private func pointFromPanel(_ location: CGPoint) -> CGPoint {
        guard panelOutside, let panelWindow = panel.window, let window else { return convert(location, from: panel) }
        let onScreen = panelWindow.convertPoint(toScreen: panel.convert(location, to: nil))
        return convert(window.convertPoint(fromScreen: onScreen), from: nil)
    }

    /// What the panel asks. After a click there, keys come here again: the
    /// next one is still the selected control's.
    private func connectBar() {
        let model = barModel
        model.setTab = { [weak self] tab in
            self?.setTab(tab)
            self?.refocus()
        }
        model.add = { [weak self] item in
            self?.place(item, at: nil)
            self?.refocus()
        }
        model.drag = { [weak self] item, phase, location in self?.paletteDragged(item, phase, location) }
        model.chooseMode = { [weak self] id in
            self?.chooseMode(id)
            self?.refocus()
        }
        model.addMode = { [weak self] in self?.addMode() }
        model.rename = { [weak self] id, name in self?.finishRenaming(id, name) }
        model.modeMenu = { [weak self] id in self?.modeMenu(id) ?? [] }
        model.templates = { [weak self] in self?.templateEntries() ?? [] }
        model.importLayout = { [weak self] in
            self?.importProfile()
            self?.refocus()
        }
        model.exportLayout = { [weak self] in
            self?.exportProfile()
            self?.refocus()
        }
        model.removeAll = { [weak self] in
            self?.removeAll()
            self?.refocus()
        }
        model.setShowOnGame = { [weak self] on in
            KeymapHints.visible = on
            self?.showHintSettings()
            self?.refocus()
        }
        model.setHintOpacity = { [weak self] value in
            // 5% steps, which include the menus' Key Visibility steps.
            KeymapHints.opacity = (value * 20).rounded() / 20
            self?.showHintSettings()
        }
        model.setEditorOpacity = { [weak self] value in
            guard let self else { return }
            seeThrough = min(max((value * 20).rounded() / 20, Self.opacityRange.lowerBound), Self.opacityRange.upperBound)
            Self.savedOpacity = seeThrough
            showEditorOpacity()
        }
        model.cancel = { [weak self] in self?.cancel() }
        model.done = { [weak self] in
            self?.saveAndClose()
            self?.refocus()
        }
        model.update = { [weak self] change in
            guard let self, let id = selected, let i = index(of: id) else { return }
            change(&profile.controls[i])
            needsDisplay = true
            refocus()
        }
        model.setActsIn = { [weak self] modes in
            self?.setActsIn(modes)
            self?.refocus()
        }
        model.setDPadSlot = { [weak self] slot in
            guard let self, let id = selected, let control = profile.controls.first(where: { $0.id == id }) else { return }
            dpadSlot = slot
            prompt(for: control)
            needsDisplay = true
            refocus()
        }
        model.mouseButtons = { [weak self] in self?.mouseEntries() ?? [] }
        model.remove = { [weak self] in
            self?.removeSelected()
            self?.refocus()
        }
        model.deselect = { [weak self] in
            guard let self else { return }
            selected = nil
            showHelp()
            needsDisplay = true
            refocus()
        }
    }

    /// Keys come to the editor again after a click in the panel (not while
    /// a mode's name is typed there).
    private func refocus() {
        guard let window, !typingInPanel else { return }
        // The panel's own window took the keyboard for a field: the game's has it again.
        if panelOutside, panel.window?.isKeyWindow == true { window.makeKey() }
        if window.firstResponder !== self { window.makeFirstResponder(self) }
    }

    /// A mode's name has the keyboard in the panel.
    private var typingInPanel: Bool {
        (panel.window?.firstResponder as? NSView)?.isDescendant(of: panel) == true
    }

    /// A mode's tab that waits for a name it never got the keyboard for
    /// keeps its name (one being typed is kept as it loses the keyboard).
    private func endStaleRenaming() {
        if let id = barModel.renaming, !typingInPanel { finishRenaming(id, nil) }
    }

    private func showHintSettings() {
        if barModel.showOnGame != KeymapHints.visible { barModel.showOnGame = KeymapHints.visible }
        if barModel.hintOpacity != KeymapHints.opacity { barModel.hintOpacity = KeymapHints.opacity }
    }

    /// The slider, and how solid the objects are.
    private func showEditorOpacity() {
        if barModel.editorOpacity != seeThrough { barModel.editorOpacity = seeThrough }
        needsDisplay = true
    }

    private func setStatus(_ text: String, problem: Bool = false) {
        if barModel.status != text { barModel.status = text }
        if barModel.problem != problem { barModel.problem = problem }
    }

    private func showHelp() {
        setStatus(String(localized: "Click a button of the game, then press its key.", bundle: .windowHost))
    }

    /// What the panel shows of the layout: its modes, the selected control,
    /// whether it has the eye.
    private func refreshBar() {
        let model = barModel
        let modes = profile.modes.map { mode in
            KeymapEditorModel.Mode(id: mode.id, name: mode.name, count: profile.controls.filter { $0.modes?.contains(mode.id) == true }.count)
        }
        if model.modes != modes { model.modes = modes }
        if model.editingMode != editingMode { model.editingMode = editingMode }
        let hasEye = profile.controls.contains(where: isEye)
        if model.hasEye != hasEye { model.hasEye = hasEye }
        let selection = selected.flatMap { id in profile.controls.first { $0.id == id } }.map { control in
            KeymapEditorModel.Selection(control: control, title: name(of: control), symbol: Self.symbol(of: control),
                                        key: control.triggers.first { !$0.isGamepad }?.shortLabel,
                                        pad: control.triggers.first(where: \.isGamepad)?.shortLabel,
                                        eyeKey: isEye(control) ? profile.fps?.cursorToggle.shortLabel : nil, dpadSlot: dpadSlot)
        }
        if model.selection != selection { model.selection = selection }
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

    /// The controls of the mode being edited (every control without modes).
    private var shownControls: [Control] { profile.controls.filter { $0.belongs(to: editingMode) } }

    private func hit(at p: CGPoint) -> Hit? {
        func near(_ a: CGPoint, _ r: CGFloat) -> Bool { hypot(a.x - p.x, a.y - p.y) <= r }
        let newestFirst = Array(shownControls.reversed())
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
        // inside it, which drags it. Another eye's area is the game's: a
        // click there puts a tap on the button under it.
        if let selectedArea {
            if let edges = edges(of: selectedArea.rect, near: p) { return .areaEdge(selectedArea.id, edges) }
            if selectedArea.movable, selectedArea.rect.contains(p) { return .area(selectedArea.id) }
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

    /// The eye's swipe area: shown all the time, dragged by its inside while
    /// the eye is selected (an anchor tap's reach is a circle, sized by its ↘ handle).
    private func hasOwnArea(_ control: Control) -> Bool {
        isEye(control)
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
        case .anchor(_, let radius): control.kind = .anchor(p, radius: radius)
        case .switchMode(let mode, _): control.kind = .switchMode(mode, position: p)
        case .mouseLook(let lock, _): control.kind = .mouseLook(lock: lock, position: p)
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

    /// Follows the ↘ handle: a D-pad's or MOBA joystick's radius, a smart
    /// cast's drag radius, an anchor tap's reach (buttons have no size to set).
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
        case .anchor(let point, _):
            control.kind = .anchor(point, radius: min(max(radius, Control.anchorRadiusRange.lowerBound), Control.anchorRadiusRange.upperBound))
        default:
            break
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

    /// A size step from the keyboard: a joystick's or smart cast's radius, an anchor tap's reach.
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
        case let .anchor(point, radius):
            let range = Control.anchorRadiusRange
            control.kind = .anchor(point, radius: min(max((radius ?? Control.defaultAnchorRadius) * factor, range.lowerBound), range.upperBound))
        default:
            break
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

    /// Binds `trigger` to the selected object. A key may do several things
    /// (F: the game's Enter vehicle button and the switch to the vehicle
    /// mode), so other controls keep theirs; the status line names them.
    func assign(_ trigger: Trigger) {
        if let at = pendingTap {
            placeTap(at: at, trigger)
            return
        }
        guard let id = selected, let index = index(of: id) else { return }
        let control = profile.controls[index]
        switch control.kind {
        case let .dpad(_, _, up, down, left, right, _) where dpadSlot == Self.runSlot:
            // The key held to run.
            if trigger.isMomentary {
                setStatus(String(localized: "The wheel cannot be held to run: press a key or a button.", bundle: .windowHost), problem: true)
            } else if [up, down, left, right].contains(trigger) {
                setStatus(String(localized: "\(short(trigger)) is a direction of this joystick: press another key to run.", bundle: .windowHost),
                          problem: true)
            } else {
                profile.controls[index].run = JoystickRun(trigger: trigger, scale: control.run?.scale ?? JoystickRun.defaultScale)
                dpadSlot = 0
                setStatus(String(localized: "Holding \(short(trigger)) runs: the joystick goes further meanwhile. Set how far in the panel.",
                                 bundle: .windowHost))
            }
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
                case .tap, .swipe, .macro, .switchMode, .mouseLook: break
                default:
                    setStatus(String(localized: "The wheel works with Tap, Swipe, Switch Mode, and Free or Lock the Mouse only.", bundle: .windowHost),
                              problem: true)
                    return
                }
            }
            // A key replaces its key, and the controller button stays.
            profile.controls[index].setTrigger(trigger)
            // The others it presses in this mode, so a shared key is no surprise.
            let others = shownControls.filter { $0.id != id && $0.allTriggers.contains(trigger) }.map { "“\(name(of: $0))”" }
            if others.isEmpty, profile.fps?.cursorToggle != trigger {
                setStatus(String(localized: "“\(name(of: control))” responds to \(short(trigger)).", bundle: .windowHost))
            } else {
                let more = others + (profile.fps?.cursorToggle == trigger ? [String(localized: "the mouse lock", bundle: .windowHost)] : [])
                setStatus(String(localized: "“\(name(of: control))” responds to \(short(trigger)), together with \(more.formatted(.list(type: .and))).",
                                 bundle: .windowHost))
            }
        }
        needsDisplay = true
    }

    /// The D-pad's "slot" past its four directions: the key held to run.
    private static let runSlot = 4

    private func direction(_ slot: Int) -> String {
        [String(localized: "up", bundle: .windowHost), String(localized: "left", bundle: .windowHost),
         String(localized: "down", bundle: .windowHost), String(localized: "right", bundle: .windowHost)][slot]
    }

    /// What to do with the selected control now; what it is is behind its (?) in the panel.
    private func prompt(for control: Control) {
        switch control.kind {
        case .dpad where dpadSlot == Self.runSlot:
            setStatus(String(localized: "Press the key to hold for running (Shift, for example).", bundle: .windowHost))
        case .dpad:
            setStatus(String(localized: "Press four keys in turn, \(direction(dpadSlot)) first.", bundle: .windowHost))
        case .aim:
            setStatus(String(localized: "Press the key that locks and frees the mouse (F8, for example).", bundle: .windowHost))
        case .anchor, .smartCast:
            setStatus(String(localized: "Press its key. Drag ↘ to set how far it reaches.", bundle: .windowHost))
        case .switchMode:
            setStatus(String(localized: "Press the key that switches in the game too.", bundle: .windowHost))
        case .mobaMove:
            setStatus(String(localized: "Press a key, or right-click for a mouse button.", bundle: .windowHost))
        default:
            setStatus(String(localized: "Press its key or controller button. Right-click for a mouse button.", bundle: .windowHost))
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        endStaleRenaming()
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
            pendingTap = nil
            let h = point(hero)
            drag = .hero(offset: CGVector(dx: h.x - p.x, dy: h.y - p.y))
            setStatus(String(localized: "Hero: where your character stands on the screen. Move by mouse and smart cast aim from here towards the cursor.",
                             bundle: .windowHost))
        case nil:
            selected = nil
            drag = nil
            if let pendingTap, hypot(point(pendingTap).x - p.x, point(pendingTap).y - p.y) <= max(painter.bubbleRadius(pendingControl), 12) {
                // Clicked again: no tap there after all.
                self.pendingTap = nil
                showHelp()
            } else if displayRect().contains(p) {
                // On the game: a tap there, once its key is pressed.
                pendingTap = normalized(p)
                setStatus(String(localized: "Press a key for this button (right-click: a mouse button). Click it again to cancel.", bundle: .windowHost))
            } else {
                pendingTap = nil
                showHelp()
            }
        }
        needsDisplay = true
    }

    private func select(_ id: String) {
        pendingTap = nil
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
        // Over the panel: its own.
        if panelFrame.contains(p) {
            if hovered != nil {
                hovered = nil
                needsDisplay = true
            }
            return
        }
        let target = hit(at: p)
        switch target {
        case .remove?, .dpadSlot?: NSCursor.pointingHand.set()
        case .resize?, .swipeEnd?: NSCursor.crosshair.set()
        case .body?, .hero?, .area?: NSCursor.openHand.set()
        case .areaEdge(_, let edges)?: NSCursor.frameResize(position: Self.resizePosition(edges), directions: .all).set()
        // On the game: a click puts a tap there.
        case nil: (displayRect().contains(p) ? NSCursor.crosshair : NSCursor.arrow).set()
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

    /// Right-click: mouse buttons and the wheel as triggers, and removal; on
    /// the game, a tap there for a mouse button.
    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let id = hit(at: p)?.controlID else {
            guard displayRect().contains(p), let window else { return }
            selected = nil
            pendingTap = normalized(p)
            setStatus(String(localized: "Choose the mouse button for this button of the game, or press a key.", bundle: .windowHost))
            HazeMenuPresenter.shared.show(mouseEntries(), at: window.convertPoint(toScreen: event.locationInWindow), for: event)
            return
        }
        select(id)
        needsDisplay = true
        let menu = NSMenu()
        for (title, trigger, symbol) in Self.mouseChoices {
            let item = NSMenuItem(title: title, action: #selector(assignFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = trigger.description
            item.symbol(symbol)
            menu.addItem(item)
        }
        if let control = profile.controls.first(where: { $0.id == id }) {
            let items = areaChoices(for: control)
            if !items.isEmpty { menu.addItem(.separator()) }
            for (title, action, symbol) in items {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.symbol(symbol)
                menu.addItem(item)
            }
            for item in modeItems(for: control) { menu.addItem(item) }
        }
        menu.addItem(.separator())
        let remove = NSMenuItem(title: String(localized: "Remove", bundle: .windowHost), action: #selector(removeSelected), keyEquivalent: "")
        remove.target = self
        remove.symbol("trash")
        menu.addItem(remove)
        HazeMenuPresenter.shared.popUpContextMenu(menu, with: event, for: self)
    }

    /// A mouse button or the wheel for a control, as the menus list them.
    static var mouseChoices: [(title: String, trigger: Trigger, symbol: String)] {
        [
            (String(localized: "Left Click", bundle: .windowHost), .mouse(.left), "cursorarrow.click"),
            (String(localized: "Right Click", bundle: .windowHost), .mouse(.right), "contextualmenu.and.cursorarrow"),
            (String(localized: "Middle Click", bundle: .windowHost), .mouse(.middle), "computermouse"),
            (String(localized: "Mouse Button 4", bundle: .windowHost), .mouse(.button4), "arrow.backward.circle"),
            (String(localized: "Mouse Button 5", bundle: .windowHost), .mouse(.button5), "arrow.forward.circle"),
            (String(localized: "Wheel Up", bundle: .windowHost), .scrollUp, "arrow.up.circle"),
            (String(localized: "Wheel Down", bundle: .windowHost), .scrollDown, "arrow.down.circle"),
        ]
    }

    /// A control's menu items for modes: the modes it acts in, a switch's
    /// target, which way a mouse control goes.
    private func modeItems(for control: Control) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        func submenu(_ title: String, _ entries: [(title: String, value: String, on: Bool)], _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu()
            menu.autoenablesItems = false
            for entry in entries {
                if entry.value.isEmpty {
                    menu.addItem(.separator())
                    continue
                }
                let choice = NSMenuItem(title: entry.title, action: action, keyEquivalent: "")
                choice.target = self
                choice.representedObject = entry.value
                choice.state = entry.on ? .on : .off
                menu.addItem(choice)
            }
            item.submenu = menu
            return item
        }
        if !profile.modes.isEmpty {
            let modes = [(String(localized: "Every Mode", bundle: .windowHost), "*", control.modes == nil), ("", "", false)]
                + profile.modes.map { ($0.name, $0.id, control.modes?.contains($0.id) == true) }
            items.append(submenu(String(localized: "Works In", bundle: .windowHost), modes, #selector(setControlModes(_:))).symbol("square.stack.3d.up"))
        }
        if case .switchMode(let target, _) = control.kind, profile.modes.count > 1 {
            let targets = profile.modes.map { ($0.name, $0.id, $0.id == target) }
            items.append(submenu(String(localized: "Switches To", bundle: .windowHost), targets, #selector(setSwitchTarget(_:)))
                .symbol("arrow.triangle.2.circlepath"))
        }
        if case .mouseLook(let lock, _) = control.kind {
            let flip = NSMenuItem(title: lock ? String(localized: "Free the Mouse Instead", bundle: .windowHost)
                                              : String(localized: "Lock the Mouse Instead", bundle: .windowHost),
                                  action: #selector(flipMouseLook), keyEquivalent: "")
            flip.target = self
            flip.symbol(lock ? "lock.open" : "lock")
            items.append(flip)
        }
        return items.isEmpty ? [] : [.separator()] + items
    }

    @objc private func setControlModes(_ item: NSMenuItem) {
        guard let id = selected, let control = profile.controls.first(where: { $0.id == id }),
              let value = item.representedObject as? String else { return }
        if value == "*" {
            setActsIn(nil)
        } else {
            var modes = control.modes ?? []
            if let at = modes.firstIndex(of: value) { modes.remove(at: at) } else { modes.append(value) }
            // In the layout's order; none left is every mode.
            modes = profile.modes.map(\.id).filter(modes.contains)
            setActsIn(modes.isEmpty ? nil : modes)
        }
    }

    /// The modes the selected control acts in (nil: every mode).
    private func setActsIn(_ modes: [String]?) {
        guard let id = selected, let i = index(of: id) else { return }
        profile.controls[i].modes = modes
        let control = profile.controls[i]
        let names = (modes ?? []).compactMap { mode in profile.modes.first { $0.id == mode }?.name }
        setStatus(names.isEmpty ? String(localized: "“\(name(of: control))” acts in every mode.", bundle: .windowHost)
                                : String(localized: "“\(name(of: control))” acts in \(names.formatted(.list(type: .and))).", bundle: .windowHost))
        // Out of the mode being edited: it goes from view.
        if !control.belongs(to: editingMode) { selected = nil }
        needsDisplay = true
    }

    @objc private func setSwitchTarget(_ item: NSMenuItem) {
        guard let id = selected, let i = index(of: id), let target = item.representedObject as? String,
              case .switchMode(_, let position) = profile.controls[i].kind else { return }
        profile.controls[i].kind = .switchMode(target, position: position)
        prompt(for: profile.controls[i])
        needsDisplay = true
    }

    @objc private func flipMouseLook() {
        guard let id = selected, let i = index(of: id), case let .mouseLook(lock, position) = profile.controls[i].kind else { return }
        profile.controls[i].kind = .mouseLook(lock: !lock, position: position)
        prompt(for: profile.controls[i])
        needsDisplay = true
    }

    // MARK: Modes

    /// A mode's tab: its controls show, and new ones go in it.
    private func chooseMode(_ id: String) {
        guard let mode = profile.modes.first(where: { $0.id == id }) else { return }
        if let id = selected, profile.controls.first(where: { $0.id == id })?.belongs(to: mode.id) != true { selected = nil }
        hovered = nil
        pendingTap = nil
        editingMode = mode.id
        setStatus(String(localized: "Editing “\(mode.name)”.", bundle: .windowHost))
        needsDisplay = true
    }

    /// + Mode: a new, empty mode, its name typed in its tab.
    private func addMode() {
        barModel.renaming = createMode()
    }

    /// A new, empty mode, edited from now on. The layout's first also makes
    /// "Default", where the game starts, with the controls the layout had;
    /// the eye stays in every mode, as a game turns its camera in all of
    /// them. Returns its id.
    @discardableResult
    private func createMode() -> String {
        let first = profile.modes.isEmpty
        if first {
            profile.modes = [KeymapMode(id: "default", name: String(localized: "Default", bundle: .windowHost))]
            for i in profile.controls.indices where profile.controls[i].modes == nil && !isEye(profile.controls[i]) {
                profile.controls[i].modes = ["default"]
            }
        }
        let id = newModeID()
        profile.modes.append(KeymapMode(id: id, name: String(localized: "Mode \(profile.modes.count + 1)", bundle: .windowHost)))
        selected = nil
        pendingTap = nil
        editingMode = id
        setStatus(first ? String(localized: "Your controls are in “Default” now. This new mode starts empty.", bundle: .windowHost)
                        : String(localized: "A new mode, empty: add its controls.", bundle: .windowHost))
        needsDisplay = true
        return id
    }

    private func newModeID() -> String {
        var n = profile.modes.count + 1
        while profile.modes.contains(where: { $0.id == "mode-\(n)" }) { n += 1 }
        return "mode-\(n)"
    }

    /// The name typed in a mode's tab (nil: Esc, its name stays).
    private func finishRenaming(_ id: String, _ name: String?) {
        guard barModel.renaming == id else { return }
        barModel.renaming = nil
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
           let i = profile.modes.firstIndex(where: { $0.id == id }) {
            profile.modes[i].name = name
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    /// A mode's menu (its tab clicked again, or right-clicked): rename,
    /// duplicate, start the game in it, the mouse on entering it (with the
    /// eye), delete.
    private func modeMenu(_ id: String) -> [HazeMenuEntry] {
        guard let index = profile.modes.firstIndex(where: { $0.id == id }) else { return [] }
        var entries: [HazeMenuEntry] = [
            .section(profile.modes[index].name),
            .item(HazeMenuItem(title: String(localized: "Rename", bundle: .windowHost), symbol: "pencil") { [weak self] in
                self?.barModel.renaming = id
            }),
            .item(HazeMenuItem(title: String(localized: "Duplicate", bundle: .windowHost), symbol: "plus.square.on.square") { [weak self] in
                self?.duplicateMode(id)
            }),
        ]
        if index > 0 {
            entries.append(.item(HazeMenuItem(title: String(localized: "Start the Game in This Mode", bundle: .windowHost), symbol: "flag") {
                [weak self] in
                self?.startIn(id)
                self?.refocus()
            }))
        }
        if profile.fps != nil {
            entries.append(.item(HazeMenuItem(title: String(localized: "Mouse When Switching Here", bundle: .windowHost), symbol: "computermouse",
                                              submenu: { [weak self] in self?.mouseChoices(for: id) ?? [] })))
        }
        entries.append(.separator())
        entries.append(.item(HazeMenuItem(title: String(localized: "Delete Mode…", bundle: .windowHost), symbol: "trash", role: .destructive) {
            [weak self] in self?.deleteMode(id)
        }))
        return entries
    }

    private func mouseChoices(for id: String) -> [HazeMenuEntry] {
        let current = profile.modes.first { $0.id == id }?.mouseLook
        let choices: [(String, Bool?)] = [(String(localized: "Locked to the Eye", bundle: .windowHost), true),
                                          (String(localized: "Free", bundle: .windowHost), false),
                                          (String(localized: "As It Was", bundle: .windowHost), nil)]
        return choices.map { title, value in
            .item(HazeMenuItem(title: title, state: current == value ? .on : .off) { [weak self] in
                guard let self, let i = self.profile.modes.firstIndex(where: { $0.id == id }) else { return }
                self.profile.modes[i].mouseLook = value
                self.refocus()
            })
        }
    }

    /// The game starts in the layout's first mode.
    private func startIn(_ id: String) {
        guard let i = profile.modes.firstIndex(where: { $0.id == id }), i > 0 else { return }
        let mode = profile.modes.remove(at: i)
        profile.modes.insert(mode, at: 0)
        setStatus(String(localized: "The game starts in “\(mode.name)” now.", bundle: .windowHost))
    }

    /// A copy of a mode, after it: its own controls copied, the others (the
    /// eye among them) acting in the copy too; its name typed in its tab.
    private func duplicateMode(_ id: String) {
        guard let index = profile.modes.firstIndex(where: { $0.id == id }) else { return }
        let source = profile.modes[index]
        let copy = newModeID()
        profile.modes.insert(KeymapMode(id: copy, name: String(localized: "\(source.name) Copy", bundle: .windowHost), mouseLook: source.mouseLook),
                             at: index + 1)
        var controls = profile.controls
        for i in controls.indices {
            guard var modes = controls[i].modes, modes.contains(id) else { continue }
            if modes == [id], !isEye(controls[i]) {
                var twin = controls[i]
                twin.id = uniqueID(like: twin.id, in: controls)
                twin.modes = [copy]
                controls.append(twin)
            } else {
                modes.append(copy)
                controls[i].modes = profile.modes.map(\.id).filter(modes.contains)
            }
        }
        profile.controls = controls
        selected = nil
        pendingTap = nil
        editingMode = copy
        barModel.renaming = copy
        setStatus(String(localized: "A copy of “\(source.name)”, with its controls: type its name in its tab.", bundle: .windowHost))
        needsDisplay = true
    }

    /// A free id like `id`: "tap-3" gives the first free "tap-n".
    private func uniqueID(like id: String, in controls: [Control]) -> String {
        var prefix = id
        if let dash = id.lastIndex(of: "-"), Int(id[id.index(after: dash)...]) != nil { prefix = String(id[..<dash]) }
        var n = 1
        while controls.contains(where: { $0.id == "\(prefix)-\(n)" }) { n += 1 }
        return "\(prefix)-\(n)"
    }

    /// Deletes a mode, with the controls that act only there and the
    /// switches to it, once the player says so. The only mode: the layout
    /// is one set of controls again, and they all stay.
    private func deleteMode(_ id: String) {
        guard let mode = profile.modes.first(where: { $0.id == id }), let window else { return }
        let only = profile.modes.count == 1
        let going = profile.controls.filter { control in
            if case .switchMode(id, _) = control.kind { return true }
            return control.modes == [id]
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete the mode “\(mode.name)”?", bundle: .windowHost)
        alert.informativeText = only
            ? String(localized: "It is the layout’s only mode: the layout is one set of controls again, and they all stay. Cancel in the editor still undoes it.",
                     bundle: .windowHost)
            : going.isEmpty
                ? String(localized: "Its controls stay in the other modes. Cancel in the editor still undoes it.", bundle: .windowHost)
                : String(localized: "\(going.count) controls that act only there or switch to it go too. Cancel in the editor still undoes it.",
                         bundle: .windowHost)
        alert.addButton(withTitle: String(localized: "Delete Mode", bundle: .windowHost))
        alert.addButton(withTitle: String(localized: "Cancel", bundle: .windowHost))
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                if response == .alertFirstButtonReturn { self?.removeMode(id) }
                self?.refocus()
            }
        }
    }

    private func removeMode(_ id: String) {
        if profile.modes.count == 1 {
            profile.modes = []
            for i in profile.controls.indices { profile.controls[i].modes = nil }
            profile.controls.removeAll { if case .switchMode = $0.kind { true } else { false } }
        } else {
            profile.controls.removeAll { control in
                if case .switchMode(id, _) = control.kind { return true }
                return control.modes == [id]
            }
            for i in profile.controls.indices { profile.controls[i].modes?.removeAll { $0 == id } }
            profile.modes.removeAll { $0.id == id }
        }
        if let fps = profile.fps, !profile.controls.contains(where: { $0.id == fps.aimControl }) { profile.fps = nil }
        selected = nil
        pendingTap = nil
        if editingMode == id || profile.modes.isEmpty { editingMode = profile.firstMode }
        showHelp()
        needsDisplay = true
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
    private func areaChoices(for control: Control) -> [(String, Selector, String)] {
        switch control.kind {
        case let .aim(_, _, _, _, _, _, _, origin):
            var choices = [(String(localized: "Full-Height Swipe Area", bundle: .windowHost), #selector(useFullHeightArea), "arrow.up.and.down"),
                           (String(localized: "Default Swipe Area (Right Side)", bundle: .windowHost), #selector(useDefaultArea),
                            "rectangle.righthalf.inset.filled")]
            if origin != nil {
                choices.append((String(localized: "Touch in the Middle", bundle: .windowHost), #selector(touchDownAtCentre), "scope"))
            }
            return choices
        case .anchor(_, nil):
            return [(String(localized: "Reach a Circle Around It", bundle: .windowHost), #selector(useCircleReach), "circle.dashed")]
        case .anchor:
            return [(String(localized: "Let the Finger Use the Whole Screen", bundle: .windowHost), #selector(useWholeScreen), "rectangle.dashed")]
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
        changeSelectedArea { control in
            if case .anchor(let point, _) = control.kind { control.kind = .anchor(point) }
        }
        setStatus(String(localized: "The finger may now go anywhere on the screen.", bundle: .windowHost))
    }

    @objc private func useCircleReach() {
        changeSelectedArea { control in
            if case .anchor(let point, _) = control.kind { control.kind = .anchor(point, radius: Control.defaultAnchorRadius) }
        }
        setStatus(String(localized: "The finger stays in the circle. Drag ↘ to set how far it reaches.", bundle: .windowHost))
    }

    override func otherMouseDown(with event: NSEvent) {
        if selected != nil || pendingTap != nil, let button = MouseButton(buttonNumber: event.buttonNumber) { assign(.mouse(button)) }
    }

    override func scrollWheel(with event: NSEvent) {
        // Wheel notches only: trackpad scrolling is not a wheel.
        guard selected != nil || pendingTap != nil, !event.hasPreciseScrollingDeltas, event.scrollingDeltaY != 0 else { return }
        assign(event.scrollingDeltaY > 0 ? .scrollUp : .scrollDown)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        endStaleRenaming()
        guard let key = KeyboardMapping.key(forMacKeyCode: event.keyCode) else { return }
        // A modifier held for this key is part of it, not a key of its own.
        pendingModifier = nil
        guard selected != nil || pendingTap != nil else { return }
        if selected != nil, nudge(key, flags: event.modifierFlags) { return }
        if !event.isARepeat { assign(.key(key)) }
    }

    override func flagsChanged(with event: NSEvent) {
        guard selected != nil || pendingTap != nil, let key = KeyboardMapping.key(forMacKeyCode: event.keyCode) else {
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

    /// The waiting tap, with the key pressed for it: a Tap where the game
    /// was clicked, in the mode being edited.
    private func placeTap(at point: NormalizedPoint, _ trigger: Trigger) {
        pendingTap = nil
        var control = Control(id: uniqueID(like: "tap", in: profile.controls), kind: .tap(point), triggers: [trigger])
        if let editingMode { control.modes = [editingMode] }
        profile.controls.append(control)
        selected = nil
        select(control.id)
        // What else it presses here, so a shared key is no surprise.
        let others = shownControls.filter { $0.id != control.id && $0.allTriggers.contains(trigger) }.map { "“\(name(of: $0))”" }
        if others.isEmpty {
            setStatus(String(localized: "A tap on \(short(trigger)). Click the next button of the game and press its key.", bundle: .windowHost))
        } else {
            setStatus(String(localized: "A tap on \(short(trigger)), together with \(others.formatted(.list(type: .and))). Click the next button of the game and press its key.",
                             bundle: .windowHost))
        }
        needsDisplay = true
    }

    /// A control from the bar: where it was let go on the game, or (clicked)
    /// where that kind usually is, off any control already there.
    private func place(_ item: KeymapPaletteItem, at p: NormalizedPoint?) {
        pendingTap = nil
        let exactly = p != nil
        switch item {
        case .tap:
            add(.tap(p ?? NormalizedPoint(0.5, 0.5)), prefix: "tap", exactly: exactly)
        case .repeatTap:
            add(.repeatTap(p ?? NormalizedPoint(0.4, 0.5), intervalMilliseconds: 150), prefix: "repeat", exactly: exactly)
        case .anchor:
            add(.anchor(p ?? NormalizedPoint(0.5, 0.65), radius: Control.defaultAnchorRadius), prefix: "anchor", exactly: exactly)
        case .joystick:
            addJoystick(at: p)
        case .swipe:
            let from = p ?? NormalizedPoint(0.5, 0.6)
            add(.swipe(from: from, to: NormalizedPoint(from.x, max(from.y - 0.2, 0)), milliseconds: 150), prefix: "swipe", exactly: exactly)
        case .eye:
            addEye(at: p)
        case .ads:
            add(.ads(p ?? NormalizedPoint(0.9, 0.45), toggle: false), prefix: "ads", exactly: exactly)
        case .freeMouse:
            add(.mouseLook(lock: false, position: p ?? NormalizedPoint(0.08, 0.2)), prefix: "free-mouse", exactly: exactly)
        case .lockMouse:
            add(.mouseLook(lock: true, position: p ?? NormalizedPoint(0.08, 0.3)), prefix: "lock-mouse", exactly: exactly)
        case .moveByMouse:
            // Right-click to walk, as in desktop MOBAs.
            add(.mobaMove(center: p ?? NormalizedPoint(0.14, 0.72), radius: Control.defaultJoystickRadius), prefix: "move",
                trigger: .mouse(.right), exactly: exactly)
        case .smartCast:
            add(.smartCast(p ?? NormalizedPoint(0.8, 0.75), radius: Control.defaultCastRadius, reach: Control.defaultCastReach),
                prefix: "skill", exactly: exactly)
        case .switchMode:
            addSwitch(at: p)
        }
    }

    /// A control dragged from the bar: drawn under the pointer as it moves,
    /// placed where it is let go on the game.
    private func paletteDragged(_ item: KeymapPaletteItem, _ phase: KeymapEditorModel.DragPhase, _ location: CGPoint) {
        let p = pointFromPanel(location)
        switch phase {
        case .moved:
            paletteDrag = (item, p)
        case .ended:
            paletteDrag = nil
            if takesDrop(at: p) { place(item, at: normalized(p)) }
            refocus()
        }
        needsDisplay = true
    }

    /// On the game, not on the panel.
    private func takesDrop(at p: CGPoint) -> Bool {
        displayRect().contains(p) && !panelFrame.contains(p)
    }

    /// Adds a control in the mode being edited, selected; `exactly`: where
    /// its kind says, else moved off a control already there.
    private func add(_ kind: Control.Kind, prefix: String, trigger: Trigger? = nil, exactly: Bool = false) {
        var control = Control(id: uniqueID(like: prefix, in: profile.controls), kind: kind)
        if let editingMode { control.modes = [editingMode] }
        // A suggested trigger only while nothing else uses it.
        if let trigger, profile.fps?.cursorToggle != trigger, !profile.controls.contains(where: { $0.allTriggers.contains(trigger) }) {
            control.triggers = [trigger]
        }
        // Not exactly under an older control, or under the hero marker,
        // which is drawn over the controls and takes their clicks.
        if !exactly {
            var taken = shownControls.map(anchor(of:))
            if showsHero || control.followsCursor { taken.append(hero) }
            let start = anchor(of: control)
            var spot = start, step = 0
            while step < 12, taken.contains(where: { abs($0.x - spot.x) < 0.02 && abs($0.y - spot.y) < 0.02 }) {
                step += 1
                spot = NormalizedPoint(min(start.x + 0.05 * Double(step), 0.95), min(start.y + 0.05 * Double(step), 0.95))
            }
            if spot != start { move(&control, to: spot) }
        }
        profile.controls.append(control)
        selected = nil
        select(control.id)
        needsDisplay = true
    }

    /// W A S D, or the arrow keys while another joystick here has them.
    private func addJoystick(at p: NormalizedPoint?) {
        let second = shownControls.contains { control in
            if case let .dpad(_, _, up, _, _, _, _) = control.kind { return up == .key(.w) }
            return false
        }
        let keys: [Trigger] = second ? [.key(.up), .key(.down), .key(.left), .key(.right)] : [.key(.w), .key(.s), .key(.a), .key(.d)]
        add(.dpad(center: p ?? NormalizedPoint(0.15, 0.7), radius: 0.12, up: keys[0], down: keys[1], left: keys[2], right: keys[3],
                  stick: second ? nil : .left), prefix: "move", exactly: p != nil)
    }

    /// The layout's one eye: the one there (selected, and brought to this
    /// mode), or a new one around where it was let go, in every mode.
    private func addEye(at p: NormalizedPoint?) {
        if let eye = profile.controls.first(where: isEye) {
            if !eye.belongs(to: editingMode), let i = index(of: eye.id) { profile.controls[i].modes = nil }
            selected = nil
            select(eye.id)
            setStatus(String(localized: "There is one eye per layout; this is it.", bundle: .windowHost))
            needsDisplay = true
            return
        }
        // Most of the right side at full height: the finger swipes far before it starts over.
        var area = Control.defaultEyeArea
        if let p { area = area.offsetBy(dx: p.x - area.center.x, dy: p.y - area.center.y) }
        add(.aim(area: area, sensitivity: AxisPair(x: 1, y: 1), adsSensitivity: AxisPair(x: 0.6, y: 0.6), exponent: 1, deadzone: 0,
                 invertY: false, stick: .right), prefix: "eye", exactly: true)
        guard let eye = profile.controls.last, let i = index(of: eye.id) else { return }
        // A game turns its camera in all of its modes.
        profile.controls[i].modes = nil
        let toggle = FPSSettings.defaultCursorToggle
        let taken = profile.controls.contains { $0.id != eye.id && $0.allTriggers.contains(toggle) }
        profile.fps = FPSSettings(cursorToggle: taken ? .key(.grave) : toggle, aimControl: eye.id)
        prompt(for: eye)
    }

    /// A switch to another mode: the one other, or one chosen in a menu; with
    /// no other yet, a new mode (its name typed in its tab) and the switch to
    /// it here.
    private func addSwitch(at p: NormalizedPoint?) {
        let spot = p ?? NormalizedPoint(0.85, 0.5)
        let others = profile.modes.filter { $0.id != editingMode }
        if others.isEmpty {
            let from = editingMode
            let mode = createMode()
            // The switch belongs where the player gets to the new mode from.
            editingMode = from ?? profile.firstMode
            add(.switchMode(mode, position: spot), prefix: "switch", exactly: p != nil)
            barModel.renaming = mode
            setStatus(String(localized: "A new mode and its Switch: name the mode, then press the Switch’s key.", bundle: .windowHost))
        } else if others.count == 1 {
            add(.switchMode(others[0].id, position: spot), prefix: "switch", exactly: p != nil)
        } else {
            let entries: [HazeMenuEntry] = [.section(String(localized: "Switch To", bundle: .windowHost))] + others.map { mode in
                .item(HazeMenuItem(title: mode.name, symbol: KeymapPaletteItem.switchMode.symbol) { [weak self] in
                    self?.add(.switchMode(mode.id, position: spot), prefix: "switch", exactly: p != nil)
                    self?.refocus()
                })
            }
            let at = p.flatMap { p in window.map { $0.convertPoint(toScreen: convert(point(p), to: nil)) } } ?? NSEvent.mouseLocation
            HazeMenuPresenter.shared.show(entries, at: at)
        }
    }

    /// Mouse buttons and the wheel, as the trigger of the selected control
    /// or of the waiting tap.
    private func mouseEntries() -> [HazeMenuEntry] {
        Self.mouseChoices.map { title, trigger, symbol in
            .item(HazeMenuItem(title: title, symbol: symbol) { [weak self] in
                self?.assign(trigger)
                self?.refocus()
            })
        }
    }

    @objc private func removeAll() {
        profile.controls.removeAll()
        profile.fps = nil
        profile.modes = []
        selected = nil
        pendingTap = nil
        editingMode = nil
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
        painter.obstacles = panelOutside ? [] : [panel.frame]
        painter.modeNames = Dictionary(profile.modes.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let eyeKey = profile.fps?.cursorToggle.shortLabel
        // Only the mode being edited (all of the layout without modes).
        let shown = shownControls
        // Lit as if selected: where a dragged part of the controller would
        // bind, and what the part under the pointer in the panel drives.
        let dropTarget = padDrag.flatMap { dropTarget(for: $0.element, at: $0.at) }
        let lit = Set(padHover.map { profile.controls(boundTo: $0).map(\.id) } ?? []).union(dropTarget.map { [$0] } ?? [])
        // Areas under everything: the eye's swipe area.
        for control in shown where hasOwnArea(control) {
            painter.drawArea(control, selected: control.id == selected || lit.contains(control.id), hovered: control.id == hovered?.controlID)
        }
        // Eyes first: buttons are drawn over their area.
        for control in shown where isEye(control) {
            painter.draw(control, selected: control.id == selected || lit.contains(control.id), eyeKey: eyeKey)
        }
        for control in shown where !isEye(control) {
            painter.draw(control, selected: control.id == selected || lit.contains(control.id),
                         activeSlot: control.id == selected ? dpadSlot : nil)
        }
        // In a layout with modes, what acts in all of them is marked so.
        if !profile.modes.isEmpty {
            for control in shown where control.modes == nil { painter.drawEveryModeBadge(control) }
        }
        if showsHero {
            let active = { if case .hero? = drag { true } else if case .hero? = hovered { true } else { false } }()
            painter.drawHero(at: hero, selected: active)
        }
        for control in shown {
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
        if let padDrag, takesDrop(at: padDrag.at) {
            let caption = dropTarget.flatMap { id in profile.controls.first { $0.id == id } }
                .map { String(localized: "Bind to “\(name(of: $0))”", bundle: .windowHost) }
                ?? String(localized: "Let go to choose a control", bundle: .windowHost)
            painter.drawGhost(symbol: padSymbol(padDrag.element), caption: caption, at: padDrag.at, binding: dropTarget != nil)
        }
        // The tap a click on the game put there, waiting for its key.
        if let pendingTap { painter.drawPendingTap(at: point(pendingTap)) }
        // A control dragged from the bar, over the game.
        if let paletteDrag, takesDrop(at: paletteDrag.at) {
            painter.drawGhost(symbol: paletteDrag.item.symbol, caption: String(localized: "Let go to place it here", bundle: .windowHost),
                              at: paletteDrag.at, binding: false)
        }
    }

    // MARK: Controller (ControllerPanel.swift)

    private static let panelTabKey = "AvoKeymapPanelTab"
    /// Every part of a controller, in GamepadButton's order, then the sticks and the d-pad.
    private static let gamepadElements: [GamepadElement] = GamepadButton.allCases.map(GamepadElement.button)
        + GamepadStick.allCases.map(GamepadElement.stick) + [.dpad]

    /// The panel's Controller tab is open.
    var showsController: Bool { barModel.tab == .controller }

    /// The panel's tab, remembered per app; the Controller tab follows the controller live.
    private func setTab(_ tab: KeymapEditorModel.Tab) {
        guard barModel.tab != tab else { return }
        barModel.tab = tab
        UserDefaults.standard.set(tab.rawValue, forKey: Self.panelTabKey)
        if tab == .controller {
            if window != nil { controllerPanel.start() }
            refreshPanel()
        } else {
            controllerPanel.stop()
            padDrag = nil
            padHover = nil
            needsDisplay = true
        }
    }

    private func connectPanel() {
        let panel = controllerPanel
        panel.drag = { [weak self] element, phase, location in self?.panelDragged(element, phase, location) }
        panel.click = { [weak self] element in
            self?.controllerPressed(element, inPanel: true)
            self?.refocus()
        }
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
    }

    /// What the panel shows of the layout: what each part drives, what drives the selected control, the settings.
    private func refreshPanel() {
        guard showsController else { return }
        var bindings: [GamepadElement: [String]] = [:]
        for element in Self.gamepadElements {
            let names = profile.controls(boundTo: element).filter { $0.belongs(to: editingMode) }.map(displayName)
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
        let p = pointFromPanel(location)
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
        guard takesDrop(at: p) else { return }
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
        HazeMenuPresenter.shared.popUp(menu, at: p, in: self)
    }

    @objc private func placeFromMenu(_ item: NSMenuItem) {
        guard let pending = item.representedObject as? PendingPlacement else { return }
        let element = pending.element
        let hadEye = profile.controls.contains(where: isEye)
        guard let id = profile.place(element, as: pending.placement, at: pending.point, modes: editingMode.map { [$0] }),
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
        // A tap waits for its key: a button is it; a stick pushed is a joystick there.
        if let at = pendingTap, !inPanel {
            switch element {
            case .button(let button):
                placeTap(at: at, .gamepad(button))
            case .stick, .dpad:
                pendingTap = nil
                if let id = profile.place(element, as: .joystick, at: at, modes: editingMode.map { [$0] }) {
                    selected = nil
                    select(id)
                    needsDisplay = true
                } else {
                    setStatus(whyNot(element), problem: true)
                }
            }
            return
        }
        // A controller button held to run, for the selected joystick.
        if case .button(let button) = element, dpadSlot == Self.runSlot, let id = selected,
           let control = profile.controls.first(where: { $0.id == id }), case .dpad = control.kind {
            assign(.gamepad(button))
            return
        }
        guard let id = selected, let control = profile.controls.first(where: { $0.id == id }) else {
            // Clicked in the panel: its controls to place, at the waiting tap
            // or where games usually have them.
            if inPanel {
                showPlacements(for: element, at: painter.point(pendingTap ?? Self.usualSpot(for: element)))
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
        case .camera: String(localized: "Eye", bundle: .windowHost)
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
        case .switchMode(let mode, _):
            String(localized: "Switch to “\(profile.modes.first { $0.id == mode }?.name ?? mode)”", bundle: .windowHost)
        case .mouseLook(let lock, _):
            lock ? String(localized: "Lock the Mouse", bundle: .windowHost) : String(localized: "Free the Mouse", bundle: .windowHost)
        }
    }

    /// Its symbol, as on the bar.
    private static func symbol(of control: Control) -> String {
        switch control.kind {
        case .tap, .hold: KeymapPaletteItem.tap.symbol
        case .repeatTap: KeymapPaletteItem.repeatTap.symbol
        case .anchor: KeymapPaletteItem.anchor.symbol
        case .dpad: KeymapPaletteItem.joystick.symbol
        case .swipe: KeymapPaletteItem.swipe.symbol
        case .aim: KeymapPaletteItem.eye.symbol
        case .ads: KeymapPaletteItem.ads.symbol
        case .macro: "list.bullet"
        case .mobaMove: KeymapPaletteItem.moveByMouse.symbol
        case .smartCast: KeymapPaletteItem.smartCast.symbol
        case .switchMode: KeymapPaletteItem.switchMode.symbol
        case .mouseLook(let lock, _): lock ? KeymapPaletteItem.lockMouse.symbol : KeymapPaletteItem.freeMouse.symbol
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

    /// The bar's Templates menu.
    private func templateEntries() -> [HazeMenuEntry] {
        [.note(String(localized: "Starting layouts: move each control onto the game's button afterwards", bundle: .windowHost))]
            + KeymapTemplate.allCases.map { template in
                .item(HazeMenuItem(title: Self.title(of: template), symbol: Self.symbol(of: template)) { [weak self] in
                    self?.chooseTemplate(template)
                    self?.refocus()
                })
            }
    }

    /// The bar's ⋯ menu.
    private func moreEntries() -> [HazeMenuEntry] {
        [
            .item(HazeMenuItem(title: String(localized: "Import…", bundle: .windowHost), symbol: "square.and.arrow.down") { [weak self] in
                self?.importProfile()
            }),
            .item(HazeMenuItem(title: String(localized: "Export…", bundle: .windowHost), symbol: "square.and.arrow.up") { [weak self] in
                self?.exportProfile()
            }),
            .separator(),
            .item(HazeMenuItem(title: String(localized: "Remove All Controls", bundle: .windowHost), symbol: "trash", role: .destructive) {
                [weak self] in
                self?.removeAll()
                self?.refocus()
            }),
        ]
    }

    private func chooseTemplate(_ template: KeymapTemplate) {
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
        let before = Set(profile.controls.map(\.id))
        let insertion = template.insert(into: profile, replacing: replacing, aspect: rect.height > 0 ? rect.width / rect.height : 16.0 / 9.0)
        profile = insertion.profile
        if let editingMode {
            for i in profile.controls.indices where !before.contains(profile.controls[i].id) { profile.controls[i].modes = [editingMode] }
        }
        selected = nil
        pendingTap = nil
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
            var message = problems.first ?? String(localized: "This profile has problems.", bundle: .windowHost)
            // The control it is about, shown in a mode it acts in.
            if let first = problems.first, let control = profile.controls.first(where: { first.hasPrefix("\($0.id):") }) {
                if !control.belongs(to: editingMode), let mode = control.modes?.first { editingMode = mode }
                select(control.id)
                needsDisplay = true
                // Selected, it needs no name ("tap-3: …"); one still without
                // its key takes the next key pressed.
                message = Self.needsKey(control)
                    ? String(localized: "This control has no key yet. Press its key or controller button, or right-click for a mouse button.",
                             bundle: .windowHost)
                    : Self.sentence(first.dropFirst("\(control.id):".count))
            }
            setStatus(message, problem: true)
            return
        }
        if let error = onSave(profile) {
            setStatus(String(localized: "Could not save: \(error)", bundle: .windowHost), problem: true)
        } else {
            close()
        }
    }

    /// A control that acts on its own key (not a joystick's four, nor the
    /// eye's lock key) and has none yet.
    private static func needsKey(_ control: Control) -> Bool {
        switch control.kind {
        case .dpad, .aim: false
        default: control.triggers.isEmpty
        }
    }

    /// A problem's text without its control's id, as a sentence.
    private static func sentence(_ text: Substring) -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        return text.prefix(1).uppercased() + text.dropFirst()
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
            editingMode = imported.firstMode
            needsDisplay = true
            let text = String(localized: "Imported “\(imported.name)”. Press Done to use it.", bundle: .windowHost)
            if let warning = Self.newerControlsWarning(imported) {
                setStatus(text + " " + warning, problem: true)
            } else {
                setStatus(text)
            }
        } catch {
            setStatus(String(localized: "This file isn’t an Avo key mapping.", bundle: .windowHost), problem: true)
        }
    }

    @objc private func close() { onClose?() }

    /// Cancel, and ⇧⌘K again: the changes go only once the player says so
    /// (none, and it just closes).
    func cancel() {
        guard profile != original, let window else {
            close()
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Discard your key mapping changes?", bundle: .windowHost)
        alert.informativeText = String(localized: "To save them, choose Keep Editing, then Done.", bundle: .windowHost)
        // Keep Editing takes Return and Esc: a stray key never throws the work away.
        alert.addButton(withTitle: String(localized: "Keep Editing", bundle: .windowHost))
        alert.addButton(withTitle: String(localized: "Discard", bundle: .windowHost)).hasDestructiveAction = true
        alert.buttons.first?.keyEquivalent = "\r"
        alert.buttons.last?.keyEquivalent = ""
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.close() } else { self?.refocus() }
        }
    }
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
