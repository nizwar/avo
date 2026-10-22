import AvoKit
import CoreGraphics
import CoreText
import Foundation
import NaturalLanguage
import os
import Translation
import Vision

/// Translate Screen's engine, one for every app: Vision reads the text in a
/// frame an App Shim sends (ScreenTextLayout groups the lines into blocks,
/// each with the colors around and under it and the language it is in), and
/// Apple's Translation framework translates it on the Mac.
///
/// It lives in the daemon because Vision takes long to get ready: it builds
/// its text models for each app that reads text (about 25 s, again after a
/// macOS update; an update of the app keeps them), then loads them in a
/// moment at that app's next start. Every App Shim is a program of its own,
/// so each app built them for itself ("Preparing text recognition" in every
/// app). Here they are built and loaded once: as the daemon starts
/// (`VMConfig.translationAtStartup`), or when Translate Screen first turns
/// on in any app, and every app after that finds the engine ready.
public final class ScreenTextEngine: Sendable {
    /// Reads, one frame at a time, after the warm-up.
    private let queue = DispatchQueue(label: "com.avodroid.screen-text", qos: .userInitiated)
    private let translator = Translator()
    private let awake = OSAllocatedUnfairLock(initialState: false)
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Translate")

    public init() {}

    /// Gets Vision's text models ready, unless they are (or are getting) already.
    public func wake() {
        let first = awake.withLock { awake -> Bool in
            defer { awake = true }
            return !awake
        }
        guard first else { return }
        queue.async { [logger] in
            let started = ProcessInfo.processInfo.systemUptime
            Self.removeSharedModels()
            if let image = Self.warmUpImage() { _ = Self.lines(in: image) }
            logger.notice("text recognition ready in \(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) ms")
        }
    }

    /// Translate Screen turned on in a window: also the languages translated
    /// last, whose model macOS lets go of a minute after it was last used
    /// (it then takes most of a second to come back).
    public func wakeForWindow() {
        wake()
        Task { await translator.warmLastPair() }
    }

