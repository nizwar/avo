import CoreGraphics
import Foundation

// What Translate Screen's engine is asked and answers. The engine runs in
// the daemon, one for every app (AvoDaemonCore's ScreenTextEngine): an App
// Shim sends the frame on screen and gets its text back in blocks, then
// sends that text and gets it back translated. Vision's text models and the
// translation models load there once instead of in every App Shim.

/// A frame to read. Its pixels go beside this, as the App Shim copied them
/// from the display (8 bits per component, 4 components per pixel).
public struct ScreenTextRequest: Codable, Sendable {
    public var width: Int
    public var height: Int
    public var bytesPerRow: Int
    /// The pixels' `CGBitmapInfo`.
    public var bitmapInfo: UInt32
    /// NaturalLanguage codes of the languages a block may be in: those that
    /// can be translated.
    public var languages: [String]

    public init(width: Int, height: Int, bytesPerRow: Int, bitmapInfo: UInt32, languages: [String]) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.bitmapInfo = bitmapInfo
        self.languages = languages
    }

    /// The bytes the pixels take, or nil for a frame the engine does not read.
    public var byteCount: Int? {
        guard (1...16_384).contains(width), (1...16_384).contains(height), bytesPerRow >= width * 4,
              bytesPerRow <= width * 4 + 4096 else { return nil }
        return bytesPerRow * height
    }
}

/// The text in one frame: Vision's lines grouped into blocks (ScreenTextLayout),
/// each with the colors around and under it and the language it is in.
public struct ScreenTextReading: Codable, Sendable {
    public struct Block: Codable, Sendable {
        public var text: String
        /// Frame pixels, origin at the top left.
        public var rect: CGRect
        public var lineHeight: Double
        public var alignment: ScreenTextLayout.Alignment
        /// How far a longer translation may widen it to the right, in frame pixels.
        public var room: Double
        public var background: ScreenTextLayout.RGB
        public var foreground: ScreenTextLayout.RGB
        /// NaturalLanguage code of the language it is in ("ja", "zh-Hant"); nil when unknown.
        public var language: String?

        public init(text: String, rect: CGRect, lineHeight: Double, alignment: ScreenTextLayout.Alignment, room: Double,
                    background: ScreenTextLayout.RGB, foreground: ScreenTextLayout.RGB, language: String?) {
            self.text = text
            self.rect = rect
            self.lineHeight = lineHeight
            self.alignment = alignment
            self.room = room
            self.background = background
            self.foreground = foreground
            self.language = language
        }
    }

    public var frameSize: CGSize
    public var blocks: [Block]

    public init(frameSize: CGSize, blocks: [Block]) {
        self.frameSize = frameSize
        self.blocks = blocks
    }
}

/// Texts to translate from one language into another, in one batch.
public struct TranslationRequest: Codable, Sendable {
    public var texts: [String]
    public var source: Locale.Language
    public var target: Locale.Language

    public init(texts: [String], source: Locale.Language, target: Locale.Language) {
        self.texts = texts
        self.source = source
        self.target = target
    }
}

/// Why the engine did not translate.
public enum TranslationProblem: Codable, Equatable, Sendable {
    /// The languages are not on this Mac: the app window asks macOS to
    /// download them (the system's sheet needs a window).
    case notInstalled
    /// This macOS translates only for a window (macOS 15).
    case needsWindow
    /// macOS cannot translate between these languages.
    case unsupported
    case failed(String)

    var message: String {
        switch self {
        case .notInstalled: String(localized: "The languages for this translation aren’t downloaded.", bundle: .avoKit)
        case .needsWindow: String(localized: "This version of macOS translates only in an app window.", bundle: .avoKit)
        case .unsupported: String(localized: "macOS can’t translate between these languages.", bundle: .avoKit)
        case .failed(let detail): detail
        }
    }
}
