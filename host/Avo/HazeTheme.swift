import AppKit
import CoreText
import SwiftUI

// The Library window's look ("haze"): Avo's green glowing over near black,
// warm light text, and cards that are only a breath lighter than the page.
// Colours, sizes and type follow the approved design (Library · Home,
// Library · Game page, Library · Notifications). The Library is always dark,
// like a game launcher, and so is the Settings window, whose forms are cards
// in the same haze (HazeFormStyle, below).

enum Haze {
    // MARK: Surfaces
    static let windowBase = Color(haze: 0x0A1108)
    /// A game page under its hero.
    static let pageBase = Color(haze: 0x0D0F09)
    static let sidebar = Color(haze: 0xF3F1E8, alpha: 0.035)
    /// Cards on a page (usage, graphics, notifications).
    static let card = Color(haze: 0xF3F1E8, alpha: 0.045)
    /// The secondary cards on Home ("Get more games").
    static let cardQuiet = Color(haze: 0xF3F1E8, alpha: 0.05)
    /// App tiles.
    static let tile = Color(haze: 0xF3F1E8, alpha: 0.04)
    /// Search field, segmented controls, filter chips.
    static let field = Color(haze: 0xF3F1E8, alpha: 0.07)
    /// Secondary buttons (Install App, Clear All).
    static let button = Color(haze: 0xF3F1E8, alpha: 0.08)
    /// Controls set into a card (a card's segmented control, a reply field).
    static let inset = Color.black.opacity(0.28)
    /// Chips over a hero ("GPU · 60 FPS").
    static let chip = Color.black.opacity(0.32)

    // MARK: Text
    static let text = Color(haze: 0xF3F1E8)
    static let textSecondary = Color(haze: 0xC5CDB9)
    static let textTertiary = Color(haze: 0x9AA58E)
    static let sectionLabel = Color(haze: 0x8F9B84)

    // MARK: Avo green
    /// Avo's flesh colour: primary buttons, the selected filter, links.
    static let accent = Color(haze: 0xD8E8A7)
    static let onAccent = Color(haze: 0x15210E)
    static let accentText = Color(haze: 0xEEF5D6)
    static let selection = Color(haze: 0xD8E8A7, alpha: 0.14)
    static let segmentSelection = Color(haze: 0xD8E8A7, alpha: 0.18)
    static let running = Color(haze: 0xBCDC8F)
    static let skin = Color(haze: 0x2F4A1F)
    static let pit = Color(haze: 0x7B4A2A)
    static let positive = Color(haze: 0xBCDC8F)

    // MARK: Warnings
    static let warning = Color(haze: 0xF0C27A)
    static let danger = Color(haze: 0xF3B8A2)
    static let dangerFill = Color(haze: 0xF39A7C, alpha: 0.14)

    /// The window: a breath of green light top right and bottom left.
    static let windowGlows: [HazeGlow] = [
        HazeGlow(x: .fraction(0.88), y: .fraction(-0.04), rx: 560, ry: 340, color: 0xD8E8A7, alpha: 0.26),
        HazeGlow(x: .fraction(0.94), y: .fraction(0.10), rx: 260, ry: 180, color: 0xFBF8F1, alpha: 0.18),
        HazeGlow(x: .fraction(0.08), y: .fraction(1.04), rx: 480, ry: 320, color: 0xBCDC8F, alpha: 0.12),
    ]
}

extension Color {
    /// sRGB from 0xRRGGBB.
    init(haze rgb: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255, opacity: alpha)
    }
}

// MARK: - Type

/// Hubot Sans (headings) and Mona Sans (text), GitHub's open source
/// typefaces (SIL OFL 1.1, Fonts/OFL-*.txt), the website's type too. They
/// are variable fonts: any weight from 200 to 900 (the design uses 750).
/// Without the files the system font stands in.
@MainActor
enum HazeFont {
    enum Family: String {
        case hubot = "hubot-sans"
        case mona = "mona-sans"
    }

    /// Ascender plus descender over the size, the same for both families.
    nonisolated static let naturalLineHeight: CGFloat = 1.41

    private static var bases: [Family: CTFontDescriptor] = [:]
    private static var cache: [String: Font] = [:]
    private static var nsCache: [String: NSFont] = [:]

    static func font(_ family: Family, _ size: CGFloat, weight: CGFloat) -> Font {
        let key = "\(family.rawValue)-\(size)-\(weight)"
        if let font = cache[key] { return font }
        let font = Font(nsFont(family, size, weight: weight))
        cache[key] = font
        return font
    }

    static func nsFont(_ family: Family, _ size: CGFloat, weight: CGFloat) -> NSFont {
        let key = "\(family.rawValue)-\(size)-\(weight)"
        if let font = nsCache[key] { return font }
        let font: NSFont
        if let base = base(family) {
            var descriptor = CTFontDescriptorCreateCopyWithVariation(base, Self.tag("wght") as CFNumber, weight)
            descriptor = CTFontDescriptorCreateCopyWithVariation(descriptor, Self.tag("wdth") as CFNumber, 100)
            font = CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
        } else {
            font = NSFont.systemFont(ofSize: size, weight: NSFont.Weight(Self.systemWeight(weight)))
        }
        nsCache[key] = font
        return font
    }

    private static func base(_ family: Family) -> CTFontDescriptor? {
        if let base = bases[family] { return base }
        guard let url = Bundle.main.url(forResource: family.rawValue, withExtension: "woff2"),
              let data = try? Data(contentsOf: url),
              let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
              let first = descriptors.first else { return nil }
        bases[family] = first
        return first
    }

    private static func tag(_ name: String) -> Int {
        name.utf8.reduce(0) { $0 << 8 | Int($1) }
    }

    /// CSS weight to NSFont.Weight (for the system font fallback).
    private static func systemWeight(_ weight: CGFloat) -> CGFloat {
        switch weight {
        case ..<450: 0
        case ..<550: 0.23
        case ..<650: 0.3
        case ..<775: 0.4
        default: 0.56
        }
    }
}

extension View {
    /// A CSS `line-height` for one line of Hubot or Mona at `size` (their own
    /// is 1.41 × size): a heading takes the design's height, not the font's.
    func hazeLineHeight(_ multiple: CGFloat, size: CGFloat) -> some View {
        padding(.vertical, (multiple - HazeFont.naturalLineHeight) * size / 2)
    }

    /// A CSS `line-height` for a paragraph of Hubot or Mona at `size`.
    func hazeParagraph(_ multiple: CGFloat, size: CGFloat) -> some View {
        lineSpacing(max(0, (multiple - HazeFont.naturalLineHeight) * size))
    }
}

