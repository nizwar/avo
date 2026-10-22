import AVFoundation
import AvoKit
import CoreMedia
import CoreVideo
import Metal
import os

/// Writes the frames one window shows to a QuickTime movie (H.264), each at
/// the time it was presented. Android draws only when something changes, so
/// the frame rate varies; the last frame lasts until the recording stops.
///
/// The renderer draws each frame into a pixel buffer from the recorder's own
/// pool on the GPU (`makeTarget`, then `append`): the engine reuses its
/// swapchain surfaces for later frames, so they never go to the encoder.
///
/// The movie is written in fragments, so a file that is cut off (the shim
/// crashed or was killed, quitting took too long, the disk filled up) still
/// plays up to its last fragment; once finished it is an ordinary movie.
///
/// Android's sound goes in an AAC track (RecordingAudio) when the engine
/// shares it and Record Android's Sound is on; without it the movie is video only.
final class ScreenRecorder: @unchecked Sendable {
    /// Why a recording ended.
    enum StopReason: Sendable {
        /// Stop Recording, the window closed or the app quit.
        case stopped
        /// The display turned the other way (a rotation); the movie keeps the frames until then.
        case resized
        /// Writing failed partway (a full disk, an encoder error): the movie
        /// keeps what was recorded until then. The error's description.
        case failed(String)
    }

    enum Outcome: Sendable {
        case saved(URL, StopReason)
        /// Nothing that plays was written; the file is gone.
        case failed(String)
    }

