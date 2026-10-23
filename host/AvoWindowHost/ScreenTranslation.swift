import AppKit
import AvoKit
import SwiftUI
import Translation
import os

/// Translate Screen (⌘⇧T) in one window: reads the text in the frame on
/// screen (ScreenTextReader), translates it on the Mac with Apple's
/// Translation framework into the Mac's language or the one chosen under
/// Translate Into, and draws the translation over the app
/// (ScreenTranslationOverlay) until ⌘⇧T or Esc. The reading and the
/// translating are the daemon's text engine's, one for every app
/// (ScreenTextEngine), ready from Avo's start or from the first app that
/// translated; only languages macOS must download first are translated in
/// the window, which can show the system's download sheet.
///
/// It follows the screen. Ten times a second it compares the frame on
/// screen with the one the plates were read from (ScreenWatch): the plates
/// over anything that changed go at once (another screen, a dialog), those
/// over text a scroll moved move with it (ScreenFollow), and the screen is
/// read again as soon as it holds still. A plate only ever shows over the
/// text it was read from: what a read finds is checked against the frame on
/// screen when the read ends, and again at every look and every translation
/// that arrives. Text read before keeps its translation (in any app: the
/// engine keeps them while Avo runs), a screen read lately is not read
/// again, and new text goes to the translator one piece at a time from the
/// top, each plate showing as soon as its translation arrives.
///
/// Nothing reaches Android: clicks go through the translation to the app,
/// and while the key mapping has the keys (Game Mode) Esc stays the game's,
/// so only ⌘⇧T hides the translation there.
@MainActor
final class ScreenTranslationController {
    private let displayView: DisplayView
    private let button: TitlebarButton
    private let showNotice: (String) -> Void
    private let keysBelongToGame: () -> Bool
    /// The daemon, whose text engine reads and translates.
    private let engine: () -> DaemonClient?
    private lazy var overlay = ScreenTranslationOverlay(displayRect: { [weak displayView] in displayView?.displayRect ?? .zero })
    private let hosted = HostedTranslator()
    /// The view whose task hands out `hosted`'s sessions. Held here, not by
    /// the translator, which the view's SwiftUI root already holds.
    private lazy var hostedView = hosted.makeView()
    /// Whether the translation is on in this window.
    private(set) var isActive = false
    private var keyMonitor: Any?
    private var observers: [any NSObjectProtocol] = []
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Translate")

    // Following the screen.

    /// When to drop plates and read again.
    private var watch = ScreenWatch()
    /// Looks at the screen ten times a second while translation is on.
    private var ticker: Timer?
    /// The look in progress: a copy of the frame on screen and its sample.
    private var lookTask: Task<Void, Never>?
    /// The frame looked at last: the one read once the screen settles on it.
    private var latestFrame: CGImage?
    /// The strip of the frame looked at last, for `follow`.
    private var latestStrip: ScreenSample?
    /// The plates over text a scroll moved, moved with it (ScreenFollow).
    private var follow = ScreenFollow()
    /// Reads that failed in a row: one is tried again, three end the translation.
    private var failedReads = 0
    /// The last look left something to do even if no new frame comes.
    private var lookAgain = true
    private var readTask: Task<Void, Never>?
    /// Shows the pill when a read takes long (Vision preparing a model).
    private var readProgress: Task<Void, Never>?
    /// What the plates show: the last frame read, its text and its languages.
    private var current: Current?
    /// Where the frame on screen differs from `current`'s, as the last look
    /// found it (nil: another size), and which `current` and look that was.
    private var spoiled: (current: Int, look: Int, changes: ScreenChanges?)?
    /// Count `current`s and looks, for `spoiled`.
    private var currentNumber = 0
    private var lookNumber = 0
    /// Screens read lately: one seen again (going back, a cursor that blinks)
    /// is not read again.
    private var readings: [(sample: ScreenSample, reading: ScreenTextReader.Reading)] = []

    private struct Current {
        var sample: ScreenSample
        /// The frame's strip, which a scroll's slides are measured from.
        var strip: ScreenSample?
        var reading: ScreenTextReader.Reading
        /// The language of each block to translate (one in the target language is not).
        var sources: [Int: Locale.Language]
        var target: Locale.Language
    }

    // Translating.

    /// Translations by language pair and text: only new text goes to the translator.
    private var translations = RecentCache<String, String>(capacity: 2000)
    /// The text on screen without a translation yet, from the top.
    private var untranslated: [(text: String, source: Locale.Language)] = []
    /// New text came: ask the engine first which of it any app translated already.
    private var needsLookUp = false
    private var translateTask: Task<Void, Never>?
    /// Language pairs the engine left to SwiftUI's session in this window
    /// (not downloaded yet, or macOS 15): several texts go at once.
    private var hostedPairs: Set<String> = []
    /// Language pairs that failed since translation started or the language
    /// changed: they are not asked again (the system would show its download
    /// sheet again each time it was declined).
    private var failedPairs: Set<String> = []

