import AppKit
import AvoKit
import CoreText
import SwiftUI

// The haze in small: the Control Panel's look (HazeTheme.swift in Avo.app)
// as the few colours, type and controls an app window's panels use (Quick
// Settings, the key mapping editor, the Location panel, the widget panels),
// in a module of its own so Avo Hub's windows wear the same ones
// (AvoKeymapUI's editor is built from them).

private func L(_ key: String.LocalizationValue) -> String { String(localized: key, bundle: .avoKit) }

/// The Control Panel's haze (HazeTheme.swift in Avo.app), the few colours,
/// type and controls the overlay uses (and the Location panel, LocationPanel.swift,
/// and the widget panels, WidgetPanels.swift, through the AppKit ones).
@MainActor
public enum QuickHaze {
    public static func rgb(_ value: UInt32, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255, opacity: alpha)
    }

    /// The same colours for AppKit views.
    public nonisolated static func nsRGB(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    public static let base = rgb(0x0A1108)
    public static let card = rgb(0xF3F1E8, 0.045)
    public static let inset = Color.black.opacity(0.28)
    public static let text = rgb(0xF3F1E8)
    public static let textSecondary = rgb(0xC5CDB9)
    public static let textTertiary = rgb(0x9AA58E)
    public static let sectionLabel = rgb(0x8F9B84)
    public static let accent = rgb(0xD8E8A7)
    public static let onAccent = rgb(0x15210E)
    public static let accentText = rgb(0xEEF5D6)
    public static let segmentSelection = rgb(0xD8E8A7, 0.2)
    /// A menu's lit item (HazeMenu.swift), and a destructive one's.
    public static let selection = rgb(0xD8E8A7, 0.14)
    public static let danger = rgb(0xF3B8A2)
    public static let dangerFill = rgb(0xF39A7C, 0.14)

    /// Near black with a breath of Avo green top right and bottom left.
    public static var background: some View {
        ZStack {
            base
            EllipticalGradient(colors: [rgb(0xD8E8A7, 0.2), rgb(0xD8E8A7, 0)], center: UnitPoint(x: 0.92, y: -0.04),
                               startRadiusFraction: 0, endRadiusFraction: 0.75)
            EllipticalGradient(colors: [rgb(0xBCDC8F, 0.09), rgb(0xBCDC8F, 0)], center: UnitPoint(x: 0.06, y: 1.04),
                               startRadiusFraction: 0, endRadiusFraction: 0.7)
        }
    }

    // Hubot Sans and Mona Sans from Avo.app (Fonts/), else the system font.

    /// More folders to find the typefaces in (Avo.app's Resources while an
    /// App Shim runs from elsewhere), set before the first window opens.
    /// The app's own Resources, and those beside the framework this module
    /// is linked into (Avo.app/Contents/Frameworks/AvoHostKit.framework, also
    /// in a shim), are looked in first.
    public static var fontDirectories: [URL] = []

    private enum Family: String {
        case hubot = "hubot-sans"
        case mona = "mona-sans"
    }

    private static var bases: [Family: CTFontDescriptor?] = [:]
    private static var fonts: [String: Font] = [:]

    public static func hubot(_ size: CGFloat, _ weight: CGFloat = 700) -> Font { font(.hubot, size, weight) }
    public static func mona(_ size: CGFloat, _ weight: CGFloat = 400) -> Font { font(.mona, size, weight) }

    /// Mona Sans for AppKit views.
    public static func monaFont(_ size: CGFloat, _ weight: CGFloat = 400) -> NSFont {
        ctFont(.mona, size, weight).map { $0 as NSFont }
            ?? .systemFont(ofSize: size, weight: weight >= 650 ? .bold : weight >= 550 ? .semibold : .regular)
    }

    private static func font(_ family: Family, _ size: CGFloat, _ weight: CGFloat) -> Font {
        let key = "\(family.rawValue)-\(size)-\(weight)"
        if let font = fonts[key] { return font }
        let font: Font = ctFont(family, size, weight).map { Font($0) }
            ?? .system(size: size, weight: weight >= 650 ? .bold : weight >= 550 ? .semibold : .regular)
        fonts[key] = font
        return font
    }

    private static func ctFont(_ family: Family, _ size: CGFloat, _ weight: CGFloat) -> CTFont? {
        guard let base = base(family) else { return nil }
        var descriptor = CTFontDescriptorCreateCopyWithVariation(base, tag("wght") as CFNumber, weight)
        descriptor = CTFontDescriptorCreateCopyWithVariation(descriptor, tag("wdth") as CFNumber, 100)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    private static func base(_ family: Family) -> CTFontDescriptor? {
        if let known = bases[family] { return known }
        // The framework is Avo.app/Contents/Frameworks/AvoHostKit.framework.
        let framework = Bundle(for: FontAnchor.self).bundleURL
        let resources = framework.deletingLastPathComponent().deletingLastPathComponent().appending(path: "Resources")
        let candidates = [resources, Bundle.main.resourceURL].compactMap { $0 } + fontDirectories
        let descriptor = candidates.lazy
            .compactMap { try? Data(contentsOf: $0.appending(path: "\(family.rawValue).woff2")) }
            .compactMap { (CTFontManagerCreateFontDescriptorsFromData($0 as CFData) as? [CTFontDescriptor])?.first }
            .first
        bases[family] = .some(descriptor)
        return descriptor
    }

    private static func tag(_ name: String) -> Int {
        name.utf8.reduce(0) { $0 << 8 | Int($1) }
    }
}

private final class FontAnchor {}

/// A card: its title, whom it applies to, and its settings.
public struct QuickCard<Content: View>: View {
    let title: String
    let scope: String
    /// A line between its settings, so each one reads as its own.
    var separated = true
    @ViewBuilder let content: Content

    public init(title: String, scope: String, separated: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.scope = scope
        self.separated = separated
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: title)
                    .font(QuickHaze.hubot(13.5, 650))
                    .foregroundStyle(QuickHaze.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Text(verbatim: scope)
                    .font(QuickHaze.mona(11, 500))
                    .foregroundStyle(QuickHaze.sectionLabel)
            }
            if separated {
                QuickRows { content }
            } else {
                content
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QuickHaze.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// Settings one under the other, a line between each two: each view of
/// `content` is one (a VStack keeps the ones that belong together).
public struct QuickRows<Content: View>: View {
    var spacing: CGFloat = 9
    @ViewBuilder let content: Content

    public init(spacing: CGFloat = 9, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    if row.id != rows.first?.id { QuickSeparator().padding(.vertical, spacing) }
                    row
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The line between two settings.
public struct QuickSeparator: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(QuickHaze.text.opacity(0.08))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

public struct QuickText: View {
    let text: String
    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(verbatim: text).font(QuickHaze.mona(13.5)).foregroundStyle(QuickHaze.text)
    }
}

public struct QuickCaption: View {
    let text: String
    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(verbatim: text)
            .font(QuickHaze.mona(11.5))
            .foregroundStyle(QuickHaze.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A setting's value at the end of its row ("35%").
public struct QuickValue: View {
    let text: Text
    public init(_ text: Text) { self.text = text }

    public var body: some View {
        text.font(QuickHaze.mona(12.5)).foregroundStyle(QuickHaze.textTertiary).monospacedDigit()
    }
}

/// Whom a setting applies to ("Every app"), on the right of its name.
public struct QuickScope: View {
    let text: String
    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(verbatim: text).font(QuickHaze.mona(11, 500)).foregroundStyle(QuickHaze.sectionLabel).lineLimit(1)
    }
}

/// A setting's (?): what it does, under the pointer, and below its name
/// while clicked.
public struct QuickHelpButton: View {
    let help: String
    @Binding var shown: Bool

    public init(help: String, shown: Binding<Bool>) {
        self.help = help
        _shown = shown
    }

    public var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { shown.toggle() }
        } label: {
            Image(systemName: shown ? "questionmark.circle.fill" : "questionmark.circle")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(shown ? QuickHaze.accent : QuickHaze.textTertiary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(verbatim: L("More about this")))
        .accessibilityHint(Text(verbatim: help))
    }
}

/// A setting's name, its key in the window ("⌘G"), and a (?) when there is
/// more to say: under the pointer, and below the name once it is clicked.
public struct QuickLabel: View {
    let title: String
    var shortcut: String?
    var help: String?
    var font = QuickHaze.mona(13.5)
    var color = QuickHaze.text
    @State private var showsHelp = false

    public init(_ title: String, shortcut: String? = nil, help: String? = nil, font: Font = QuickHaze.mona(13.5), color: Color = QuickHaze.text) {
        self.title = title
        self.shortcut = shortcut
        self.help = help
        self.font = font
        self.color = color
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(verbatim: title).font(font).foregroundStyle(color)
                if let shortcut {
                    Text(verbatim: shortcut).font(QuickHaze.mona(11.5)).foregroundStyle(QuickHaze.textTertiary)
                }
                if let help { QuickHelpButton(help: help, shown: $showsHelp) }
            }
            if showsHelp, let help { QuickCaption(help) }
        }
    }
}

/// A setting: its name (and its ?) with whom it applies to on the right,
/// and its control under them, as wide as the card; `inline`, a small
/// control (a menu, a value) on the right of the name instead.
public struct QuickRow<Control: View>: View {
    let label: String
    /// Whom it applies to ("Every app").
    var caption: String?
    var help: String?
    var inline = false
    @ViewBuilder let control: Control

    public init(label: String, caption: String? = nil, help: String? = nil, inline: Bool = false, @ViewBuilder control: () -> Control) {
        self.label = label
        self.caption = caption
        self.help = help
        self.inline = inline
        self.control = control()
    }

    public var body: some View {
        if inline {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    QuickLabel(label, help: help)
                    if let caption { QuickScope(caption) }
                }
                Spacer(minLength: 6)
                control
            }
        } else {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    QuickLabel(label, help: help)
                    Spacer(minLength: 6)
                    if let caption { QuickScope(caption) }
                }
                control
            }
        }
    }
}

