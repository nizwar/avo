import AppKit
import AvoKit
import SwiftUI

/// The form rows of one set of graphics settings, shared by Settings ›
/// Graphics (the Apps and Games profiles) and an app's Graphics Settings
/// sheet. "Android’s screen" picks the mode: the window's pixels × a render
/// scale, a fixed resolution, or the screen of the phone chosen as device
/// profile; then come the shape (Aspect ratio) and the Orientation. What
/// each control does is in the (?) after its title. Errors show under their
/// control through `fieldPrefix` (`appGraphics`, `gameGraphics` or
/// `graphicsOverrides.<package>`).
struct GraphicsSettingsEditor: View {
    @Environment(ControlPanelModel.self) private var model
    @Binding var settings: GraphicsSettings
    let fieldPrefix: String

    /// Custom is picked but the value is still a preset.
    @State private var customResolution = false
    /// The value a typed-in resolution was rounded to, until the next edit.
    @State private var roundedTo: Int?

    private var screen: NSScreen? { NSScreen.main }
    private var backingScale: Double { Double(screen?.backingScaleFactor ?? 2) }
    private var minimumRenderScale: Int {
        DisplaySizing.minimumRenderScale(backingScale: backingScale, interfaceScale: settings.interfaceScale)
    }
    /// The chosen device profile, and its screen (none for Avo's own identity).
    private var phone: DeviceProfile? { model.deviceProfile }
    private var device: DeviceProfile.Display? { phone?.display }
    /// The mode in effect: without a phone's screen, Android follows the window.
    private var mode: GraphicsSettings.Mode { settings.effectiveMode(device: device) }

    var body: some View {
        modeRow

        switch mode {
        case .followWindow: renderScaleRows
        case .fixed: resolutionRows
        case .deviceProfile: phoneRows
        }
        aspectRatioRow
        orientationRow

        // The phone's screen has the phone's own density.
        if mode != .deviceProfile {
            LabeledContent {
                HazePicker("Interface size", selection: $settings.interfaceScale) {
                    for preset in GraphicsSettings.InterfaceSizePreset.allCases {
                        HazeOption(verbatim: title(for: preset), preset.rawValue)
                    }
                    if GraphicsSettings.InterfaceSizePreset(rawValue: settings.interfaceScale) == nil {
                        HazeOption("Custom (\(settings.interfaceScale)%)", settings.interfaceScale)
                    }
                }
            } label: {
                HelpTitle("Interface size", help: "Default makes 1 Android dp the size of 1 Mac point. Avo sets the density for you, so changing the resolution or render scale changes sharpness, not the layout.")
            }
            IssueText(field: "\(fieldPrefix).interfaceScale")
        }

        LabeledContent {
            HazePicker("Upscaling", selection: $settings.filter) {
                HazeOption("Sharp (MetalFX)", GraphicsSettings.Filter.metalFXSpatial)
                HazeOption("Smooth", GraphicsSettings.Filter.bilinear)
                HazeOption("Pixel art", GraphicsSettings.Filter.nearest)
            }
        } label: {
            HelpTitle("Upscaling") {
                HelpTerm("Sharp (MetalFX)", "Apple's MetalFX keeps edges and text sharp when the picture is enlarged. Best for most games.")
                HelpTerm("Smooth", "Slightly soft, uses the least power.")
                HelpTerm("Pixel art", "Keeps pixels square and crisp. Cleanest at 2×, 3× and so on.")
                // Why Result says "Shrunk" with MetalFX chosen.
                if settings.filter == .metalFXSpatial, previews.contains(where: { $0.preview.shrinks }) {
                    Text("MetalFX only enlarges. When Android's picture is larger than the window, Avo shrinks it smoothly instead.")
                }
            }
        }

        LabeledContent {
            CommittingSlider(value: $settings.sharpness, range: GraphicsSettings.sharpnessRange, step: GraphicsSettings.sharpnessStep) {
                $0 == 0 ? Text("Off") : Text(Double($0) / 100, format: .percent)
            }
        } label: {
            HelpTitle("Sharpness", help: "Adds adaptive sharpening after scaling. Add a little if the picture looks soft.")
        }
        .disabled(settings.filter == .nearest)
        IssueText(field: "\(fieldPrefix).sharpness")

        LabeledContent {
            HazePicker("Smooth edges", selection: $settings.antiAliasing) {
                HazeOption("Off", GraphicsSettings.AntiAliasing.off)
                HazeOption("Fast (FXAA)", GraphicsSettings.AntiAliasing.fxaa)
                HazeOption("High (2× supersampling)", GraphicsSettings.AntiAliasing.ssaa2x)
                HazeOption("Ultra (4× supersampling)", GraphicsSettings.AntiAliasing.ssaa4x)
            }
        } label: {
            HelpTitle("Smooth edges") {
                HelpTerm("Fast (FXAA)", "Smooths jagged edges in Avo's renderer, before the picture is scaled. Light on the GPU; edges and small text get a little softer.")
                HelpTerm("High and Ultra", "Android renders 2 or 4 times the pixels at the same layout, and Avo shrinks the picture to the window: the smoothest edges, but the GPU draws that many more pixels.")
            }
        }

        resultRows
        warnings
    }