    /// A pixel buffer to draw one frame into, wrapped as a Metal texture.
    struct Target: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let texture: MTLTexture
        /// Keeps `texture` valid until the frame is appended.
        let metalTexture: CVMetalTexture
    }

    let url: URL
    /// Size of the display frames this recording takes.
    let sourceWidth: Int
    let sourceHeight: Int
    /// Where the renderer draws a frame in a target (left, top, width,
    /// height in normalized device coordinates): pixel for pixel, or scaled
    /// down to fit H.264.
    let drawRect: SIMD4<Float>

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    /// Android's sound, when it is recorded.
    private let audio: RecordingAudio?
    private let pool: CVPixelBufferPool
    private let textureCache: CVMetalTextureCache
    private let width: Int
    private let height: Int
    private let queue = DispatchQueue(label: "com.avodroid.recorder", qos: .userInitiated)
    /// Frames being drawn or appended: finishing waits for them.
    private let inFlight = DispatchGroup()
    private let lock = NSLock()
    private var pending = 0
    private var stopping = false
    private var failure: String?
    /// Writer state, on `queue` only.
    private var started = false
    private var lastTime = CMTime.invalid
    /// The newest frame in the movie, and the timer that adds it again (with a sound track only).
    private var lastFrame: CVPixelBuffer?
    private var repeater: (any DispatchSourceTimer)?
    private let onFinish: @MainActor (ScreenRecorder, Outcome) -> Void
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Recording")

    /// Media time scale: whole ticks for 24, 25, 30, 60 and 120 fps.
    private static let timescale: CMTimeScale = 6000
    /// Frames drawn but not yet appended; more are dropped while the encoder catches up.
    private static let maxPending = 3
    /// With a sound track, the newest frame is added again after this long without a new one.
    private static let repeatInterval = CMTime(seconds: 1, preferredTimescale: 600)
    /// At most this much is lost when the file is cut off. Each fragment
    /// costs about a kilobyte, nothing next to the video, and finishing
    /// takes no longer.
    private static let fragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
    /// Color attachments of the frames: untagged, the encoder takes them as
    /// BT.709 and the movie comes out a little too light. Never mutated.
    nonisolated(unsafe) private static let sRGB = [
        kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_sRGB,
        kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
    ] as CFDictionary

    /// Recordings whose file is not complete: quitting waits for them.
    private static let unfinished = DispatchGroup()
    private static let unfinishedCount = OSAllocatedUnfairLock(initialState: 0)

    static var anyUnfinished: Bool { unfinishedCount.withLock { $0 > 0 } }

    /// Returns once every recording's file is complete, or after `timeout`.
    static func waitForUnfinished(timeout: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = unfinished.wait(timeout: .now() + timeout)
                continuation.resume()
            }
        }
    }

    /// The movie's size for frames of this size: even numbers (the encoder
    /// works in 2 × 2 blocks), scaled down to H.264's largest picture
    /// (4096 × 2304 either way up) for a full-screen window on a 5K display.
    static func movieSize(width: Int, height: Int) -> (width: Int, height: Int, scale: Double) {
        let long = Double(max(width, height)), short = Double(min(width, height))
        let scale = min(1, 4096 / long, 2304 / short)
        return (Int(Double(width) * scale) & ~1, Int(Double(height) * scale) & ~1, scale)
    }

    /// Opens the movie file, with Android's sound from the engine's ring at
    /// `sound` (nil: video only). `onFinish` runs on the main actor once the
    /// file is complete (or could not be written).
    init(url: URL, frameWidth: Int, frameHeight: Int, device: MTLDevice, sound: AudioTapLocation? = nil,
         onFinish: @escaping @MainActor (ScreenRecorder, Outcome) -> Void) throws {
        self.url = url
        self.onFinish = onFinish
        sourceWidth = frameWidth
        sourceHeight = frameHeight
        let size = Self.movieSize(width: frameWidth, height: frameHeight)
        guard size.width >= 16, size.height >= 16 else { throw CaptureFiles.Failure.noFrame }
        width = size.width
        height = size.height
        // At least the movie's size: an odd last row or column is cut off, never stretched.
        drawRect = SIMD4(-1, 1, Float(2 * Double(frameWidth) * size.scale / Double(width)),
                         Float(2 * Double(frameHeight) * size.scale / Double(height)))

        let pixels = width * height
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                // About 15 Mbit/s for a phone-sized window: games stay sharp in motion.
                AVVideoAverageBitRateKey: min(max(pixels * 6, 4_000_000), 50_000_000),
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
            // Android draws sRGB, which shares its primaries with BT.709; the
            // buffers say they are sRGB (`makeTarget`), so the colors survive the encoder's conversion.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = Self.fragmentInterval
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        input.mediaTimeScale = Self.timescale
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw CaptureFiles.Failure.cannotWrite }
        writer.add(input)
        // An engine without the ring, or one that has gone: video only.
        var audio: RecordingAudio?
        if let sound, let made = RecordingAudio(location: sound, queue: queue), writer.canAdd(made.input) {
            writer.add(made.input)
            audio = made
        }
        self.audio = audio

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        var cache: CVMetalTextureCache?
        guard CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: Self.maxPending + 1] as CFDictionary,
                                      attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool,
              CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache
        else { throw CaptureFiles.Failure.cannotWrite }
        self.pool = pool
        textureCache = cache

        guard writer.startWriting() else {
            throw writer.error ?? CaptureFiles.Failure.cannotWrite
        }
        audio?.onFailure = { [weak self] error in self?.fail(error ?? self?.writer.error) }
        Self.unfinished.enter()
        Self.unfinishedCount.withLock { $0 += 1 }
    }

    /// Where a frame of this size goes in a target, in the same terms as
    /// `drawRect`. Android re-plugs its display when the window resizes or
    /// a graphics setting changes, and the movie keeps its size through
    /// that: a frame of another size is aspect-fitted, with black bars.
    /// Nil when the frame is turned the other way (a rotation), which would
    /// leave only a sliver of the movie, so the recording ends there.
    func drawRect(forFrameWidth frameWidth: Int, height frameHeight: Int) -> SIMD4<Float>? {
        if frameWidth == sourceWidth, frameHeight == sourceHeight { return drawRect }
        guard frameWidth > 0, frameHeight > 0, (frameWidth > frameHeight) == (sourceWidth > sourceHeight) else { return nil }
        let scale = min(Double(width) / Double(frameWidth), Double(height) / Double(frameHeight))
        let w = Float(2 * Double(frameWidth) * scale / Double(width))
        let h = Float(2 * Double(frameHeight) * scale / Double(height))
        return SIMD4(-w / 2, h / 2, w, h)
    }

    /// Writing failed (a full disk, an encoder error): the window stops the recording.
    var hasFailed: Bool { lock.withLock { failure != nil } }

    /// A buffer for the next frame, or nil to drop it (the encoder is behind,
    /// or the recording is stopping). Every target goes back with `append` or `drop`.
    func makeTarget() -> Target? {
        // Counted under the lock: `finish` waits for every target handed out before it.
        let accepted = lock.withLock { () -> Bool in
            guard !stopping, failure == nil, pending < Self.maxPending else { return false }
            pending += 1
            inFlight.enter()
            return true
        }
        guard accepted else { return nil }
        var buffer: CVPixelBuffer?
        var wrapped: CVMetalTexture?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer,
              CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, .bgra8Unorm, width, height, 0,
                                                        &wrapped) == kCVReturnSuccess,
              let wrapped, let texture = CVMetalTextureGetTexture(wrapped) else {
            done()
            return nil
        }
        CVBufferSetAttachments(buffer, Self.sRGB, .shouldPropagate)
        return Target(pixelBuffer: buffer, texture: texture, metalTexture: wrapped)
    }

    /// Adds a drawn frame shown at `time` (host clock).
    func append(_ target: Target, at time: CMTime) {
        queue.async { [self] in
            defer { done() }
            let time = CMTimeConvertScale(time, timescale: Self.timescale, method: .roundHalfAwayFromZero)
            guard writer.status == .writing else {
                fail(writer.error)
                return
            }
            // Live frames are never queued up: a frame the encoder cannot take now is dropped.
            guard input.isReadyForMoreMediaData else { return }
            if !started {
                writer.startSession(atSourceTime: time)
                started = true
                if let audio {
                    audio.start(at: time)
                    startRepeatingFrames()
                }
            } else if time <= lastTime {
                return // two frames in the same tick: keep the first
            }
            if adaptor.append(target.pixelBuffer, withPresentationTime: time) {
                lastTime = time
                if repeater != nil { lastFrame = target.pixelBuffer }
            } else {
                fail(writer.error)
            }
        }
    }

    /// With a sound track the movie's fragments go on being written while
    /// Android draws nothing, and a frame still waiting for the next one gets
    /// a guessed length in its fragment: the picture would end long before
    /// the sound. So the newest frame is added again once a second (on `queue`).
    private func startRepeatingFrames() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.repeatLastFrame() }
        timer.resume()
        repeater = timer
    }

    private func repeatLastFrame() {
        guard let lastFrame, writer.status == .writing, input.isReadyForMoreMediaData,
              lock.withLock({ pending == 0 && !stopping }) else { return }
        // A little in the past: a frame being drawn now was shown later still.
        let now = CMClockGetTime(CMClockGetHostTimeClock()) - CMTime(value: 1, timescale: 10)
        let time = CMTimeConvertScale(now, timescale: Self.timescale, method: .roundHalfAwayFromZero)
        guard time - lastTime >= Self.repeatInterval else { return }
        if adaptor.append(lastFrame, withPresentationTime: time) { lastTime = time } else { fail(writer.error) }
    }

    /// Gives back a target that was not drawn.
    func drop(_ target: Target) {
        queue.async { [self] in done() }
    }

    private func done() {
        lock.withLock { pending -= 1 }
        inFlight.leave()
    }

    private func fail(_ error: (any Error)?) {
        let message = error?.localizedDescription ?? CaptureFiles.Failure.cannotWrite.localizedDescription
        logger.error("recording failed: \(message, privacy: .public)")
        lock.withLock { if failure == nil { failure = message } }
    }

    /// Ends the movie at `time` (host clock), once the frames being drawn are in.
    /// Only the first call counts.
    func finish(_ reason: StopReason, at time: CMTime) {
        let first = lock.withLock { () -> Bool in
            defer { stopping = true }
            return !stopping
        }
        guard first else { return }
        if let audio {
            // The sound of the last moments is still on its way from the engine.
            inFlight.enter()
            queue.async { audio.ends(at: time) }
            queue.asyncAfter(deadline: .now() + RecordingAudio.lag + 0.05) { [self] in
                if started, writer.status == .writing { audio.finish() } else { audio.stop() }
                inFlight.leave()
            }
        }
        inFlight.notify(queue: queue) { [self] in complete(reason, at: time) }
    }

    /// On `queue`, after the last frame.
    private func complete(_ reason: StopReason, at time: CMTime) {
        repeater?.cancel()
        repeater = nil
        lastFrame = nil
        let problem = lock.withLock { failure } ?? (writer.status == .failed ? writer.error?.localizedDescription : nil)
        guard started else {
            // No frame written: leave no empty file behind.
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: url)
            report(.failed(problem ?? String(localized: "Nothing was recorded.", bundle: .windowHost)))
            return
        }
        guard writer.status == .writing else {
            keepWhatPlays(problem ?? CaptureFiles.Failure.cannotWrite.localizedDescription)
            return
        }
        // The last frame stays on screen until the recording stops (at least
        // one frame long). The session ends before the tracks do: a sound
        // track closed first would leave the last frame a guessed length.
        let end = CMTimeConvertScale(time, timescale: Self.timescale, method: .roundHalfAwayFromZero)
        writer.endSession(atSourceTime: CMTimeMaximum(end, lastTime + CMTime(value: 1, timescale: 60)))
        input.markAsFinished()
        audio?.input.markAsFinished()
        writer.finishWriting { [self] in
            if writer.status == .completed {
                report(.saved(url, reason))
            } else {
                let message = writer.error?.localizedDescription ?? CaptureFiles.Failure.cannotWrite.localizedDescription
                logger.error("cannot finish the recording: \(message, privacy: .public)")
                keepWhatPlays(message)
            }
        }
    }

    /// After writing failed partway: the fragments written until then still
    /// play, so the file stays, unless it ended before the first fragment
    /// and nothing in it plays.
    private func keepWhatPlays(_ message: String) {
        Task { [self] in
            let duration = try? await AVURLAsset(url: url).load(.duration)
            if let duration, duration.isNumeric, duration > .zero {
                report(.saved(url, .failed(message)))
            } else {
                try? FileManager.default.removeItem(at: url)
                report(.failed(message))
            }
        }
    }

    private func report(_ outcome: Outcome) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { onFinish(self, outcome) }
        }
        // The file is complete (or gone): quitting need not wait for the window.
        Self.unfinishedCount.withLock { $0 -= 1 }
        Self.unfinished.leave()
    }
}