/// A setting with a slider: its name (and its ?) and its value on one line,
/// the slider under them.
public struct QuickSliderRow<Slider: View>: View {
    let label: String
    let value: Text
    var help: String?
    @ViewBuilder let slider: Slider

    public init(label: String, value: Text, help: String? = nil, @ViewBuilder slider: () -> Slider) {
        self.label = label
        self.value = value
        self.help = help
        self.slider = slider()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                QuickLabel(label, help: help)
                Spacer(minLength: 6)
                QuickValue(value)
            }
            slider.frame(maxWidth: .infinity)
        }
    }
}

/// The haze checkbox (an Avo green square with a dark check) at the end of
/// its row; a click on the name sets it too.
public struct QuickToggle: View {
    let label: String
    /// Its key in the window ("⌘G"), after the label.
    var shortcut: String?
    /// What it does, behind its (?).
    var caption: String?
    let isOn: Bool
    let set: (Bool) -> Void

    public init(label: String, shortcut: String? = nil, caption: String? = nil, isOn: Bool, set: @escaping (Bool) -> Void) {
        self.label = label
        self.shortcut = shortcut
        self.caption = caption
        self.isOn = isOn
        self.set = set
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            QuickLabel(label, shortcut: shortcut, help: caption)
                .contentShape(Rectangle())
                .onTapGesture { set(!isOn) }
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            Button {
                set(!isOn)
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isOn ? QuickHaze.accent : Color.white.opacity(0.92))
                        .frame(width: 18, height: 18)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(QuickHaze.onAccent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: label))
            .accessibilityValue(Text(verbatim: isOn ? L("On") : L("Off")))
            .accessibilityHint(Text(verbatim: caption ?? ""))
            .accessibilityAddTraits(.isToggle)
        }
    }
}