extension Font {
    /// Hubot Sans, the design's headings.
    @MainActor static func hubot(_ size: CGFloat, _ weight: CGFloat = 700) -> Font { HazeFont.font(.hubot, size, weight: weight) }
    /// Mona Sans, the design's text.
    @MainActor static func mona(_ size: CGFloat, _ weight: CGFloat = 400) -> Font { HazeFont.font(.mona, size, weight: weight) }
    /// Small capitals labels ("RUNNING", "CONTINUE PLAYING").
    static func hazeMono(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .monospaced) }
}

// MARK: - Glows

/// One CSS `radial-gradient(<rx> <ry> at <x> <y>, color α, transparent <stop>)`:
/// an ellipse of light that fades out at `stop` of its radius.
struct HazeGlow: Hashable, Sendable {
    enum Position: Hashable, Sendable {
        /// Of the view's width or height (CSS percentages).
        case fraction(CGFloat)
        case points(CGFloat)

        func resolve(_ length: CGFloat) -> CGFloat {
            switch self {
            case .fraction(let value): value * length
            case .points(let value): value
            }
        }
    }

    var x: Position
    var y: Position
    var rx: CGFloat
    var ry: CGFloat
    var color: UInt32
    var alpha: Double
    var stop: CGFloat = 0.7

    /// A glow in a colour from an icon (`IconPalette`).
    init(x: Position, y: Position, rx: CGFloat, ry: CGFloat, color: UInt32, alpha: Double, stop: CGFloat = 0.7) {
        self.x = x
        self.y = y
        self.rx = rx
        self.ry = ry
        self.color = color
        self.alpha = alpha
        self.stop = stop
    }
}

/// A CSS `linear-gradient(<angle>deg, …)`: colours along a line through the
/// view's centre at `angle` (0 points up, 90 right), as long as CSS makes it.
struct HazeLinear: Hashable, Sendable {
    var angle: Double
    var stops: [Stop]

    struct Stop: Hashable, Sendable {
        var color: UInt32
        var alpha: Double = 1
        var location: CGFloat
    }
}

/// Glows over an optional linear gradient over a base colour, drawn exactly
/// as the design's CSS does. Drawn with Core Graphics, so it also shows in
/// offscreen renders.
struct HazeBackground: View {
    var base: Color? = nil
    var linear: HazeLinear? = nil
    var glows: [HazeGlow] = []

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            if let base { context.fill(Path(rect), with: .color(base)) }
            if let linear { Self.draw(linear, in: &context, size: size) }
            for glow in glows { Self.draw(glow, in: &context, size: size) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func draw(_ linear: HazeLinear, in context: inout GraphicsContext, size: CGSize) {
        let radians = linear.angle * .pi / 180
        let direction = CGVector(dx: sin(radians), dy: -cos(radians))
        let length = abs(size.width * sin(radians)) + abs(size.height * cos(radians))
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let start = CGPoint(x: center.x - direction.dx * length / 2, y: center.y - direction.dy * length / 2)
        let end = CGPoint(x: center.x + direction.dx * length / 2, y: center.y + direction.dy * length / 2)
        let gradient = Gradient(stops: linear.stops.map { .init(color: Color(haze: $0.color, alpha: $0.alpha), location: $0.location) })
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(gradient, startPoint: start, endPoint: end))
    }

    static func draw(_ glow: HazeGlow, in context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: glow.x.resolve(size.width), y: glow.y.resolve(size.height))
        var layer = context
        layer.translateBy(x: center.x, y: center.y)
        layer.scaleBy(x: 1, y: glow.ry / glow.rx)
        let gradient = Gradient(stops: [
            .init(color: Color(haze: glow.color, alpha: glow.alpha), location: 0),
            .init(color: Color(haze: glow.color, alpha: 0), location: glow.stop),
        ])
        let reach = glow.rx * glow.stop
        layer.fill(Path(ellipseIn: CGRect(x: -reach, y: -reach, width: reach * 2, height: reach * 2)),
                   with: .radialGradient(gradient, center: .zero, startRadius: 0, endRadius: glow.rx))
    }
}

// MARK: - Controls

/// The design's pill buttons: Avo green with dark text, or a light veil.
/// Under the pointer they brighten (Avo green glows a little more); a
/// click presses them down a touch.
struct HazeButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        /// Over a hero image.
        case overlay
        case destructive
    }

    var kind: Kind = .secondary
    var height: CGFloat = 38
    var fontSize: CGFloat = 13
    var horizontalPadding: CGFloat = 16

    func makeBody(configuration: Configuration) -> some View {
        HazeButtonBody(configuration: configuration, kind: kind, height: height, fontSize: fontSize,
                       horizontalPadding: horizontalPadding)
    }
}

private struct HazeButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: HazeButtonStyle.Kind
    let height: CGFloat
    let fontSize: CGFloat
    let horizontalPadding: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.hazeSecondaryFill) private var secondaryFill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let lit = hovering && isEnabled
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .font(.mona(fontSize, kind == .primary ? 700 : 600))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background {
                ZStack {
                    Capsule().fill(background)
                    Capsule().fill(Color.white.opacity(lit ? (kind == .primary ? 0.16 : 0.06) : 0))
                }
                // Avo green glows a little more under the pointer.
                .shadow(color: Haze.accent.opacity(kind == .primary && lit ? 0.34 : 0), radius: 12, y: 4)
            }
            .contentShape(Capsule())
            .scaleEffect(pressed && !reduceMotion ? Haze.Motion.pressScale : 1)
            .opacity(isEnabled ? (pressed ? 0.85 : 1) : 0.4)
            .animation(Haze.Motion.press, value: pressed)
            .animation(Haze.Motion.hover, value: lit)
            .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .primary: Haze.onAccent
        case .secondary, .overlay: Haze.text
        case .destructive: Haze.danger
        }
    }

    private var background: Color {
        switch kind {
        case .primary: Haze.accent
        case .secondary: secondaryFill ?? Haze.button
        case .overlay: Haze.chip
        case .destructive: Haze.dangerFill
        }
    }
}

/// A round icon button (the status pill's, a card's dismiss).
struct HazeIconButtonStyle: ButtonStyle {
    var size: CGFloat = 44
    var fill: Color = Haze.button
    var foreground: Color = Haze.text

    func makeBody(configuration: Configuration) -> some View {
        HazeIconButtonBody(configuration: configuration, size: size, fill: fill, foreground: foreground)
    }
}

private struct HazeIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    let fill: Color
    let foreground: Color
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let lit = hovering && isEnabled
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background {
                ZStack {
                    Circle().fill(fill)
                    Circle().fill(Color.white.opacity(lit ? 0.08 : 0))
                }
            }
            .contentShape(Circle())
            .scaleEffect(pressed && !reduceMotion ? 0.9 : 1)
            .opacity(isEnabled ? (pressed ? 0.8 : 1) : 0.4)
            .animation(Haze.Motion.press, value: pressed)
            .animation(Haze.Motion.hover, value: lit)
            .onHover { hovering = $0 }
    }
}

