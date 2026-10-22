import AppKit
import AvoKeymap
import SwiftUI

// The controller panel of the key mapping editor (KeymapEditorView): the
// controller in use drawn as its kind (Xbox, PlayStation, Nintendo), its
// buttons and sticks lighting up as they are pressed and moved, a mark on
// each part that drives something. Drag a part onto the game to place a
// control for it, or onto a control to bind it; with a control selected,
// click a part here or press it on the controller. Its other tabs set the
// sticks' dead zones and sensitivity, vibration, and the game's controller
// presets. It is the Controller tab of the editor's panel beside the game
// (KeymapEditorPanel), in the Quick Settings' haze look.

private func L(_ key: String.LocalizationValue) -> String { String(localized: key, bundle: .windowHost) }

// MARK: - Model

/// What the panel shows: the controller from GamepadHub, the layout from
/// the editor, which also does everything the panel asks.
@MainActor
final class ControllerPanelModel: ObservableObject {
    enum Tab: Hashable { case buttons, sticks, presets }
    enum DragPhase { case moved, ended }

    @Published private(set) var info: GamepadHub.Info?
    @Published private(set) var reading = GamepadReading()
    @Published var tab = Tab.buttons
    @Published var stick = GamepadStick.left
    /// The kind of controller drawn while none is connected.
    @Published var chosenLayout = GamepadHub.shared.layout
    /// What each part drives, by the controls' names (the editor's).
    @Published var bindings: [GamepadElement: [String]] = [:]
    /// The parts that drive the selected control.
    @Published var selection: Set<GamepadElement> = []
    @Published var settings = GamepadSettings.standard

    var layout: GamepadLayout { info?.layout ?? chosenLayout }

    // What the panel asks of the editor.
    var drag: (GamepadElement, DragPhase, CGPoint) -> Void = { _, _, _ in }
    var click: (GamepadElement) -> Void = { _ in }
    var hover: (GamepadElement?) -> Void = { _ in }
    var changeSettings: (GamepadSettings) -> Void = { _ in }
    var applyTemplate: (KeymapTemplate) -> Void = { _ in }
    var applyPreset: (String) -> Void = { _ in }
    var deletePreset: (String) -> Void = { _ in }
    var savePreset: () -> Void = {}
    var reset: () -> Void = {}

    private var listener: UUID?
    private var observer: (any NSObjectProtocol)?

    func start() {
        guard listener == nil else { return }
        listener = GamepadHub.shared.addListener { [weak self] _, reading in
            guard let self, reading != self.reading else { return }
            self.reading = reading
        }
        observer = NotificationCenter.default.addObserver(forName: GamepadHub.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshController() }
        }
        refreshController()
    }

    func stop() {
        if let listener { GamepadHub.shared.removeListener(listener) }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        listener = nil
        observer = nil
    }

    func refreshController() {
        let new = GamepadHub.shared.info
        if new != info { info = new }
        reading = GamepadHub.shared.reading
        if let layout = new?.layout { chosenLayout = layout }
    }

    func setStick(_ change: (inout StickSettings) -> Void) {
        var settings = settings
        change(&settings[stick])
        changeSettings(settings)
    }

    /// A button's or stick's name as the controller prints it: "A", "✕", "LS".
    func label(_ element: GamepadElement) -> String {
        switch element {
        case .button(let button): layout.label(button)
        case .stick(let stick): layout.label(stick)
        case .dpad: L("D-pad")
        }
    }

    /// The part's long name, for help tags and VoiceOver.
    func name(_ element: GamepadElement) -> String {
        switch element {
        case .button(let button): L("Button \(layout.label(button))")
        case .stick(.left): L("Left stick")
        case .stick(.right): L("Right stick")
        case .dpad: L("D-pad (all four directions)")
        }
    }
}

// MARK: - The panel

