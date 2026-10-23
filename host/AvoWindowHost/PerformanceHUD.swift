import AppKit
import AvoKit

/// The performance overlay in the top-left corner of an app window (View ›
/// Performance HUD, ⌥⌘P): frame rate, and in Detailed also Android's size,
/// how the picture is scaled and the density. It is a view above the
/// picture, never drawn by the renderer, so it is never in Avo's screenshots
/// or recordings. Digits only, no colour coding: a number never alarms
/// without a reason. White on a near-opaque dark plate with a hairline edge,
/// so it reads over bright and dark scenes alike while covering little.
@MainActor
final class PerformanceHUDView: NSView {
    var level: PerformanceHUDLevel = .off {
        didSet {
            guard level != oldValue else { return }
            isHidden = level == .off
            updateTimer()
            refresh()
        }
    }

    weak var renderer: MetalRenderer?
    /// What the window last asked Android for (size, density).
    var request: () -> DisplayRequest? = { nil }

    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?
    /// The text on the label, so an unchanged reading is not set again.
    private var shownText = ""
    /// Display scaling of the window's screen, recomputed only when the
    /// screen or its backing scale changes.
    private var scalingCache: (screen: CGDirectDisplayID, backing: CGFloat, factor: Double?)?

    /// The first line (the frame rate) bold, the details a little smaller;
    /// fixed-width digits, so the numbers do not shift as they change.
    private static let headlineFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
    private static let detailFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        layer?.cornerRadius = 8
        isHidden = true
        label.font = Self.headlineFont
        label.textColor = .white
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        // One element for VoiceOver, read as a sentence.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        label.setAccessibilityElement(false)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Never takes a click or the keyboard: everything belongs to the game.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTimer()
    }

    /// 4 Hz, only while shown: a hidden HUD costs nothing.
    private func updateTimer() {
        let wanted = level != .off && window != nil
        if !wanted {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
                // Fired on the main run loop, which it never leaves.
                nonisolated(unsafe) let timer = timer
                MainActor.assumeIsolated {
                    // A closed window frees the HUD without hiding it first.
                    guard let self else { return timer.invalidate() }
                    self.refresh()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    private func updateAppearance() {
        let workspace = NSWorkspace.shared
        // Dark enough that white text keeps its contrast over a white sky;
        // Reduce Transparency: opaque. The hairline keeps the plate's edge
        // over dark scenes; Increase Contrast: a solid border.
        let alpha = workspace.accessibilityDisplayShouldReduceTransparency ? 1 : 0.8
        layer?.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: alpha).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(workspace.accessibilityDisplayShouldIncreaseContrast ? 1 : 0.18).cgColor
    }

    private func refresh() {
        guard level != .off, let renderer else { return }
        updateAppearance()
        let stats = renderer.statistics()
        let fps = Int(stats.framesPerSecond.rounded())
        let fpsText = stats.idle ? String(localized: "Idle", bundle: .windowHost) : String(localized: "\(fps) FPS", bundle: .windowHost)
        var lines: [String]
        if level == .fps {
            lines = [fpsText]
        } else {
            lines = detailedLines(stats, fpsText: fpsText)
        }
        if stats.waitingForAndroid { lines.append(String(localized: "Waiting for Android…", bundle: .windowHost)) }
        show(lines)
        setAccessibilityLabel(String(localized: "Performance HUD, \(stats.idle ? 0 : fps) frames per second", bundle: .windowHost))
    }

    private func show(_ lines: [String]) {
        let text = lines.joined(separator: "\n")
        guard text != shownText else { return }
        shownText = text
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        let styled = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            styled.append(NSAttributedString(string: (index > 0 ? "\n" : "") + line, attributes: [
                .font: index == 0 ? Self.headlineFont : Self.detailFont,
                .foregroundColor: index == 0 ? NSColor.white : NSColor.white.withAlphaComponent(0.88),
                .paragraphStyle: paragraph,
            ]))
        }
        label.attributedStringValue = styled
    }

    private func detailedLines(_ stats: RenderStatistics, fpsText: String) -> [String] {
        var lines: [String] = []
        if stats.idle {
            lines.append(fpsText)
        } else {
            let timing = String(localized: "\(Self.decimal(stats.averageFrameMs, 1)) ms (max \(Self.decimal(stats.maxFrameMs, 1)))", bundle: .windowHost)
            lines.append("\(fpsText) · \(timing)")
        }
        if let source = stats.source {
            let presented = stats.destination.map { DisplaySizing.presentationRect(source: source, target: $0).size }
            let screen = presented.map(Self.size) ?? "–"
            lines.append(String(localized: "Android \(Self.size(source)) → \(screen)", bundle: .windowHost))
            if let path = stats.path, let presented {
                lines.append(pathLine(path, source: source, presented: presented, stats: stats))
            }
        }
        if let request = request() {
            var parts = [String(localized: "\(Int(request.dpi)) dpi", bundle: .windowHost),
                         String(localized: "\(Self.size(request.layoutDP)) dp", bundle: .windowHost)]
            if stats.skippedFrames > 0 { parts.append(String(localized: "Skipped \(stats.skippedFrames)", bundle: .windowHost)) }
            lines.append(parts.joined(separator: " · "))
        }
        if let factor = displayScaling() {
            lines.append(String(localized: "Display scaling ×\(Self.decimal(factor, 2))", bundle: .windowHost))
        }
        return lines
    }

    /// "MetalFX ×1.14 · Sharpness Off · Scaling 0.3 ms", "Bilinear ×1.14 (resizing)", "1:1", …
    private func pathLine(_ path: ScalingPath, source: PixelSize, presented: PixelSize, stats: RenderStatistics) -> String {
        func ratio(_ from: PixelSize, _ to: PixelSize) -> String {
            guard from.width > 0, from.height > 0 else { return "–" }
            return Self.decimal(min(Double(to.width) / Double(from.width), Double(to.height) / Double(from.height)), 2)
        }
        var text: String
        switch path {
        case .native:
            text = "1:1"
        case let .metalFX(output):
            text = String(localized: "MetalFX ×\(ratio(source, output))", bundle: .windowHost)
            if output != presented { text += " + " + String(localized: "Smooth ×\(ratio(output, presented))", bundle: .windowHost) }
        case .bilinear:
            text = String(localized: "Smooth ×\(ratio(source, presented))", bundle: .windowHost)
        case .nearest:
            text = String(localized: "Pixel art ×\(ratio(source, presented))", bundle: .windowHost)
        case .downsample:
            text = String(localized: "Shrunk ×\(ratio(source, presented))", bundle: .windowHost)
        }
        if let fallback = stats.fallback {
            let reason = switch fallback {
            case .preparing: String(localized: "(preparing MetalFX…)", bundle: .windowHost)
            case .resizing: String(localized: "(resizing)", bundle: .windowHost)
            case .failed: String(localized: "(MetalFX failed)", bundle: .windowHost)
            case .memoryPressure: String(localized: "(low memory)", bundle: .windowHost)
            // No MetalFX on this GPU: the filter row already says Bilinear.
            case .unavailable: ""
            }
            if !reason.isEmpty { text += " " + reason }
        }
        if stats.sharpened, let sharpness = currentSharpness {
            text += " · " + String(localized: "Sharpness \(sharpness)%", bundle: .windowHost)
        } else if case .metalFX = path {
            text += " · " + String(localized: "Sharpness Off", bundle: .windowHost)
        }
        if let scaling = stats.scalingMs {
            text += " · " + String(localized: "Scaling \(Self.decimal(scaling, 1)) ms", bundle: .windowHost)
        }
        return text
    }

    /// The sharpness the window asked for, shown when the renderer sharpened.
    var currentSharpness: Int?

    /// Pixels the screen really has per backing pixel, below 1 on scaled
    /// display modes ("More Space"): WindowServer resamples the picture once
    /// more, so 1:1 there is sharp but not pixel-exact. nil when it is 1.
    private func displayScaling() -> Double? {
        guard let screen = window?.screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let id = CGDirectDisplayID(number.uint32Value)
        let backing = screen.backingScaleFactor
        if let cache = scalingCache, cache.screen == id, cache.backing == backing { return cache.factor }
        var factor: Double?
        // The current mode's pixels are the backing store (3600 wide for a
        // "looks like 1800" mode); the panel's own are the native mode's.
        let modes = CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary)
            as? [CGDisplayMode] ?? []
        let nativeFlag: UInt32 = 0x0200_0000   // kDisplayModeNativeFlag (IOGraphicsTypes.h)
        let panel = modes.filter { $0.ioFlags & nativeFlag != 0 }.map(\.pixelWidth).max() ?? CGDisplayCopyDisplayMode(id)?.pixelWidth
        if let panel, screen.frame.width > 0 {
            let value = Double(panel) / (Double(screen.frame.width) * Double(backing))
            if abs(value - 1) > 0.005 { factor = value }
        }
        scalingCache = (id, backing, factor)
        return factor
    }

    private static func size(_ size: PixelSize) -> String { "\(size.width) × \(size.height)" }

    private static func decimal(_ value: Double, _ digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).grouping(.never))
    }
}
