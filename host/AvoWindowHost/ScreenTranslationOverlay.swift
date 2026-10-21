import AppKit
import AvoKit

/// The translated text over the app (Translate Screen): one plate per block
/// of text, in the color of what it covers, with the translation at the
/// largest size that fits where the original was. It never takes a click,
/// so the app under it works as usual. AppKit draws it above the frames,
/// never into them, so screenshots and recordings show the app as it is.
@MainActor
final class ScreenTranslationOverlay: NSView {
    struct Plate: Equatable {
        /// Which block of the reading it covers.
        var id: Int
        var text: String
        /// Frame pixels, origin at the top left.
        var rect: CGRect
        var lineHeight: Double
        var alignment: ScreenTextLayout.Alignment
        /// How far a longer translation may widen it to the right, in frame pixels.
        var room: Double
        var background: NSColor
        var foreground: NSColor
        /// How far a scroll moved its text since it was read, in frame
        /// pixels (positive: down). It moves without being laid out again.
        var shift: Double = 0

        /// The same plate wherever a scroll took it.
        var unmoved: Plate {
            var plate = self
            plate.shift = 0
            return plate
        }
    }

    /// The plates drawn now.
    private(set) var plates: [Plate] = []
    /// The size of the frame the plates were read from.
    private var frameSize = CGSize.zero
    private let displayRect: () -> CGRect
    /// Each plate as drawn at the current size, by id (reset when the size changes).
    private var laidOut: [Int: (plate: CGRect, text: NSAttributedString, textRect: CGRect)] = [:]
    /// Where the picture was when `laidOut` was worked out.
    private var laidOutIn = CGRect.null

    /// The smallest size a translation shrinks to; below it, the plate grows.
    private static let minimumFontSize: CGFloat = 7
    /// "Translating the screen…" while a read takes long: Vision's first
    /// read in an app can take half a minute, a language download longer.
    private let progress = ProgressPill()

    init(displayRect: @escaping () -> CGRect) {
        self.displayRect = displayRect
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.isHidden = true
        addSubview(progress)
        NSLayoutConstraint.activate([
            progress.centerXAnchor.constraint(equalTo: centerXAnchor),
            progress.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            progress.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }
    /// Top-down like the frame, so text lays out from where the original starts.
    override var isFlipped: Bool { true }

    /// The window was resized, rotated or went full screen: the plates are
    /// laid out again over the picture at its new size (a frame of another
    /// size, once Android has one, makes the controller read it again).
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        laidOut = [:]
        needsDisplay = true
    }

    /// Shows `plates` (read from a frame of `frameSize`) instead of those on
    /// screen. Plates that did not change keep their layout, so a plate that
    /// goes or arrives costs no more than itself.
    func show(_ plates: [Plate], frameSize: CGSize) {
        guard plates != self.plates || frameSize != self.frameSize else { return }
        if frameSize != self.frameSize {
            laidOut = [:]
        } else {
            let kept = Dictionary(plates.map { ($0.id, $0.unmoved) }, uniquingKeysWith: { first, _ in first })
            for old in self.plates where kept[old.id] != old.unmoved { laidOut[old.id] = nil }
        }
        self.plates = plates
        self.frameSize = frameSize
        needsDisplay = true
    }

    func clear() {
        show([], frameSize: .zero)
        showProgress(false)
    }

    /// The pill, with `slow`'s text once a first read takes long.
    func showProgress(_ on: Bool, slow: Bool = false) {
        progress.isHidden = !on
        progress.slow = slow
        if on { progress.start() } else { progress.stop() }
    }

    var showsProgress: Bool { !progress.isHidden }

    override func draw(_ dirtyRect: NSRect) {
        guard frameSize.width > 0, frameSize.height > 0 else { return }
        let display = displayRect()
        if display != laidOutIn {
            laidOut = [:]
            laidOutIn = display
        }
        for index in plates.indices {
            let id = plates[index].id
            let layout = laidOut[id] ?? layOut(plates[index], in: display)
            laidOut[id] = layout
            // Frame pixels to view points; this view counts from the top, like the frame.
            let move = plates[index].shift * display.height / frameSize.height
            let plate = layout.plate.offsetBy(dx: 0, dy: move)
            guard plate.intersects(dirtyRect) else { continue }
            plates[index].background.setFill()
            let radius = min(4, plate.height * 0.2)
            NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius).fill()
            layout.text.draw(with: layout.textRect.offsetBy(dx: 0, dy: move), options: [.usesLineFragmentOrigin, .usesFontLeading],
                             context: nil)
        }
    }