/// A card or tile that is a button: it gives a little under a click.
struct HazeCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HazeCardButtonBody(configuration: configuration)
    }
}

private struct HazeCardButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? Haze.Motion.cardPressScale : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.85 : 1)
            .animation(Haze.Motion.press, value: configuration.isPressed)
    }
}

/// A text link ("See all", "Not Now"): brighter under the pointer, dimmer
/// while pressed.
struct HazeLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HazeLinkButtonBody(configuration: configuration)
    }
}

private struct HazeLinkButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .brightness(hovering && isEnabled ? 0.12 : 0)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.45)
            .contentShape(Rectangle())
            .animation(Haze.Motion.hover, value: hovering)
            .animation(Haze.Motion.press, value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

/// A small capsule over a hero or a page header ("Key mapping · 14 controls").
struct HazeChip: View {
    let text: Text
    var fill: Color = Haze.chip

    init(_ text: Text, fill: Color = Haze.chip) {
        self.text = text
        self.fill = fill
    }

    var body: some View {
        text
            .font(.mona(12))
            .foregroundStyle(Haze.text)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(fill, in: Capsule())
    }
}

/// The design's segmented control: options in a recessed capsule, the
/// chosen one lit. The light slides to a new choice, which the trackpad
/// confirms with a light tick.
struct HazeSegmented<Value: Hashable>: View {
    let options: [(value: Value, label: Text)]
    @Binding var selection: Value
    var height: CGFloat = 32
    var padding: CGFloat = 3
    var cornerRadius: CGFloat? = nil
    var fontSize: CGFloat = 13
    var fill: Color = Haze.field
    var selectedFill: Color = Haze.segmentSelection
    var segmentPadding: CGFloat = 16
    /// Each option as wide as the others (inside a card).
    var equalWidths = false
    @Namespace private var indicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let selected = option.value == selection
                Button {
                    let changed = option.value != selection
                    selection = option.value
                    if changed { Haze.Haptics.snap() }
                } label: {
                    HazeSegmentLabel(label: option.label, selected: selected, fontSize: fontSize, height: height,
                                     segmentPadding: segmentPadding, equalWidth: equalWidths, shape: segmentShape) {
                        // One light for the whole control, so it slides (with
                        // Reduce Motion each option has its own, which fades).
                        segmentShape.fill(selectedFill)
                            .matchedGeometryEffect(id: reduceMotion ? AnyHashable(index) : AnyHashable("selection"), in: indicator)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(padding)
        .background(outerShape.fill(fill))
        .animation(Haze.Motion.animation(Haze.Motion.slide, reduceMotion: reduceMotion), value: selection)
    }

    private var segmentShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius.map { max(0, $0 - padding) } ?? height / 2, style: .continuous)
    }

    private var outerShape: some Shape {
        RoundedRectangle(cornerRadius: cornerRadius ?? (height / 2 + padding), style: .continuous)
    }
}

/// One option of a segmented control, a little brighter under the pointer.
private struct HazeSegmentLabel<Indicator: View>: View {
    let label: Text
    let selected: Bool
    let fontSize: CGFloat
    let height: CGFloat
    let segmentPadding: CGFloat
    let equalWidth: Bool
    let shape: RoundedRectangle
    @ViewBuilder var indicator: Indicator
    @State private var hovering = false

    var body: some View {
        label
            .font(.mona(fontSize, selected ? 600 : 400))
            .foregroundStyle(selected ? Haze.accentText : (hovering ? Haze.text : Haze.textSecondary))
            .lineLimit(1)
            .padding(.horizontal, segmentPadding)
            .frame(maxWidth: equalWidth ? .infinity : nil)
            .frame(height: height)
            .background {
                if selected {
                    indicator
                } else if hovering {
                    shape.fill(Haze.text.opacity(0.05))
                }
            }
            .contentShape(shape)
            .onHover { inside in withAnimation(Haze.Motion.hover) { hovering = inside } }
    }
}

/// The design's checkbox (a filled Avo green square with a dark check that
/// draws itself on).
struct HazeCheckboxStyle: ToggleStyle {
    /// The box before the label (a lone checkbox) instead of at the row's end.
    var boxLeading = false

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 10) {
                if boxLeading {
                    box(configuration.isOn)
                    configuration.label
                } else {
                    configuration.label
                    Spacer(minLength: 8)
                    box(configuration.isOn)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? Text("On") : Text("Off"))
    }

    private func box(_ on: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(on ? Haze.accent : Color.white.opacity(0.92))
                .frame(width: 18, height: 18)
            HazeCheck(drawn: on, color: Haze.onAccent, lineWidth: 2.3)
                .frame(width: 10, height: 9)
        }
        .animation(Haze.Motion.press, value: on)
    }
}

/// A checkmark that draws itself on (a trim of its stroke) when it turns on
/// or, with `drawsOnAppear`, when it appears (a step just done); with
/// Reduce Motion it fades in instead.
struct HazeCheck: View {
    var drawn = true
    var color: Color = Haze.onAccent
    var lineWidth: CGFloat = 2.2
    var drawsOnAppear = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = drawn && (appeared || !drawsOnAppear)
        HazeCheckShape()
            .trim(from: 0, to: reduceMotion || shown ? 1 : 0)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .opacity(reduceMotion && !shown ? 0 : 1)
            .animation(reduceMotion ? Haze.Motion.fade : .easeOut(duration: 0.28), value: shown)
            .onAppear {
                guard drawsOnAppear, !appeared else { return }
                withAnimation(reduceMotion ? Haze.Motion.fade : .easeOut(duration: 0.38).delay(0.08)) { appeared = true }
            }
            .accessibilityHidden(true)
    }
}

/// The check's stroke, from its short arm to the end of its long one.
struct HazeCheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.06, y: rect.minY + rect.height * 0.54))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.37, y: rect.minY + rect.height * 0.88))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.95, y: rect.minY + rect.height * 0.12))
        return path
    }
}