    // Telling the user.

    /// What Translate Screen does now was said (once per start, or per language).
    private var announced = false
    /// A failure is said once, not on every read.
    private var reportedProblem = false
    /// Nothing to show yet since translation started or the language changed.
    private var waitingForFirstPlates = false
    /// Shows "Translating the screen…" when the first plates take long.
    private var progressDelay: Task<Void, Never>?

    init(displayView: DisplayView, button: TitlebarButton, notice: @escaping (String) -> Void,
         keysBelongToGame: @escaping () -> Bool, engine: @escaping () -> DaemonClient?) {
        self.displayView = displayView
        self.button = button
        showNotice = notice
        self.keysBelongToGame = keysBelongToGame
        self.engine = engine
        // Translate Into lists them by the time a menu opens.
        Task { _ = await TranslationLanguages.supported() }
    }

    func toggle() {
        if isActive { stop() } else { start() }
    }

    /// The menu item's title and state; nil for another item.
    func validate(_ item: NSMenuItem, hasDisplay: Bool) -> Bool? {
        guard item.action == #selector(AndroidWindowController.toggleScreenTranslation) else { return nil }
        item.title = isActive ? String(localized: "Hide Translation", bundle: .windowHost)
                              : String(localized: "Translate Screen", bundle: .windowHost)
        return isActive || hasDisplay
    }

