import AppKit
import AvoKeymap
import SwiftUI

// The key mapping editor's panel, beside the game in its window
// (KeymapEditorView, which does everything it asks; the game's picture
// moves over for it while the editor is open). Its Controls tab has what to
// do now, the layout's modes, the controls to add (a click puts one where
// that kind usually is, a drag puts it where it is let go on the game), the
// selected control's keys, modes and settings, how the key mapping shows on
// the game, and the layout's templates, import and export. Its Controller
// tab is the controller panel (ControllerPanel.swift). In the Quick
// Settings' haze look.

private func L(_ key: String.LocalizationValue) -> String { String(localized: key, bundle: .windowHost) }

/// A kind of control on the panel, to add.
enum KeymapPaletteItem: String, CaseIterable, Identifiable, Hashable {
    case tap, repeatTap, anchor, joystick, swipe
    case eye, ads, freeMouse, lockMouse
    case moveByMouse, smartCast
    case switchMode

    var id: String { rawValue }

    /// The panel's rows: buttons, shooters, then MOBAs and modes.
    static let rows: [[KeymapPaletteItem]] = [[.tap, .repeatTap, .anchor, .joystick, .swipe], [.eye, .ads, .freeMouse, .lockMouse],
                                               [.moveByMouse, .smartCast, .switchMode]]
    static let columns = 5

    /// Its word under its symbol on the panel.
    var caption: String {
        switch self {
        case .tap: L("Tap")
        case .repeatTap: L("Repeat")
        case .anchor: L("Anchor")
        case .joystick: L("Joystick")
        case .swipe: L("Swipe")
        case .eye: L("Eye")
        case .ads: L("Aim")
        case .freeMouse: L("Unlock")
        case .lockMouse: L("Lock")
        case .moveByMouse: L("Move")
        case .smartCast: L("Skill")
        case .switchMode: L("Switch")
        }
    }

    var title: String {
        switch self {
        case .tap: L("Tap")
        case .repeatTap: L("Repeat Tap")
        case .anchor: L("Anchor Tap")
        case .joystick: L("Joystick")
        case .swipe: L("Swipe")
        case .eye: L("Eye (Mouse Look)")
        case .ads: L("Aim Down Sights")
        case .freeMouse: L("Free the Mouse")
        case .lockMouse: L("Lock the Mouse")
        case .moveByMouse: L("Move by Mouse (MOBA)")
        case .smartCast: L("Smart Cast (MOBA)")
        case .switchMode: L("Switch Mode")
        }
    }

    var symbol: String {
        switch self {
        case .tap: "hand.tap"
        case .repeatTap: "repeat"
        case .anchor: "arrow.up.and.down.and.arrow.left.and.right"
        case .joystick: "dpad"
        case .swipe: "hand.draw"
        case .eye: "eye"
        case .ads: "scope"
        case .freeMouse: "cursorarrow"
        case .lockMouse: "lock"
        case .moveByMouse: "cursorarrow.motionlines"
        case .smartCast: "sparkles"
        case .switchMode: "arrow.triangle.2.circlepath"
        }
    }

    /// What it does, under the pointer.
    var help: String {
        switch self {
        case .tap: L("Tap: its key touches the game’s button while it is held.")
        case .repeatTap: L("Repeat Tap: taps again and again while its key is held.")
        case .anchor: L("Anchor Tap: while its key is held, the mouse moves the finger from its point, within a circle (emote wheels, aiming a skill).")
        case .joystick: L("Joystick: four keys (W A S D) or a controller’s stick push the game’s joystick.")
        case .swipe: L("Swipe: its key swipes from one point to another.")
        case .eye: L("Eye: with the mouse locked, moving the mouse turns the game’s camera. One per layout.")
        case .ads: L("Aim Down Sights: its button aims, and the eye turns at its aiming sensitivity meanwhile.")
        case .freeMouse: L("Free the Mouse: its key frees the mouse from the eye, for a map or an inventory.")
        case .lockMouse: L("Lock the Mouse: its key locks the mouse to the eye again.")
        case .moveByMouse: L("Move by Mouse: while its button is held, the joystick follows the cursor (MOBA).")
        case .smartCast: L("Smart Cast: its key drags the skill towards the cursor, and letting go casts (MOBA).")
        case .switchMode: L("Switch Mode: its key changes to another mode of the layout (in a vehicle, an inventory).")
        }
    }

    /// Freeing and locking the mouse are the eye's.
    var needsEye: Bool { self == .freeMouse || self == .lockMouse }

    /// What a control on the game is, as the panel's kinds: its help.
    static func item(for control: Control) -> KeymapPaletteItem? {
        switch control.kind {
        case .tap, .hold: .tap
        case .repeatTap: .repeatTap
        case .anchor: .anchor
        case .dpad: .joystick
        case .swipe: .swipe
        case .aim: .eye
        case .ads: .ads
        case .mouseLook(let lock, _): lock ? .lockMouse : .freeMouse
        case .mobaMove: .moveByMouse
        case .smartCast: .smartCast
        case .switchMode: .switchMode
        case .macro: nil
        }
    }
}