/// The design's slider: an Avo green fill and thumb on a dark track. Drag
/// or click anywhere on it; arrow keys and VoiceOver step it. The thumb
/// grows a little under the pointer and while held.
struct HazeSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    /// Begins and ends a drag (for writing only when it ends).
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var dragging = false
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let thumb: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - thumb)
            let fraction = (value - range.lowerBound) / max(range.upperBound - range.lowerBound, .ulpOfOne)
            let lit = (hovering || dragging) && isEnabled
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.35))
                    .overlay { Capsule().strokeBorder(Haze.text.opacity(0.12)) }
                    .frame(height: 6)
                    .padding(.horizontal, thumb / 2)
                Capsule().fill(Haze.accent)
                    .frame(width: thumb / 2 + width * fraction, height: 6)
                    .padding(.leading, thumb / 2)
                Circle()
                    .fill(Haze.accent)
                    .overlay { Circle().strokeBorder(Haze.onAccent.opacity(0.25)) }
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .background { Circle().fill(Haze.accent.opacity(lit ? 0.22 : 0)).padding(-5) }
                    .frame(width: thumb, height: thumb)
                    .scaleEffect(reduceMotion ? 1 : (dragging ? 1.2 : lit ? 1.1 : 1))
                    .offset(x: width * fraction)
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .animation(Haze.Motion.hover, value: lit)
            .animation(Haze.Motion.press, value: dragging)
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
        .frame(height: 20)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .accessibilityElement()
        .accessibilityValue(Text(value, format: .number))
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
        if snapped != value { value = min(max(snapped, range.lowerBound), range.upperBound) }
    }
}

// MARK: - The Avo mark

/// Avo's avocado: the skin ring with its stem, the flesh, the pit
/// (branding's mark, 232 × 232 units).
struct AvoMark: View {
    var showsSkin = true

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 232
            context.scaleBy(x: scale, y: scale)
            if showsSkin {
                // Bowl and stem as one solid shape (nonzero): their overlap
                // stays filled. The flesh circle below covers the centre, so
                // the skin needs no cut-out hole — cutting one here with
                // even-odd also punched a notch where the stem meets the bowl.
                var skin = Path(ellipseIn: CGRect(x: 16, y: 16, width: 200, height: 200))
                skin.addRoundedRect(in: CGRect(x: 174.5, y: 18.25, width: 41.5, height: 179.2), cornerSize: CGSize(width: 20.75, height: 20.75))
                context.fill(skin, with: .color(Haze.skin))
            }
            context.fill(Path(ellipseIn: CGRect(x: 57.5, y: 57.5, width: 117, height: 117)), with: .color(Haze.accent))
            context.fill(Path(ellipseIn: CGRect(x: 86, y: 86, width: 60, height: 60)), with: .color(Haze.pit))
        }
        .accessibilityHidden(true)
    }
}

/// The glowing dot of something running. Its colour changes softly; while
/// something is under way (`pulsing`: Android starting or stopping) a ring
/// breathes out of it.
struct RunningDot: View {
    var size: CGFloat = 7
    var color: Color = Haze.running
    var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.8), radius: size * 0.6)
            .background {
                if pulsing { HazeDotPulse(color: color, size: size).transition(.opacity) }
            }
            .animation(.easeInOut(duration: 0.5), value: color)
            .animation(Haze.Motion.fade, value: pulsing)
            .accessibilityHidden(true)
    }
}

/// A ring that grows out of a dot and fades, again and again (a fade only
/// with Reduce Motion).
private struct HazeDotPulse: View {
    let color: Color
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HazeLoop(period: 1.6) { phase in
            let grown = 1 - (1 - phase) * (1 - phase)
            Circle()
                .stroke(color, lineWidth: max(1, size * 0.16))
                .frame(width: size, height: size)
                .scaleEffect(reduceMotion ? 1.6 : 1 + grown * 1.7)
                .opacity(reduceMotion ? 0.45 * (0.5 - 0.5 * cos(phase * 2 * .pi)) : 0.8 * (1 - phase))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Environment

private struct HazeSecondaryFillKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    /// A lighter veil for a secondary button over a hero.
    var hazeSecondaryFill: Color? {
        get { self[HazeSecondaryFillKey.self] }
        set { self[HazeSecondaryFillKey.self] = newValue }
    }
}

// MARK: - Motion

extension Haze {
    /// One vocabulary of motion for every window in the haze: responsive
    /// springs that settle without bouncing, the same timing everywhere.
    /// With Reduce Motion, movement and scale give way to plain fades.
    enum Motion {
        /// The pointer arriving or leaving: a card lifting, a button brightening.
        static let hover: Animation = .spring(response: 0.32, dampingFraction: 0.82)
        /// A click going down and coming back up.
        static let press: Animation = .spring(response: 0.22, dampingFraction: 0.8)
        /// A selection sliding to its new place (sidebar, segmented controls).
        static let slide: Animation = .spring(response: 0.38, dampingFraction: 0.84)
        /// Content changing: sections, steps, pages, the status pill.
        static let content: Animation = .spring(response: 0.42, dampingFraction: 0.88)
        /// Cards coming and going (notifications, the running apps).
        static let list: Animation = .spring(response: 0.4, dampingFraction: 0.84)
        /// Numbers rolling to their value.
        static let count: Animation = .spring(response: 0.7, dampingFraction: 0.9)
        /// A card turning toward the pointer, and back to flat.
        static let tilt: Animation = .spring(response: 0.55, dampingFraction: 0.8)
        /// Haze leaning toward the pointer: slow, with a lag, like light through mist.
        static let drift: Animation = .spring(response: 1.6, dampingFraction: 1)
        /// What Reduce Motion gets instead of movement.
        static let fade: Animation = .easeInOut(duration: 0.2)

        static let hoverScale: CGFloat = 1.015
        static let pressScale: CGFloat = 0.96
        static let cardPressScale: CGFloat = 0.985
        /// The most a card turns toward the pointer, in degrees.
        static let maxTilt: Double = 5

        /// `animation`, or a plain fade with Reduce Motion.
        static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation {
            reduceMotion ? fade : animation
        }

        /// Content arriving rises a few points as it fades in; leaving, it
        /// fades. Only the fades with Reduce Motion.
        @MainActor static func arrival(reduceMotion: Bool, rise: CGFloat = 10) -> AnyTransition {
            reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: rise)), removal: .opacity)
        }
    }

    /// The trackpad's lightest tick, kept for a choice snapping into place.
    enum Haptics {
        @MainActor static func snap() {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }
}

/// A phase from 0 to 1, looping every `period` seconds, for a pulse or a
/// sheen tied to something under way (Android starting, a download, a
/// list loading): at most 60 frames a second, nothing while not `running`.
struct HazeLoop<Content: View>: View {
    var period: Double
    var running: Bool
    var content: (Double) -> Content

    init(period: Double, running: Bool = true, @ViewBuilder content: @escaping (Double) -> Content) {
        self.period = period
        self.running = running
        self.content = content
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !running)) { context in
            content(running ? (context.date.timeIntervalSinceReferenceDate / period).truncatingRemainder(dividingBy: 1) : 0)
        }
    }
}