/// The haze segmented control: options in a recessed capsule, the chosen one lit.
public struct QuickSegmented<Value: Hashable>: View {
    let label: String
    let options: [(value: Value, title: String)]
    let selection: Value?
    /// Each option as wide as the others, across the row.
    var fill = false
    var segmentPadding: CGFloat = 10
    /// What an option does, under the pointer.
    var help: ((Value) -> String)?
    /// Whether an option can be chosen (all, without it).
    var enabled: ((Value) -> Bool)?
    let choose: (Value) -> Void

    public init(label: String, options: [(value: Value, title: String)], selection: Value?, fill: Bool = false,
                segmentPadding: CGFloat = 10, help: ((Value) -> String)? = nil, enabled: ((Value) -> Bool)? = nil,
                choose: @escaping (Value) -> Void) {
        self.label = label
        self.options = options
        self.selection = selection
        self.fill = fill
        self.segmentPadding = segmentPadding
        self.help = help
        self.enabled = enabled
        self.choose = choose
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.value == selection
                Button {
                    if !selected { choose(option.value) }
                } label: {
                    Text(verbatim: option.title)
                        .font(QuickHaze.mona(12.5, selected ? 600 : 400))
                        .foregroundStyle(selected ? QuickHaze.accentText : QuickHaze.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, fill ? 4 : segmentPadding)
                        .frame(maxWidth: fill ? .infinity : nil)
                        .frame(height: 24)
                        .background {
                            if selected { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(QuickHaze.segmentSelection) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!(enabled?(option.value) ?? true))
                .opacity(enabled?(option.value) ?? true ? 1 : 0.45)
                .help(help?(option.value) ?? "")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(QuickHaze.inset))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: label))
    }
}