    // MARK: Mode

    @ViewBuilder private var modeRow: some View {
        LabeledContent {
            HazePicker("Screen size", selection: Binding(get: { mode }, set: { settings.mode = $0 })) {
                HazeOption("Window", GraphicsSettings.Mode.followWindow)
                HazeOption("Fixed", GraphicsSettings.Mode.fixed)
                if let phone, device != nil {
                    HazeOption("Phone (\(phone.name))", GraphicsSettings.Mode.deviceProfile)
                } else {
                    HazeOption("Phone", GraphicsSettings.Mode.deviceProfile, isEnabled: false)
                }
            }
        } label: {
            HelpTitle("Screen size") {
                HelpTerm("Window", "Android renders at the window's size, so text stays sharp. Resizing the window changes Android's resolution.")
                HelpTerm("Fixed", "Android keeps the resolution below when you resize the window or enter full screen. Enlarging the window enlarges the picture; it doesn't give the app more room.")
                HelpTerm("Phone", "Android gets the screen of the phone chosen as device profile, its resolution and density, so apps lay out exactly as on that phone. The window keeps the phone's shape, and Interface size doesn't apply.")
            }
        }
        if device == nil {
            caption("To use Phone, choose a phone in Settings › Privacy & Security › Device profile.")
        }
    }

    // MARK: Follow mode

    @ViewBuilder private var renderScaleRows: some View {
        let floor = minimumRenderScale
        LabeledContent {
            HazePicker("Render scale", selection: $settings.renderScale) {
                for preset in GraphicsSettings.RenderScalePreset.allCases {
                    if preset.rawValue < floor {
                        HazeOption("\(title(for: preset)) — not on this display", preset.rawValue, isEnabled: false)
                    } else {
                        HazeOption(verbatim: title(for: preset), preset.rawValue)
                    }
                }
                if GraphicsSettings.RenderScalePreset(rawValue: settings.renderScale) == nil {
                    HazeOption("Custom (\(settings.renderScale)%)", settings.renderScale)
                }
            }
        } label: {
            HelpTitle("Render scale", help: "Android renders fewer pixels and Avo enlarges the picture to fill the window. The layout stays the same.")
        }
        CommittingSlider(value: $settings.renderScale, range: GraphicsSettings.renderScaleRange, step: 1) {
            Text(Double($0) / 100, format: .percent)
        }
        .hazeRowNote()
        // A limit of this display, so it stays in view.
        if floor > GraphicsSettings.renderScaleRange.lowerBound {
            caption("On this display the lowest is \(floor)%, because Android's density can't go below 120 dpi.")
        }
        IssueText(field: "\(fieldPrefix).renderScale")
    }

    // MARK: Fixed mode