// MARK: - The pointer

/// The pointer over a window, for everything in it that reacts to where it
/// is: the haze leaning toward it, cards turning to face it, icons catching
/// its light. One tracker per window (`hazeTracksPointer`), published at
/// most once per display frame. Nil outside the window, while the window
/// is in the background and with Reduce Motion, so every effect rests.
@MainActor
@Observable
final class HazePointer {
    /// In the window's coordinates (SwiftUI's global space).
    private(set) var location: CGPoint?
    @ObservationIgnored private var pending: CGPoint?
    @ObservationIgnored private var live = false
    @ObservationIgnored private let clock = HazeFrameClock()

    init() {
        clock.onTick = { [weak self] _ in self?.publish() }
    }

    /// Paces the updates by the window's display.
    func attach(to window: NSWindow) { clock.attach(to: window) }

    func detach() { clock.invalidate() }

    /// Off while the window is in the background or Reduce Motion is on.
    func setLive(_ live: Bool) {
        self.live = live
        guard !live else { return }
        pending = nil
        clock.isRunning = false
        if location != nil { location = nil }
    }

    func move(_ point: CGPoint?) {
        guard live else { return }
        pending = point
        if clock.isAttached { clock.isRunning = true } else { publish() }
    }

    private func publish() {
        clock.isRunning = false
        if location != pending { location = pending }
    }
}

/// Calls `onTick` once per frame of a window's display while running (the
/// window's CADisplayLink, paused otherwise, so it costs nothing at rest).
@MainActor
final class HazeFrameClock {
    var onTick: ((CFTimeInterval) -> Void)?
    private var link: CADisplayLink?
    private let target = Target()

    init() {
        target.clock = self
    }

    var isAttached: Bool { link != nil }

    var isRunning: Bool {
        get { link.map { !$0.isPaused } ?? false }
        set { link?.isPaused = !newValue }
    }

    func attach(to window: NSWindow) {
        invalidate()
        let link = window.displayLink(target: target, selector: #selector(Target.step(_:)))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func invalidate() {
        link?.invalidate()
        link = nil
    }

    @MainActor
    private final class Target: NSObject {
        weak var clock: HazeFrameClock?

        @objc func step(_ link: CADisplayLink) {
            clock?.onTick?(link.targetTimestamp)
        }
    }
}

/// The arithmetic of the pointer effects, apart from the main actor so
/// visual effects (which run off it) can use it.
enum HazeGeometry {
    struct Tilt: Sendable {
        var degrees: Double = 0
        var x: CGFloat = 0
        var y: CGFloat = 1
    }

    /// A card turning to face the pointer: the angle and axis of its
    /// rotation3DEffect. With `reach` 0 it turns while the pointer is over
    /// it, with a reach wherever the pointer is within that of its centre.
    static func tilt(toward point: CGPoint?, in frame: CGRect, degrees: Double, reach: CGFloat) -> Tilt {
        guard let point, frame.width > 0, frame.height > 0 else { return Tilt() }
        var dx: CGFloat, dy: CGFloat
        if reach > 0 {
            dx = (point.x - frame.midX) / reach
            dy = (point.y - frame.midY) / reach
        } else {
            guard frame.contains(point) else { return Tilt() }
            dx = (point.x - frame.midX) / (frame.width / 2)
            dy = (point.y - frame.midY) / (frame.height / 2)
        }
        // Mostly about the vertical axis, a little about the horizontal one.
        dx = min(max(dx, -1), 1)
        dy = min(max(dy, -1), 1) * 0.6
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.001 else { return Tilt() }
        // A positive turn about y sends the right edge back, about x the top
        // edge: the side nearest the pointer goes back, so the card faces it.
        return Tilt(degrees: degrees * Double(min(length, 1)), x: -dy / length, y: dx / length)
    }

    /// How far a glow resting at `center` leans toward the pointer: `pull`
    /// of the way, easing off to at most `limit` points.
    static func drift(toward point: CGPoint?, from center: CGPoint, pull: CGFloat, limit: CGFloat) -> CGSize {
        guard let point, limit > 0 else { return .zero }
        func soft(_ value: CGFloat) -> CGFloat { limit * tanh(value / limit) }
        return CGSize(width: soft((point.x - center.x) * pull), height: soft((point.y - center.y) * pull))
    }

    /// The light on an icon's edge: the direction it faces (radians, 0
    /// to the right, clockwise) and how bright it is, from 0 at `reach`
    /// points away to 1 over the icon.
    static func edgeLight(toward point: CGPoint?, in frame: CGRect, reach: CGFloat) -> (angle: Double, intensity: Double) {
        guard let point, frame.width > 0, reach > 0 else { return (0, 0) }
        let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance < reach else { return (0, 0) }
        let t = 1 - distance / reach
        return (atan2(Double(point.y - frame.midY), Double(point.x - frame.midX)), Double(t * t * (3 - 2 * t)))
    }
}

extension View {
    /// Tracks the pointer for the window's effects (once, at its root).
    func hazeTracksPointer(_ pointer: HazePointer) -> some View {
        environment(pointer)
            .onContinuousHover(coordinateSpace: .global) { phase in
                switch phase {
                case .active(let location): pointer.move(location)
                case .ended: pointer.move(nil)
                }
            }
    }

    /// `hovering` follows the pointer, with the Library's timing.
    func hazeHover(_ hovering: Binding<Bool>) -> some View {
        modifier(HazeHoverTracking(hovering: hovering))
    }

    /// A card under the pointer, lit where the pointer is and lifted a little.
    func hazeCard(hovering: Bool, cornerRadius: CGFloat, glow: Color = Haze.accentText, lifts: Bool = true,
                  shadow: Bool = false) -> some View {
        hazePointerGlow(hovering, cornerRadius: cornerRadius, color: glow)
            .hazeLift(hovering && lifts, shadow: shadow)
    }

    /// A soft haze of light inside the view where the pointer is, while it hovers.
    func hazePointerGlow(_ hovering: Bool, cornerRadius: CGFloat, color: Color = Haze.accentText) -> some View {
        modifier(HazePointerGlowModifier(hovering: hovering, cornerRadius: cornerRadius, color: color))
    }

    /// Lifted a little while hovered, over its neighbours; opaque cards
    /// also cast a deeper shadow.
    func hazeLift(_ lifted: Bool, shadow: Bool = false) -> some View {
        modifier(HazeLiftModifier(lifted: lifted, shadow: shadow))
    }

    /// Turns a few degrees to face the pointer while `active` (over the
    /// view, or anywhere within `reach` of its centre), and back to flat
    /// with a spring. Only how it looks: layout and clicks stay put.
    func hazeTilt(_ active: Bool = true, degrees: Double = Haze.Motion.maxTilt, reach: CGFloat = 0) -> some View {
        modifier(HazeTiltModifier(active: active, degrees: degrees, reach: reach))
    }

