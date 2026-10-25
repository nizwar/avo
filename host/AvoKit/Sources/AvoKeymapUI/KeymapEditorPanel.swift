import AppKit
import AvoHazeUI
import AvoKeymap
import AvoKit
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

private func L(_ key: String.LocalizationValue) -> String { String(localized: key, bundle: .avoKit) }

/// The kinds of controls, as the panel groups them: for every game, for
/// shooters, for MOBAs.
enum KeymapCategory: String, CaseIterable, Identifiable, Hashable {
    case general, fps, moba

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L("General")
        case .fps: L("FPS")
        case .moba: L("MOBA")
        }
    }

    /// Its controls on the panel, in their order.
    var items: [KeymapPaletteItem] { KeymapPaletteItem.allCases.filter { $0.category == self } }
}

/// A kind of control on the panel, to add.
enum KeymapPaletteItem: String, CaseIterable, Identifiable, Hashable {
    case tap, repeatTap, anchor, joystick, swipe, scrollBar, clickArea, hotkey
    case eye, ads
    case moveByMouse, smartCast

    var id: String { rawValue }

    static let columns = 4

    var category: KeymapCategory {
        switch self {
        case .tap, .repeatTap, .anchor, .joystick, .swipe, .scrollBar, .clickArea, .hotkey: .general
        case .eye, .ads: .fps
        case .moveByMouse, .smartCast: .moba
        }
    }

    /// Its word under its symbol on the panel.
    var caption: String {
        switch self {
        case .tap: L("Tap")
        case .repeatTap: L("Repeat")
        case .anchor: L("Anchor")
        case .joystick: L("Joystick")
        case .swipe: L("Swipe")
        case .scrollBar: L("Scroll")
        case .clickArea: L("Click Area")
        case .hotkey: L("Hotkey")
        case .eye: L("Eye")
        case .ads: L("Aim")
        case .moveByMouse: L("Move")
        case .smartCast: L("Skill")
        }
    }

    var title: String {
        switch self {
        case .tap: L("Tap")
        case .repeatTap: L("Repeat Tap")
        case .anchor: L("Anchor Tap")
        case .joystick: L("Joystick")
        case .swipe: L("Swipe")
        case .scrollBar: L("Scroll Bar")
        case .clickArea: L("Click Area")
        case .hotkey: L("Hotkey")
        case .eye: L("Eye (Mouse Look)")
        case .ads: L("Aim Down Sights")
        case .moveByMouse: L("Move by Mouse (MOBA)")
        case .smartCast: L("Smart Cast (MOBA)")
        }
    }

    var symbol: String {
        switch self {
        case .tap: "hand.tap"
        case .repeatTap: "repeat"
        case .anchor: "arrow.up.and.down.and.arrow.left.and.right"
        case .joystick: "dpad"
        case .swipe: "hand.draw"
        case .scrollBar: "slider.vertical.3"
        case .clickArea: "cursorarrow.click.2"
        case .hotkey: "keyboard"
        case .eye: "eye"
        case .ads: "scope"
        case .moveByMouse: "cursorarrow.motionlines"
        case .smartCast: "sparkles"
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
        case .scrollBar: L("Scroll Bar: the wheel drags the thumb of a slider of the game (a map’s zoom) a step a notch, within its ends.")
        case .clickArea: L("Click Area: a part of the game that, clicked while the mouse is free, does its actions (back to combat when you close the inventory).")
        case .hotkey: L("Hotkey: a key that touches nothing, only does its actions (switch the mode, free the mouse).")
        case .eye: L("Eye: with the mouse locked, moving the mouse turns the game’s camera. One per layout.")
        case .ads: L("Aim Down Sights: its button aims, and the eye turns at its aiming sensitivity meanwhile.")
        case .moveByMouse: L("Move by Mouse: while its button is held, the joystick follows the cursor (MOBA).")
        case .smartCast: L("Smart Cast: its key drags the skill towards the cursor, and letting go casts (MOBA).")
        }
    }