// MARK: - Model

/// What the panel shows, from the editor, which also does everything it asks.
@MainActor
final class KeymapEditorModel: ObservableObject {
    enum Tab: String, Hashable { case controls, controller }
    enum DragPhase { case moved, ended }

    struct Mode: Identifiable, Equatable {
        let id: String
        var name: String
        /// Its own controls, not counting those that act in every mode.
        var count: Int
    }

    /// The selected control, as the panel shows it.
    struct Selection: Equatable {
        var control: Control
        var title: String
        var symbol: String
        /// Its key or mouse button and its controller button, as they are written.
        var key: String?
        var pad: String?
        /// The eye's key, which locks and frees the mouse.
        var eyeKey: String?
        /// The joystick direction the next key sets: 0 up, 1 left, 2 down, 3 right.
        var dpadSlot: Int
    }

    @Published var tab = Tab.controls
    @Published var modes: [Mode] = []
    @Published var editingMode: String?
    /// The mode whose name is being typed in its tab.
    @Published var renaming: String?
    @Published var hasEye = false
    @Published var showOnGame = true
    @Published var hintOpacity = 0.75
    @Published var editorOpacity = 0.6
    /// The panel stands in a window of its own beside the game's (a card
    /// with rounded corners), not inside it at its edge.
    @Published var outside = false
    @Published var status = ""
    @Published var problem = false
    @Published var selection: Selection?

    // What the panel asks of the editor.
    var setTab: (Tab) -> Void = { _ in }
    var add: (KeymapPaletteItem) -> Void = { _ in }
    /// A control dragged from the panel, where the pointer is (the panel's coordinates).
    var drag: (KeymapPaletteItem, DragPhase, CGPoint) -> Void = { _, _, _ in }
    var chooseMode: (String) -> Void = { _ in }
    var addMode: () -> Void = {}
    /// The name typed for a mode; nil keeps its name.
    var rename: (String, String?) -> Void = { _, _ in }
    var modeMenu: (String) -> [HazeMenuEntry] = { _ in [] }
    var templates: () -> [HazeMenuEntry] = { [] }
    var importLayout: () -> Void = {}
    var exportLayout: () -> Void = {}
    var removeAll: () -> Void = {}
    var setShowOnGame: (Bool) -> Void = { _ in }
    var setHintOpacity: (Double) -> Void = { _ in }
    var setEditorOpacity: (Double) -> Void = { _ in }
    var cancel: () -> Void = {}
    var done: () -> Void = {}
    /// Changes the selected control.
    var update: ((inout Control) -> Void) -> Void = { _ in }
    /// The modes the selected control acts in; nil: every mode.
    var setActsIn: ([String]?) -> Void = { _ in }
    var setDPadSlot: (Int) -> Void = { _ in }
    var mouseButtons: () -> [HazeMenuEntry] = { [] }
    var remove: () -> Void = {}
    var deselect: () -> Void = {}
}

// MARK: - The panel

struct KeymapEditorPanel: View {
    /// The panel's coordinates: its hosting view's, y down from its top left.
    static let space = "avo.keymapEditorPanel"
    @ObservedObject var model: KeymapEditorModel
    @ObservedObject var controller: ControllerPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            QuickSegmented(label: L("Key mapping panel"),
                           options: [(KeymapEditorModel.Tab.controls, L("Controls")), (.controller, L("Controller"))],
                           selection: model.tab, fill: true) { model.setTab($0) }
            if !model.status.isEmpty { status }
            ScrollView(.vertical) {
                Group {
                    switch model.tab {
                    case .controls:
                        QuickRows(spacing: 14) {
                            ModesSection(model: model)
                            // The control just added or clicked, under the ones to add.
                            VStack(alignment: .leading, spacing: 14) {
                                PaletteSection(model: model)
                                if let selection = model.selection {
                                    InspectorCard(model: model, selection: selection)
                                }
                            }
                            DisplaySection(model: model)
                            LayoutSection(model: model)
                        }
                    case .controller:
                        ControllerPanelView(model: controller)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { QuickHaze.background }
        .clipShape(RoundedRectangle(cornerRadius: model.outside ? 12 : 0, style: .continuous))
        .overlay {
            if model.outside {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(QuickHaze.text.opacity(0.12))
            }
        }
        .overlay(alignment: .leading) {
            if !model.outside { Rectangle().fill(QuickHaze.text.opacity(0.12)).frame(width: 1) }
        }
        .environment(\.colorScheme, .dark)
        .coordinateSpace(name: Self.space)
        .coordinateSpace(name: ControllerPanelView.space)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(verbatim: L("Key Mapping"))
                .font(QuickHaze.hubot(15, 650))
                .foregroundStyle(QuickHaze.text)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 6)
            BarButton(title: L("Cancel"), style: .secondary) { model.cancel() }
                .help(L("Close without saving"))
            BarButton(title: L("Done"), style: .primary) { model.done() }
                .help(L("Save the key mapping and close the editor"))
        }
    }