struct ControllerPanelView: View {
    /// Where a part dragged from the diagram is: the editor's panel's
    /// coordinates (KeymapEditorPanel names them so), y down from its top left.
    static let space = "avo.controllerPanel"
    @ObservedObject var model: ControllerPanelModel
    @State private var showsHowTo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            QuickSegmented(label: L("Controller panel"),
                           options: [(ControllerPanelModel.Tab.buttons, L("Buttons")), (.sticks, L("Sticks")), (.presets, L("Presets"))],
                           selection: model.tab, fill: true) { tab in
                withAnimation(.easeOut(duration: 0.15)) { model.tab = tab }
            }
            switch model.tab {
            case .buttons: ButtonsTab(model: model)
            case .sticks: SticksTab(model: model)
            case .presets: PresetsTab(model: model)
            }
        }
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.layout.logoSymbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(model.info == nil ? QuickHaze.textTertiary : QuickHaze.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: model.info?.name ?? L("No controller connected"))
                    .font(QuickHaze.hubot(14, 650))
                    .foregroundStyle(QuickHaze.text)
                    .lineLimit(1)
                Text(verbatim: status)
                    .font(QuickHaze.mona(11.5))
                    .foregroundStyle(QuickHaze.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            QuickHelpButton(help: Self.howTo, shown: $showsHowTo)
        }
        if showsHowTo { QuickCaption(Self.howTo) }
    }

    /// How the diagram maps the controller, behind the header's (?).
    private static var howTo: String {
        L("Click a button or stick to place its control, or drag it to where it goes on the game (onto a control to bind it). With a control selected, press a button on the controller or click it here to bind it.")
    }

    private var status: String {
        guard let info = model.info else { return L("Connect one over Bluetooth or USB") }
        if info.charging { return L("Connected · charging") }
        if let battery = info.battery {
            return L("Connected · battery \(Int((battery * 100).rounded()))%")
        }
        return L("Connected")
    }
}

/// The diagram, and how to use it.
private struct ButtonsTab: View {
    @ObservedObject var model: ControllerPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if model.info == nil {
                QuickSegmented(label: L("Controller to show"),
                               options: [(GamepadLayout.xbox, "Xbox"), (.playStation, "PlayStation"), (.nintendo, "Nintendo")],
                               selection: model.chosenLayout, fill: true) { model.chosenLayout = $0 }
            }
            ControllerDiagram(model: model)
        }
    }
}

/// A stick's dead zone and sensitivity, with a live view of both, and vibration.
private struct SticksTab: View {
    @ObservedObject var model: ControllerPanelModel

    var body: some View {
        let stick = model.settings[model.stick]
        let deadzone = Text(stick.deadzone, format: .percent.precision(.fractionLength(0)))
        let sensitivity = Text(verbatim: stick.sensitivity.formatted(.number.precision(.fractionLength(0...2))) + "×")
        VStack(alignment: .leading, spacing: 10) {
            QuickSegmented(label: L("Stick"), options: [(GamepadStick.left, L("Left stick")), (.right, L("Right stick"))],
                           selection: model.stick, fill: true) { model.stick = $0 }
            HStack(alignment: .center, spacing: 12) {
                StickPreview(position: model.reading.position(of: model.stick), settings: stick,
                             pressed: model.reading.pressed.contains(GamepadElement.pressButton(of: model.stick)))
                    .frame(width: 78, height: 78)
                VStack(alignment: .leading, spacing: 8) {
                    QuickSliderRow(label: L("Dead zone"), value: deadzone,
                                   help: L("Small movements around the middle are ignored, so a worn stick’s drift stays out of the game.")) {
                        QuickSlider(label: L("Dead zone"), value: Binding(get: { stick.deadzone }, set: { value in
                            model.setStick { $0.deadzone = value }
                        }), range: StickSettings.deadzoneRange, step: 0.01, valueText: deadzone)
                    }
                    // Doubling and halving are the same step: 1× in the middle.
                    QuickSliderRow(label: L("Sensitivity"), value: sensitivity,
                                   help: L("Above 1×, a smaller push reaches the joystick’s edge, and the eye turns faster.")) {
                        QuickSlider(label: L("Sensitivity"), value: Binding(get: { log2(stick.sensitivity) }, set: { value in
                            model.setStick { $0.sensitivity = min(max((pow(2, value) * 20).rounded() / 20, 0.25), 4) }
                        }), range: log2(StickSettings.sensitivityRange.lowerBound)...log2(StickSettings.sensitivityRange.upperBound),
                        step: 0.05, valueText: sensitivity)
                    }
                }
            }
            QuickCaption(drives)
            HStack {
                PanelButton(title: L("Reset This Stick"), symbol: "arrow.counterclockwise", style: .secondary) {
                    model.setStick { $0 = .standard }
                }
                .disabled(stick == .standard)
                Spacer(minLength: 0)
            }
            Divider().overlay(QuickHaze.text.opacity(0.08))
            let canVibrate = model.info?.canVibrate ?? false
            QuickToggle(label: L("Vibrate on press"),
                        caption: model.info == nil || canVibrate ? L("A light pulse when a button touches the screen")
                                                                 : L("This controller cannot vibrate"),
                        isOn: model.settings.vibration) { on in
                var settings = model.settings
                settings.vibration = on
                model.changeSettings(settings)
            }
            .disabled(model.info != nil && !canVibrate)
            .opacity(model.info != nil && !canVibrate ? 0.5 : 1)
        }
    }