    /// A thin light along a rounded edge that turns toward the pointer and
    /// brightens as it comes near (the Library's icons).
    func hazeEdgeLight(cornerRadius: CGFloat, reach: CGFloat = 150) -> some View {
        modifier(HazeEdgeLightModifier(cornerRadius: cornerRadius, reach: reach))
    }

    /// Arrives with its page: fades in and rises a few points after `delay`
    /// (only the fade with Reduce Motion).
    func hazeEntrance(_ shown: Bool, delay: Double = 0, rise: CGFloat = 12) -> some View {
        modifier(HazeEntranceModifier(shown: shown, delay: delay, rise: rise))
    }

    /// A band of light crossing the view now and again while `active` (a
    /// download, a placeholder) and its window is active.
    func hazeSheen(_ active: Bool, in shape: some Shape, intensity: Double = 0.22, period: Double = 1.8) -> some View {
        modifier(HazeSheenModifier(active: active, shape: shape, intensity: intensity, period: period))
    }
}

private struct HazeHoverTracking: ViewModifier {
    @Binding var hovering: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.onHover { inside in
            withAnimation(Haze.Motion.animation(Haze.Motion.hover, reduceMotion: reduceMotion)) { hovering = inside }
        }
    }
}

private struct HazePointerGlowModifier: ViewModifier {
    let hovering: Bool
    let cornerRadius: CGFloat
    let color: Color
    @Environment(HazePointer.self) private var pointer: HazePointer?

    func body(content: Content) -> some View {
        content.overlay {
            if hovering, let pointer {
                HazePointerGlow(pointer: pointer, cornerRadius: cornerRadius, color: color)
                    .transition(.opacity)
            }
        }
    }
}

/// Only this follows the pointer, not the card under it.
private struct HazePointerGlow: View {
    let pointer: HazePointer
    let cornerRadius: CGFloat
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            if let location = pointer.location {
                let frame = proxy.frame(in: .global)
                RadialGradient(colors: [color.opacity(0.16), color.opacity(0.05), color.opacity(0)],
                               center: UnitPoint(x: (location.x - frame.minX) / max(frame.width, 1),
                                                 y: (location.y - frame.minY) / max(frame.height, 1)),
                               startRadius: 0, endRadius: 190)
                    .blendMode(.plusLighter)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct HazeLiftModifier: ViewModifier {
    let lifted: Bool
    let shadow: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(lifted && !reduceMotion ? Haze.Motion.hoverScale : 1)
            .shadow(color: .black.opacity(shadow && lifted ? 0.42 : 0), radius: 16, y: 10)
            .zIndex(lifted ? 1 : 0)
    }
}

private struct HazeTiltModifier: ViewModifier {
    let active: Bool
    let degrees: Double
    let reach: CGFloat
    @Environment(HazePointer.self) private var pointer: HazePointer?

    func body(content: Content) -> some View {
        // Read only while active: a card at rest doesn't follow the pointer at all.
        let location = active ? pointer?.location : nil
        content
            .visualEffect { [degrees, reach] effect, proxy in
                let tilt = HazeGeometry.tilt(toward: location, in: proxy.frame(in: .global), degrees: degrees, reach: reach)
                return effect.rotation3DEffect(.degrees(tilt.degrees), axis: (x: tilt.x, y: tilt.y, z: 0), perspective: 0.5)
            }
            .animation(Haze.Motion.tilt, value: location)
    }
}

private struct HazeEdgeLightModifier: ViewModifier {
    let cornerRadius: CGFloat
    let reach: CGFloat
    @Environment(HazePointer.self) private var pointer: HazePointer?

    func body(content: Content) -> some View {
        content.overlay {
            if let pointer { HazeEdgeLight(pointer: pointer, cornerRadius: cornerRadius, reach: reach) }
        }
    }
}

/// An angular gradient stroke, bright where it faces the pointer.
private struct HazeEdgeLight: View {
    let pointer: HazePointer
    let cornerRadius: CGFloat
    let reach: CGFloat

    private static let stops: [Gradient.Stop] = [
        .init(color: Color(haze: 0xFBF8F1, alpha: 0.95), location: 0),
        .init(color: Color(haze: 0xD8E8A7, alpha: 0.4), location: 0.08),
        .init(color: Color(haze: 0xD8E8A7, alpha: 0), location: 0.2),
        .init(color: Color(haze: 0xD8E8A7, alpha: 0), location: 0.8),
        .init(color: Color(haze: 0xD8E8A7, alpha: 0.4), location: 0.92),
        .init(color: Color(haze: 0xFBF8F1, alpha: 0.95), location: 1),
    ]

    var body: some View {
        GeometryReader { proxy in
            let light = HazeGeometry.edgeLight(toward: pointer.location, in: proxy.frame(in: .global), reach: reach)
            if light.intensity > 0.01 {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(AngularGradient(stops: Self.stops, center: .center, angle: .radians(light.angle)), lineWidth: 1.4)
                    .opacity(light.intensity)
                    .blendMode(.plusLighter)
            }
        }
        .animation(.easeOut(duration: 0.3), value: pointer.location == nil)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct HazeEntranceModifier: ViewModifier {
    let shown: Bool
    let delay: Double
    let rise: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : rise)
            .animation(Haze.Motion.animation(Haze.Motion.content, reduceMotion: reduceMotion).delay(delay), value: shown)
    }
}

private struct HazeSheenModifier<S: Shape>: ViewModifier {
    let active: Bool
    let shape: S
    let intensity: Double
    let period: Double
    @Environment(\.appearsActive) private var windowActive