    /// What to do now, or what just happened.
    private var status: some View {
        let yellow = Color(nsColor: .systemYellow)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: model.problem ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(model.problem ? yellow : QuickHaze.accent)
                .padding(.top, 1)
            Text(verbatim: model.status)
                .font(QuickHaze.mona(12))
                .foregroundStyle(model.problem ? yellow : QuickHaze.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(QuickHaze.inset))
        .accessibilityElement(children: .combine)
    }
}

/// A section's name over it, and its (?) when there is more to say.
private struct SectionLabel: View {
    let text: String
    var help: String?
    init(_ text: String, help: String? = nil) {
        self.text = text
        self.help = help
    }

    var body: some View {
        QuickLabel(text, help: help, font: QuickHaze.mona(11.5, 650), color: QuickHaze.sectionLabel)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The layout's modes as tabs, and + Mode.
private struct ModesSection: View {
    @ObservedObject var model: KeymapEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel(L("Modes"), help: L("A mode is another set of controls for another situation in the game (on foot, in a vehicle, an inventory). A Switch control changes to it with a key or a controller button."))
            FlowRows(spacing: 6) {
                ForEach(Array(model.modes.enumerated()), id: \.element.id) { index, mode in
                    ModeTab(model: model, mode: mode, starts: index == 0)
                }
                AddModeButton(model: model)
            }
        }
    }
}

/// The controls to add, a row for buttons, shooters, and MOBAs and modes.
private struct PaletteSection: View {
    @ObservedObject var model: KeymapEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel(L("Add a Control"),
                         help: L("Click one to add it, or drag it onto the game’s button. A tap is quickest: click the game’s button, then press its key."))
            ForEach(Array(KeymapPaletteItem.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row) { item in
                        PaletteTile(model: model, item: item)
                    }
                    ForEach(row.count..<KeymapPaletteItem.columns, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
            }
        }
    }
}

/// How the key mapping shows on the game, and how solid the editor is.
private struct DisplaySection: View {
    @ObservedObject var model: KeymapEditorModel

    var body: some View {
        let percent: FloatingPointFormatStyle<Double>.Percent = .percent.precision(.fractionLength(0))
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(L("Visibility"))
            QuickToggle(label: L("Show keys on game"), caption: L("The keys show on the game’s buttons while you play."), isOn: model.showOnGame) {
                model.setShowOnGame($0)
            }
            QuickSliderRow(label: L("Key visibility"), value: Text(model.hintOpacity, format: percent)) {
                QuickSlider(label: L("Key visibility"),
                            value: Binding(get: { model.hintOpacity }, set: { model.setHintOpacity($0) }),
                            range: KeymapHints.opacityRange, step: 0.05, valueText: Text(model.hintOpacity, format: percent))
            }
            .allowsHitTesting(model.showOnGame)
            .opacity(model.showOnGame ? 1 : 0.4)
            QuickSliderRow(label: L("Editor opacity"), value: Text(model.editorOpacity, format: percent),
                           help: L("Lower it to see the game through the editor while you put controls on its buttons.")) {
                QuickSlider(label: L("Editor opacity"),
                            value: Binding(get: { model.editorOpacity }, set: { model.setEditorOpacity($0) }),
                            range: KeymapEditorView.opacityRange, step: 0.05, valueText: Text(model.editorOpacity, format: percent))
            }
        }
    }
}

/// Templates, import, export, and removing everything.
private struct LayoutSection: View {
    @ObservedObject var model: KeymapEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(L("Layout"))
            HazeMenuButton(matchesWidth: true, entries: { model.templates() }) {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 11, weight: .bold))
                    Text(verbatim: L("Templates")).font(QuickHaze.mona(12.5, 650)).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(QuickHaze.textTertiary)
                }
                .foregroundStyle(QuickHaze.accentText)
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(QuickHaze.inset))
                .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(QuickHaze.accent.opacity(0.3)) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Starting layouts for shooters, MOBAs, racing games and platformers"))
            HStack(spacing: 6) {
                PanelButton(title: L("Import…"), symbol: "square.and.arrow.down", style: .secondary, fill: true) { model.importLayout() }
                PanelButton(title: L("Export…"), symbol: "square.and.arrow.up", style: .secondary, fill: true) { model.exportLayout() }
            }
            PanelButton(title: L("Remove All Controls"), symbol: "trash", style: .destructive, fill: true) { model.removeAll() }
        }
    }
}