    /// The text in the frame `pixels` holds.
    public func read(_ request: ScreenTextRequest, pixels: Data) async throws -> ScreenTextReading {
        guard let count = request.byteCount, pixels.count >= count, let image = Self.image(request, pixels: pixels) else {
            throw AvoError.internalError("That frame cannot be read.")
        }
        wake()
        let languages = request.languages
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.read(image, languages: languages))
            }
        }
    }

    /// `request`'s texts translated, in their order.
    public func translate(_ request: TranslationRequest) async throws -> [String] {
        try await translator.translate(request.texts, from: request.source, to: request.target)
    }

    /// The translations of `request`'s texts the engine has already (any
    /// app's, since the daemon started); nil for the others.
    public func known(_ request: TranslationRequest) async -> [String?] {
        await translator.known(request.texts, from: request.source, to: request.target)
    }

    private static func image(_ request: ScreenTextRequest, pixels: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: pixels as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: request.width, height: request.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: request.bytesPerRow, space: space, bitmapInfo: CGBitmapInfo(rawValue: request.bitmapInfo),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func read(_ image: CGImage, languages: [String]) -> ScreenTextReading {
        let blocks = ScreenTextLayout.blocks(lines(in: image))
        let texts = blocks.map(\.text)
        let languages = languagesOf(texts, among: languages)
        let read = blocks.indices.map { index in
            let block = blocks[index]
            let colors = colors(in: image, around: block.rect, lineHeight: block.lineHeight)
            return ScreenTextReading.Block(text: texts[index], rect: block.rect, lineHeight: block.lineHeight, alignment: block.alignment,
                                           room: ScreenTextLayout.room(after: index, in: blocks, frameWidth: Double(image.width)),
                                           background: colors.background, foreground: colors.text, language: languages[index])
        }
        return ScreenTextReading(frameSize: CGSize(width: image.width, height: image.height), blocks: read)
    }

    // MARK: Vision's models

    /// Vision keeps the models it builds in its program's caches
    /// (~/Library/Caches/<bundle identifier>/com.apple.e5rt.e5bundlecache).
    /// App Shims, which read the screen themselves before, shared one such
    /// folder in the Window Host's caches, but Vision builds the models again
    /// for a program that finds another's there, so each app rebuilt them
    /// over the last one's. The daemon keeps its own; the shared one goes,
    /// with the App Shims' links to it.
    private static func removeSharedModels() {
        let files = FileManager.default
        guard let caches = files.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let name = "com.apple.e5rt.e5bundlecache"
        try? files.removeItem(at: caches.appending(path: AvoIdentifiers.windowHost, directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory))
        for folder in (try? files.contentsOfDirectory(atPath: caches.path)) ?? [] where folder.hasPrefix(AvoIdentifiers.shimPrefix) {
            let link = caches.appending(path: folder, directoryHint: .isDirectory).appending(path: name)
            if (try? files.destinationOfSymbolicLink(atPath: link.path)) != nil { try? files.removeItem(at: link) }
        }
    }

    /// A little dark text on white, for the warm-up read.
    private static func warmUpImage() -> CGImage? {
        let width = 360, height = 72
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Core Text draws in black without a color.
        let font = CTFontCreateUIFontForLanguage(.system, 30, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 30, nil)
        let text = NSAttributedString(string: "Avo 123 Play", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        context.textPosition = CGPoint(x: 14, y: 22)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        return context.makeImage()
    }

    // MARK: Text

    private static func lines(in image: CGImage) -> [ScreenTextLayout.Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        // Vision skips text under 1/32 of the image's height by default:
        // most of an app's text on a tall phone display. 12 pixels is 6 points on Retina.
        request.minimumTextHeight = Float(min(1, 12 / Double(max(image.height, 1))))
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        return (request.results ?? []).compactMap { observation in
            // Vision's lowest confidence is mostly texture read as letters.
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3,
                  ScreenTextLayout.hasLetters(candidate.string) else { return nil }
            // Vision's boxes are normalized with the origin at the bottom left.
            let box = observation.boundingBox
            return ScreenTextLayout.Line(text: candidate.string,
                                         rect: CGRect(x: box.minX * width, y: (1 - box.maxY) * height,
                                                      width: box.width * width, height: box.height * height))
        }
    }

    /// The language of each text: its own when it says enough to tell, the
    /// screen's otherwise ("OK" and "設定" alone could be many languages).
    private static func languagesOf(_ texts: [String], among codes: [String]) -> [String?] {
        let constraints = codes.map(NLLanguage.init(rawValue:))
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = constraints
        recognizer.processString(texts.joined(separator: "\n"))
        let dominant = recognizer.dominantLanguage
        return texts.map { text in
            guard text.count(where: \.isLetter) >= 4 else { return dominant?.rawValue }
            recognizer.reset()
            recognizer.languageConstraints = constraints
            if let dominant { recognizer.languageHints = [dominant: 0.6] }
            recognizer.processString(text)
            guard let (language, probability) = recognizer.languageHypotheses(withMaximum: 1).first,
                  probability >= 0.5 else { return dominant?.rawValue }
            return language.rawValue
        }
    }

    // MARK: Pixels

    /// The colors around `rect` (the plate's) and in it (the text's), from
    /// the block scaled down to 24 pixels high with a margin of background.
    private static func colors(in image: CGImage, around rect: CGRect,
                               lineHeight: Double) -> (background: ScreenTextLayout.RGB, text: ScreenTextLayout.RGB) {
        let margin = max(2, lineHeight * 0.2)
        let area = rect.insetBy(dx: -margin, dy: -margin)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard area.width >= 3, area.height >= 3, let crop = image.cropping(to: area),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return ScreenTextLayout.plateColors(edge: [], inside: []) }
        let height = 24
        let width = max(4, min(192, Int((Double(height) * area.width / area.height).rounded())))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return ScreenTextLayout.plateColors(edge: [], inside: []) }
        var edge: [ScreenTextLayout.RGB] = [], inside: [ScreenTextLayout.RGB] = []
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let color = ScreenTextLayout.RGB(red: Double(bytes[offset]) / 255, green: Double(bytes[offset + 1]) / 255,
                                                 blue: Double(bytes[offset + 2]) / 255)
                if x == 0 || y == 0 || x == width - 1 || y == height - 1 { edge.append(color) } else { inside.append(color) }
            }
        }
        return ScreenTextLayout.plateColors(edge: edge, inside: inside)
    }
}

// MARK: - Translating