    @ViewBuilder private var resolutionRows: some View {
        let presets = GraphicsSettings.resolutionPresets
        let isCustom = customResolution || !presets.contains(settings.shortSide)
        let selection = Binding(get: { isCustom ? 0 : settings.shortSide }, set: { value in
            roundedTo = nil
            if value == 0 {
                customResolution = true
            } else {
                customResolution = false
                settings.shortSide = value
            }
        })
        LabeledContent {
            // Every preset in a row when it fits (Settings), else a menu (an app's sheet).
            ViewThatFits(in: .horizontal) {
                HazeSegmented.inset(presets.map { ($0, Text(verbatim: GraphicsSettings.resolutionName($0))) } + [(0, Text("Custom"))],
                                    selection: selection)
                    .fixedSize()
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(Text("Resolution"))
                HazePicker("Resolution", selection: selection) {
                    for preset in presets { HazeOption(verbatim: GraphicsSettings.resolutionName(preset), preset) }
                    HazeOption("Custom", 0)
                }
            }
        } label: {
            HelpTitle("Resolution") {
                Text("Pixels on the short side of Android's screen, up to 4K (2160).")
                Text("Fewer pixels mean more FPS: 720p draws less than half the pixels of 1080p.")
            }
        }
        if isCustom {
            HStack(spacing: 6) {
                Spacer()
                // Commits on Return or when focus leaves the field.
                TextField("Resolution", value: Binding(get: { settings.shortSide }, set: { value in
                    let normalized = GraphicsSettings.normalizedShortSide(value)
                    roundedTo = normalized == value ? nil : normalized
                    settings.shortSide = normalized
                }), format: .number.grouping(.never))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .hazeField()
                    .frame(width: 76)
                Text("px").foregroundStyle(Haze.textTertiary)
            }
            .hazeRowNote()
            if let roundedTo {
                // Strings: resolutions are never digit-grouped.
                let range = GraphicsSettings.shortSideRange
                caption("Rounded to \(String(roundedTo)) px: Android needs an even number between \(String(range.lowerBound)) and \(String(range.upperBound)).")
            }
        }
        // Above 1600p the density stops at Android's highest, and the layout grows.
        if let window = previews.first?.preview.request, window.dpi >= DisplaySizing.maximumDPI, window.limitedByDensity {
            let layout = window.layoutDP
            caption("Android's density stops at its highest, 640 dpi, so apps lay out for \(Self.size(layout.width, layout.height)) dp: a little smaller than at lower resolutions.")
        }
        IssueText(field: "\(fieldPrefix).shortSide")
    }

    // MARK: Phone's screen

    @ViewBuilder private var phoneRows: some View {
        if let phone, let device {
            let request = previews.first?.preview.request
            LabeledContent {
                Text(verbatim: request.map { "\(Self.size(Int($0.width), Int($0.height))) · \($0.dpi) dpi" } ?? "")
                    .monospacedDigit()
                    .foregroundStyle(Haze.textSecondary)
            } label: {
                HelpTitle("Resolution") {
                    Text("\(phone.name)’s screen: \(Self.size(device.width, device.height)) pixels at \(device.dpi) dpi, from its device profile.")
                    Text("Changing the device profile changes it in open windows right away; some apps reload their screen for a moment.")
                }
            }
        }
    }

    // MARK: Shape

    @ViewBuilder private var aspectRatioRow: some View {
        if mode == .deviceProfile, let device {
            LabeledContent("Aspect ratio") {
                Text("\(device.ratioName) (the phone’s)").foregroundStyle(Haze.textSecondary)
            }
        } else {
            let ratios = GraphicsSettings.AspectRatio.allCases.filter { $0 != .matchWindow }
            let current = mode
            LabeledContent {
                HazePicker("Aspect ratio", selection: Binding(get: { settings.aspectRatio(for: current) },
                                                              set: { settings.setAspectRatio($0, for: current) })) {
                    HazeOption("Match window", GraphicsSettings.AspectRatio.matchWindow)
                    for ratio in ratios {
                        HazeOption(verbatim: ratio.rawValue, ratio)
                    }
                }
            } label: {
                HelpTitle("Aspect ratio") {
                    let fixedRatios = ratios.map(\.rawValue).formatted(.list(type: .or))
                    if current == .followWindow {
                        HelpTerm("Match window", "The window resizes freely, and Android takes its shape.")
                        HelpTerm(verbatim: fixedRatios,
                                 "The window keeps this shape when you resize it; Android still renders at the window's size. Full screen adds black bars when the screen's shape differs.")
                    } else {
                        HelpTerm("Match window", "Android takes the window's shape. Changing the shape (dragging an edge, full screen) makes Android lay out again once.")
                        HelpTerm(verbatim: fixedRatios,
                                 "The window keeps this shape when you resize it, so Android never lays out again. Full screen adds black bars when the screen's shape differs.")
                    }
                }
            }
        }
    }