    /// What a control on the game is, as the panel's kinds: its help.
    static func item(for control: Control) -> KeymapPaletteItem? {
        switch control.kind {
        case .tap, .hold: .tap
        case .repeatTap: .repeatTap
        case .anchor: .anchor
        case .dpad: .joystick
        case .swipe: .swipe
        case .scrollBar: .scrollBar
        case .clickArea: .clickArea
        case .hotkey: .hotkey
        case .aim: .eye
        case .ads: .ads
        case .mobaMove: .moveByMouse
        case .smartCast: .smartCast
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

    /// A control of the mode being edited, as the panel lists it.
    struct Listed: Identifiable, Equatable {
        let id: String
        var title: String
        var symbol: String
        /// Its keys as they are written ("F", "W A S D"); nil without one.
        var keys: String?
        var category: KeymapCategory
        var actions: [ControlAction]
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
    /// The controls of the mode being edited, the hotkeys among them.
    @Published var listed: [Listed] = []
    /// The kind of controls the panel offers to add.
    @Published var category = KeymapCategory.general

    // What the panel asks of the editor.
    var setTab: (Tab) -> Void = { _ in }
    var setCategory: (KeymapCategory) -> Void = { _ in }
    /// Selects a control from the list.
    var select: (String) -> Void = { _ in }
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
    /// Gives the selected control a click zone around its button, or takes it away.
    var setClickZone: (Bool) -> Void = { _ in }
    var mouseButtons: () -> [HazeMenuEntry] = { [] }
    /// The actions to add to the selected control.
    var addActionMenu: () -> [HazeMenuEntry] = { [] }
    /// The modes its switch at this index may go to instead.
    var switchTargets: (Int) -> [HazeMenuEntry] = { _ in [] }
    /// Moves its action at an index up (-1) or down (+1).
    var moveAction: (Int, Int) -> Void = { _, _ in }
    var removeAction: (Int) -> Void = { _ in }
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
                            if !model.listed.isEmpty { ControlListSection(model: model) }
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
            SectionLabel(L("Modes"), help: L("A mode is another set of controls for another situation in the game (on foot, in a vehicle, an inventory). A control’s Switch Mode action changes to it."))
            FlowRows(spacing: 6) {
                ForEach(Array(model.modes.enumerated()), id: \.element.id) { index, mode in
                    ModeTab(model: model, mode: mode, starts: index == 0)
                }
                AddModeButton(model: model)
            }
        }
    }
}

/// The controls to add, by the kind of game: General, FPS, MOBA.
private struct PaletteSection: View {
    @ObservedObject var model: KeymapEditorModel