/// Lines of views as wide as they are, a new line where one would not fit.
private struct FlowRows: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(subviews, width: proposal.width ?? .infinity)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + spacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in line.views {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }

    private func lines(_ subviews: Subviews, width: CGFloat) -> [(views: [Int], width: CGFloat, height: CGFloat)] {
        var lines: [(views: [Int], width: CGFloat, height: CGFloat)] = []
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if let last = lines.last, !last.views.isEmpty, last.width + spacing + size.width <= width {
                lines[lines.count - 1] = (last.views + [index], last.width + spacing + size.width, max(last.height, size.height))
            } else {
                lines.append(([index], size.width, size.height))
            }
        }
        return lines
    }
}

/// A control to add: a click adds it where that kind usually is, a drag
/// puts it where it is let go on the game.
private struct PaletteTile: View {
    @ObservedObject var model: KeymapEditorModel
    let item: KeymapPaletteItem
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        let enabled = !item.needsEye || model.hasEye
        let lit = hovering && enabled
        VStack(spacing: 3) {
            Image(systemName: item.symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(height: 17)
            Text(verbatim: item.caption)
                .font(QuickHaze.mona(10, 550))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(enabled ? (lit ? QuickHaze.accentText : QuickHaze.textSecondary) : QuickHaze.textTertiary.opacity(0.45))
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(lit ? QuickHaze.selection : QuickHaze.inset))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(QuickHaze.text.opacity(lit ? 0.2 : 0.06))
        }
        .scaleEffect(dragging ? 0.9 : 1)
        .animation(.easeOut(duration: 0.12), value: lit)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(enabled ? item.help + "\n" + L("Click to add it, or drag it onto the game’s button.")
                      : item.help + "\n" + L("Add the eye (mouse look) first."))
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(KeymapEditorPanel.space))
            .onChanged { drag in
                guard enabled else { return }
                dragging = true
                model.drag(item, .moved, drag.location)
            }
            .onEnded { drag in
                guard enabled else { return }
                dragging = false
                model.drag(item, .ended, drag.location)
            })
        .simultaneousGesture(TapGesture().onEnded {
            if enabled { model.add(item) }
        })
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: item.title))
        .accessibilityHint(Text(verbatim: item.help))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if enabled { model.add(item) }
        }
    }
}

/// A mode of the layout: a click edits it, a click on the one being edited
/// (or a right click) shows its menu, and its name is typed in place.
private struct ModeTab: View {
    @ObservedObject var model: KeymapEditorModel
    let mode: KeymapEditorModel.Mode
    /// The game starts in it.
    let starts: Bool
    @State private var anchor = HazeMenuAnchorBox()
    @State private var name = ""
    @FocusState private var typing: Bool

    var body: some View {
        if model.renaming == mode.id {
            TextField(L("Name"), text: $name)
                .textFieldStyle(.plain)
                .font(QuickHaze.mona(12.5, 600))
                .foregroundStyle(QuickHaze.text)
                .frame(width: 120)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(Color.black.opacity(0.45)))
                .overlay(Capsule().strokeBorder(QuickHaze.accent, lineWidth: 1.5))
                .focused($typing)
                .onSubmit { model.rename(mode.id, name) }
                .onExitCommand { model.rename(mode.id, nil) }
                .onAppear {
                    name = mode.name
                    typing = true
                }
                .onChange(of: typing) { _, focused in
                    if !focused { model.rename(mode.id, name) }
                }
                .accessibilityLabel(Text(verbatim: L("The mode’s name")))
        } else {
            let selected = model.editingMode == mode.id
            Button {
                if selected, let view = anchor.view {
                    HazeMenuPresenter.shared.show(model.modeMenu(mode.id), below: view)
                } else {
                    model.chooseMode(mode.id)
                }
            } label: {
                label(selected: selected)
            }
            .buttonStyle(.plain)
            .background(HazeMenuAnchor(anchor))
            .hazeContextMenu { model.modeMenu(mode.id) }
            .help(starts ? L("The game starts in this mode. Its own controls: \(mode.count). Click it again for its menu.")
                         : L("Its own controls: \(mode.count). Click it again for its menu."))
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    private func label(selected: Bool) -> some View {
        HStack(spacing: 5) {
            if starts {
                Image(systemName: "flag.fill").font(.system(size: 8.5, weight: .bold))
            }
            Text(verbatim: mode.name)
                .font(QuickHaze.mona(12.5, selected ? 650 : 500))
                .lineLimit(1)
            Text(verbatim: "\(mode.count)")
                .font(QuickHaze.mona(10.5, 650))
                .monospacedDigit()
                .padding(.horizontal, 5)
                .frame(minWidth: 17, minHeight: 15)
                .background(Capsule().fill(selected ? QuickHaze.onAccent.opacity(0.15) : Color.white.opacity(0.08)))
            if selected {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7)
            }
        }
        .foregroundStyle(selected ? QuickHaze.onAccent : QuickHaze.textSecondary)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(selected ? QuickHaze.accent : QuickHaze.inset))
        .overlay(Capsule().strokeBorder(QuickHaze.text.opacity(selected ? 0 : 0.1)))
        .contentShape(Capsule())
    }
}

private struct AddModeButton: View {
    @ObservedObject var model: KeymapEditorModel