    private func start() {
        guard !isActive, let container = displayView.superview else { return }
        isActive = true
        // Ready already, unless no app translated since Avo started and
        // Settings › General doesn't start it with Avo.
        if let client = engine() { Task { try? await client.wakeScreenText() } }
        announced = false
        reportedProblem = false
        failedPairs = []
        // Right above the frames: key mapping hints, notices and the editor stay on top.
        overlay.frame = displayView.frame
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay, positioned: .above, relativeTo: displayView)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: displayView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: displayView.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: displayView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: displayView.bottomAnchor),
        ])
        // The translation sessions SwiftUI hands out need their view in the window.
        overlay.addSubview(hostedView)
        watchEscape()
        if let window = displayView.window {
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                                    queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: ScreenTranslationSettings.changed, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.targetChanged() }
        })
        showState()
        watch.reset()
        follow = ScreenFollow()
        failedReads = 0
        current = nil
        lookAgain = true
        waitForFirstPlates()
        let ticker = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.look() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
        look()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        ticker?.invalidate()
        ticker = nil
        // The tasks end without touching anything (they check isActive and cancellation).
        for task in [lookTask, readTask, readProgress, translateTask, progressDelay] { task?.cancel() }
        lookTask = nil
        readTask = nil
        readProgress = nil
        translateTask = nil
        progressDelay = nil
        spoiled = nil
        waitingForFirstPlates = false
        untranslated = []
        watch.reset()
        follow = ScreenFollow()
        current = nil
        latestFrame = nil
        latestStrip = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        hosted.cancelAll()
        hostedPairs = []
        overlay.clear()
        overlay.removeFromSuperview()
        showState()
    }

    /// Says why it stops, and stops.
    private func end(_ message: String) {
        showNotice(message)
        stop()
    }

    private func showState() {
        let label = isActive ? String(localized: "Hide Translation (⇧⌘T)", bundle: .windowHost)
                             : String(localized: "Translate Screen (⇧⌘T)", bundle: .windowHost)
        button.state = isActive ? .on : .off
        button.contentTintColor = isActive ? .controlAccentColor : nil
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    // MARK: Keys and language

    /// Esc hides the translation instead of going Back, unless the game has
    /// the keys or something else has the keyboard (the key mapping editor).
    private func watchEscape() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.escape(event) == true ? nil : event
        }
    }

    /// True when `event` was Esc for the translation, which then hides.
    private func escape(_ event: NSEvent) -> Bool {
        guard isActive, event.keyCode == 53, // kVK_Escape
              let window = event.window, window === displayView.window, window.firstResponder === displayView,
              event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]),
              !keysBelongToGame() else { return false }
        stop()
        return true
    }

    /// Translate Into changed (here or in another window of this app): the
    /// text on screen goes into the new language right away, without
    /// reading the screen again, and pairs that failed are tried again.
    private func targetChanged() {
        guard isActive else { return }
        announced = false
        reportedProblem = false
        failedPairs = []
        waitForFirstPlates()
        let supported = TranslationLanguages.known
        guard let current, let target = TranslationLanguages.target(among: supported) else { return }
        show(current.reading, of: current.sample, strip: current.strip, into: target, supported: supported)
    }

    // MARK: Following the screen

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    /// Looks at the frame on screen (ten times a second while the window
    /// shows): plates over what changed go, and a screen that settled is read.
    private func look() {
        guard isActive, lookTask == nil, let window = displayView.window, !window.isMiniaturized,
              window.occlusionState.contains(.visible) else { return }
        let renderer = displayView.renderer
        // A screen that holds still gets no new frames: the last one stands,
        // and costs nothing once nothing waits to be read.
        if let latest = watch.latest, let latestFrame, renderer.statistics().idle,
           renderer.frameSize == CGSize(width: latest.width, height: latest.height) {
            if lookAgain { apply(watch.look(at: latest, time: Self.now), frame: latestFrame, strip: latestStrip) }
            return
        }
        lookTask = Task { [weak self] in
            let image = await renderer.captureFrame()
            var samples: (sample: ScreenSample, strip: ScreenSample)?
            if let image { samples = await ScreenTextReader.samples(of: image) }
            guard let self, !Task.isCancelled else { return }
            lookTask = nil
            guard isActive else { return }
            guard let image, let samples else {
                // No frame at all: the app has not drawn anything yet.
                if watch.latest == nil { end(CaptureFiles.Failure.noFrame.localizedDescription) }
                return
            }
            latestFrame = image
            latestStrip = samples.strip
            lookNumber += 1
            if current != nil { follow.look(at: samples.strip) }
            apply(watch.look(at: samples.sample, time: Self.now), frame: image, strip: samples.strip)
        }
    }

    private func apply(_ step: ScreenWatch.Step, frame: CGImage, strip: ScreenSample?) {
        lookAgain = step.pending
        // What changed since the plates' frame, which the look worked out already.
        if let current, let shown = watch.shown, shown == current.sample {
            spoiled = (currentNumber, lookNumber, step.sinceShown)
        }
        refreshPlates()
        guard step.read, let sample = watch.latest else { return }
        read(frame, sample: sample, strip: strip)
    }

    /// Reads the text in `frame` (unless that screen was read lately) and
    /// shows its translation.
    private func read(_ frame: CGImage, sample: ScreenSample, strip: ScreenSample?) {
        readTask = Task { [weak self] in
            let supported = await TranslationLanguages.supported()
            guard let self, !Task.isCancelled, isActive else { return }
            guard let target = TranslationLanguages.target(among: supported) else {
                end(String(localized: "Translation is not available on this Mac.", bundle: .windowHost))
                return
            }
            var reading: ScreenTextReader.Reading
            if let known = readings.first(where: { $0.sample.matches(sample) })?.reading {
                reading = known
            } else {
                guard let client = engine() else {
                    end(AvoError.daemonUnreachable(String(localized: "not connected", bundle: .windowHost)).localizedDescription)
                    return
                }
                let started = Self.now
                showProgressIfReadTakesLong()
                let languages = supported.compactMap(ScreenTextLanguages.naturalLanguageCode(for:))
                do {
                    reading = try await ScreenTextReader.read(frame, languages: languages, with: client)
                } catch {
                    guard !Task.isCancelled, isActive else { return }
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    logger.error("cannot read the screen: \(message, privacy: .public)")
                    failedReads += 1
                    guard failedReads >= 3 else {
                        // Tried again at the next look that finds the screen still.
                        readEnded()
                        readTask = nil
                        watch.abandonedReading()
                        lookAgain = true
                        return
                    }
                    end(String(localized: "Could not read the screen: \(message)", bundle: .windowHost))
                    return
                }
                guard !Task.isCancelled, isActive else { return }
                failedReads = 0
                readEnded()
                logger.info("read \(reading.blocks.count) blocks in \(Int((Self.now - started) * 1000)) ms")
            }
            readTask = nil
            let foundNewText = keepUnchangedText(of: &reading, sample: sample)
            readings.removeAll { $0.sample.matches(sample) }
            readings.insert((sample, reading), at: 0)
            if readings.count > 8 { readings.removeLast() }
            watch.finishedReading(sample, foundNewText: foundNewText)
            show(reading, of: sample, strip: strip, into: target, supported: supported)
        }
    }

    /// Keeps the text read before where nothing changed since (Vision reads
    /// the same pixels a little differently each time, and a plate should
    /// not change for that), and says whether the change brought new text.
    private func keepUnchangedText(of reading: inout ScreenTextReader.Reading, sample: ScreenSample) -> Bool {
        guard let current, let changes = current.sample.changes(to: sample) else { return true }
        let old = current.reading.blocks
        let carried = changes.carriedOver(new: reading.blocks.map(\.rect), old: old.map(\.rect))
        let before = Set(old.map(\.text))
        var foundNewText = false
        for index in reading.blocks.indices {
            if let match = carried[index] {
                // Its own room: what is next to it may have changed.
                var kept = old[match]
                kept.room = reading.blocks[index].room
                reading.blocks[index] = kept
            } else if !before.contains(reading.blocks[index].text) {
                foundNewText = true
            }
        }
        return foundNewText
    }

    /// A read that takes long shows the pill, and after 4 s says that Vision
    /// is getting ready: the first time on this Mac (or after a macOS
    /// update) the engine builds its models, which takes most of a minute.
    private func showProgressIfReadTakesLong() {
        readProgress?.cancel()
        readProgress = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, !Task.isCancelled, isActive else { return }
            if !overlay.showsProgress { overlay.showProgress(true) }
            try? await Task.sleep(for: .milliseconds(2500))
            guard !Task.isCancelled, isActive else { return }
            overlay.showProgress(true, slow: true)
        }
    }

    private func readEnded() {
        guard let readProgress else { return }
        readProgress.cancel()
        self.readProgress = nil
        // The first plates' own pill stays until they show.
        if !waitingForFirstPlates { overlay.showProgress(false) }
    }

    /// Shows `reading`, the text of the frame `sample` was taken of, in
    /// `target`: the plates whose translation is known at once, the others
    /// as their translations arrive.
    private func show(_ reading: ScreenTextReader.Reading, of sample: ScreenSample, strip: ScreenSample?, into target: Locale.Language,
                      supported: [Locale.Language]) {
        var sources: [Int: Locale.Language] = [:]
        var wanted: [(text: String, source: Locale.Language)] = []
        var inTarget = 0
        // The text of the screen before: what moved (a scroll) is the same
        // text, which Vision may read a little differently at its new place.
        let before = current?.reading.blocks.map(\.text) ?? []
        for (index, block) in reading.blocks.enumerated() {
            guard let code = block.language,
                  let source = ScreenTextLanguages.match(Locale.Language(identifier: code), in: supported) else { continue }
            if ScreenTextLanguages.same(source, target) {
                inTarget += 1
                continue
            }
            sources[index] = source
            guard !failedPairs.contains(Self.pair(source, target)),
                  translations.value(for: Self.key(block.text, source, target)) == nil else { continue }
            var known: String?
            for text in before where ScreenTextLayout.sameTextRead(text, block.text) {
                known = translations.value(for: Self.key(text, source, target))
                if known != nil { break }
            }
            if let known {
                translations.insert(known, for: Self.key(block.text, source, target))
            } else if !wanted.contains(where: { $0.text == block.text && $0.source == source }) {
                wanted.append((block.text, source))
            }
        }
        current = Current(sample: sample, strip: strip, reading: reading, sources: sources, target: target)
        currentNumber += 1
        // A scroll from here on moves these plates.
        follow.start(from: strip)
        untranslated = wanted
        needsLookUp = !wanted.isEmpty
        refreshPlates()
        // Nothing left to wait for (all of it translated before, or nothing that needs it).
        if wanted.isEmpty { stopWaiting() }
        translateNext()
        // Said on the first screen read after starting or choosing a language.
        guard !announced else { return }
        announced = true
        let language = TranslationLanguages.name(of: target)
        if sources.isEmpty, inTarget > 0 {
            showNotice(String(localized: "The text on screen is already in \(language). To translate it into another language, choose one under Translate Into.",
                              bundle: .windowHost))
        } else if keysBelongToGame() {
            showNotice(String(localized: "Translating into \(language) as the screen changes. ⇧⌘T stops.", bundle: .windowHost))
        } else {
            showNotice(String(localized: "Translating into \(language) as the screen changes. Esc or ⇧⌘T stops.", bundle: .windowHost))
        }
    }

    /// Shows the plates of what was read last that have a translation and
    /// still sit on their text: none over anything that changed since,
    /// except text a scroll moved, whose plates move with it.
    private func refreshPlates() {
        guard isActive, let current, let latest = watch.latest else {
            overlay.show([], frameSize: .zero)
            return
        }
        if spoiled?.current != currentNumber || spoiled?.look != lookNumber {
            spoiled = (currentNumber, lookNumber, current.sample.changes(to: latest))
        }
        guard let changes = spoiled?.changes else {
            // Another size: no plate fits.
            overlay.show([], frameSize: .zero)
            return
        }
        var plates: [ScreenTranslationOverlay.Plate] = []
        for (index, block) in current.reading.blocks.enumerated() {
            guard let source = current.sources[index],
                  let translation = translations.value(for: Self.key(block.text, source, current.target)),
                  !ScreenTextLayout.sameText(block.text, translation) else { continue }
            // A longer translation may take the room on its right: a change there spoils it too.
            var area = block.rect
            area.size.width += block.room
            var shift = 0.0
            if changes.spoils(area) {
                // Its text slid with a scroll: the plate goes along, unless other text is there now.
                guard let moved = follow.moved(block.rect) else { continue }
                shift = moved.minY - block.rect.minY
            }
            plates.append(ScreenTranslationOverlay.Plate(id: index, text: translation, rect: block.rect, lineHeight: block.lineHeight,
                                                         alignment: block.alignment, room: block.room,
                                                         background: NSColor(block.background), foreground: NSColor(block.foreground),
                                                         shift: shift))
        }
        overlay.show(plates, frameSize: current.reading.frameSize)
        if !plates.isEmpty { stopWaiting() }
    }

    // MARK: Translating

    /// Translates the text on screen that has no translation yet, from the
    /// top, showing each plate as soon as its translation arrives.
    private func translateNext() {
        guard translateTask == nil, isActive, !untranslated.isEmpty else { return }
        translateTask = Task { [weak self] in
            while true {
                guard let self, !Task.isCancelled else { return }
                if needsLookUp, let client = engine() {
                    needsLookUp = false
                    await lookUpKnown(with: client)
                    guard !Task.isCancelled, isActive else { return }
                    refreshPlates()
                }
                guard isActive, let batch = nextBatch() else {
                    translateTask = nil
                    // All of it translated: if no plate shows (every translation
                    // was the text itself), there is nothing more to wait for.
                    stopWaiting()
                    return
                }
                let started = Self.now
                do {
                    let translated = try await translate(batch.texts, from: batch.source, to: batch.target)
                    guard !Task.isCancelled, isActive else { return }
                    for (text, translation) in zip(batch.texts, translated) {
                        translations.insert(translation, for: Self.key(text, batch.source, batch.target))
                    }
                    logger.info("translated \(batch.texts.count) texts in \(Int((Self.now - started) * 1000)) ms")
                } catch {
                    guard !Task.isCancelled, isActive else { return }
                    failed(from: batch.source, to: batch.target, error)
                }
                refreshPlates()
            }
        }
    }

    /// Asks the engine which of the text on screen it translated already
    /// (in this window or another app's, since Avo started): those plates
    /// show at once, before anything new is translated, as macOS translates
    /// only about five texts a second.
    private func lookUpKnown(with client: DaemonClient) async {
        guard let target = current?.target else { return }
        var bySource: [Locale.Language: [String]] = [:]
        for item in untranslated {
            let pair = Self.pair(item.source, target)
            guard !hostedPairs.contains(pair), !failedPairs.contains(pair) else { continue }
            bySource[item.source, default: []].append(item.text)
        }
        for (source, texts) in bySource {
            guard let known = try? await client.knownTranslations(texts, from: source, to: target) else { continue }
            for (text, translation) in zip(texts, known) {
                if let translation { translations.insert(translation, for: Self.key(text, source, target)) }
            }
        }
    }

    /// The next text to translate: the first on screen without a
    /// translation. A language pair that needs SwiftUI's session takes up to
    /// eight at once, as each session costs a round through SwiftUI.
    private func nextBatch() -> (texts: [String], source: Locale.Language, target: Locale.Language)? {
        guard let target = current?.target else {
            untranslated = []
            return nil
        }
        untranslated.removeAll { item in
            failedPairs.contains(Self.pair(item.source, target))
                || translations.value(for: Self.key(item.text, item.source, target)) != nil
        }
        guard let first = untranslated.first else { return nil }
        let batch = hostedPairs.contains(Self.pair(first.source, target))
            ? Array(untranslated.filter { $0.source == first.source }.prefix(8)) : [first]
        untranslated.removeAll { item in batch.contains { $0.text == item.text && $0.source == item.source } }
        return (batch.map(\.text), first.source, target)
    }

    private func failed(from source: Locale.Language, to target: Locale.Language, _ error: any Error) {
        logger.error("cannot translate from \(source.maximalIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
        failedPairs.insert(Self.pair(source, target))
        guard !reportedProblem else { return }
        reportedProblem = true
        // Said instead of the announcement.
        announced = true
        stopWaiting()
        showNotice(Self.message(for: error, target: TranslationLanguages.name(of: target)))
    }

    /// Shows "Translating the screen…" when no plate shows within a second
    /// of starting (or of choosing another language), and that Vision is
    /// getting ready when the first read is still going after 4 s: the
    /// first read on a Mac builds Vision's models, which takes most of a minute.
    private func waitForFirstPlates() {
        waitingForFirstPlates = true
        progressDelay?.cancel()
        progressDelay = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1000))
            guard let self, !Task.isCancelled, waitingForFirstPlates else { return }
            overlay.showProgress(true)
            try? await Task.sleep(for: .milliseconds(3000))
            guard !Task.isCancelled, waitingForFirstPlates, watch.shown == nil, readTask != nil else { return }
            overlay.showProgress(true, slow: true)
        }
    }

    private func stopWaiting() {
        guard waitingForFirstPlates else { return }
        waitingForFirstPlates = false
        progressDelay?.cancel()
        progressDelay = nil
        overlay.showProgress(false)
    }

    private static func pair(_ source: Locale.Language, _ target: Locale.Language) -> String {
        "\(source.maximalIdentifier)>\(target.maximalIdentifier)"
    }

    private static func key(_ text: String, _ source: Locale.Language, _ target: Locale.Language) -> String {
        "\(pair(source, target))\u{1F}\(text)"
    }

    /// The daemon's engine translates languages already on the Mac (macOS
    /// 26). Languages to download first, and every pair on macOS 15, get a
    /// session from SwiftUI in this window, which also asks to download them.
    private func translate(_ texts: [String], from source: Locale.Language, to target: Locale.Language) async throws -> [String] {
        let pair = Self.pair(source, target)
        if !hostedPairs.contains(pair), let client = engine() {
            do {
                return try await client.translate(texts, from: source, to: target)
            } catch AvoError.translation(.notInstalled), AvoError.translation(.needsWindow) {
                hostedPairs.insert(pair)
            } catch AvoError.translation(.unsupported) {
                throw TranslationError.unsupportedLanguagePairing
            }
        }
        return try await hosted.translate(texts, from: source, to: target)
    }

    private static func message(for error: any Error, target: String) -> String {
        if TranslationError.unsupportedLanguagePairing ~= error || TranslationError.unsupportedSourceLanguage ~= error
            || TranslationError.unsupportedTargetLanguage ~= error {
            return String(localized: "macOS can’t translate this text into \(target).", bundle: .windowHost)
        }
        // A session that ends before translating: the download it asked for was declined.
        var notDownloaded = error is CancellationError
        if #available(macOS 26.0, *), TranslationError.notInstalled ~= error { notDownloaded = true }
        if notDownloaded {
            return String(localized: "The languages for this translation aren’t downloaded. Download them in System Settings › General › Language & Region › Translation Languages.",
                          bundle: .windowHost)
        }
        return String(localized: "Could not translate the screen: \(error.localizedDescription)", bundle: .windowHost)
    }
}

