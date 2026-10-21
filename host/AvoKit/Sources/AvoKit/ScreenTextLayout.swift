import CoreGraphics
import Foundation

/// The rules behind Translate Screen in an app window (AvoWindowHost):
/// which recognized lines read as one block, how a block's lines join into
/// one text to translate, the font size a translation fits at and the colors
/// of the plate that covers the original (ScreenChanges.swift has where two
/// frames differ). They are plain functions of text, rectangles and pixels,
/// so they are tested here without Vision, the Translation framework or AppKit.
public enum ScreenTextLayout {
    /// One line of text Vision found, in frame pixels with the origin at the
    /// top left (the way Android and the frame's bytes count rows).
    public struct Line: Equatable, Sendable {
        public var text: String
        public var rect: CGRect

        public init(text: String, rect: CGRect) {
            self.text = text
            self.rect = rect
        }
    }

    public enum Alignment: Codable, Equatable, Sendable {
        case leading, center
    }

    /// Lines that read as one paragraph or label: they are translated as one
    /// text, because a sentence broken over lines translates badly line by line.
    public struct Block: Equatable, Sendable {
        public var lines: [Line]
        /// All the lines' rects together.
        public var rect: CGRect
        /// The height of a typical line, which the translation's font follows.
        public var lineHeight: Double
        public var alignment: Alignment

        public init(lines: [Line]) {
            self.lines = lines
            rect = lines.dropFirst().reduce(lines.first?.rect ?? .zero) { $0.union($1.rect) }
            let heights = lines.map { Double($0.rect.height) }.sorted()
            lineHeight = heights.isEmpty ? 0 : heights[heights.count / 2]
            alignment = Self.alignment(of: lines, lineHeight: lineHeight)
        }

        /// The block's text, its lines joined the way the script writes them.
        public var text: String { ScreenTextLayout.joined(lines.map(\.text)) }

        /// Centered when the lines share a middle but not a left edge (a
        /// title, a dialog's message); otherwise text starts where it reads from.
        private static func alignment(of lines: [Line], lineHeight: Double) -> Alignment {
            guard lines.count > 1 else { return .leading }
            func spread(_ values: [CGFloat]) -> Double { Double((values.max() ?? 0) - (values.min() ?? 0)) }
            let tolerance = lineHeight * 0.6
            if spread(lines.map(\.rect.minX)) <= tolerance { return .leading }
            return spread(lines.map(\.rect.midX)) <= tolerance ? .center : .leading
        }
    }

    // MARK: Blocks

    /// Groups lines into blocks, top to bottom. A line joins the block whose
    /// last line it continues: just below it, about as tall, and in the same
    /// column. Lines side by side (tabs, a row's label and value) stay apart.
    public static func blocks(_ lines: [Line]) -> [Block] {
        let sorted = lines
            .filter { $0.rect.width > 0 && $0.rect.height > 0 }
            .sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
        var groups: [[Line]] = []
        for line in sorted {
            var best: (index: Int, gap: CGFloat)?
            for (index, group) in groups.enumerated() {
                guard let last = group.last, continues(last, with: line) else { continue }
                let gap = line.rect.minY - last.rect.maxY
                if best.map({ gap < $0.gap }) ?? true { best = (index, gap) }
            }
            if let best { groups[best.index].append(line) } else { groups.append([line]) }
        }
        return groups.map(Block.init(lines:))
    }

    /// Whether `below` is the next line of the paragraph `above` ends.
    static func continues(_ above: Line, with below: Line) -> Bool {
        let a = above.rect, b = below.rect
        guard max(a.height, b.height) / min(a.height, b.height) <= 1.35 else { return false }
        let height = (a.height + b.height) / 2
        // Line spacing; a list's rows are further apart than that.
        let gap = b.minY - a.maxY
        guard gap >= -0.3 * height, gap <= 0.7 * height else { return false }
        let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        return overlap >= 0.5 * min(a.width, b.width)
            || abs(a.minX - b.minX) <= height
            || abs(a.midX - b.midX) <= height
    }

    /// How far the block at `index` may widen to the right when its
    /// translation is longer: up to half its width, but never into the next
    /// text on its row or past the frame's edge (keeping half a line clear).
    /// A label's longer translation then keeps its size instead of shrinking.
    public static func room(after index: Int, in blocks: [Block], frameWidth: Double) -> Double {
        guard blocks.indices.contains(index) else { return 0 }
        let rect = blocks[index].rect
        let margin = blocks[index].lineHeight / 2
        var limit = frameWidth - margin
        for (other, block) in blocks.enumerated() where other != index {
            let rowOverlap = min(rect.maxY, block.rect.maxY) - max(rect.minY, block.rect.minY)
            if rowOverlap > 0, block.rect.minX >= rect.maxX { limit = min(limit, Double(block.rect.minX) - margin) }
        }
        return max(0, min(limit - Double(rect.maxX), Double(rect.width) / 2))
    }