    func body(content: Content) -> some View {
        content.overlay {
            if active && windowActive {
                HazeSheenBand(intensity: intensity, period: period)
                    .clipShape(shape)
                    .transition(.opacity)
            }
        }
    }
}

/// The light of a sheen: a soft band sweeping across, then a pause (with
/// Reduce Motion, a glow that comes and goes instead).
private struct HazeSheenBand: View {
    let intensity: Double
    let period: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HazeLoop(period: period) { phase in
            GeometryReader { proxy in
                if reduceMotion {
                    Color.white.opacity(intensity * 0.4 * (0.5 - 0.5 * cos(phase * 2 * .pi)))
                } else {
                    let t = min(1, phase / 0.7)
                    let band = max(40, proxy.size.width * 0.4)
                    LinearGradient(colors: [.white.opacity(0), .white.opacity(intensity), .white.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: band, height: proxy.size.height)
                        .offset(x: -band + (proxy.size.width + band) * t * t * (3 - 2 * t))
                }
            }
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Placeholder bars where something is loading, a light passing over them.
struct HazeSkeleton: View {
    /// Each bar's width (of the row) and height.
    var bars: [(width: CGFloat, height: CGFloat)]
    var spacing: CGFloat = 10
    @Environment(\.appearsActive) private var windowActive

    var body: some View {
        GeometryReader { proxy in
            barShapes(width: proxy.size.width, fill: Haze.text.opacity(0.07))
                .overlay(alignment: .topLeading) {
                    if windowActive {
                        HazeSheenBand(intensity: 0.09, period: 1.6)
                            .mask(alignment: .topLeading) { barShapes(width: proxy.size.width, fill: .white) }
                    }
                }
        }
        .frame(height: bars.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, bars.count - 1)))
        .accessibilityHidden(true)
    }

    private func barShapes(width: CGFloat, fill: Color) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(bars.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: min(8, bars[index].height / 2), style: .continuous)
                    .fill(fill)
                    .frame(width: width * bars[index].width, height: bars[index].height)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

// MARK: - Drifting haze

/// Glows on a canvas `overscan` points larger than the view on every side,
/// so they can drift without showing an edge.
struct HazeGlowLayer: View {
    var glows: [HazeGlow]
    var overscan: CGFloat = 0

    var body: some View {
        Canvas { context, size in
            context.translateBy(x: overscan, y: overscan)
            let inner = CGSize(width: size.width - overscan * 2, height: size.height - overscan * 2)
            for glow in glows { HazeBackground.draw(glow, in: &context, size: inner) }
        }
        .padding(-overscan)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Glows that lean toward the pointer, slowly and with a lag, like light
/// through mist: each layer `pull` of the way from where it rests (a
/// negative pull leans away, for depth), at most `limit` points. Only
/// their offsets change; the glows are drawn once. They rest without a
/// pointer (another window active, Reduce Motion). Clip the view.
struct HazeDriftingGlows: View {
    struct Layer: Sendable {
        var glow: HazeGlow
        var pull: CGFloat
    }

    var layers: [Layer]
    var limit: CGFloat = 60
    @Environment(HazePointer.self) private var pointer: HazePointer?

    var body: some View {
        let location = pointer?.location
        ZStack {
            ForEach(layers.indices, id: \.self) { index in
                let layer = layers[index]
                HazeGlowLayer(glows: [layer.glow], overscan: limit * 1.5)
                    .visualEffect { [limit] effect, proxy in
                        let frame = proxy.frame(in: .global)
                        let center = CGPoint(x: frame.minX + layer.glow.x.resolve(frame.width),
                                             y: frame.minY + layer.glow.y.resolve(frame.height))
                        return effect.offset(HazeGeometry.drift(toward: location, from: center, pull: layer.pull, limit: limit))
                    }
            }
        }
        .animation(Haze.Motion.drift, value: location)
    }
}

/// The Library window's haze: Avo's green glowing over near black, its
/// light leaning toward the pointer.
struct HazeWindowBackground: View {
    var body: some View {
        ZStack {
            Haze.windowBase
            HazeDriftingGlows(layers: [
                .init(glow: Haze.windowGlows[0], pull: 0.06),
                .init(glow: Haze.windowGlows[1], pull: 0.09),
                .init(glow: Haze.windowGlows[2], pull: -0.025),
            ], limit: 64)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Forms

/// A Form in the haze (the Settings window, an app page's All Graphics
/// Settings): each Section is a card, its header the card's title and its
/// footer a note under the rows; rows in Mona with their values and
/// controls at the trailing edge, as `hazeFormControls` styles them. The
/// cards rise in one after another and catch the pointer's light. A Picker
/// has no style of its own here: rows use `HazePicker` or `HazeSegmented`
/// in a LabeledContent. `embedded` lays the sections out without cards or
/// scrolling, for a card of their own.
struct HazeFormStyle: FormStyle {
    var embedded = false

    func makeBody(configuration: Configuration) -> some View {
        HazeFormBody(content: configuration.content, embedded: embedded)
    }
}

private struct HazeFormBody: View {
    let content: FormStyleConfiguration.Content
    let embedded: Bool
    @State private var appeared = false

    var body: some View {
        if embedded {
            sections
        } else {
            ScrollView {
                sections
                    .padding(.horizontal, 34)
                    .padding(.top, 10)
                    .padding(.bottom, 40)
            }
            .scrollIndicators(.automatic)
            .onAppear { appeared = true }
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: embedded ? 18 : 16) {
            Group(sections: content) { sections in
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    if embedded, index > 0 {
                        Rectangle().fill(Haze.text.opacity(0.06)).frame(height: 1)
                    }
                    HazeFormSection(section: section, embedded: embedded)
                        .hazeEntrance(appeared || embedded, delay: Double(min(index, 6)) * 0.035, rise: 8)
                }
            }
        }
        .hazeFormControls()
    }
}

/// One section: a card with its title, rows and note.
private struct HazeFormSection: View {
    let section: SectionConfiguration
    let embedded: Bool
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let card = VStack(alignment: .leading, spacing: 14) {
            Group(subviews: section.header) { header in
                if !header.isEmpty {
                    HStack(spacing: 4) { ForEach(header) { $0 } }
                        .font(.mona(15, 600))
                        .foregroundStyle(Haze.text)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            HazeFormRows(rows: section.content)
            Group(subviews: section.footer) { footer in
                if !footer.isEmpty {
                    VStack(alignment: .leading, spacing: 6) { ForEach(footer) { $0 } }
                        .font(.mona(12))
                        .foregroundStyle(Haze.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if embedded {
            card
        } else {
            card
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .background {
                    ZStack {
                        shape.fill(Haze.card)
                        shape.strokeBorder(Haze.text.opacity(hovering ? 0.08 : 0.045))
                    }
                }
                .hazeCard(hovering: hovering, cornerRadius: 18, lifts: false)
                .hazeHover($hovering)
        }
    }
}

/// Rows one under the other outside a form (the app page's Graphics card),
/// a line between each two as in a form's section: each view of `content`
/// is a row.
struct HazeRows<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Group(subviews: content) { rows in HazeFormRows(rows: rows) }
    }
}

/// A section's rows, a line between each two as in System Settings; a
/// row's note (`hazeRowNote`) stays right under it.
private struct HazeFormRows: View {
    let rows: SubviewsCollection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                if row.id != rows.first?.id {
                    if row.containerValues.hazeRowNote {
                        Color.clear.frame(height: 7)
                    } else {
                        Rectangle().fill(Haze.text.opacity(0.07)).frame(height: 1).padding(.vertical, 10)
                    }
                }
                row
            }
        }
    }
}

extension ContainerValues {
    /// A form row's note, caption, problem or second control: it stays
    /// under that row, with no line between them (HazeFormRows).
    @Entry var hazeRowNote = false
}

extension View {
    /// This view belongs to the form row above it: no line between them.
    func hazeRowNote() -> some View {
        containerValue(\.hazeRowNote, true)
    }

    /// The haze's form controls for everything inside: labeled values,
    /// switches, buttons (a destructive role in the haze's red), disclosures,
    /// Mona and Avo's green.
    @MainActor func hazeFormControls() -> some View {
        labeledContentStyle(HazeLabeledContentStyle())
            .toggleStyle(HazeFormToggleStyle())
            .buttonStyle(HazeFormButtonStyle())
            .disclosureGroupStyle(HazeDisclosureStyle())
            .font(.mona(13.5))
            .foregroundStyle(Haze.text)
            .tint(Haze.accent)
    }

    /// A text field in the haze: plain, on a recessed rounded field that
    /// lights up while it has the focus.
    func hazeField() -> some View {
        modifier(HazeFieldModifier())
    }
}

/// A form row: the label leading, its value or control trailing.
struct HazeLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label
                .foregroundStyle(Haze.text)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Spacer(minLength: 12)
            configuration.content
                .foregroundStyle(Haze.textSecondary)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 26)
    }
}

/// A form's buttons: the haze's small pill, red for a destructive role.
struct HazeFormButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HazeButtonStyle(kind: configuration.role == .destructive ? .destructive : .secondary, height: 30, fontSize: 12.5,
                        horizontalPadding: 14)
            .makeBody(configuration: configuration)
    }
}

/// A form row's switch at the row's end, as in System Settings, in the
/// colours of the Setup Assistant's (HazeSwitchStyle): moss green when on,
/// its knob sliding across. The label stays outside the switch, so a (?) in
/// it opens its help; VoiceOver gets a Toggle with that label.
struct HazeFormToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            HazeSwitch(isOn: configuration.$isOn)
                .accessibilityRepresentation {
                    Toggle(isOn: configuration.$isOn) { configuration.label }
                }
        }
        .frame(minHeight: 26)
    }
}