// MARK: Translate Into, for menus

extension ScreenTranslationController {
    /// A language Translate Into offers.
    struct TargetLanguage: Equatable, Sendable {
        /// What `chooseTarget(_:)` takes.
        let identifier: String
        /// Its name in Avo's language: "English", "Chinese, Traditional".
        let name: String
    }

    /// The languages to translate into, each once, sorted by name. Empty
    /// until macOS has said which it has, moments after the app starts
    /// (`loadTargetLanguages()` waits for that).
    var targetLanguages: [TargetLanguage] { TranslationLanguages.menu }

    func loadTargetLanguages() async -> [TargetLanguage] {
        _ = await TranslationLanguages.supported()
        return TranslationLanguages.menu
    }

    /// The language chosen under Translate Into, as one of
    /// `targetLanguages`' identifiers; nil when it follows the Mac's language.
    var chosenTarget: String? { TranslationLanguages.chosenMenuIdentifier }

    /// The Mac's language, for "System Language (English)".
    var systemLanguageName: String { TranslationLanguages.name(of: TranslationLanguages.systemLanguage) }

    /// Translates into `identifier` (one of `targetLanguages`; nil for the
    /// Mac's language) from now on, in every app. A translation on screen
    /// changes to it right away.
    func chooseTarget(_ identifier: String?) {
        ScreenTranslationSettings.target = identifier
    }
}

