import AppKit
import SwiftUI

/// Colours taken from an app's icon, for its game page and its cards in the
/// Library: a small k-means over the icon's pixels in OKLab (a perceptual
/// colour space), then the most vivid cluster that covers enough of the
/// icon, set to a lightness that glows on the dark page. Icons without a
/// vivid colour get Avo's green.
struct IconPalette: Equatable, Sendable {
    /// The glow and the page's small capitals ("GAME · GOOGLE PLAY").
    var accent: UInt32
    /// The accent, darker: the second glow, low in the hero.
    var deep: UInt32

    /// Avo's own green, for apps without an icon (or a grey one).
    static let avo = IconPalette(accent: 0xBCDC8F, deep: 0x4F6B2E)

    /// Where the dark base gradient ends: its green, warmed by the accent.
    func baseEnd(from base: UInt32, amount: Double) -> UInt32 {
        OKLab.mix(base, accent, amount)
    }

    // MARK: Extraction

    /// The palette of `image`; nil for one without enough opaque pixels.
    static func extract(from image: NSImage) -> IconPalette? {
        guard let pixels = samples(of: image), pixels.count >= 16 else { return nil }
        let clusters = kMeans(pixels, k: 5)
        let total = Double(pixels.count)
        // The most vivid colour that is more than a speck: vividness counts
        // more than area (orange letters on an olive tile are the accent),
        // and near black or white makes a poor glow.
        let scored = clusters.filter { Double($0.count) / total >= 0.015 }.map { cluster -> (OKLab, Double) in
            let lab = cluster.center
            var score = lab.chroma * lab.chroma * pow(Double(cluster.count) / total, 0.4)
            if lab.l < 0.35 { score *= 0.5 }
            if lab.l < 0.2 || lab.l > 0.96 { score *= 0.3 }
            return (lab, score)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.0.chroma >= 0.035 else { return .avo }
        let hue = best.0.hue
        let chroma = min(max(best.0.chroma, 0.07), 0.16)
        let lightness = min(max(best.0.l, 0.72), 0.84)
        let accent = OKLab(lightness: lightness, chroma: chroma, hue: hue)
        let deep = OKLab(lightness: lightness * 0.6, chroma: chroma * 0.75, hue: hue)
        return IconPalette(accent: accent.rgb, deep: deep.rgb)
    }

    /// The icon at 40 × 40, its opaque pixels in OKLab.
    private static func samples(of image: NSImage) -> [OKLab]? {
        let side = 40
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: rect)
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var pixels: [OKLab] = []
        pixels.reserveCapacity(side * side)
        for index in 0..<(side * side) {
            let alpha = Double(bytes[index * 4 + 3]) / 255
            guard alpha >= 0.8 else { continue }
            let r = Double(bytes[index * 4]) / 255 / alpha
            let g = Double(bytes[index * 4 + 1]) / 255 / alpha
            let b = Double(bytes[index * 4 + 2]) / 255 / alpha
            pixels.append(OKLab(r: min(r, 1), g: min(g, 1), b: min(b, 1)))
        }
        return pixels
    }

    struct Cluster {
        var center: OKLab
        var count: Int
    }

    /// Lloyd's k-means with farthest-point seeding (deterministic).
    static func kMeans(_ pixels: [OKLab], k: Int, iterations: Int = 10) -> [Cluster] {
        guard !pixels.isEmpty else { return [] }
        var centers: [OKLab] = []
        // Seed: the pixel nearest the mean, then each time the pixel farthest from the seeds.
        let mean = OKLab.mean(pixels)
        centers.append(pixels.min { $0.distance(to: mean) < $1.distance(to: mean) }!)
        while centers.count < min(k, pixels.count) {
            let next = pixels.max { a, b in
                centers.map { a.distance(to: $0) }.min()! < centers.map { b.distance(to: $0) }.min()!
            }!
            if centers.contains(next) { break }
            centers.append(next)
        }
        var assignment = [Int](repeating: 0, count: pixels.count)
        for _ in 0..<iterations {
            var changed = false
            for (index, pixel) in pixels.enumerated() {
                var nearest = 0
                var best = Double.infinity
                for (c, center) in centers.enumerated() {
                    let d = pixel.distance(to: center)
                    if d < best { best = d; nearest = c }
                }
                if assignment[index] != nearest { assignment[index] = nearest; changed = true }
            }
            for c in centers.indices {
                let members = pixels.indices.filter { assignment[$0] == c }.map { pixels[$0] }
                if !members.isEmpty { centers[c] = OKLab.mean(members) }
            }
            if !changed { break }
        }
        return centers.indices.map { c in Cluster(center: centers[c], count: assignment.filter { $0 == c }.count) }
    }
}

/// Palettes per app, worked out once per icon image.
@MainActor
final class IconPaletteCache {
    static let shared = IconPaletteCache()
    private var entries: [String: (image: ObjectIdentifier, palette: IconPalette)] = [:]

    func palette(for package: String, icon: NSImage?) -> IconPalette {
        guard let icon else { return .avo }
        if let entry = entries[package], entry.image == ObjectIdentifier(icon) { return entry.palette }
        let palette = IconPalette.extract(from: icon) ?? .avo
        entries[package] = (ObjectIdentifier(icon), palette)
        return palette
    }
}