    private var orientationRow: some View {
        LabeledContent {
            HazeSegmented.inset([(VMConfig.Orientation.portrait, Text("Portrait")), (.landscape, Text("Landscape"))],
                                selection: $settings.orientation)
                .fixedSize()
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Orientation"))
        } label: {
            HelpTitle("Orientation", help: "The shape an app's window opens in, and the one a fixed shape or the phone's screen keeps; open windows turn right away. An app that asks for the other orientation still turns its window.")
        }
    }

    // MARK: Result

    private struct PreviewRow: Identifiable {
        let id: Int
        /// "Window 892 × 502", "Full screen · Studio Display".
        let title: Text
        /// For VoiceOver: "Window", "Full screen".
        let name: String
        let preview: GraphicsPreview
    }

    /// The default window (turned to the orientation, conformed to a locked
    /// shape) and this Mac's full screen below the camera housing, both at
    /// the main screen's scale.
    private var previews: [PreviewRow] {
        guard let config = model.config else { return [] }
        let landscape = settings.orientation == .landscape
        var window = config.defaultWindowSize
        if landscape != (window.width > window.height) { window = window.rotated }
        var content = (width: Double(window.width), height: Double(window.height))
        if let ratio = settings.lockedRatio(device: device) {
            content = DisplaySizing.conformedContentSize(width: content.width, height: content.height, longOverShort: ratio)
        }
        let windowSize = Self.size(Int(content.width.rounded()), Int(content.height.rounded()))
        var rows = [PreviewRow(id: 0, title: Text("Window \(windowSize)"), name: String(localized: "Window"),
                               preview: GraphicsPreview(contentWidth: content.width, contentHeight: content.height,
                                                        backingScale: backingScale, settings: settings, device: device, landscape: landscape))]
        if let screen {
            let full = screen.frame.size
            rows.append(PreviewRow(id: 1, title: Text("Full screen · \(screen.localizedName)"), name: String(localized: "Full screen"),
                                   preview: GraphicsPreview(contentWidth: full.width, contentHeight: full.height - screen.safeAreaInsets.top,
                                                            backingScale: backingScale, settings: settings, device: device,
                                                            landscape: landscape)))
        }
        return rows
    }