extension AndroidWindowController {
    /// View › Translate Screen and the title bar's translate button; again, or Esc, hides it.
    @objc func toggleScreenTranslation() {
        translation.toggle()
    }
}

// MARK: Translation sessions

/// Translation sessions from SwiftUI's `translationTask`: the only kind
/// macOS 15 has, and the kind that asks to download a language the Mac does
/// not have yet (the system shows its own sheet on the window). A session
/// lives only while its task runs, so the work comes to the task: each job
/// sets the languages, SwiftUI starts the task with a session for them, and
/// the task translates every job for those languages before it ends.
///
/// A session is not Sendable, so it is only ever used off the main actor,
/// where the task got it.
@MainActor
final class HostedTranslator: ObservableObject {
    @Published fileprivate var configuration: TranslationSession.Configuration?

    fileprivate struct Job: Sendable {
        let source: Locale.Language
        let target: Locale.Language
        let texts: [String]
        let continuation: CheckedContinuation<[String], any Error>
    }

    private var jobs: [Job] = []
    /// Tasks translating (one, or a cancelled one still ending); the next
    /// languages are set once none is.
    private var serving = 0

    /// The 1-point view that runs the task, in the window while translation
    /// is on. It holds the translator, so the translator must not hold it.
    func makeView() -> NSView {
        let view = NSHostingView(rootView: TranslationTaskHost(translator: self))
        view.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        return view
    }

