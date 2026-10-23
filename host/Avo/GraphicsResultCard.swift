import AvoKit
import SwiftUI

// Settings › Graphics › Result: each target (the default window, this Mac's
// full screen) drawn to scale from a GraphicsPreview. The filled box is what
// Android renders, the outlined box the pixels it is shown on (with black
// bars where the shapes differ), and the arrow says how Avo scales between
// them.

struct GraphicsResultCard: View {
    /// "Window 892 × 502", "Full screen · Studio Display".
    let title: Text
    /// What VoiceOver calls the card: "Window", "Full screen".
    let name: String
    let preview: GraphicsPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            title
                .font(.mona(12.5, 600))
                .foregroundStyle(Haze.text)
                .lineLimit(1)
            GraphicsResultDiagram(preview: preview)
        }
        .padding(10)
        // Two fit side by side in an app's Graphics Settings sheet too; in a
        // row both take the taller one's height (its diagram stretches).
        .frame(idealWidth: 230, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Set into the card, as the haze's controls are.
        .background(Haze.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Haze.text.opacity(0.06))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.summary(name: name, preview: preview))
        .accessibilityAddTraits(.isImage)
    }

    /// One sentence per card: "Window: Android renders 1280 by 720, MetalFX
    /// enlarges it 1.4 times to 1784 by 1004." Sizes are passed as strings:
    /// an Int would be digit-grouped ("1.280", read as a fraction).
    static func summary(name: String, preview: GraphicsPreview) -> Text {
        let (w, h) = (String(preview.request.width), String(preview.request.height))
        let (shownW, shownH) = (String(preview.shown.width), String(preview.shown.height))
        let ratio = factor(preview.ratio)
        var text = switch preview.path {
        case .native:
            Text("\(name): Android renders \(w) by \(h), shown 1:1 without scaling.")
        case .metalFX:
            if let capped = preview.cappedMetalFXRatio {
                Text("\(name): Android renders \(w) by \(h), MetalFX enlarges it \(factor(capped)) times and bilinear scaling the rest, to \(shownW) by \(shownH).")
            } else {
                Text("\(name): Android renders \(w) by \(h), MetalFX enlarges it \(ratio) times to \(shownW) by \(shownH).")
            }
        case .bilinear:
            Text("\(name): Android renders \(w) by \(h), bilinear scaling enlarges it \(ratio) times to \(shownW) by \(shownH).")
        case .nearest:
            Text("\(name): Android renders \(w) by \(h), nearest neighbor enlarges it \(ratio) times to \(shownW) by \(shownH).")
        case .downsample:
            Text("\(name): Android renders \(w) by \(h), shrunk \(ratio) times to \(shownW) by \(shownH).")
        }
        if preview.hasBars {
            let (screenW, screenH) = (String(preview.screen.width), String(preview.screen.height))
            text = text + Text(verbatim: " ") + Text("Black bars fill the rest of the \(screenW) by \(screenH) screen.")
        }
        return text
    }

    /// "1.5", "2", "0.7" in the user's number format (Indonesian "1,5"); two
    /// decimals near 1, so a slight shrink never reads "×1".
    static func factor(_ value: Double) -> String {
        let digits = abs(value - 1) < 0.05 ? 2 : 1
        return value.formatted(.number.precision(.fractionLength(0...digits)))
    }
}

extension GraphicsPreview {
    /// Black bars left and right of the picture (beyond the few pixels a 1:1
    /// copy leaves at the edges).
    var hasSideBars: Bool { screen.width - shown.width > max(screen.width / 100, DisplaySizing.widthAlignment) }
    /// Black bars above and below it.
    var hasTopBars: Bool { screen.height - shown.height > max(screen.height / 100, 2) }
    var hasBars: Bool { hasSideBars || hasTopBars }
}

/// The two boxes at one scale, the arrow with the scaling chip between them,
/// and their sizes underneath. The boxes are neutral, so only the chip's
/// color (the accent, or orange) means something.
private struct GraphicsResultDiagram: View {
    let preview: GraphicsPreview