    /// Where `plate` goes in the view, and its text at the size that fits.
    private func layOut(_ plate: Plate, in display: CGRect) -> (plate: CGRect, text: NSAttributedString, textRect: CGRect) {
        // Frame pixels to view points. `display` is in DisplayView's
        // coordinates (y up); this view has its bounds, flipped.
        let sx = display.width / frameSize.width, sy = display.height / frameSize.height
        let top = bounds.height - display.maxY
        let original = CGRect(x: display.minX + plate.rect.minX * sx, y: top + plate.rect.minY * sy,
                              width: plate.rect.width * sx, height: plate.rect.height * sy)
        let lineHeight = plate.lineHeight * sy
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = plate.alignment == .center ? .center : .natural
        paragraph.lineBreakMode = .byWordWrapping
        func text(_ size: Double) -> NSAttributedString {
            NSAttributedString(string: plate.text, attributes: [
                .font: NSFont.systemFont(ofSize: size),
                .foregroundColor: plate.foreground,
                .paragraphStyle: paragraph,
            ])
        }
        func measure(_ text: NSAttributedString, width: CGFloat) -> CGSize {
            text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                              options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        }
        // Vision's box spans ascenders to descenders: a font about 0.85 of it tall.
        let maximum = max(lineHeight * 0.85, 1)
        func fittedSize(width: CGFloat) -> Double {
            ScreenTextLayout.fittedSize(minimum: Self.minimumFontSize, maximum: maximum) { size in
                let measured = measure(text(size), width: width)
                return measured.height <= original.height + 0.5 && measured.width <= width + 0.5
            }
        }
        var area = original
        var size = fittedSize(width: area.width)
        // A longer translation of a label may take free space on its right rather than shrink.
        if size < maximum, plate.alignment == .leading, plate.room > 0 {
            let wider = original.width + plate.room * sx
            let widerSize = fittedSize(width: wider)
            if widerSize > size {
                size = widerSize
                area.size.width = wider
            }
        }
        let fitted = text(size)
        let height = ceil(measure(fitted, width: area.width).height)
        // Text that does not fit even at the smallest size goes on below the original.
        area.size.height = max(area.height, height)
        let textRect = CGRect(x: area.minX, y: area.midY - height / 2, width: area.width, height: height)
        let plateRect = area.insetBy(dx: -max(2, lineHeight * 0.15), dy: -max(1.5, lineHeight * 0.1))
        return (plateRect, fitted, textRect)
    }
}

/// A spinner and "Translating the screen…" on a dark plate, like a notice.
private final class ProgressPill: NSView {
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: String(localized: "Translating the screen…", bundle: .windowHost))
    /// The first read in a long while: Vision is building its models.
    var slow = false {
        didSet {
            guard slow != oldValue else { return }
            label.stringValue = slow ? String(localized: "Preparing text recognition. The first time can take a minute…", bundle: .windowHost)
                                     : String(localized: "Translating the screen…", bundle: .windowHost)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        layer?.cornerRadius = 10
        spinner.style = .spinning
        spinner.controlSize = .small
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func start() { spinner.startAnimation(nil) }
    func stop() { spinner.stopAnimation(nil) }
}

extension NSColor {
    convenience init(_ color: ScreenTextLayout.RGB) {
        self.init(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
    }
}
