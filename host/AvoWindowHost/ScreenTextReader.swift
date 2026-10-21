import AvoKit
import CoreGraphics
import Foundation

/// Reads the text in one frame for Translate Screen. The daemon's text
/// engine does the reading (ScreenTextEngine: Vision finds the lines in any
/// script it knows, ScreenTextLayout groups them into blocks, and each block
/// gets the colors around and under it and its language), one engine for
/// every app, so Vision's models load once instead of in every App Shim.
/// The samples that tell where a later frame differs are taken here.
enum ScreenTextReader {
    typealias Block = ScreenTextReading.Block
    typealias Reading = ScreenTextReading

    /// Samples have a queue of their own: they never wait for anything.
    private static let sampleQueue = DispatchQueue(label: "dev.avo.screen-sample", qos: .userInitiated)

    /// Reads `image` (a frame the renderer copied) in the daemon.
    /// `languages` (NaturalLanguage codes) are the ones a block may be in:
    /// those that can be translated.
    static func read(_ image: CGImage, languages: [String], with client: DaemonClient) async throws -> Reading {
        guard image.bitsPerPixel == 32, image.bitsPerComponent == 8, let pixels = image.dataProvider?.data as Data? else {
            throw CaptureFiles.Failure.noFrame
        }
        let request = ScreenTextRequest(width: image.width, height: image.height, bytesPerRow: image.bytesPerRow,
                                        bitmapInfo: image.bitmapInfo.rawValue, languages: languages)
        return try await client.readScreenText(request, pixels: pixels)
    }

    /// `image` as a ScreenSample, to tell where a later frame differs, and
    /// as a strip, to tell how far a scroll moved it (ScreenFollow): a
    /// millisecond or two for a phone's frame.
    static func samples(of image: CGImage) async -> (sample: ScreenSample, strip: ScreenSample) {
        await withCheckedContinuation { continuation in
            sampleQueue.async {
                let grid = ScreenSample.grid(width: image.width, height: image.height)
                let strip = ScreenSample.stripGrid(width: image.width, height: image.height)
                continuation.resume(returning: (sampleNow(image, columns: grid.columns, rows: grid.rows),
                                                sampleNow(image, columns: strip.columns, rows: strip.rows)))
            }
        }
    }

    // MARK: Pixels

    /// The frame scaled down to a grid of gray cells, each the average of
    /// the pixels it covers, so a changed word still changes a cell or two.
    private static func sampleNow(_ image: CGImage, columns: Int, rows: Int) -> ScreenSample {
        var cells = [UInt8](repeating: 0, count: columns * rows)
        cells.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: columns, height: rows, bitsPerComponent: 8,
                                          bytesPerRow: columns, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            // Medium is Core Graphics' box filter: each cell the true average
            // (high resamples, and can miss a small change between its taps).
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        }
        return ScreenSample(width: image.width, height: image.height, columns: columns, rows: rows, cells: cells)
    }
}