/// The switch itself.
struct HazeSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let lit = hovering && isEnabled
        Button {
            isOn.toggle()
            Haze.Haptics.snap()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Color(haze: 0x7FA85C) : Haze.text.opacity(lit ? 0.2 : 0.16))
                    .overlay { Capsule().strokeBorder(Haze.text.opacity(isOn ? 0 : 0.08)) }
                Circle()
                    .fill(Color(haze: 0xFBF8F1))
                    .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                    .padding(2)
            }
            .frame(width: 38, height: 22)
            // Avo's green glows when on, a little more under the pointer.
            .shadow(color: Haze.accent.opacity(isOn ? (lit ? 0.4 : 0.25) : 0), radius: 7)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(Haze.Motion.animation(Haze.Motion.press, reduceMotion: reduceMotion), value: isOn)
        .animation(Haze.Motion.hover, value: lit)
        .onHover { hovering = $0 }
    }
}

extension HazeSegmented {
    /// Set into a card or a form row (the app page's Graphics card).
    static func inset(_ options: [(value: Value, label: Text)], selection: Binding<Value>, equalWidths: Bool = false) -> HazeSegmented {
        HazeSegmented(options: options, selection: selection, height: 28, cornerRadius: 10, fontSize: 12.5, fill: Haze.inset,
                      selectedFill: Haze.accent.opacity(0.2), segmentPadding: 12, equalWidths: equalWidths)
    }
}

/// − value +, in the haze. VoiceOver adjusts it like a stepper.
struct HazeStepper<Label: View>: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    /// The value between the buttons.
    @ViewBuilder var label: Label

    var body: some View {
        HStack(spacing: 8) {
            Button { change(by: -step) } label: {
                Image(systemName: "minus").font(.system(size: 10, weight: .bold))
            }
            .disabled(value <= range.lowerBound)
            .accessibilityLabel(Text("Decrease"))
            label
                .monospacedDigit()
                .lineLimit(1)
                .frame(minWidth: 48)
            Button { change(by: step) } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
            }
            .disabled(value >= range.upperBound)
            .accessibilityLabel(Text("Increase"))
        }
        .buttonStyle(HazeIconButtonStyle(size: 24, fill: Haze.field, foreground: Haze.text))
        .accessibilityElement(children: .combine)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: change(by: step)
            case .decrement: change(by: -step)
            @unknown default: break
            }
        }
    }

    private func change(by delta: Int) {
        let new = min(max(value + delta, range.lowerBound), range.upperBound)
        if new != value { value = new }
    }
}

/// A disclosure in the haze ("Older builds", "Advanced"): a chevron that
/// turns before the title, the content rising in below.
struct HazeDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        HazeDisclosureBody(configuration: configuration)
    }
}

private struct HazeDisclosureBody: View {
    let configuration: DisclosureGroupStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(Haze.Motion.animation(Haze.Motion.content, reduceMotion: reduceMotion)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                    configuration.label
                        .font(.mona(13, 600))
                }
                .foregroundStyle(Haze.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(HazeLinkButtonStyle())
            .accessibilityValue(configuration.isExpanded ? Text("Expanded") : Text("Collapsed"))
            if configuration.isExpanded {
                configuration.content
                    .padding(.leading, 17)
                    .transition(Haze.Motion.arrival(reduceMotion: reduceMotion, rise: 6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HazeFieldModifier: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        content
            .textFieldStyle(.plain)
            .font(.mona(13))
            .foregroundStyle(Haze.text)
            .focused($focused)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Haze.inset, in: shape)
            .overlay { shape.strokeBorder(focused ? Haze.accent.opacity(0.5) : Haze.text.opacity(0.1)) }
            .animation(Haze.Motion.hover, value: focused)
    }
}

/// Something to know or do, in a form: a symbol on a tinted tile, the text,
/// and buttons under it.
struct HazeNote<Actions: View>: View {
    let symbol: String
    let tint: Color
    let text: Text
    @ViewBuilder var actions: Actions

    init(symbol: String, tint: Color, text: Text, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.symbol = symbol
        self.tint = tint
        self.text = text
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                text
                    .font(.mona(13))
                    .foregroundStyle(Haze.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                actions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A sheet's ground in the haze: near black, a breath of Avo's green at
/// the top right (Change Android Version…, Change Size…).
struct HazeSheetBackground: View {
    var body: some View {
        ZStack {
            Haze.windowBase
            HazeBackground(glows: [HazeGlow(x: .fraction(0.9), y: .fraction(-0.06), rx: 460, ry: 300, color: 0xD8E8A7, alpha: 0.18)])
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