    var body: some View {
        Button { model.addMode() } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                Text(verbatim: model.modes.isEmpty ? L("Add Mode") : L("Mode")).font(QuickHaze.mona(12, 600)).lineLimit(1)
            }
            .foregroundStyle(QuickHaze.accentText)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(QuickHaze.accent.opacity(0.08)))
            .overlay(Capsule().strokeBorder(QuickHaze.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L("A mode is another set of controls for another situation in the game (on foot, in a vehicle, an inventory). A Switch control changes to it with a key or a controller button."))
        .accessibilityLabel(Text(verbatim: L("Add Mode")))
    }
}

// MARK: - The selected control

private struct InspectorCard: View {
    @ObservedObject var model: KeymapEditorModel
    let selection: KeymapEditorModel.Selection
    @State private var showsHelp = false

    var body: some View {
        let help = KeymapPaletteItem.item(for: selection.control)?.help
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: selection.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(QuickHaze.onAccent)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(QuickHaze.accent))
                Text(verbatim: selection.title)
                    .font(QuickHaze.hubot(14.5, 650))
                    .foregroundStyle(QuickHaze.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let help { QuickHelpButton(help: help, shown: $showsHelp) }
                Spacer(minLength: 6)
                BarIconButton(symbol: "trash", label: L("Remove"), destructive: true) { model.remove() }
                BarIconButton(symbol: "xmark", label: L("Deselect")) { model.deselect() }
            }
            if showsHelp, let help { QuickCaption(help) }
            QuickRows(spacing: 9) {
                keys
                InspectorSettings(model: model, selection: selection)
                if !model.modes.isEmpty { worksIn }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(QuickHaze.card))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(QuickHaze.accent.opacity(0.28)) }
        .accessibilityElement(children: .contain)
    }

    /// Its key and controller button ("Press a key" while it has none), and
    /// a mouse button or the wheel instead; the eye's is the mouse lock.
    @ViewBuilder private var keys: some View {
        switch selection.control.kind {
        case .dpad:
            EmptyView()
        case .aim:
            InspectorRow(label: L("Mouse lock key")) {
                KeyCap(text: selection.eyeKey ?? L("Press a key"), symbol: "lock", waiting: selection.eyeKey == nil)
                    .help(L("The key that locks the mouse to the eye, and frees it again. Press another key to change it."))
                Spacer(minLength: 0)
            }
        default:
            InspectorRow(label: L("Key")) {
                HStack(spacing: 4) {
                    if let key = selection.key { KeyCap(text: key) }
                    if let pad = selection.pad { KeyCap(text: pad, symbol: "gamecontroller") }
                    if selection.key == nil, selection.pad == nil { KeyCap(text: L("Press a key"), waiting: true) }
                }
                Spacer(minLength: 4)
                HazeMenuButton(entries: { model.mouseButtons() }) {
                    BarLabel(title: nil, symbol: "computermouse")
                }
                .buttonStyle(.plain)
                .help(L("Use a mouse button or the wheel instead of a key"))
                .accessibilityLabel(Text(verbatim: L("Mouse button")))
            }
        }
    }

    /// The modes it works in: every mode, or some.
    private var worksIn: some View {
        let own = selection.control.modes
        return InspectorRow(label: L("Works in"), help: L("The modes this control works in.")) {
            FlowRows(spacing: 5) {
                Chip(title: L("Every mode"), on: own == nil) {
                    if own != nil { model.setActsIn(nil) }
                }
                ForEach(model.modes) { mode in
                    Chip(title: mode.name, on: own?.contains(mode.id) == true) {
                        var modes = own ?? []
                        if let at = modes.firstIndex(of: mode.id) { modes.remove(at: at) } else { modes.append(mode.id) }
                        // In the layout's order, and never none.
                        let ordered = model.modes.map(\.id).filter(modes.contains)
                        if !ordered.isEmpty { model.setActsIn(ordered) }
                    }
                }
            }
        }
    }
}

/// The settings of the selected control's kind, each its own row of the
/// inspector (the ones that belong together in one).
private struct InspectorSettings: View {
    @ObservedObject var model: KeymapEditorModel
    let selection: KeymapEditorModel.Selection