    var body: some View {
        let items = model.category.items
        let rows = stride(from: 0, to: items.count, by: KeymapPaletteItem.columns).map {
            Array(items[$0..<min($0 + KeymapPaletteItem.columns, items.count)])
        }
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel(L("Add a Control"),
                         help: L("Click one to add it, or drag it onto the game’s button. A tap is quickest: click the game’s button, then press its key."))
            QuickSegmented(label: L("Kind of control"), options: KeymapCategory.allCases.map { ($0, $0.title) },
                           selection: model.category, fill: true) { model.setCategory($0) }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
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

/// The controls of the mode being edited by kind, each with its keys and
/// what it does besides its touch: a click selects it (the only way to
/// a hotkey, which has no place on the game).
private struct ControlListSection: View {
    @ObservedObject var model: KeymapEditorModel
    @AppStorage("AvoKeymapControlListShown") private var shown = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { shown.toggle() } label: {
                HStack(spacing: 5) {
                    Text(verbatim: L("Controls"))
                        .font(QuickHaze.mona(11.5, 650))
                        .foregroundStyle(QuickHaze.sectionLabel)
                    Text(verbatim: "\(model.listed.count)")
                        .font(QuickHaze.mona(10.5, 650))
                        .monospacedDigit()
                        .foregroundStyle(QuickHaze.textTertiary)
                    Spacer(minLength: 4)
                    Image(systemName: shown ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(QuickHaze.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(shown ? L("Hide the list of controls") : L("Show the list of controls"))
            .accessibilityAddTraits(.isHeader)
            if shown {
                ForEach(KeymapCategory.allCases) { category in
                    let rows = model.listed.filter { $0.category == category }
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: category.title)
                                .font(QuickHaze.mona(10.5, 600))
                                .foregroundStyle(QuickHaze.textTertiary)
                                .padding(.leading, 2)
                                .padding(.bottom, 1)
                            ForEach(rows) { row in
                                ControlListRow(model: model, row: row, selected: model.selection?.control.id == row.id)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ControlListRow: View {
    @ObservedObject var model: KeymapEditorModel
    let row: KeymapEditorModel.Listed
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        Button { model.select(row.id) } label: {
            HStack(spacing: 7) {
                Image(systemName: row.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18)
                Text(verbatim: row.title)
                    .font(QuickHaze.mona(12, selected ? 620 : 500))
                    .lineLimit(1)
                if let keys = row.keys { KeyCap(text: keys) } else { KeyCap(text: "?", waiting: true) }
                Spacer(minLength: 4)
                ForEach(Array(row.actions.enumerated()), id: \.offset) { _, action in
                    Image(systemName: action.symbol)
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(QuickHaze.accentText)
                }
            }
            .foregroundStyle(selected ? QuickHaze.text : QuickHaze.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? QuickHaze.selection : hovering ? QuickHaze.inset : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
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
        let lit = hovering
        VStack(spacing: 3) {
            Image(systemName: item.symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(height: 17)
            Text(verbatim: item.caption)
                .font(QuickHaze.mona(10, 550))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(lit ? QuickHaze.accentText : QuickHaze.textSecondary)
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
        .help(item.help + "\n" + (item == .hotkey ? L("Click to add it: it shows in the list of controls, not on the game.")
                                                   : L("Click to add it, or drag it onto the game’s button.")))
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(KeymapEditorPanel.space))
            .onChanged { drag in
                dragging = true
                model.drag(item, .moved, drag.location)
            }
            .onEnded { drag in
                dragging = false
                model.drag(item, .ended, drag.location)
            })
        .simultaneousGesture(TapGesture().onEnded { model.add(item) })
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: item.title))
        .accessibilityHint(Text(verbatim: item.help))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.add(item) }
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
        .help(L("A mode is another set of controls for another situation in the game (on foot, in a vehicle, an inventory). A control’s Switch Mode action changes to it."))
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
                if selection.control.canCarryActions { ActionsSection(model: model, control: selection.control) }
                if selection.control.canHaveClickZone { ClickZoneSection(model: model, control: selection.control) }
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
        case .dpad, .clickArea:
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
        case let .scrollBar(_, _, rest, step):
            let vertical = control.isVerticalScrollBar
            InspectorRow(label: L("Direction")) {
                QuickSegmented(label: L("Direction"), options: [(true, L("Up and down")), (false, L("Across"))], selection: vertical,
                               fill: true) { on in model.update { $0.setScrollBar(vertical: on) } }
            }
            InspectorRow(label: L("Wheel up drags it"), help: L("Which way a turn of the wheel up drags the thumb; down drags it back.")) {
                QuickSegmented(label: L("Wheel up drags it"),
                               options: vertical ? [(true, L("Up")), (false, L("Down"))] : [(true, L("Right")), (false, L("Left"))],
                               selection: control.scrollsForward, fill: true) { on in model.update { $0.setScrollBar(forward: on) } }
            }
            slider(L("Step per notch"), Binding(get: { step }, set: { value in model.update { $0.setScrollBar(step: value) } }),
                   Control.scrollStepRange, step: 0.01, text: percent(step), help: L("How far one notch of the wheel drags the thumb, of the track’s length."))
            slider(L("Rests at"), Binding(get: { rest }, set: { value in model.update { $0.setScrollBar(rest: value) } }),
                   0...1, step: 0.05, text: percent(rest),
                   help: L("Where the thumb is when the game starts, in a new mode, and after its reset key: 0% is the wheel-down end."))
            InspectorRow(label: L("Reset key"), help: L("Press it to drag the thumb back to where it rests (the map’s zoom back to normal). Click the key, then press another to change it.")) {
                Button { model.setDPadSlot(4) } label: {
                    KeyCap(text: control.reset?.shortLabel ?? L("No key"), symbol: "arrow.counterclockwise", active: selection.dpadSlot == 4)
                }
                .buttonStyle(.plain)
                .help(L("Click it, then press the key that resets the scroll bar."))
                Spacer(minLength: 4)
                if control.reset != nil {
                    BarIconButton(symbol: "xmark", label: L("No reset key")) { model.update { $0.reset = nil } }
                }
            }
        case .tap, .hold, .macro, .hotkey, .clickArea:
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

/// Everything the selected control does when its key is pressed (a click
/// area: when it is clicked), in order: its own touch, then each action,
/// each moved up or down or removed, and + Add Action.
private struct ActionsSection: View {
    @ObservedObject var model: KeymapEditorModel
    let control: Control

    var body: some View {
        let touch = Self.touch(of: control)
        let steps = (touch == nil ? 0 : 1) + control.actions.count
        VStack(alignment: .leading, spacing: 6) {
            QuickLabel(L("What it does"), help: help, font: QuickHaze.mona(12, 600), color: QuickHaze.textSecondary)
            if steps > 0 {
                VStack(spacing: 0) {
                    if let touch { touchRow(touch) }
                    ForEach(Array(control.actions.enumerated()), id: \.offset) { index, action in
                        if index > 0 || touch != nil { Divider().overlay(QuickHaze.text.opacity(0.06)) }
                        ActionRow(model: model, action: action, index: index, number: index + (touch == nil ? 1 : 2),
                                  count: control.actions.count)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(QuickHaze.inset))
                .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(QuickHaze.text.opacity(0.06)) }
            }
            if control.actions.isEmpty, !control.touchesTheScreen {
                Text(verbatim: L("Add what it does: switch to another mode, or free or lock the mouse."))
                    .font(QuickHaze.mona(11.5))
                    .foregroundStyle(Color(nsColor: .systemYellow))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HazeMenuButton(matchesWidth: true, entries: { model.addActionMenu() }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                    Text(verbatim: L("Add Action")).font(QuickHaze.mona(12, 620)).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(QuickHaze.textTertiary)
                }
                .foregroundStyle(QuickHaze.accentText)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(QuickHaze.accent.opacity(0.08)))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(QuickHaze.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Switch to another mode, or free or lock the mouse, after its touch"))
        }
    }

    private var help: String {
        switch control.kind {
        case .clickArea:
            L("Clicked while the mouse is free, the area does these in order. Switch Mode changes to another set of controls; Free and Lock the Mouse change what the mouse does with the eye.")
        case .hotkey:
            L("Pressed, the hotkey does these in order and touches nothing. Switch Mode changes to another set of controls; Free and Lock the Mouse change what the mouse does with the eye.")
        default:
            L("Pressed, the control does these in order: its own touch first, then each action. Switch Mode changes to another set of controls; Free and Lock the Mouse change what the mouse does with the eye.")
        }
    }

    /// Its own touch, the first thing it does; nil for a hotkey.
    static func touch(of control: Control) -> (title: String, symbol: String)? {
        switch control.kind {
        case .tap, .hold: (L("Tap the game’s button"), "hand.tap")
        case .repeatTap: (L("Tap it again and again"), "repeat")
        case .anchor: (L("Hold it, the mouse moving the finger"), "arrow.up.and.down.and.arrow.left.and.right")
        case .swipe: (L("Swipe"), "hand.draw")
        case .ads: (L("Aim down sights"), "scope")
        case .macro: (L("Play the macro"), "list.bullet")
        case .mobaMove: (L("Move towards the cursor"), "cursorarrow.motionlines")
        case .smartCast: (L("Cast towards the cursor"), "sparkles")
        case .clickArea: (L("Touch the game where clicked"), "cursorarrow.click.2")
        case .hotkey, .dpad, .aim, .scrollBar: nil
        }
    }

    /// The touch, numbered 1; a click area's may be turned off.
    private func touchRow(_ touch: (title: String, symbol: String)) -> some View {
        let passThrough: Bool? = if case .clickArea(_, let on) = control.kind { on } else { nil }
        let off = passThrough == false
        return HStack(spacing: 8) {
            StepNumber(number: 1, dim: true)
            Image(systemName: touch.symbol).font(.system(size: 11, weight: .semibold)).frame(width: 16)
            Text(verbatim: touch.title)
                .font(QuickHaze.mona(12, 520))
                .strikethrough(off)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let passThrough {
                Toggle(isOn: Binding(get: { passThrough }, set: { on in model.update { $0.setPassThrough(on) } })) { EmptyView() }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help(L("On: the click also touches the game there (its Close button). Off: it only does the actions."))
                    .accessibilityLabel(Text(verbatim: L("Touch the game where clicked")))
            }
        }
        .foregroundStyle(off ? QuickHaze.textTertiary : QuickHaze.textSecondary)
        .padding(.horizontal, 9)
        .frame(minHeight: 32)
    }
}

/// Whether a click on the game presses the selected control as its key
/// would (its click zone), and the zone's shape, sized on the game.
private struct ClickZoneSection: View {
    @ObservedObject var model: KeymapEditorModel
    let control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            QuickToggle(label: L("Clicking the game presses it"),
                        caption: L("A click with the mouse free inside its area presses this control, as its key would: the game’s button is touched once, and its actions run once. Drag the area or its edges on the game."),
                        isOn: control.clickZone != nil) { on in model.setClickZone(on) }
            if let zone = control.clickZone {
                InspectorRow(label: L("Area shape")) {
                    QuickSegmented(label: L("Area shape"),
                                   options: [(ClickZone.Shape.rounded, L("Rounded")), (.rectangle, L("Square")), (.ellipse, L("Round"))],
                                   selection: zone.shape, fill: true) { shape in model.update { $0.clickZone?.shape = shape } }
                }
            }
        }
    }
}

/// One of the selected control's actions: its number, what it does (a
/// switch's mode, chosen from a menu), and up, down and remove.
private struct ActionRow: View {
    @ObservedObject var model: KeymapEditorModel
    let action: ControlAction
    let index: Int
    let number: Int
    let count: Int

    var body: some View {
        let needsEye = action.isMouse && !model.hasEye
        HStack(spacing: 8) {
            StepNumber(number: number, dim: false)
            Image(systemName: action.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(needsEye ? Color(nsColor: .systemYellow) : QuickHaze.accentText)
                .frame(width: 16)
            if case .switchMode(let mode) = action {
                Text(verbatim: L("Switch to")).font(QuickHaze.mona(12, 520)).lineLimit(1).layoutPriority(1)
                HazeMenuButton(entries: { model.switchTargets(index) }) {
                    HStack(spacing: 4) {
                        Text(verbatim: model.modes.first { $0.id == mode }?.name ?? mode).font(QuickHaze.mona(12, 620)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7)
                    }
                    .foregroundStyle(QuickHaze.accentText)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule().fill(QuickHaze.segmentSelection))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(L("The mode it switches to"))
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: action.title)
                        .font(QuickHaze.mona(12, 520))
                        .lineLimit(2)
                    if needsEye {
                        Text(verbatim: L("Needs the eye (FPS)"))
                            .font(QuickHaze.mona(10.5, 550))
                            .foregroundStyle(Color(nsColor: .systemYellow))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .help(needsEye ? L("This needs the eye (mouse look): add it from FPS, or Done won’t save.") : action.title)
            }
            Spacer(minLength: 2)
            HStack(spacing: 1) {
                RowIconButton(symbol: "chevron.up", label: L("Earlier"), enabled: index > 0) { model.moveAction(index, -1) }
                RowIconButton(symbol: "chevron.down", label: L("Later"), enabled: index < count - 1) { model.moveAction(index, 1) }
                RowIconButton(symbol: "xmark", label: L("Remove This Action"), enabled: true) { model.removeAction(index) }
            }
        }
        .foregroundStyle(QuickHaze.text)
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .frame(minHeight: 32)
    }
}

/// A step's number in what a control does.
private struct StepNumber: View {
    let number: Int
    let dim: Bool

    var body: some View {
        Text(verbatim: "\(number)")
            .font(QuickHaze.mona(10, 700))
            .monospacedDigit()
            .foregroundStyle(dim ? QuickHaze.textTertiary : QuickHaze.onAccent)
            .frame(width: 17, height: 17)
            .background(Circle().fill(dim ? Color.white.opacity(0.08) : QuickHaze.accent))
            .accessibilityHidden(true)
    }
}

private struct RowIconButton: View {
    let symbol: String
    let label: String
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(enabled ? (hovering ? QuickHaze.text : QuickHaze.textSecondary) : QuickHaze.textTertiary.opacity(0.35))
                .frame(width: 22, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering && enabled ? Color.white.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(Text(verbatim: label))
    }
}

extension ControlAction {
    /// How the panel and the menus write it ("Free the mouse"); a switch names its mode elsewhere.
    var title: String {
        switch self {
        case .switchMode: L("Switch Mode")
        case .lockMouse: L("Lock the mouse")
        case .freeMouse: L("Free the mouse")
        case .toggleMouse: L("Lock or free the mouse")
        }
    }

    var symbol: String {
        switch self {
        case .switchMode: "arrow.triangle.2.circlepath"
        case .lockMouse: "lock.fill"
        case .freeMouse: "lock.open.fill"
        case .toggleMouse: "lock.rotation"
        }
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

    /// Whether a click area's click also touches the game.
    /// A scroll bar's wheel-up end is the top or the right one.
    var scrollsForward: Bool {
        guard case let .scrollBar(from, to, _, _) = kind else { return true }
        return isVerticalScrollBar ? to.y < from.y : to.x > from.x
    }

    /// A scroll bar turned up and down or across (around its middle, as long
    /// on the screen as it was), wheel up dragging the other way, or another
    /// step or rest point.
    mutating func setScrollBar(vertical: Bool? = nil, forward: Bool? = nil, step: Double? = nil, rest: Double? = nil) {
        guard case let .scrollBar(from, to, oldRest, oldStep) = kind else { return }
        var (a, b) = (from, to)
        if let vertical, vertical != isVerticalScrollBar {
            let mid = NormalizedPoint((a.x + b.x) / 2, (a.y + b.y) / 2)
            let half = max(abs(b.x - a.x), abs(b.y - a.y)) / 2
            let forward = scrollsForward
            if vertical {
                a = NormalizedPoint(mid.x, min(max(mid.y + (forward ? half : -half), 0), 1))
                b = NormalizedPoint(mid.x, min(max(mid.y - (forward ? half : -half), 0), 1))
            } else {
                a = NormalizedPoint(min(max(mid.x - (forward ? half : -half), 0), 1), mid.y)
                b = NormalizedPoint(min(max(mid.x + (forward ? half : -half), 0), 1), mid.y)
            }
        }
        var newRest = rest ?? oldRest
        kind = .scrollBar(from: a, to: b, rest: newRest, step: step ?? oldStep)
        if let forward, forward != scrollsForward {
            // The ends change places; the thumb rests where it did on the screen.
            newRest = 1 - newRest
            kind = .scrollBar(from: b, to: a, rest: newRest, step: step ?? oldStep)
        }
    }

    mutating func setPassThrough(_ on: Bool) {
        if case .clickArea(let area, _) = kind { kind = .clickArea(area, passThrough: on) }
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