    func translate(_ texts: [String], from source: Locale.Language, to target: Locale.Language) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            jobs.append(Job(source: source, target: target, texts: texts, continuation: continuation))
            startNext()
        }
    }

    /// Fails every waiting job (translation turned off).
    func cancelAll() {
        let waiting = jobs
        jobs = []
        configuration = nil
        for job in waiting { job.continuation.resume(throwing: CancellationError()) }
    }

    /// Asks SwiftUI for a session with the first waiting job's languages: a
    /// new configuration, or the same one invalidated, runs the task again.
    private func startNext() {
        guard serving == 0, let next = jobs.first else { return }
        if var configuration, configuration.source == next.source, configuration.target == next.target {
            configuration.invalidate()
            self.configuration = configuration
        } else {
            configuration = TranslationSession.Configuration(source: next.source, target: next.target)
        }
    }

    /// The languages of the session SwiftUI just started.
    private func beginServing() -> (source: Locale.Language, target: Locale.Language)? {
        guard let source = configuration?.source, let target = configuration?.target else { return nil }
        serving += 1
        return (source, target)
    }

    private func nextJob(source: Locale.Language, target: Locale.Language) -> Job? {
        guard let index = jobs.firstIndex(where: { $0.source == source && $0.target == target }) else { return nil }
        return jobs.remove(at: index)
    }

    private func endServing() {
        serving -= 1
        startNext()
    }

    /// The task's work: every job for the session's languages.
    fileprivate nonisolated static func serve(_ session: TranslationSession, for translator: HostedTranslator) async {
        guard let languages = await translator.beginServing() else { return }
        // A cancelled task leaves new jobs to the next one.
        while !Task.isCancelled, let job = await translator.nextJob(source: languages.source, target: languages.target) {
            do {
                job.continuation.resume(returning: try await translations(of: job.texts, with: session))
            } catch {
                job.continuation.resume(throwing: error)
            }
        }
        await translator.endServing()
    }

    /// `texts` translated in one batch, in their order (one the session
    /// returns nothing for stays as it was).
    private nonisolated static func translations(of texts: [String], with session: TranslationSession) async throws -> [String] {
        let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: String($0)) }
        var translated = texts
        for response in try await session.translations(from: requests) {
            if let index = response.clientIdentifier.flatMap(Int.init), translated.indices.contains(index) {
                translated[index] = response.targetText
            }
        }
        return translated
    }
}