    private var drives: String {
        let names = model.bindings[.stick(model.stick)] ?? []
        guard !names.isEmpty else {
            return L("Drives nothing yet: drag it onto a joystick or the eye, or onto the game.")
        }
        return L("Drives \(names.joined(separator: ", ")).")
    }
}

/// Ready-made layouts for this kind of game, the game's saved presets, and reset.
private struct PresetsTab: View {
    @ObservedObject var model: ControllerPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                QuickLabel(L("Ready-made for this game’s controls"),
                           help: L("Puts each control on the button games of that kind use, going by its name and key."))
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(KeymapTemplate.allCases, id: \.self) { template in
                        PanelButton(title: ControllerPanelView.title(of: template), symbol: ControllerPanelView.symbol(of: template),
                                    style: .secondary, fill: true) { model.applyTemplate(template) }
                    }
                }
            }
            Divider().overlay(QuickHaze.text.opacity(0.08))
            VStack(alignment: .leading, spacing: 6) {
                QuickLabel(L("Saved for this game"),
                           help: L("Save the controller layout as it is, to come back to it or to switch between layouts."))
                ForEach(model.settings.presets) { preset in
                    HStack(spacing: 8) {
                        Image(systemName: "gamecontroller").font(.system(size: 12)).foregroundStyle(QuickHaze.textTertiary)
                        Text(verbatim: preset.name).font(QuickHaze.mona(13)).foregroundStyle(QuickHaze.text).lineLimit(1)
                        Spacer(minLength: 6)
                        PanelButton(title: L("Use"), symbol: "checkmark", style: .secondary) { model.applyPreset(preset.name) }
                        PanelIconButton(symbol: "trash", label: L("Delete “\(preset.name)”")) { model.deletePreset(preset.name) }
                    }
                }
                PanelButton(title: L("Save as Preset…"), symbol: "square.and.arrow.down", style: .primary, fill: true) { model.savePreset() }
            }
            Divider().overlay(QuickHaze.text.opacity(0.08))
            PanelButton(title: L("Reset Controller Mapping…"), symbol: "arrow.counterclockwise", style: .destructive, fill: true) {
                model.reset()
            }
        }
    }
}

extension ControllerPanelView {
    static func title(of template: KeymapTemplate) -> String {
        switch template {
        case .fps: L("Shooter")
        case .moba: L("MOBA")
        case .racing: L("Racing")
        case .platformer: L("Platformer")
        }
    }