    /// A card per target, side by side when they fit (GraphicsResultCard.swift).
    @ViewBuilder private var resultRows: some View {
        let rows = previews
        if let first = rows.first {
            VStack(alignment: .leading, spacing: 8) {
                HelpTitle("Result") {
                    Text("The filled box is what Android renders, the outlined box the pixels it is shown on, both at the same scale.")
                    let layout = first.preview.request.layoutDP
                    Text("Android lays out for \(Self.size(layout.width, layout.height)) dp at \(Int(first.preview.request.dpi)) dpi.")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 10) { resultCards(rows) }
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 10) { resultCards(rows) }
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func resultCards(_ rows: [PreviewRow]) -> some View {
        ForEach(rows) { row in
            GraphicsResultCard(title: row.title, name: row.name, preview: row.preview)
        }
    }

    // MARK: Warnings

    /// Only for choices that look wrong on this Mac; the factory defaults
    /// never show one on a Retina screen.
    @ViewBuilder private var warnings: some View {
        if let window = previews.first?.preview {
            if settings.filter == .nearest, case .nearest = window.path, abs(window.ratio - window.ratio.rounded()) > 0.01 {
                warning("Pixel art looks uneven at \(window.ratio.formatted(.number.precision(.fractionLength(2))))×; it is cleanest at 2× or 3×.")
            }
            if mode == .fixed, window.ratio < 0.8 {
                warning("The window shows fewer pixels than Android renders. A lower resolution looks the same and runs faster.")
            }
            // Software rendering draws on the Mac's CPU: many pixels are slow.
            if rendersInSoftware, window.request.width * window.request.height > GraphicsSettings.softwareRenderingPixelBudget {
                HazeNote(symbol: "tortoise.fill", tint: Haze.warning,
                         text: Text("Android renders in software on this Mac’s CPU, so this many pixels can make apps and games slow. A lower resolution, or the GPU renderer under Rendering, runs faster."))
                    .hazeRowNote()
            }
        }
    }

    /// The Software renderer is chosen, or Android fell back to it.
    private var rendersInSoftware: Bool {
        model.config?.rendererMode == .software || model.status.renderer?.mode == .software
    }

    // MARK: Helpers

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.mona(12)).foregroundStyle(Haze.textTertiary).fixedSize(horizontal: false, vertical: true)
            .hazeRowNote()
    }

    private func warning(_ text: LocalizedStringKey) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.mona(12))
            .foregroundStyle(Haze.warning)
            .fixedSize(horizontal: false, vertical: true)
            .hazeRowNote()
    }

    private func title(for preset: GraphicsSettings.RenderScalePreset) -> String {
        let value = preset.rawValue
        return switch preset {
        case .native: String(localized: "Native (\(value)%)")
        case .ultraQuality: String(localized: "Ultra Quality (\(value)%)")
        case .quality: String(localized: "Quality (\(value)%)")
        case .balanced: String(localized: "Balanced (\(value)%)")
        case .performance: String(localized: "Performance (\(value)%)")
        }
    }

    private func title(for preset: GraphicsSettings.InterfaceSizePreset) -> String {
        switch preset {
        case .smaller: String(localized: "Smaller")
        case .standard: String(localized: "Default")
        case .larger: String(localized: "Larger")
        case .largest: String(localized: "Largest")
        }
    }

    /// "1280 × 720": resolutions are never digit-grouped.
    private static func size(_ width: Int, _ height: Int) -> String { "\(width) × \(height)" }
}

/// A slider whose value reaches the binding when the drag ends, or 400 ms
/// after the last change that is not part of a drag (keyboard and VoiceOver
/// changes have no drag), so open windows re-plug Android once rather than
/// at every step. The number beside it follows the thumb meanwhile.
struct CommittingSlider: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    /// The number beside the slider, for the value under the thumb.
    let label: (Int) -> Text
    @State private var draft: Double?
    @State private var dragging = false
    @State private var pending: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 12) {
            HazeSlider(value: Binding(get: { draft ?? Double(value) }, set: { newValue in
                draft = newValue
                pending?.cancel()
                // Holding the thumb still is not the end of a drag.
                guard !dragging else { return }
                pending = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    if !Task.isCancelled { commit() }
                }
            }), range: Double(range.lowerBound)...Double(range.upperBound), step: Double(step)) { editing in
                dragging = editing
                if editing { pending?.cancel() } else { commit() }
            }
            .frame(minWidth: 140, maxWidth: 240)
            // The ends reserve the width, so a wider word (Indonesian
            // "Nonaktif") stays on one line and the slider never moves.
            ZStack(alignment: .trailing) {
                label(range.lowerBound).hidden()
                label(range.upperBound).hidden()
                label(draft.map(clamped) ?? value)
            }
            .monospacedDigit()
            .lineLimit(1)
            .frame(minWidth: 44, alignment: .trailing)
        }
    }

    private func clamped(_ value: Double) -> Int {
        min(max(Int(value.rounded()), range.lowerBound), range.upperBound)
    }

    private func commit() {
        pending?.cancel()
        pending = nil
        guard let draft else { return }
        self.draft = nil
        let committed = clamped(draft)
        if committed != value { value = committed }
    }
}