private struct TranslationTaskHost: View {
    @ObservedObject var translator: HostedTranslator

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
            // Sendable, so not on the main actor: the session stays where it was handed over.
            .translationTask(translator.configuration) { @Sendable [translator] session in
                await HostedTranslator.serve(session, for: translator)
            }
    }
}

// MARK: Languages and settings

/// The languages Apple's Translation framework translates between, and
/// which of them Translate Screen translates into.
@MainActor
enum TranslationLanguages {
    private static var cached: [Locale.Language]?
    private static var loading: Task<[Locale.Language], Never>?

    /// Asked of the framework once per app.
    static func supported() async -> [Locale.Language] {
        if let cached { return cached }
        let task = loading ?? Task { await fetchSupported() }
        loading = task
        let languages = await task.value
        // None means the framework could not answer yet: ask again next time.
        if !languages.isEmpty { cached = languages }
        loading = nil
        return languages
    }

    /// Off the main actor: LanguageAvailability may not cross into it.
    private nonisolated static func fetchSupported() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages
    }

    /// What `supported()` found, or nothing before it returned.
    static var known: [Locale.Language] { cached ?? [] }

    /// The chosen language, or the first of the Mac's preferred languages
    /// that can be translated into, or English.
    static func target(among supported: [Locale.Language]) -> Locale.Language? {
        if let chosen = ScreenTranslationSettings.target,
           let language = ScreenTextLanguages.match(Locale.Language(identifier: chosen), in: supported) { return language }
        return ScreenTextLanguages.target(preferred: Locale.preferredLanguages, supported: supported)
            ?? ScreenTextLanguages.match(Locale.Language(identifier: "en"), in: supported)
    }

    /// The Mac's language, as Translate Into's first item names it.
    static var systemLanguage: Locale.Language {
        ScreenTextLanguages.target(preferred: Locale.preferredLanguages, supported: known)
            ?? Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
    }

    /// "en-US", "zh-Hans", "id": what the framework says, without the parts
    /// it leaves implicit. Saved as the chosen language.
    static func identifier(of language: Locale.Language) -> String {
        [language.languageCode?.identifier, language.script?.identifier, language.region?.identifier]
            .compactMap { $0 }.joined(separator: "-")
    }

    /// "English", "Chinese, Traditional": in the language of Avo's own
    /// text, never with the region the framework lists it in.
    static func name(of language: Locale.Language) -> String {
        let locale = Locale(identifier: Bundle.windowHost.preferredLocalizations.first ?? "en")
        let identifier = ScreenTextLanguages.nameIdentifier(of: language, among: known)
        return locale.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// Translate Into's languages: each once, sorted by name.
    static var menu: [ScreenTranslationController.TargetLanguage] {
        ScreenTextLanguages.distinct(known)
            .map { ScreenTranslationController.TargetLanguage(identifier: identifier(of: $0), name: name(of: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The chosen language as Translate Into lists it (a choice saved for
    /// another region of it counts as that language); nil for the Mac's.
    static var chosenMenuIdentifier: String? {
        guard let chosen = ScreenTranslationSettings.target else { return nil }
        let language = Locale.Language(identifier: chosen)
        return menu.first { ScreenTextLanguages.same(Locale.Language(identifier: $0.identifier), language) }?.identifier ?? chosen
    }
}

/// Translate Screen's setting: the language to translate into, the same in
/// every app (Avo's Window Host defaults, which every App Shim reads).
@MainActor
enum ScreenTranslationSettings {
    static let changed = Notification.Name("dev.avo.ScreenTranslationChanged")
    /// Where it is kept: the Window Host's defaults (a test keeps its own).
    static var store = UserDefaults(suiteName: AvoIdentifiers.windowHost) ?? .standard

    /// A language identifier (TranslationLanguages.identifier), or nil for the Mac's language.
    static var target: String? {
        get { store.string(forKey: "AvoTranslationTarget") }
        set {
            store.set(newValue, forKey: "AvoTranslationTarget")
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
}

/// Translate Into for the Control Panel's Settings (Avo.app), the same
/// choice as in every app window: every app's, so it is set there too.
/// Windows translate into a new choice from their next look at the screen.
@MainActor
public enum TranslateIntoChoice {
    /// A language to translate into: what `chosen` takes, and its name.
    public struct Language: Hashable, Sendable {
        public let identifier: String
        public let name: String
    }

    /// Each language once, sorted by name, once macOS has said which it
    /// has (empty when it could not say yet).
    public static func languages() async -> [Language] {
        _ = await TranslationLanguages.supported()
        return TranslationLanguages.menu.map { Language(identifier: $0.identifier, name: $0.name) }
    }

    /// The Mac's language, for "System Language (English)".
    public static var systemLanguageName: String { TranslationLanguages.name(of: TranslationLanguages.systemLanguage) }

    /// One of `languages()`' identifiers; nil follows the Mac's language.
    public static var chosen: String? {
        get { TranslationLanguages.chosenMenuIdentifier }
        set { ScreenTranslationSettings.target = newValue }
    }
}

// MARK: Menu

/// The View menu of every App Shim: Translate Screen (⌘⇧T, kept from
/// Android by MacShortcuts.windowShiftKeys) and Translate Into.
@MainActor
final class ScreenTranslationMenu: NSObject, NSMenuDelegate {
    static let shared = ScreenTranslationMenu()

    func makeViewMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: String(localized: "View", bundle: .windowHost))
        let translate = menu.addItem(withTitle: String(localized: "Translate Screen", bundle: .windowHost),
                                     action: #selector(AndroidWindowController.toggleScreenTranslation), keyEquivalent: "t")
        translate.keyEquivalentModifierMask = [.command, .shift]
        translate.symbol("translate")
        let languages = NSMenu(title: String(localized: "Translate Into", bundle: .windowHost))
        languages.delegate = self
        let into = menu.addItem(withTitle: String(localized: "Translate Into", bundle: .windowHost), action: nil, keyEquivalent: "")
        into.submenu = languages
        into.symbol("globe")
        let item = NSMenuItem()
        item.submenu = menu
        // Listed by the time the menu opens.
        Task { _ = await TranslationLanguages.supported() }
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let chosen = TranslationLanguages.chosenMenuIdentifier
        let system = TranslationLanguages.name(of: TranslationLanguages.systemLanguage)
        let automatic = menu.addItem(withTitle: String(localized: "System Language (\(system))", bundle: .windowHost),
                                     action: #selector(chooseTarget(_:)), keyEquivalent: "")
        automatic.target = self
        automatic.state = chosen == nil ? .on : .off
        let languages = TranslationLanguages.menu
        guard !languages.isEmpty else { return }
        menu.addItem(.separator())
        for language in languages {
            let item = menu.addItem(withTitle: language.name, action: #selector(chooseTarget(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.identifier
            item.state = language.identifier == chosen ? .on : .off
        }
    }

    @objc private func chooseTarget(_ sender: NSMenuItem) {
        ScreenTranslationSettings.target = sender.representedObject as? String
    }
}