    var body: some View {
        let source = preview.request.size
        ScaledPairLayout(source: source, target: preview.screen) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.primary.opacity(0.45))
            ScalingConnector(preview: preview)
            ScreenBox(preview: preview)
            Text("Android \(Self.size(source))")
            Text(verbatim: Self.size(preview.screen))
        }
        .font(.mona(11))
        .foregroundStyle(Haze.textTertiary)
        .monospacedDigit()
        .animation(.easeInOut(duration: 0.25), value: preview)
    }

    /// "1280 × 720": resolutions are never digit-grouped.
    static func size(_ size: PixelSize) -> String { "\(size.width) × \(size.height)" }
}

/// The outlined screen (or window) with Android's picture where it lands and
/// black bars around it, at least 3 pt thick so they show at this scale.
private struct ScreenBox: View {
    let preview: GraphicsPreview
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            let screen = preview.screen
            guard screen.width > 0, screen.height > 0 else { return }
            let sx = size.width / CGFloat(screen.width)
            let sy = size.height / CGFloat(screen.height)
            let box = CGRect(origin: .zero, size: size)
            let outline = Path(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2)
            context.fill(outline, with: .color(Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.14)))
            if preview.hasBars {
                let shown = preview.shown
                var picture = box
                if preview.hasSideBars {
                    let bar = max(3, CGFloat(shown.x) * sx)
                    picture = picture.insetBy(dx: min(bar, size.width / 3), dy: 0)
                }
                if preview.hasTopBars {
                    let bar = max(3, CGFloat(shown.y) * sy)
                    picture = picture.insetBy(dx: 0, dy: min(bar, size.height / 3))
                }
                var bars = Path(box)
                bars.addRect(picture)
                context.fill(bars, with: .color(.black.opacity(colorScheme == .dark ? 0.9 : 0.8)), style: FillStyle(eoFill: true))
            }
            context.stroke(outline, with: .color(Color.primary.opacity(0.5)), lineWidth: 1)
        }
    }
}

/// The arrow from Android's picture to the screen, carrying the scaling path.
private struct ScalingConnector: View {
    let preview: GraphicsPreview

    private enum Kind { case accent, neutral, warning }

    var body: some View {
        let (label, kind) = chip
        HStack(spacing: 3) {
            Rectangle()
                .frame(minWidth: 6, maxHeight: 1)
            HStack(spacing: 3) {
                // Not only color: an accent that is orange too stays apart.
                switch kind {
                case .accent: Image(systemName: "sparkles")
                case .warning: Image(systemName: "exclamationmark.triangle.fill")
                case .neutral: EmptyView()
                }
                label
            }
            .font(.mona(11, 600))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(foreground(kind))
            .background(background(kind), in: Capsule())
            ArrowShape()
                .stroke(style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                .frame(minWidth: 10, maxHeight: 7)
        }
        .foregroundStyle(Color.primary.opacity(0.45))
        .padding(.horizontal, 4)
    }

    /// MetalFX in the accent color, plain scaling neutral, and shrinking
    /// orange, since Android then renders pixels nobody sees.
    private var chip: (Text, Kind) {
        let ratio = GraphicsResultCard.factor(preview.ratio)
        return switch preview.path {
        case .native: (Text("1:1 sharp"), .neutral)
        case .metalFX:
            if let capped = preview.cappedMetalFXRatio {
                (Text("MetalFX ×\(GraphicsResultCard.factor(capped)) + Smooth"), .accent)
            } else {
                (Text("MetalFX ×\(ratio)"), .accent)
            }
        case .bilinear: (Text("Smooth ×\(ratio)"), .neutral)
        case .nearest: (Text("Pixel art ×\(ratio)"), .neutral)
        case .downsample: (Text("Shrunk ×\(ratio)"), .warning)
        }
    }

    private func foreground(_ kind: Kind) -> Color {
        switch kind {
        case .accent: Haze.onAccent
        case .neutral: Haze.text
        case .warning: Haze.warning
        }
    }

    private func background(_ kind: Kind) -> Color {
        switch kind {
        case .accent: Haze.accent
        case .neutral: Haze.text.opacity(0.1)
        case .warning: Haze.warning.opacity(0.18)
        }
    }
}

private struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.move(to: CGPoint(x: rect.maxX - 4, y: rect.midY - 3.5))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.midY + 3.5))
        return path
    }
}