/// Translation sessions for languages on the Mac (macOS 26 makes them
/// without a window), one batch at a time. A pair whose languages are not
/// downloaded goes back to the app window, where macOS can ask to download
/// them; so does every pair on macOS 15, which translates only for a window.
///
/// macOS translates about five texts a second, however they are sent (one
/// by one, in a batch, joined or at once), so nothing is translated twice:
/// every app's translations are kept while the daemon runs, in memory only,
/// as they are the screen's text.
private actor Translator {
    /// Pairs known to be on the Mac (one removed since fails, and is asked again).
    private var installed: Set<String> = []
    /// Every app's translations, by pair and text.
    private var translations = RecentCache<String, String>(capacity: 20_000)
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Translate")
    /// The pair translated last, kept for the next start ("en-Latn-US>id-Latn-ID").
    private static let lastPairKey = "AvoLastTranslationPair"

    func known(_ texts: [String], from source: Locale.Language, to target: Locale.Language) -> [String?] {
        let pair = Self.pair(source, target)
        return texts.map { translations.value(for: Self.key(pair, $0)) }
    }

    /// `texts` translated, those translated before from memory; `cache`
    /// false asks macOS even so (and keeps nothing), to load the pair's model.
    func translate(_ texts: [String], from source: Locale.Language, to target: Locale.Language,
                   cache: Bool = true) async throws -> [String] {
        guard #available(macOS 26.0, *) else { throw AvoError.translation(.needsWindow) }
        let pair = Self.pair(source, target)
        var result: [String?] = cache ? known(texts, from: source, to: target) : texts.map { _ in nil }
        if !result.contains(nil) { return result.compactMap { $0 } }
        if !installed.contains(pair) {
            switch await LanguageAvailability().status(from: source, to: target) {
            case .installed: installed.insert(pair)
            case .unsupported: throw AvoError.translation(.unsupported)
            default: throw AvoError.translation(.notInstalled)
            }
        }
        await lock()
        defer { unlock() }
        // Translated meanwhile, for another window.
        if cache {
            for index in result.indices where result[index] == nil {
                result[index] = translations.value(for: Self.key(pair, texts[index]))
            }
        }
        let missing = result.indices.filter { result[$0] == nil }
        if missing.isEmpty { return result.compactMap { $0 } }
        do {
            let translated = try await Self.translations(of: missing.map { texts[$0] }, from: source, to: target)
            for (index, translation) in zip(missing, translated) {
                result[index] = translation
                if cache { translations.insert(translation, for: Self.key(pair, texts[index])) }
            }
            if UserDefaults.standard.string(forKey: Self.lastPairKey) != pair {
                UserDefaults.standard.set(pair, forKey: Self.lastPairKey)
            }
            return result.enumerated().map { $1 ?? texts[$0] }
        } catch {
            if TranslationError.notInstalled ~= error {
                // Removed since: the window offers to download it again.
                installed.remove(pair)
                throw AvoError.translation(.notInstalled)
            }
            if TranslationError.unsupportedLanguagePairing ~= error || TranslationError.unsupportedSourceLanguage ~= error
                || TranslationError.unsupportedTargetLanguage ~= error {
                throw AvoError.translation(.unsupported)
            }
            throw AvoError.translation(.failed(error.localizedDescription))
        }
    }

    /// Loads the model of the pair translated last, if it is on the Mac.
    func warmLastPair() async {
        guard #available(macOS 26.0, *), let pair = UserDefaults.standard.string(forKey: Self.lastPairKey) else { return }
        let parts = pair.split(separator: ">").map(String.init)
        guard parts.count == 2 else { return }
        let source = Locale.Language(identifier: parts[0]), target = Locale.Language(identifier: parts[1])
        let started = ProcessInfo.processInfo.systemUptime
        guard (try? await translate(["OK"], from: source, to: target, cache: false)) != nil else { return }
        logger.info("\(pair, privacy: .public) ready in \(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) ms")
    }

    private static func pair(_ source: Locale.Language, _ target: Locale.Language) -> String {
        "\(source.maximalIdentifier)>\(target.maximalIdentifier)"
    }

    private static func key(_ pair: String, _ text: String) -> String {
        "\(pair)\u{1F}\(text)"
    }

    /// One translation at a time, in the order asked.
    private func lock() async {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            busy = true
        }
    }

    private func unlock() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    /// `texts` translated in one batch, in their order (one the session
    /// returns nothing for stays as it was).
    @available(macOS 26.0, *)
    private nonisolated static func translations(of texts: [String], from source: Locale.Language,
                                                 to target: Locale.Language) async throws -> [String] {
        let session = TranslationSession(installedSource: source, target: target)
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
