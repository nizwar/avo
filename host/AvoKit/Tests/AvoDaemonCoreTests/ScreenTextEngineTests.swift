import AvoKit
import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import AvoDaemonCore

/// Translate Screen's engine in the daemon (ScreenTextEngine): who may use
/// it, the frames it refuses before Vision runs, and what crosses XPC.
/// Vision itself does not run here: its first read in a process can build
/// models for most of a minute.
@Suite(.serialized, .timeLimit(.minutes(1))) struct ScreenTextEngineTests {
    private static let frame = ScreenTextRequest(width: 4, height: 2, bytesPerRow: 16,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue, languages: ["en"])
    private static let translation = TranslationRequest(texts: ["OK"], source: Locale.Language(identifier: "en"),
                                                        target: Locale.Language(identifier: "id"))

    @Test func onlyAppShimsUseTheEngine() async throws {
        let harness = try Harness(apps: [], screenText: ScreenTextEngine())
        defer { harness.cleanUp() }
        let (panel, _) = await harness.connect(.controlPanel)
        await #expect(throws: AvoError.unauthorizedCaller) { try await harness.core.wakeScreenText(client: panel) }
        await #expect(throws: AvoError.unauthorizedCaller) {
            try await harness.core.readScreenText(Self.frame, pixels: Data(count: 32), client: panel)
        }
        await #expect(throws: AvoError.unauthorizedCaller) {
            try await harness.core.translateTexts(Self.translation, client: panel)
        }
        await #expect(throws: AvoError.unauthorizedCaller) {
            try await harness.core.knownTranslations(Self.translation, client: panel)
        }
        // A window asks which texts any app had translated: none yet.
        let (shim, _) = await harness.connect(.shim(package: "dev.example"))
        #expect(try await harness.core.knownTranslations(Self.translation, client: shim) == [nil])
    }

    @Test func aFrameWithoutAllItsPixelsIsNotRead() async throws {
        let harness = try Harness(apps: [], screenText: ScreenTextEngine())
        defer { harness.cleanUp() }
        let (shim, _) = await harness.connect(.shim(package: "dev.example"))
        await #expect(throws: AvoError.internalError("That frame cannot be read.")) {
            try await harness.core.readScreenText(Self.frame, pixels: Data(count: 31), client: shim)
        }
        #expect(Self.frame.byteCount == 32)
        #expect(ScreenTextRequest(width: 4, height: 2, bytesPerRow: 15, bitmapInfo: 0, languages: []).byteCount == nil)
        #expect(ScreenTextRequest(width: 0, height: 2, bytesPerRow: 16, bitmapInfo: 0, languages: []).byteCount == nil)
        #expect(ScreenTextRequest(width: 20_000, height: 2, bytesPerRow: 80_000, bitmapInfo: 0, languages: []).byteCount == nil)
    }

    @Test func aDaemonWithoutTheEngineSaysSo() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        let (shim, _) = await harness.connect(.shim(package: "dev.example"))
        await #expect(throws: AvoError.internalError("Translate Screen is not available.")) {
            try await harness.core.wakeScreenText(client: shim)
        }
    }

    @Test func readingsAndTranslationsCrossXPC() throws {
        let block = ScreenTextReading.Block(text: "設定", rect: CGRect(x: 1, y: 2, width: 30, height: 12), lineHeight: 12,
                                            alignment: .center, room: 4, background: .init(red: 1, green: 1, blue: 1),
                                            foreground: .init(red: 0, green: 0, blue: 0), language: "ja")
        let reading = try AvoXPC.decode(ScreenTextReading.self,
                                        from: AvoXPC.encode(ScreenTextReading(frameSize: CGSize(width: 1080, height: 2400), blocks: [block])))
        #expect(reading.frameSize == CGSize(width: 1080, height: 2400))
        #expect(reading.blocks.first?.text == "設定" && reading.blocks.first?.alignment == .center)
        #expect(reading.blocks.first?.rect == block.rect && reading.blocks.first?.language == "ja")
        let request = try AvoXPC.decode(TranslationRequest.self, from: AvoXPC.encode(
            TranslationRequest(texts: ["设置"], source: Locale.Language(identifier: "zh-Hans"), target: Locale.Language(identifier: "en"))))
        #expect(request.source == Locale.Language(identifier: "zh-Hans") && request.texts == ["设置"])
        // The window falls back to its own session on these, so they must arrive as they left.
        for problem in [TranslationProblem.notInstalled, .needsWindow, .unsupported, .failed("busy")] {
            #expect(AvoXPC.avoError(AvoXPC.nsError(AvoError.translation(problem))) == .translation(problem))
        }
    }

    /// The engine itself on this Mac, with a frame as App Shims copy them
    /// (BGRA): run with AVO_SCREEN_TEXT=1 (Vision may first build its models).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AVO_SCREEN_TEXT"] != nil), .timeLimit(.minutes(3)))
    func theEngineReadsAndTranslatesAFrame() async throws {
        let width = 1080, height = 400, bytesPerRow = 1080 * 4
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        var pixels = Data(count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { return }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let font = CTFontCreateUIFontForLanguage(.system, 44, nil)!
            let text = NSAttributedString(string: "Settings and privacy", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            context.textPosition = CGPoint(x: 40, y: 180)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        let engine = ScreenTextEngine()
        let request = ScreenTextRequest(width: width, height: height, bytesPerRow: bytesPerRow, bitmapInfo: info, languages: ["en", "id", "ja"])
        let started = ContinuousClock.now
        let first = try await engine.read(request, pixels: pixels)
        let warm = ContinuousClock.now
        let again = try await engine.read(request, pixels: pixels)
        print("first read \(warm - started), again \(ContinuousClock.now - warm): \(again.blocks.map(\.text))")
        #expect(first.blocks.map(\.text) == ["Settings and privacy"])
        #expect(first.blocks.first?.language == "en")
        #expect(first.frameSize == CGSize(width: width, height: height))
        let background = try #require(first.blocks.first?.background)
        #expect(background.red > 0.9 && background.green > 0.9 && background.blue > 0.9, "white around the text")
        let translated = try await engine.translate(TranslationRequest(texts: ["Settings", "Privacy"], source: Locale.Language(identifier: "en"),
                                                                       target: Locale.Language(identifier: "id")))
        print("translated: \(translated)")
        #expect(translated.count == 2 && translated != ["Settings", "Privacy"])
        // Kept for every app: known at once, and not translated again.
        let kept = TranslationRequest(texts: ["Privacy", "Settings", "Help"], source: Locale.Language(identifier: "en"),
                                      target: Locale.Language(identifier: "id"))
        #expect(await engine.known(kept) == [translated[1], translated[0], nil])
        let asked = ContinuousClock.now
        #expect(try await engine.translate(TranslationRequest(texts: ["Settings"], source: kept.source, target: kept.target))
            == [translated[0]])
        #expect(ContinuousClock.now - asked < .milliseconds(50))
    }

    /// Settings › General › Translate Screen: on unless turned off, and it applies at once.
    @Test func theEngineStartsWithAvoUnlessTurnedOff() throws {
        let old = try JSONDecoder().decode(VMConfig.self, from: Data(#"{"memoryMiB": 4096}"#.utf8))
        #expect(old.translationAtStartup)
        var off = VMConfig()
        off.translationAtStartup = false
        #expect(off.effect(of: VMConfig()) == .immediate)
        #expect(try !JSONDecoder().decode(VMConfig.self, from: JSONEncoder().encode(off)).translationAtStartup)
    }
}