    static func symbol(of template: KeymapTemplate) -> String {
        switch template {
        case .fps: "scope"
        case .moba: "cursorarrow.rays"
        case .racing: "car"
        case .platformer: "figure.run"
        }
    }
}

// MARK: - The diagram

/// The controller, from GamepadDiagram's table: its body, then each part
/// as SF Symbols' glyph for it (or a drawn stick and d-pad), lit while
/// pressed, marked when it drives something, ringed when it drives the
/// selected control.
private struct ControllerDiagram: View {
    @ObservedObject var model: ControllerPanelModel

    var body: some View {
        let diagram = GamepadDiagram(layout: model.layout)
        GeometryReader { geometry in
            let scale = geometry.size.width / GamepadDiagram.size.width
            ZStack(alignment: .topLeading) {
                ControllerBody()
                    .fill(LinearGradient(colors: [QuickHaze.text.opacity(0.1), QuickHaze.text.opacity(0.04)], startPoint: .top, endPoint: .bottom))
                ControllerBody().stroke(QuickHaze.text.opacity(0.2), lineWidth: 1)
                ForEach(Array(diagram.decorations.enumerated()), id: \.offset) { _, decoration in
                    DecorationView(decoration: decoration, layout: model.layout, scale: scale)
                }
                ForEach(diagram.spots, id: \.element) { spot in
                    SpotView(model: model, spot: spot, scale: scale)
                }
            }
        }
        .aspectRatio(GamepadDiagram.size.width / GamepadDiagram.size.height, contentMode: .fit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: L("Controller")))
    }
}

/// A controller's outline in GamepadDiagram's drawing: the shoulders, the
/// two grips and the bridge between them.
private struct ControllerBody: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / GamepadDiagram.size.width, sy = rect.height / GamepadDiagram.size.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var path = Path()
        path.move(to: p(60, 50))
        path.addCurve(to: p(160, 58), control1: p(95, 46), control2: p(130, 58))
        path.addCurve(to: p(260, 50), control1: p(190, 58), control2: p(225, 46))
        path.addCurve(to: p(304, 104), control1: p(288, 54), control2: p(300, 78))
        path.addCurve(to: p(290, 186), control1: p(310, 140), control2: p(306, 176))
        path.addCurve(to: p(246, 176), control1: p(276, 196), control2: p(258, 194))
        path.addCurve(to: p(208, 164), control1: p(236, 168), control2: p(222, 164))
        path.addLine(to: p(112, 164))
        path.addCurve(to: p(74, 176), control1: p(98, 164), control2: p(84, 168))
        path.addCurve(to: p(30, 186), control1: p(62, 194), control2: p(44, 196))
        path.addCurve(to: p(16, 104), control1: p(14, 176), control2: p(10, 140))
        path.addCurve(to: p(60, 50), control1: p(20, 78), control2: p(32, 54))
        path.closeSubpath()
        return path
    }
}

private struct DecorationView: View {
    let decoration: GamepadDiagram.Decoration
    let layout: GamepadLayout
    let scale: CGFloat

    var body: some View {
        switch decoration {
        case .touchpad(let frame):
            RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
                .fill(Color.black.opacity(0.22))
                .overlay { RoundedRectangle(cornerRadius: 6 * scale, style: .continuous).strokeBorder(QuickHaze.text.opacity(0.12)) }
                .frame(width: frame.width * scale, height: frame.height * scale)
                .position(x: frame.midX * scale, y: frame.midY * scale)
        case .home(let frame):
            Image(systemName: layout == .nintendo || layout == .generic ? "house.fill" : layout.logoSymbol)
                .font(.system(size: frame.height * scale * 0.62, weight: .semibold))
                .foregroundStyle(QuickHaze.textTertiary.opacity(0.6))
                .frame(width: frame.width * scale, height: frame.height * scale)
                .background(Circle().fill(Color.black.opacity(0.22)))
                .help(L("macOS keeps the Home button for itself"))
                .position(x: frame.midX * scale, y: frame.midY * scale)
        }
    }
}