    // MARK: Text

    /// Lines joined into one text: with a space, but none where the script
    /// writes no spaces (Chinese, Japanese, Thai, …), and a word hyphenated
    /// over two lines made whole again ("trans-" "lation", "Wi-" "Fi").
    public static func joined(_ lines: [String]) -> String {
        var text = ""
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = line.first else { continue }
            guard let last = text.last else {
                text = line
                continue
            }
            if last == "-", text.dropLast().last?.isLetter == true, first.isLetter {
                // A lowercase letter goes on the broken word; a capital
                // starts the second half of a compound, which keeps its hyphen.
                if first.isLowercase { text.removeLast() }
                text += line
            } else if writtenWithoutSpaces(last) || writtenWithoutSpaces(first) {
                text += line
            } else {
                text += " " + line
            }
        }
        return text
    }

    /// Han, kana, full-width forms and the Southeast Asian scripts that
    /// separate phrases, not words, with spaces.
    static func writtenWithoutSpaces(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0E00...0x0EFF, // Thai, Lao
                 0x1000...0x109F, // Myanmar
                 0x1780...0x17FF, // Khmer
                 0x3000...0x30FF, // CJK punctuation, Hiragana, Katakana
                 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, // Han
                 0xFF00...0xFFEF: // full-width and half-width forms
                true
            default:
                false
            }
        }
    }

    /// Whether `text` has anything to translate: times, prices and
    /// percentages read the same in every language.
    public static func hasLetters(_ text: String) -> Bool {
        text.contains { $0.isLetter }
    }

    /// Whether two texts are one text read twice: Vision reads the same words
    /// a little differently from frame to frame (an emoji as a letter or two,
    /// a stray quote, an icon as "T"), and a text read before keeps its
    /// translation instead of waiting for a new one. Both have at least six
    /// characters, the same digits ("3 comments" is not "4 comments"), and
    /// differ in at most one character in eight.
    public static func sameTextRead(_ a: String, _ b: String) -> Bool {
        let x = Array(a.lowercased()), y = Array(b.lowercased())
        guard min(x.count, y.count) >= 6, a.filter(\.isNumber) == b.filter(\.isNumber) else { return false }
        let limit = max(1, max(x.count, y.count) / 8)
        guard abs(x.count - y.count) <= limit else { return false }
        // Edit distance, given up once every way exceeds the limit.
        var previous = Array(0...y.count), current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            var best = i
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
                best = min(best, current[j])
            }
            if best > limit { return false }
            swap(&previous, &current)
        }
        return previous[y.count] <= limit
    }

    /// Whether a translation says nothing new (a name, a brand, a word both
    /// languages share): the original then shows without a plate over it.
    public static func sameText(_ original: String, _ translation: String) -> Bool {
        let a = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        return a.compare(b, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
    }

    // MARK: Font size

    /// The largest size from `minimum` to `maximum` (to half a point) at
    /// which `fits` holds, or `minimum` when even that does not fit. A
    /// `maximum` below `minimum` (tiny original text) is taken as it is.
    public static func fittedSize(minimum: Double, maximum: Double, fits: (Double) -> Bool) -> Double {
        let minimum = min(minimum, maximum)
        if fits(maximum) { return maximum }
        guard fits(minimum) else { return minimum }
        var low = minimum, high = maximum // `low` fits, `high` does not
        while high - low > 0.5 {
            let middle = (low + high) / 2
            if fits(middle) { low = middle } else { high = middle }
        }
        return low
    }

    // MARK: Colors

    /// An sRGB color, each component from 0 to 1.
    public struct RGB: Codable, Equatable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        public static let black = RGB(red: 0, green: 0, blue: 0)
        public static let white = RGB(red: 1, green: 1, blue: 1)

        /// Relative luminance (WCAG 2).
        public var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        /// WCAG contrast ratio, from 1 (the same) to 21 (black on white).
        public func contrast(with other: RGB) -> Double {
            let (a, b) = (luminance, other.luminance)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }

        func distance(to other: RGB) -> Double {
            ((red - other.red) * (red - other.red) + (green - other.green) * (green - other.green)
                + (blue - other.blue) * (blue - other.blue)).squareRoot()
        }
    }

    /// The plate's color and the translation's for a block: the plate takes
    /// the color around the text (`edge`: the pixels just outside it), so it
    /// blends into what it covers; the text takes the original's color (the
    /// `inside` pixels most unlike the background: scaled down, a glyph's
    /// edges are a mix of the two) when that still reads well on the plate,
    /// black or white otherwise.
    public static func plateColors(edge: [RGB], inside: [RGB]) -> (background: RGB, text: RGB) {
        guard let background = median(edge) else { return (.white, .black) }
        let ink = inside.map { (color: $0, distance: $0.distance(to: background)) }
            .filter { $0.distance > 0.25 }
            .sorted { $0.distance > $1.distance }
        let strongest = ink.prefix(max(1, ink.count / 3)).map(\.color)
        if ink.count * 33 >= inside.count, let text = median(strongest), text.contrast(with: background) >= 3 {
            return (background, text)
        }
        return (background, background.contrast(with: .black) >= background.contrast(with: .white) ? .black : .white)
    }

    /// Each component's median: one stray pixel (an icon, a border) does not tint the result.
    static func median(_ colors: [RGB]) -> RGB? {
        guard !colors.isEmpty else { return nil }
        func middle(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        return RGB(red: middle(colors.map(\.red)), green: middle(colors.map(\.green)), blue: middle(colors.map(\.blue)))
    }
}