    var body: some View {
        let control = selection.control
        if let item = control.buttonItem { kind(control, item) }
        switch control.kind {
        case .repeatTap(_, let interval):
            VStack(alignment: .leading, spacing: 6) {
                slider(L("Repeat every"), Binding(get: { Double(interval) }, set: { value in model.update { $0.setRepeatInterval(Int(value)) } }),
                       50...1000, step: 10, text: L("\(interval) ms"))
                if model.hasEye {
                    caption(L("Repeated taps are not allowed with the eye (no automatic rapid fire): Done won’t save until you change this."), problem: true)
                }
            }
        case .anchor(_, let radius):
            VStack(alignment: .leading, spacing: 9) {
                InspectorRow(label: L("Finger reach"), help: L("How far the mouse may move the finger from its point.")) {
                    QuickSegmented(label: L("Finger reach"), options: [(true, L("In a circle")), (false, L("Whole screen"))],
                                   selection: radius != nil, fill: true) { circle in
                        model.update { $0.setAnchorReach(circle ? Control.defaultAnchorRadius : nil) }
                    }
                }
                if let radius {
                    slider(L("Circle size"), Binding(get: { radius }, set: { value in model.update { $0.setAnchorReach(value) } }),
                           Control.anchorRadiusRange, step: 0.01, text: percent(radius))
                }
            }
        case let .dpad(_, radius, up, down, left, right, _):
            InspectorRow(label: L("Keys")) {
                HStack(spacing: 5) {
                    ForEach(Array([(up, "arrow.up"), (left, "arrow.left"), (down, "arrow.down"), (right, "arrow.right")].enumerated()),
                            id: \.offset) { slot, entry in
                        Button { model.setDPadSlot(slot) } label: {
                            KeyCap(text: entry.0.shortLabel, symbol: entry.1, active: slot == selection.dpadSlot)
                        }
                        .buttonStyle(.plain)
                        .help(L("Click it, then press the key for this direction"))
                    }
                }
            }
            slider(L("Size"), Binding(get: { radius }, set: { value in model.update { $0.setJoystickRadius(value) } }),
                   0.04...0.45, step: 0.01, text: percent(radius))
            VStack(alignment: .leading, spacing: 9) {
                InspectorRow(label: L("Run key"), help: L("Hold it to push the joystick further, for games that run when it is pushed all the way. Click the key, then press another to change it.")) {
                    Button { model.setDPadSlot(4) } label: {
                        KeyCap(text: control.run?.trigger.shortLabel ?? L("No key"), symbol: "figure.run", active: selection.dpadSlot == 4)
                    }
                    .buttonStyle(.plain)
                    .help(L("Click it, then press the key to hold for running (Shift, for example)."))
                    Spacer(minLength: 4)
                    if control.run != nil {
                        BarIconButton(symbol: "xmark", label: L("No run key")) { model.update { $0.run = nil } }
                    }
                }
                if let run = control.run {
                    slider(L("Running reach"), Binding(get: { run.scale }, set: { value in model.update { $0.run?.scale = value } }),
                           JoystickRun.scaleRange, step: 0.05, text: percent(run.scale),
                           help: L("How far the joystick is pushed while the run key is held, compared with its size."))
                }
            }
        case .swipe(_, _, let ms):
            slider(L("Duration"), Binding(get: { Double(ms) }, set: { value in model.update { $0.setSwipeDuration(Int(value)) } }),
                   30...1000, step: 10, text: L("\(ms) ms"))
        case let .aim(_, sensitivity, aiming, _, _, invertY, _, origin):
            VStack(alignment: .leading, spacing: 9) {
                slider(L("Sensitivity"), Binding(get: { sensitivity.x }, set: { value in model.update { $0.setEye(sensitivity: value) } }),
                       0.1...5, step: 0.05, text: times(sensitivity.x))
                slider(L("Aiming sensitivity"), Binding(get: { aiming.x }, set: { value in model.update { $0.setEye(aiming: value) } }),
                       0.1...5, step: 0.05, text: times(aiming.x), help: L("How fast the eye turns while Aim Down Sights is held."))
            }
            InspectorRow(label: L("Vertical look")) {
                QuickSegmented(label: L("Vertical look"), options: [(false, L("Normal")), (true, L("Inverted"))], selection: invertY, fill: true) { inverted in
                    model.update { $0.setEye(invertY: inverted) }
                }
            }
            InspectorRow(label: L("Swipe area"), help: L("Where the finger swipes to turn the camera. While the eye is selected, drag the area or its edges on the game.")) {
                HStack(spacing: 6) {
                    SmallButton(title: L("Full height")) {
                        model.update { control in
                            guard let area = control.fingerArea else { return }
                            let full = Control.defaultEyeArea
                            control.setFingerArea(NormalizedRect(area.minX, full.minY, area.maxX, full.maxY))
                        }
                    }
                    SmallButton(title: L("Right side")) { model.update { $0.setFingerArea(Control.defaultEyeArea) } }
                    if origin != nil {
                        SmallButton(title: L("Touch in the middle")) { model.update { $0.setTouchPoint(nil) } }
                    }
                }
            }
        case .ads(_, let toggle):
            InspectorRow(label: L("Aiming"), help: L("Hold to aim: it aims while the key is held. Press to toggle: one press aims, the next stops.")) {
                QuickSegmented(label: L("Aiming"), options: [(false, L("Hold to aim")), (true, L("Press to toggle"))], selection: toggle, fill: true) { on in
                    model.update { $0.setADSToggle(on) }
                }
            }
        case .mobaMove(_, let radius):
            slider(L("Size"), Binding(get: { radius }, set: { value in model.update { $0.setJoystickRadius(value) } }),
                   0.04...0.45, step: 0.01, text: percent(radius))
        case let .smartCast(_, radius, reach):
            slider(L("Drag distance"), Binding(get: { radius }, set: { value in model.update { $0.setCast(radius: value) } }),
                   0.03...0.45, step: 0.01, text: percent(radius), help: L("How far the skill button is dragged."))
            slider(L("Cursor range"), Binding(get: { reach }, set: { value in model.update { $0.setCast(reach: value) } }),
                   Control.castReachRange, step: 0.05, text: percent(reach), help: L("How far from your hero the cursor must be for a full drag."))
        case .switchMode(let target, _):
            if !model.modes.isEmpty {
                InspectorRow(label: L("Switches to")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        QuickSegmented(label: L("Switches to"), options: model.modes.map { ($0.id, $0.name) }, selection: target) { mode in
                            model.update { $0.setSwitchTarget(mode) }
                        }
                    }
                }
            }
        case .mouseLook(let lock, _):
            InspectorRow(label: L("Action")) {
                QuickSegmented(label: L("Action"), options: [(false, L("Free the mouse")), (true, L("Lock the mouse"))], selection: lock, fill: true) { on in
                    model.update { $0.setMouseLock(on) }
                }
            }
        case .tap, .hold, .macro:
            EmptyView()
        }
    }

    /// Tap, Repeat, Anchor or Aim: the same button, another kind. The wheel
    /// only taps, and the eye allows no repeated taps.
    private func kind(_ control: Control, _ item: KeymapPaletteItem) -> some View {
        let wheel = control.allTriggers.contains(where: \.isMomentary)
        let eye = model.hasEye
        return InspectorRow(label: L("Type")) {
            QuickSegmented(label: L("Type"), options: [(KeymapPaletteItem.tap, L("Tap")), (.repeatTap, L("Repeat")), (.anchor, L("Anchor")), (.ads, L("Aim"))],
                           selection: item, fill: true,
                           help: { option in option.help },
                           enabled: { option in
                               if wheel { return option == .tap }
                               return option != .repeatTap || !eye
                           }) { option in
                model.update { $0.convert(to: option) }
            }
        }
    }

    /// A slider: its name (and its ?) and value on one line, the slider under them.
    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double, text: String,
                        help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                QuickLabel(label, help: help, font: QuickHaze.mona(12, 600), color: QuickHaze.textSecondary)
                Spacer(minLength: 6)
                Text(verbatim: text).font(QuickHaze.mona(12, 600)).foregroundStyle(QuickHaze.textSecondary).monospacedDigit()
            }
            QuickSlider(label: label, value: value, range: range, step: step, valueText: Text(verbatim: text))
        }
    }

    private func caption(_ text: String, problem: Bool = false) -> some View {
        Text(verbatim: text)
            .font(QuickHaze.mona(11.5))
            .foregroundStyle(problem ? Color(nsColor: .systemYellow) : QuickHaze.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    private func times(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2))) + "×"
    }
}