/// One part of the controller: drawn by its shape, dragged onto the game, clicked to bind.
private struct SpotView: View {
    @ObservedObject var model: ControllerPanelModel
    let spot: GamepadDiagram.Spot
    let scale: CGFloat
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        let frame = spot.frame
        let bound = !(model.bindings[spot.element] ?? []).isEmpty
        let selected = model.selection.contains(spot.element)
        content(pressed: pressed, bound: bound, selected: selected)
            .frame(width: frame.width * scale, height: frame.height * scale)
            .overlay(alignment: .topTrailing) {
                if bound {
                    Circle().fill(QuickHaze.accent)
                        .overlay { Circle().strokeBorder(QuickHaze.base, lineWidth: 1) }
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: -2)
                }
            }
            .scaleEffect(dragging ? 0.9 : hovering ? 1.08 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: pressed)
            // The part's own frame takes the pointer: after `position` (last,
            // below) it would be the whole diagram, and the part drawn last
            // (Menu) would take every click, hover and drag.
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                model.hover(inside ? spot.element : nil)
            }
            .help(help)
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(ControllerPanelView.space))
                .onChanged { drag in
                    dragging = true
                    model.drag(spot.element, .moved, drag.location)
                }
                .onEnded { drag in
                    dragging = false
                    model.drag(spot.element, .ended, drag.location)
                })
            .simultaneousGesture(TapGesture().onEnded { model.click(spot.element) })
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: model.name(spot.element)))
            .accessibilityValue(Text(verbatim: (model.bindings[spot.element] ?? []).joined(separator: ", ")))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.click(spot.element) }
            .position(x: frame.midX * scale, y: frame.midY * scale)
    }

    /// Pressed on the controller now (a stick: pushed past its dead zone, or pressed down).
    private var pressed: Bool {
        switch spot.element {
        case .button(let button): model.reading.pressed.contains(button)
        case .stick(let stick):
            model.reading.pressed.contains(GamepadElement.pressButton(of: stick)) || {
                let p = model.reading.position(of: stick)
                return model.settings[stick].deflection(x: p.x, y: p.y) != (0, 0)
            }()
        case .dpad: !model.reading.pressed.isDisjoint(with: GamepadElement.dpadButtons)
        }
    }

    private var help: String {
        let names = model.bindings[spot.element] ?? []
        let what = model.name(spot.element)
        return names.isEmpty ? L("\(what): drag it onto the game") : L("\(what): \(names.joined(separator: ", "))")
    }

    private func color(pressed: Bool, bound: Bool, selected: Bool) -> Color {
        if pressed { return QuickHaze.accent }
        if selected { return Color(nsColor: .systemYellow) }
        return bound ? QuickHaze.text : QuickHaze.textSecondary.opacity(0.75)
    }

    @ViewBuilder
    private func content(pressed: Bool, bound: Bool, selected: Bool) -> some View {
        let tint = color(pressed: pressed, bound: bound, selected: selected)
        switch (spot.shape, spot.element) {
        case (.stick, .stick(let stick)):
            StickPreview(position: model.reading.position(of: stick), settings: model.settings[stick],
                         pressed: model.reading.pressed.contains(GamepadElement.pressButton(of: stick)),
                         ring: selected ? Color(nsColor: .systemYellow) : nil, letter: stick == .left ? "L" : "R")
        case (.dpadArm, .button(let button)):
            RoundedRectangle(cornerRadius: 3 * scale, style: .continuous)
                .fill(pressed ? QuickHaze.accent : Color.white.opacity(bound ? 0.2 : 0.11))
                .overlay {
                    RoundedRectangle(cornerRadius: 3 * scale, style: .continuous)
                        .strokeBorder(selected ? Color(nsColor: .systemYellow) : QuickHaze.text.opacity(0.18), lineWidth: selected ? 1.5 : 1)
                }
                .overlay {
                    Image(systemName: Self.chevron(button))
                        .font(.system(size: 7 * scale, weight: .heavy))
                        .foregroundStyle(pressed ? QuickHaze.onAccent : tint)
                }
        case (.dpadCenter, _):
            Circle()
                .fill(pressed ? QuickHaze.accent.opacity(0.5) : Color.white.opacity(0.08))
                .overlay { Circle().strokeBorder(selected ? Color(nsColor: .systemYellow) : QuickHaze.text.opacity(0.2), lineWidth: selected ? 1.5 : 1) }
                .overlay {
                    Image(systemName: "plus").font(.system(size: 6.5 * scale, weight: .heavy)).foregroundStyle(tint)
                }
        case (_, .button(let button)):
            Image(systemName: model.layout.symbol(button, pressed: pressed))
                .resizable()
                .scaledToFit()
                .fontWeight(.medium)
                .foregroundStyle(tint)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .systemYellow).opacity(0.16)).padding(-3)
                    }
                }
        default:
            EmptyView()
        }
    }

    private static func chevron(_ button: GamepadButton) -> String {
        switch button {
        case .dpadUp: "chevron.up"
        case .dpadDown: "chevron.down"
        case .dpadLeft: "chevron.left"
        default: "chevron.right"
        }
    }
}

