import AppKit

/// What a screenshot or recording looks and sounds like: the white flash and
/// the sounds macOS plays for its own screenshots and screen recordings.
@MainActor
enum CaptureFeedback {
    enum Sound {
        case screenshot, recordingStarted, recordingStopped

        fileprivate var file: String {
            switch self {
            case .screenshot: "Screen Capture.aif"
            case .recordingStarted: "begin_record.caf"
            case .recordingStopped: "end_record.caf"
            }
        }
    }

    private static var sounds: [String: NSSound] = [:]

    /// Plays `sound` unless the user turned off user interface sound effects
    /// (Sound settings), as macOS's own screenshots do.
    static func play(_ sound: Sound) {
        let effects = UserDefaults(suiteName: "com.apple.systemsound")?.object(forKey: "com.apple.sound.uiaudio.enabled") as? Int
        guard effects != 0 else { return }
        let player = sounds[sound.file] ?? NSSound(
            contentsOf: URL(filePath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system")
                .appending(path: sound.file),
            byReference: true)
        guard let player else { return } // not in this macOS version: no sound
        sounds[sound.file] = player
        player.stop()
        player.play()
    }

    /// A white flash over `rect` of `view`, fading out like the screenshot flash.
    static func flash(_ rect: NSRect, in view: NSView) {
        let flash = FlashView(frame: rect)
        view.addSubview(flash, positioned: .above, relativeTo: nil)
        // Softer with Reduce Motion.
        flash.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.35 : 0.85
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            flash.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { flash.removeFromSuperview() }
        }
    }

    private final class FlashView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.white.cgColor
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The red dot and elapsed time while a window records: in the title bar,
/// or on a dark plate over the game in full screen, where the title bar
/// hides until the pointer reaches the top. AppKit draws it above the
/// frames, never into them, so it is not in the movie.
final class RecordingIndicator: NSView {
    private let dot = NSImageView()
    private let time = NSTextField(labelWithString: "")
    private var started = Date.now
    private var timer: Timer?
    /// In the title bar: wide enough for hours.
    private var fixedSize: NSSize?

    /// `plate`: on a dark plate, sized to its content by Auto Layout (over
    /// the game); otherwise a fixed size for the title bar's buttons.
    init(plate: Bool) {
        super.init(frame: .zero)
        dot.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        dot.contentTintColor = .systemRed
        time.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        time.textColor = .systemRed
        let stack = NSStackView(views: [dot, time])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        if plate {
            wantsLayer = true
            // The same plate as the notices, in any appearance.
            appearance = NSAppearance(named: .darkAqua)
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
            layer?.cornerRadius = 8
            stack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 9)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            time.stringValue = Self.format(36_000 - 1)
            let size = stack.fittingSize
            fixedSize = NSSize(width: size.width + 12, height: max(size.height, 28))
            setFrameSize(fixedSize ?? .zero)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { fixedSize ?? super.intrinsicContentSize }

    // It only shows: clicks go on to the title bar or the game beneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Counts the time since `start` while recording; nil stops. Each
    /// indicator of a window gets the same start, so they agree.
    func run(since start: Date?) {
        timer?.invalidate()
        timer = nil
        dot.removeAllSymbolEffects()
        started = start ?? .now
        if start != nil {
            dot.addSymbolEffect(.pulse, options: .repeating)
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
            // Also while a menu is open or the window is being resized.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        update()
    }

    private func update() {
        let elapsed = Int(Date.now.timeIntervalSince(started))
        time.stringValue = Self.format(elapsed)
        setAccessibilityLabel(String(localized: "Recording \(Self.format(elapsed))", bundle: .windowHost))
    }

    /// "0:42", "12:05", "1:02:03".
    private static func format(_ seconds: Int) -> String {
        let hours = seconds / 3600, minutes = seconds / 60 % 60, rest = seconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}