/// Places [source box, connector, screen box, source label, screen label]:
/// both boxes at the largest scale that fits (up to `maxBoxHeight` tall),
/// centered on one line with the connector between them, and each label
/// under its box's outer edge. As tall as the boxes need, or as the card
/// beside it in a row.
private struct ScaledPairLayout: Layout {
    let source: PixelSize
    let target: PixelSize
    var maxBoxHeight: CGFloat = 64
    var labelGap: CGFloat = 4

    private struct Geometry {
        var source: CGSize
        var target: CGSize
        var gap: CGFloat
        /// The boxes' and the connector's height.
        var band: CGFloat
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 5 else { return .zero }
        let width = proposal.width ?? 210
        let labels = labelHeight(subviews) + labelGap
        let needed = geometry(width: width, boxHeight: maxBoxHeight, subviews: subviews).band + labels
        let height = min(max(proposal.height ?? needed, needed), max(needed, maxBoxHeight + labels))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 5 else { return }
        let band = max(0, bounds.height - labelHeight(subviews) - labelGap)
        let geometry = geometry(width: bounds.width, boxHeight: min(maxBoxHeight, band), subviews: subviews)
        let (a, b, gap) = (geometry.source, geometry.target, geometry.gap)
        let x = bounds.minX + (bounds.width - a.width - gap - b.width) / 2
        let midY = bounds.minY + band / 2
        subviews[0].place(at: CGPoint(x: x, y: midY), anchor: .leading, proposal: ProposedViewSize(a))
        subviews[1].place(at: CGPoint(x: x + a.width, y: midY), anchor: .leading,
                          proposal: ProposedViewSize(width: gap, height: subviews[1].sizeThatFits(.unspecified).height))
        subviews[2].place(at: CGPoint(x: x + a.width + gap, y: midY), anchor: .leading, proposal: ProposedViewSize(b))
        let labelY = bounds.minY + band + labelGap
        subviews[3].place(at: CGPoint(x: x, y: labelY), anchor: .topLeading, proposal: .unspecified)
        subviews[4].place(at: CGPoint(x: x + a.width + gap + b.width, y: labelY), anchor: .topTrailing, proposal: .unspecified)
    }

    private func geometry(width: CGFloat, boxHeight: CGFloat, subviews: Subviews) -> Geometry {
        let connector = subviews[1].sizeThatFits(.unspecified)
        let sourceLabel = subviews[3].sizeThatFits(.unspecified)
        let targetLabel = subviews[4].sizeThatFits(.unspecified)
        let (w1, h1) = (CGFloat(max(source.width, 1)), CGFloat(max(source.height, 1)))
        let (w2, h2) = (CGFloat(max(target.width, 1)), CGFloat(max(target.height, 1)))
        let scale = max(0, min((width - connector.width) / (w1 + w2), boxHeight / max(h1, h2)))
        let a = Self.visible(CGSize(width: w1 * scale, height: h1 * scale))
        let b = Self.visible(CGSize(width: w2 * scale, height: h2 * scale))
        // Wider than the connector needs when the labels would meet.
        let gap = max(0, min(max(connector.width, sourceLabel.width + 12 + targetLabel.width - a.width - b.width),
                             width - a.width - b.width))
        return Geometry(source: a, target: b, gap: gap, band: max(a.height, b.height, connector.height))
    }

    private func labelHeight(_ subviews: Subviews) -> CGFloat {
        max(subviews[3].sizeThatFits(.unspecified).height, subviews[4].sizeThatFits(.unspecified).height)
    }

    /// At least 6 pt on the short side, so a tiny Android picture (360p on
    /// a 5K display) still reads as a box rather than a dash.
    private static func visible(_ size: CGSize) -> CGSize {
        let short = min(size.width, size.height)
        guard short > 0, short < 6 else { return size }
        return CGSize(width: size.width * 6 / short, height: size.height * 6 / short)
    }
}
