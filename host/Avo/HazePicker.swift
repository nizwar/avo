import AvoHazeUI
import AvoWindowHost
import SwiftUI

/// One choice of a HazePicker: what it says and the value it stands for.
struct HazeOption<Value: Hashable> {
    var title: String
    var value: Value
    var isEnabled = true
    /// The section it is listed under (HazeSection).
    var section: String?

    init(_ title: LocalizedStringResource, _ value: Value, isEnabled: Bool = true) {
        self.title = String(localized: title)
        self.value = value
        self.isEnabled = isEnabled
    }

    init(verbatim title: String, _ value: Value, isEnabled: Bool = true) {
        self.title = title
        self.value = value
        self.isEnabled = isEnabled
    }
}

/// Options under a title in the menu.
struct HazeSection<Value: Hashable> {
    var options: [HazeOption<Value>]

    init(_ title: LocalizedStringResource, @HazeOptionsBuilder<Value> options: () -> [HazeOption<Value>]) {
        let title = String(localized: title)
        self.options = options().map { option in
            var option = option
            option.section = title
            return option
        }
    }
}

/// A HazePicker's choices, written as a Picker's content is: options, `for`
/// loops, `if`, and sections.
@resultBuilder
enum HazeOptionsBuilder<Value: Hashable> {
    static func buildExpression(_ option: HazeOption<Value>) -> [HazeOption<Value>] { [option] }
    static func buildExpression(_ section: HazeSection<Value>) -> [HazeOption<Value>] { section.options }
    static func buildBlock(_ parts: [HazeOption<Value>]...) -> [HazeOption<Value>] { parts.flatMap { $0 } }
    static func buildArray(_ parts: [[HazeOption<Value>]]) -> [HazeOption<Value>] { parts.flatMap { $0 } }
    static func buildOptional(_ part: [HazeOption<Value>]?) -> [HazeOption<Value>] { part ?? [] }
    static func buildEither(first part: [HazeOption<Value>]) -> [HazeOption<Value>] { part }
    static func buildEither(second part: [HazeOption<Value>]) -> [HazeOption<Value>] { part }
}

/// A choice from a menu in the haze: the chosen option on a veiled capsule
/// with chevrons, and the options in a haze menu under it (HazeMenu.swift in
/// AvoHazeUI), with a check mark on the choice, sections, and options
/// that cannot be chosen. VoiceOver gets a Picker with `title`.
struct HazePicker<Value: Hashable>: View {
    private let title: Text
    @Binding private var selection: Value
    private let options: [HazeOption<Value>]
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: LocalizedStringKey, selection: Binding<Value>, @HazeOptionsBuilder<Value> options: () -> [HazeOption<Value>]) {
        self.title = Text(title)
        _selection = selection
        self.options = options()
    }

    var body: some View {
        HazeMenuButton(matchesWidth: true) { entries() } label: {
            HStack(spacing: 7) {
                // The chosen option, as the menu shows it.
                Text(verbatim: options.first { $0.value == selection }?.title ?? "")
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Haze.textTertiary)
            }
            .font(.mona(13))
            .foregroundStyle(Haze.text)
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .frame(height: 28)
            .background {
                ZStack {
                    Capsule().fill(Haze.field)
                    Capsule().fill(Haze.text.opacity(hovering && isEnabled ? 0.05 : 0))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.45)
        .animation(Haze.Motion.hover, value: hovering)
        .onHover { hovering = $0 }
        .accessibilityRepresentation {
            Picker(selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Text(verbatim: option.title).tag(option.value)
                }
            } label: {
                title
            }
        }
    }

    /// The options under their sections, the choice checked.
    private func entries() -> [HazeMenuEntry] {
        let selection = $selection
        var entries: [HazeMenuEntry] = []
        var section: String?
        for option in options {
            if option.section != section {
                section = option.section
                if !entries.isEmpty { entries.append(.separator()) }
                if let section { entries.append(.section(section)) }
            }
            entries.append(.item(HazeMenuItem(title: option.title, state: option.value == selection.wrappedValue ? .on : .off,
                                              isEnabled: option.isEnabled) { selection.wrappedValue = option.value }))
        }
        return entries
    }
}