/// A setting of the selected control: its name (and its ?) over its control.
private struct InspectorRow<Content: View>: View {
    let label: String
    var help: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            QuickLabel(label, help: help, font: QuickHaze.mona(12, 600), color: QuickHaze.textSecondary)
            HStack(spacing: 8) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Pieces

/// A key as it is written on it.
private struct KeyCap: View {
    let text: String
    var symbol: String?
    /// No key yet: the editor waits for one.
    var waiting = false
    /// The direction the next key sets.
    var active = false

    var body: some View {
        let yellow = Color(nsColor: .systemYellow)
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8.5, weight: .bold)) }
            Text(verbatim: text).font(QuickHaze.mona(12, 650)).lineLimit(1)
        }
        .foregroundStyle(active ? QuickHaze.onAccent : waiting ? yellow : QuickHaze.text)
        .padding(.horizontal, 7)
        .frame(minWidth: 24, minHeight: 22)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(active ? yellow : Color.white.opacity(waiting ? 0.04 : 0.1)))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(waiting ? yellow.opacity(0.7) : QuickHaze.text.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: waiting ? [3, 2] : []))
        }
        .fixedSize()
    }
}

/// On or off, among others (the modes a control acts in).
private struct Chip: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if on { Image(systemName: "checkmark").font(.system(size: 8.5, weight: .heavy)) }
                Text(verbatim: title).font(QuickHaze.mona(12, on ? 620 : 500)).lineLimit(1)
            }
            .foregroundStyle(on ? QuickHaze.accentText : QuickHaze.textSecondary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(on ? QuickHaze.segmentSelection : QuickHaze.inset))
            .overlay(Capsule().strokeBorder(on ? QuickHaze.accent.opacity(0.45) : QuickHaze.text.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct SmallButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(QuickHaze.mona(12, 600))
                .foregroundStyle(QuickHaze.accentText)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(QuickHaze.inset))
                .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(QuickHaze.accent.opacity(0.25)) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct BarButton: View {
    enum Style { case primary, secondary }
    let title: String
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(QuickHaze.mona(12.5, 650))
                .foregroundStyle(style == .primary ? QuickHaze.onAccent : QuickHaze.accentText)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(style == .primary ? QuickHaze.accent : QuickHaze.inset))
                .overlay {
                    if style == .secondary {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(QuickHaze.accent.opacity(0.3))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A bar button's look, for menus and toggles: lit while `on`.
private struct BarLabel: View {
    let title: String?
    let symbol: String
    var on = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold))
            if let title { Text(verbatim: title).font(QuickHaze.mona(12.5, 600)).lineLimit(1) }
        }
        .foregroundStyle(on ? QuickHaze.onAccent : QuickHaze.accentText)
        .padding(.horizontal, title == nil ? 0 : 10)
        .frame(minWidth: 28, minHeight: 28)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? QuickHaze.accent : QuickHaze.inset))
        .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(QuickHaze.text.opacity(on ? 0 : 0.08)) }
        .contentShape(Rectangle())
    }
}