/// A dictionary that forgets its least recently used entries beyond
/// `capacity` (Translate Screen's translations of the text it has seen).
public struct RecentCache<Key: Hashable, Value> {
    public let capacity: Int
    private var entries: [Key: (value: Value, used: UInt64)] = [:]
    private var clock: UInt64 = 0

    public init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    public var count: Int { entries.count }

    public mutating func value(for key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        clock += 1
        entries[key] = (entry.value, clock)
        return entry.value
    }

    public mutating func insert(_ value: Value, for key: Key) {
        clock += 1
        entries[key] = (value, clock)
        guard entries.count > capacity else { return }
        // Forget a quarter at once, so a full cache is not sorted on every insert.
        let keep = max(capacity * 3 / 4, 1)
        for (key, _) in entries.sorted(by: { $0.value.used < $1.value.used }).prefix(entries.count - keep) {
            entries[key] = nil
        }
    }
}

/// Matching languages between the Mac's preferences, NaturalLanguage's
/// codes and the languages Apple's Translation framework supports.
public enum ScreenTextLanguages {
    /// The same language for translating: English and British English are,
    /// Simplified and Traditional Chinese are not.
    public static func same(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        guard let code = a.languageCode, code == b.languageCode else { return false }
        return script(a) == script(b)
    }

    private static func script(_ language: Locale.Language) -> Locale.Script? {
        language.script ?? Locale.Language(identifier: language.maximalIdentifier).script
    }

    /// The NaturalLanguage code (`NLLanguage`) for `language`: its language
    /// code, with the script for Chinese.
    public static func naturalLanguageCode(for language: Locale.Language) -> String? {
        guard let code = language.languageCode?.identifier else { return nil }
        guard code == "zh" else { return code }
        return script(language) == .hanTraditional ? "zh-Hant" : "zh-Hans"
    }

    /// The supported language that `language` is: the one in its region
    /// when there are several (English in the UK), else the one in the
    /// language's own region (English in the US, not India, for English in
    /// Indonesia) or in none, else the first.
    public static func match(_ language: Locale.Language, in supported: [Locale.Language]) -> Locale.Language? {
        let candidates = supported.filter { same($0, language) }
        if let region = language.region, let regional = candidates.first(where: { $0.region == region }) { return regional }
        let home = Locale.Language(identifier: Locale.Language(identifier: base(of: language)).maximalIdentifier).region
        if let home, let own = candidates.first(where: { $0.region == home }) { return own }
        return candidates.first { $0.region == nil } ?? candidates.first
    }

    /// "en", "zh-Hant": the language and its script, without the region.
    private static func base(of language: Locale.Language) -> String {
        [language.languageCode?.identifier, script(language)?.identifier].compactMap { $0 }.joined(separator: "-")
    }

    /// Translate Into's list: each language once, in its own region where
    /// the framework has several (English in the US, not in nine regions),
    /// and Chinese once per script.
    public static func distinct(_ supported: [Locale.Language]) -> [Locale.Language] {
        var seen: Set<String> = []
        return supported.compactMap { language in
            let key = base(of: language)
            guard seen.insert(key).inserted else { return nil }
            return match(Locale.Language(identifier: key), in: supported)
        }
    }

    /// What to name `language` by: its language ("en"), with the script
    /// when `supported` has it in another script too ("zh-Hant"). Never the
    /// region: "English", not "English (Latin, United States)".
    public static func nameIdentifier(of language: Locale.Language, among supported: [Locale.Language]) -> String {
        guard let code = language.languageCode else { return language.minimalIdentifier }
        let scripts = Set(supported.filter { $0.languageCode == code }.compactMap { script($0) })
        return scripts.count > 1 ? base(of: language) : code.identifier
    }

    /// The first of the Mac's preferred languages (`Locale.preferredLanguages`)
    /// that can be translated into.
    public static func target(preferred: [String], supported: [Locale.Language]) -> Locale.Language? {
        preferred.lazy.compactMap { match(Locale.Language(identifier: $0), in: supported) }.first
    }
}