/// The haze slider: an Avo green fill and thumb on a dark track. Drag or
/// click anywhere on it; arrow keys and VoiceOver step it.
public struct QuickSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    /// What VoiceOver reads for the value ("35%").
    var valueText: Text?
    /// Begins and ends a drag (for saving only when it ends).
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var dragging = false

    public init(label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double = 1, valueText: Text? = nil,
                onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.label = label
        _value = value
        self.range = range
        self.step = step
        self.valueText = valueText
        self.onEditingChanged = onEditingChanged
    }

    private let thumb: CGFloat = 15

    public var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - thumb)
            let fraction = (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound)
                / max(range.upperBound - range.lowerBound, .ulpOfOne)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.35))
                    .overlay { Capsule().strokeBorder(QuickHaze.text.opacity(0.12)) }
                    .frame(height: 5)
                    .padding(.horizontal, thumb / 2)
                Capsule().fill(QuickHaze.accent)
                    .frame(width: thumb / 2 + width * fraction, height: 5)
                    .padding(.leading, thumb / 2)
                Circle()
                    .fill(QuickHaze.accent)
                    .overlay { Circle().strokeBorder(QuickHaze.onAccent.opacity(0.25)) }
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .frame(width: thumb, height: thumb)
                    .offset(x: width * fraction)
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if !dragging {
                        dragging = true
                        onEditingChanged(true)
                    }
                    set(fraction: (drag.location.x - thumb / 2) / width)
                }
                .onEnded { _ in
                    dragging = false
                    onEditingChanged(false)
                })
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityValue(valueText ?? Text(value, format: .number))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }

    private func set(fraction: CGFloat) {
        let raw = range.lowerBound + Double(min(max(fraction, 0), 1)) * (range.upperBound - range.lowerBound)
        let snapped = ((raw - range.lowerBound) / step).rounded() * step + range.lowerBound
        let clamped = min(max(snapped, range.lowerBound), range.upperBound)
        if abs(clamped - value) > step / 1000 { value = clamped }
    }
}