private struct BarIconButton: View {
    let symbol: String
    let label: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(destructive ? QuickHaze.danger : QuickHaze.textSecondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(destructive ? QuickHaze.dangerFill : QuickHaze.inset))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(Text(verbatim: label))
    }
}

// MARK: - Control changes the inspector makes

extension Control {
    /// Where a button (tap, hold, repeat, anchor, aim down sights) touches.
    var buttonPoint: NormalizedPoint? {
        switch kind {
        case .tap(let p), .hold(let p), .repeatTap(let p, _), .anchor(let p, _), .ads(let p, _): p
        default: nil
        }
    }

    /// Which of them it is, as the inspector's Kind row says.
    var buttonItem: KeymapPaletteItem? {
        switch kind {
        case .tap, .hold: .tap
        case .repeatTap: .repeatTap
        case .anchor: .anchor
        case .ads: .ads
        default: nil
        }
    }

    /// The same button as another kind, where it is, with its keys.
    mutating func convert(to item: KeymapPaletteItem) {
        guard let p = buttonPoint, buttonItem != item else { return }
        switch item {
        case .tap: kind = .tap(p)
        case .repeatTap: kind = .repeatTap(p, intervalMilliseconds: 150)
        case .anchor: kind = .anchor(p, radius: Control.defaultAnchorRadius)
        case .ads: kind = .ads(p, toggle: false)
        default: break
        }
    }

    mutating func setRepeatInterval(_ milliseconds: Int) {
        if case .repeatTap(let p, _) = kind { kind = .repeatTap(p, intervalMilliseconds: milliseconds) }
    }

    mutating func setSwipeDuration(_ milliseconds: Int) {
        if case let .swipe(from, to, _) = kind { kind = .swipe(from: from, to: to, milliseconds: milliseconds) }
    }

    /// nil: the finger may go anywhere on the screen.
    mutating func setAnchorReach(_ radius: Double?) {
        if case .anchor(let p, _) = kind { kind = .anchor(p, radius: radius) }
    }

    /// A joystick's radius, or a MOBA joystick's.
    mutating func setJoystickRadius(_ radius: Double) {
        switch kind {
        case let .dpad(center, _, up, down, left, right, stick):
            kind = .dpad(center: center, radius: radius, up: up, down: down, left: left, right: right, stick: stick)
        case .mobaMove(let center, _):
            kind = .mobaMove(center: center, radius: radius)
        default:
            break
        }
    }

    mutating func setCast(radius: Double? = nil, reach: Double? = nil) {
        if case let .smartCast(p, oldRadius, oldReach) = kind { kind = .smartCast(p, radius: radius ?? oldRadius, reach: reach ?? oldReach) }
    }

    mutating func setADSToggle(_ toggle: Bool) {
        if case .ads(let p, _) = kind { kind = .ads(p, toggle: toggle) }
    }

    mutating func setSwitchTarget(_ mode: String) {
        if case .switchMode(_, let p) = kind { kind = .switchMode(mode, position: p) }
    }

    mutating func setMouseLock(_ lock: Bool) {
        if case .mouseLook(_, let p) = kind { kind = .mouseLook(lock: lock, position: p) }
    }

    /// The eye's sensitivity, its sensitivity while aiming down sights (both
    /// axes alike), and whether up and down are the other way round.
    mutating func setEye(sensitivity: Double? = nil, aiming: Double? = nil, invertY: Bool? = nil) {
        guard case let .aim(area, oldSensitivity, oldAiming, exponent, deadzone, oldInvertY, stick, origin) = kind else { return }
        kind = .aim(area: area, sensitivity: sensitivity.map { AxisPair(x: $0, y: $0) } ?? oldSensitivity,
                    adsSensitivity: aiming.map { AxisPair(x: $0, y: $0) } ?? oldAiming, exponent: exponent, deadzone: deadzone,
                    invertY: invertY ?? oldInvertY, stick: stick, origin: origin)
    }
}