/// A stick from above: its travel, the dead zone in it (dashed), and the
/// knob where the stick is now, lit once it leans past the dead zone.
private struct StickPreview: View {
    let position: (x: Double, y: Double)
    let settings: StickSettings
    var pressed = false
    var ring: Color?
    var letter: String?

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let r = side / 2
            let lean = settings.deflection(x: position.x, y: position.y)
            let active = lean != (0, 0) || pressed
            let travel = r * 0.42
            let x = min(max(position.x, -1), 1), y = min(max(position.y, -1), 1)
            ZStack {
                Circle().fill(Color.black.opacity(0.32))
                Circle().strokeBorder(ring ?? QuickHaze.text.opacity(0.2), lineWidth: ring == nil ? 1 : 1.5)
                // The dead zone around the centre, as the knob's centre sees it.
                Circle()
                    .stroke(QuickHaze.accent.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(width: max(2 * travel * settings.deadzone, 2), height: max(2 * travel * settings.deadzone, 2))
                Circle()
                    .fill(active ? QuickHaze.accent : Color.white.opacity(0.18))
                    .overlay { Circle().strokeBorder(QuickHaze.onAccent.opacity(active ? 0.3 : 0)) }
                    .frame(width: r * 1.05, height: r * 1.05)
                    .scaleEffect(pressed ? 0.88 : 1)
                    .overlay {
                        if let letter {
                            Text(verbatim: letter)
                                .font(.system(size: r * 0.42, weight: .bold, design: .rounded))
                                .foregroundStyle(active ? QuickHaze.onAccent : QuickHaze.textSecondary)
                        }
                    }
                    .offset(x: x * travel, y: -y * travel)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Buttons

struct PanelButton: View {
    enum Style { case primary, secondary, destructive }
    let title: String
    let symbol: String
    let style: Style
    var fill = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                Text(verbatim: title).font(QuickHaze.mona(12.5, 650)).lineLimit(1).minimumScaleFactor(0.85)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 11)
            .frame(maxWidth: fill ? .infinity : nil)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(style == .primary ? QuickHaze.accent : QuickHaze.inset)
            }
            .overlay {
                if style != .primary {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(style == .destructive ? Color.red.opacity(0.45) : QuickHaze.accent.opacity(0.3))
                }
            }
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var foreground: Color {
        switch style {
        case .primary: QuickHaze.onAccent
        case .secondary: QuickHaze.accentText
        case .destructive: Color(red: 1, green: 0.62, blue: 0.58)
        }
    }
}

struct PanelIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(QuickHaze.textSecondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(QuickHaze.inset))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(Text(verbatim: label))
    }
}
