import AvoKit
import CoreMedia
import IOSurface
import Metal
import MetalFX
import QuartzCore

/// Draws the display's current IOSurface into a CAMetalLayer. Frames are
/// never encoded or copied on the CPU (spec: "frame tidak perlu di-encode
/// menjadi video"); only a screenshot copies the one frame on screen, and a
/// screen recording has the GPU draw each frame a second time, into the
/// recorder's buffer.
///
/// Android's frame fills the window or is aspect-fitted with black bars
/// (`DisplaySizing.presentationRect`, which `DisplayView` uses for touches
/// too). How it is scaled (`DisplaySizing.scalingPath`): 1:1 when the sizes
/// match, MetalFX Spatial when it is enlarged, an averaging filter when it
/// is shrunk, and bilinear while the window is being resized or a scaler is
/// still being built. An optional RCAS pass sharpens 1:1 pictures.
final class MetalRenderer: @unchecked Sendable {
    let layer = CAMetalLayer()
    let device: MTLDevice
    private let queue: MTLCommandQueue
    /// Pipelines, one per fragment shader in `MetalShaders`. The recorder uses `linearPipeline`.
    private let linearPipeline: MTLRenderPipelineState
    private let nearestPipeline: MTLRenderPipelineState
    private let downsamplePipeline: MTLRenderPipelineState
    private let copyPipeline: MTLRenderPipelineState
    private let rcasPipeline: MTLRenderPipelineState
    private let keyedPipeline: MTLRenderPipelineState
    /// Widget panels: black is transparent and the layer is not opaque
    /// (`avo_keyed`). Set before the first frame.
    var keysOutBlack = false {
        didSet {
            layer.isOpaque = !keysOutBlack
            layer.backgroundColor = keysOutBlack ? CGColor(gray: 0, alpha: 0) : CGColor(gray: 0, alpha: 1)
        }
    }
    private let renderQueue = DispatchQueue(label: "dev.avo.render", qos: .userInteractive)
    private let lock = NSLock()
    private var textures: [MTLTexture] = []
    /// The IOSurface behind each texture (same index).
    private var surfaces: [IOSurface] = []
    private var current: Int?
    private var onScreen = true
    /// The screen recording in progress (render queue only).
    private var recorder: ScreenRecorder?
    private(set) var lastSequence: UInt64 = 0
    /// Called once on the main queue after the next frame is shown.
    private var onFirstFrame: (@MainActor () -> Void)?
    /// Whether this GPU has a MetalFX spatial scaler. Every Apple Silicon Mac
    /// does; the check stays so a missing one shows as a fallback in the HUD
    /// instead of a black window.
    let isMetalFXSupported: Bool
    /// Filter and sharpness for the next draw (under `lock`).
    private var options = RenderOptions(filter: GraphicsSettings.appsDefault.filter,
                                        sharpness: GraphicsSettings.appsDefault.sharpness)
    /// A live resize or full-screen transition is in progress (under `lock`).
    private var interactiveResize = false

    /// The frame kept on screen while Android re-plugs its display (under `lock`).
    private struct Hold {
        var texture: MTLTexture
        /// Keeps the frame's memory: the engine drops the old swapchain on a re-plug.
        var surface: IOSurface?
        /// `texture` and `surface` are the renderer's own copy (`snapshot`),
        /// not a swapchain surface the daemon goes on writing old-size frames
        /// into until Android unplugs, the black ones of the switch included.
        var copied = false
        var expected: PixelSize
        var deadline: TimeInterval
        /// When `releaseHold` came, if it has.
        var released: TimeInterval?
        var generation: Int
    }
    private var hold: Hold?
    private var holdGeneration = 0
    /// After `releaseHold`, the hold waits this long for a frame of the expected size.
    private static let releaseGrace: TimeInterval = 1

    // Statistics (under `lock`).
    /// Arrival times of Android's frames over the last two seconds.
    private var arrivals: [TimeInterval] = []
    private var skippedFrames = 0
    /// `present` calls queued on the render queue: only the newest is drawn.
    private var pendingPresents = 0
    /// Android's frames come faster than the screen refreshes (FrameRateHint):
    /// the newest is drawn at each refresh (`refreshed`), not each as it
    /// comes, so they replace each other instead of queueing up behind the
    /// screen with their latency, and nothing draws faster than the screen
    /// shows. `frameWaiting`: one came since the last draw.
    private var newestPerRefresh = false
    private var frameWaiting = false
    private var lastRefresh: TimeInterval = 0
    /// Without a refresh for this long, frames are drawn as they come again.
    private static let refreshTimeout: TimeInterval = 0.05
    private var lastPath: ScalingPath?
    private var lastFallback: ScalerFallback?
    private var lastSharpened = false
    private var gpuMs: Double?

    // Drawing state (render queue only).
    private lazy var upscalers = SpatialUpscalerCache(device: device, queue: renderQueue)
    /// Bilinear output that RCAS sharpens, the size of the presentation rect.
    private var scratch: MTLTexture?
    /// Draws on the GPU not yet completed: at most two, so a slow GPU drops
    /// frames instead of queueing them up (and their latency).
    private let inFlight = DispatchSemaphore(value: 2)
    private var redrawPending = false
    private var lastTarget: PixelSize?
    private var targetChangedAt: TimeInterval = 0
    /// The redraw once the drawable size settles is scheduled (one for a whole resize).
    private var settledRedrawScheduled = false
    /// A scaler is built only for a drawable size that has held this long,
    /// so a resize animation never builds one per frame.
    private static let settleTime: TimeInterval = 0.15

    /// Calls back on the main actor once a frame is on screen: right away if
    /// one already is (frames can arrive before the window is ready for them).
    func whenFrameShown(_ callback: @escaping @MainActor () -> Void) {
        let shown = lock.withLock { () -> Bool in
            if current != nil { return true }
            onFirstFrame = callback
            return false
        }
        if shown { DispatchQueue.main.async { MainActor.assumeIsolated { callback() } } }
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        isMetalFXSupported = MTLFXSpatialScalerDescriptor.supportsDevice(device)
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        // Android draws sRGB (screenshots and recordings say so too): the
        // Mac converts to the display's color space, as it does for apps.
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.displaySyncEnabled = true
        layer.maximumDrawableCount = 3

        do {
            let library = try device.makeLibrary(source: MetalShaders.source, options: nil)
            func pipeline(_ fragment: String) throws -> MTLRenderPipelineState {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "avo_vertex")
                descriptor.fragmentFunction = library.makeFunction(name: fragment)
                // The drawable, the recorder's buffers and the scratch texture are all BGRA.
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                return try device.makeRenderPipelineState(descriptor: descriptor)
            }
            linearPipeline = try pipeline("avo_linear")
            nearestPipeline = try pipeline("avo_nearest")
            downsamplePipeline = try pipeline("avo_downsample")
            copyPipeline = try pipeline("avo_copy")
            rcasPipeline = try pipeline("avo_rcas")
            keyedPipeline = try pipeline("avo_keyed")
        } catch {
            return nil
        }
    }

    /// Wraps the engine's swapchain (IOSurfaces shared through the daemon).
    func setSurfaces(_ surfaces: [IOSurface]) {
        // Handed over to the render queue; nothing else holds them.
        nonisolated(unsafe) let wrapped: [(IOSurface, MTLTexture)] = surfaces.compactMap { surface in
            // The engine says which order the bytes are in ('RGBA' or 'BGRA').
            let format = (FramePixelFormat(surface.pixelFormat) ?? .bgra).metal
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: surface.width,
                                                                      height: surface.height, mipmapped: false)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            return device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0).map { (surface, $0) }
        }
        // On the render queue, after any frame of the old swapchain still
        // waiting there: a new swapchain numbers its frames from the start.
        // A recording goes on; `record` decides whether the new size fits it.
        renderQueue.async { [self] in
            lock.withLock {
                textures = wrapped.map(\.1)
                self.surfaces = wrapped.map(\.0)
                current = nil
                lastSequence = 0
                skippedFrames = 0
            }
            upscalers.clearFailures()
        }
    }

    /// False while nobody can see the window (minimized, covered, on another
    /// Space), when Android still draws only for a recording. Frames are then
    /// recorded but not drawn: Core Animation may hold back the drawables of
    /// a hidden layer, and waiting up to a second for each would hold up the
    /// recording. The last frame is drawn once the window shows again.
    /// Hiding frees the scalers and their textures (tens of megabytes in full screen).
    var isOnScreen: Bool {
        get { lock.withLock { onScreen } }
        set {
            let (appeared, hidden) = lock.withLock { () -> (Bool, Bool) in
                defer { onScreen = newValue }
                return (newValue && !onScreen, !newValue && onScreen)
            }
            if appeared { redraw() }
            if hidden {
                renderQueue.async { [self] in
                    upscalers.releaseAll()
                    scratch = nil
                }
            }
        }
    }

    func present(index: Int, sequence: UInt64) {
        let time = Self.now()
        let arrival = CACurrentMediaTime()
        lock.withLock { pendingPresents += 1 }
        renderQueue.async { [self] in
            let shown: (texture: MTLTexture, draw: Bool, record: Bool)? = lock.withLock {
                pendingPresents -= 1
                guard textures.indices.contains(index), sequence > lastSequence else { return nil }
                if lastSequence > 0 { skippedFrames += Int(clamping: sequence - lastSequence - 1) }
                current = index
                lastSequence = sequence
                noteArrival(arrival)
                let texture = textures[index]
                // While holding, frames count but are neither drawn nor recorded.
                guard holdEnds(with: texture, at: arrival) else { return (texture, false, false) }
                // At the screen's next refresh, unless the refreshes stopped coming.
                if newestPerRefresh, arrival - lastRefresh < Self.refreshTimeout {
                    frameWaiting = true
                    return (texture, false, true)
                }
                // A backlog (the render queue was busy): only its newest frame is drawn.
                let newest = pendingPresents == 0
                if !newest { skippedFrames += 1 }
                return (texture, onScreen && newest, true)
            }
            guard let shown else { return }
            if shown.draw { draw(shown.texture) }
            if shown.record { record(shown.texture, at: time) }
            let callback: (@MainActor () -> Void)? = lock.withLock {
                defer { onFirstFrame = nil }
                return onFirstFrame
            }
            if let callback { DispatchQueue.main.async { MainActor.assumeIsolated { callback() } } }
        }
    }

    /// Redraws the frame on screen (after a resize, before the guest catches
    /// up; a setting change; a scaler that became ready).
    func redraw() {
        renderQueue.async { [self] in
            let texture: MTLTexture? = lock.withLock { onScreen ? shownTexture : nil }
            if let texture { draw(texture) }
        }
    }

    /// Draws the newest frame once a refresh of the screen (`refreshed`)
    /// instead of each as it comes, while Android's frames come faster than
    /// the screen refreshes (FrameRateHint). Any thread.
    func setNewestPerRefresh(_ on: Bool) {
        let waiting = lock.withLock { () -> Bool in
            defer {
                newestPerRefresh = on
                frameWaiting = false
            }
            return frameWaiting
        }
        if waiting { redraw() }
    }

    /// A refresh of the window's screen (FrameRateHint's display link): the
    /// newest frame is drawn if one came since the last draw. Any thread.
    func refreshed() {
        let draw = lock.withLock { () -> Bool in
            lastRefresh = CACurrentMediaTime()
            defer { frameWaiting = false }
            return newestPerRefresh && frameWaiting
        }
        if draw { redraw() }
    }

    /// The held frame while holding, else the newest (under `lock`).
    private var shownTexture: MTLTexture? {
        if let hold { return hold.texture }
        return current.flatMap { textures.indices.contains($0) ? textures[$0] : nil }
    }

    // MARK: Scaling options, frame hold and statistics

    /// Sets the filter and sharpness. They apply on the next draw, with no
    /// re-plug, so the window redraws the frame on screen right away. Any thread.
    func setOptions(_ options: RenderOptions) {
        let changed = lock.withLock { () -> Bool in
            defer { self.options = options }
            return self.options != options
        }
        if changed { redraw() }
    }

    /// True during a live resize or a full-screen transition. Draws then take
    /// the bilinear path: a MetalFX scaler is built for one input and output
    /// size, and the output changes on every frame of a drag. Ending it
    /// redraws, so the settled size gets MetalFX without waiting for Android.
    func setInteractiveResize(_ active: Bool) {
        lock.withLock { interactiveResize = active }
        if !active { redraw() }
    }

    /// Builds the scaler for `destination` ahead of time (entering full
    /// screen), so the first frame after the animation is already upscaled
    /// instead of switching from bilinear a moment later.
    func prepareScaler(destination: PixelSize) {
        renderQueue.async { [self] in
            guard isMetalFXSupported else { return }
            let (texture, options) = lock.withLock { (shownTexture, self.options) }
            guard let texture else { return }
            let source = PixelSize(width: texture.width, height: texture.height)
            let rect = DisplaySizing.presentationRect(source: source, target: destination)
            guard case let .metalFX(output) = DisplaySizing.scalingPath(source: source, destination: rect.size,
                                                                       filter: options.filter, metalFXAvailable: true,
                                                                       interactive: false) else { return }
            upscalers.request(FXKey(input: source, output: output, format: texture.pixelFormat)) {}
        }
    }

    /// Keeps the frame on screen up while Android re-plugs its display at
    /// `size`: between the unplug and the app's return Android has nothing
    /// to show, and drawing that would flash black. `frameSize` reports the
    /// held frame meanwhile, so touches land where the picture is. The hold
    /// ends at the first frame of `size` after `releaseHold()`, or by itself
    /// after `timeout`. A new hold replaces the expected size and the timeout.
    func holdCurrentFrame(expecting size: PixelSize, timeout: Duration = .seconds(4)) {
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let generation = lock.withLock { () -> Int? in
            let now = CACurrentMediaTime()
            holdGeneration += 1
            if hold != nil {
                hold?.expected = size
                hold?.deadline = now + seconds
                hold?.released = nil
                hold?.generation = holdGeneration
            } else {
                // Nothing on screen yet: there is no frame to keep.
                guard let index = current, textures.indices.contains(index) else { return nil }
                hold = Hold(texture: textures[index], surface: surfaces.indices.contains(index) ? surfaces[index] : nil,
                            expected: size, deadline: now + seconds, released: nil, generation: holdGeneration)
            }
            return holdGeneration
        }
        guard let generation else { return }
        endHoldLater(generation, after: seconds)
        renderQueue.async { [self] in copyHeldFrame(generation) }
    }

    /// Replaces the held swapchain surface with a copy of it (render
    /// queue): the daemon rewrites each of its three surfaces every third
    /// frame until Android unplugs the display, and drawing the held frame
    /// meanwhile (a resize, a scaler that became ready) would show those
    /// frames half-written, or the black of the switch.
    private func copyHeldFrame(_ generation: Int) {
        guard let original = lock.withLock({ hold?.generation == generation && hold?.copied == false ? hold?.surface : nil })
        else { return }
        let copy = Self.copy(of: original).flatMap { surface -> (IOSurface, MTLTexture)? in
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: (FramePixelFormat(surface.pixelFormat) ?? .bgra).metal,
                                                                      width: surface.width, height: surface.height, mipmapped: false)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            return device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0).map { (surface, $0) }
        }
        guard let copy else { return }
        lock.withLock {
            guard hold?.surface === original else { return }
            hold?.surface = copy.0
            hold?.texture = copy.1
            hold?.copied = true
        }
    }

    /// A new IOSurface with `surface`'s pixels, laid out the same way.
    private static func copy(of surface: IOSurface) -> IOSurface? {
        let properties: [IOSurfacePropertyKey: any Sendable] = [
            .width: surface.width,
            .height: surface.height,
            .bytesPerElement: surface.bytesPerElement,
            .bytesPerRow: surface.bytesPerRow,
            .allocSize: surface.allocationSize,
            .pixelFormat: surface.pixelFormat,
        ]
        guard let copy = IOSurface(properties: properties), copy.allocationSize >= surface.bytesPerRow * surface.height else { return nil }
        surface.lock(options: .readOnly, seed: nil)
        copy.lock(options: [], seed: nil)
        memcpy(copy.baseAddress, surface.baseAddress, surface.bytesPerRow * surface.height)
        copy.unlock(options: [], seed: nil)
        surface.unlock(options: .readOnly, seed: nil)
        return copy
    }

    /// Android has the new size and the app is back: the next frame of the
    /// expected size ends the hold, or the newest frame does after a second.
    /// Also called when the resize failed, so a hold never outlives its re-plug.
    func releaseHold() {
        let generation = lock.withLock { () -> Int? in
            guard hold != nil, hold?.released == nil else { return nil }
            hold?.released = CACurrentMediaTime()
            return hold?.generation
        }
        if let generation { endHoldLater(generation, after: Self.releaseGrace) }
    }

    /// Ends hold `generation` once it is due, and draws the newest frame.
    private func endHoldLater(_ generation: Int, after seconds: TimeInterval) {
        renderQueue.asyncAfter(deadline: .now() + seconds + 0.005) { [self] in
            let ended = lock.withLock { () -> Bool in
                guard let hold, hold.generation == generation, Self.holdIsDue(hold, at: CACurrentMediaTime()) else { return false }
                self.hold = nil
                return true
            }
            if ended { redraw() }
        }
    }

    /// Whether a new frame ends the hold (under `lock`): true when nothing is held.
    private func holdEnds(with texture: MTLTexture, at time: TimeInterval) -> Bool {
        guard let hold else { return true }
        let arrived = hold.released != nil && texture.width == hold.expected.width && texture.height == hold.expected.height
        guard arrived || Self.holdIsDue(hold, at: time) else { return false }
        self.hold = nil
        return true
    }

    private static func holdIsDue(_ hold: Hold, at time: TimeInterval) -> Bool {
        time >= hold.deadline || hold.released.map { time >= $0 + releaseGrace } == true
    }

    /// Records a frame's arrival for the FPS and frame-time figures (under `lock`).
    private func noteArrival(_ time: TimeInterval) {
        arrivals.append(time)
        if let stale = arrivals.firstIndex(where: { $0 > time - 2 }), stale > 0 { arrivals.removeFirst(stale) }
    }

    /// What the renderer is doing now, for the performance HUD. Any thread.
    func statistics() -> RenderStatistics {
        let drawable = PixelSize(layer.drawableSize)
        let now = CACurrentMediaTime()
        return lock.withLock {
            let recent = arrivals.filter { $0 > now - 2 }
            let lastSecond = recent.filter { $0 > now - 1 }
            let intervals = zip(recent.dropFirst(), recent).map { ($0 - $1) * 1000 }
            let source = shownTexture.map { PixelSize(width: $0.width, height: $0.height) }
            return RenderStatistics(
                framesPerSecond: Double(lastSecond.count),
                averageFrameMs: intervals.isEmpty ? 0 : intervals.reduce(0, +) / Double(intervals.count),
                maxFrameMs: intervals.max() ?? 0,
                skippedFrames: skippedFrames,
                source: source,
                destination: drawable.width > 0 && drawable.height > 0 ? drawable : nil,
                path: lastPath,
                fallback: lastFallback,
                sharpened: lastSharpened,
                scalingMs: gpuMs,
                idle: lastSecond.isEmpty,
                waitingForAndroid: hold != nil)
        }
    }

    // MARK: Screenshots and recording

    /// Host time now, the clock recordings are timed with.
    private static func now() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    /// Size in pixels of the frame on screen, the held one while holding
    /// (nil before the first frame).
    var frameSize: CGSize? {
        lock.withLock { shownTexture.map { CGSize(width: $0.width, height: $0.height) } }
    }

    /// A copy of the frame on screen. Made on the render queue between two
    /// frames: the engine writes into a shown surface again only three frames later.
    func captureFrame() async -> CGImage? {
        await withCheckedContinuation { continuation in
            renderQueue.async { [self] in
                let surface = lock.withLock { () -> IOSurface? in
                    if let hold { return hold.surface }
                    return current.flatMap { surfaces.indices.contains($0) ? surfaces[$0] : nil }
                }
                continuation.resume(returning: surface?.makeImage())
            }
        }
    }

    /// Runs `body` on the render queue with the frame on screen (the held
    /// one while holding) and its sequence number, between two frames as
    /// `captureFrame` does, without copying it: a cheap look at part of the
    /// picture (the mouse wheel's scroll watch, WheelScrolling.swift).
    func withShownFrame<T: Sendable>(_ body: @escaping @Sendable (IOSurface?, UInt64) -> T) async -> T {
        await withCheckedContinuation { continuation in
            renderQueue.async { [self] in
                let (surface, sequence) = lock.withLock { () -> (IOSurface?, UInt64) in
                    if let hold { return (hold.surface, lastSequence) }
                    return (current.flatMap { surfaces.indices.contains($0) ? surfaces[$0] : nil }, lastSequence)
                }
                continuation.resume(returning: body(surface, sequence))
            }
        }
    }

    /// Records every frame shown from now on, starting with the one on screen.
    func startRecording(_ recorder: ScreenRecorder) {
        let time = Self.now()
        renderQueue.async { [self] in
            self.recorder?.finish(.stopped, at: time)
            self.recorder = recorder
            let texture: MTLTexture? = lock.withLock { shownTexture }
            if let texture { record(texture, at: time) }
        }
    }

    /// Ends the recording in progress, if any; its file is finished in the background.
    func stopRecording() {
        let time = Self.now()
        renderQueue.async { [self] in
            recorder?.finish(.stopped, at: time)
            recorder = nil
        }
    }

    /// Draws `texture` once more, into the recorder's next buffer (render
    /// queue), at Android's own resolution: never the upscaled picture.
    private func record(_ texture: MTLTexture, at time: CMTime) {
        guard let recorder else { return }
        // A re-plug or resize of the same orientation keeps the movie going, fitted into it.
        guard var rect = recorder.drawRect(forFrameWidth: texture.width, height: texture.height) else {
            // The display turned: the movie ends with the last frame of the old orientation.
            self.recorder = nil
            recorder.finish(.resized, at: time)
            return
        }
        // No buffer: the encoder is behind, and a variable frame rate can skip this one.
        guard let target = recorder.makeTarget() else { return }
        let covers = rect.x <= -1 && rect.y >= 1 && rect.x + rect.z >= 1 && rect.y - rect.w <= -1
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target.texture
        // A frame that covers every pixel needs no clear; a fitted one gets black bars.
        pass.colorAttachments[0].loadAction = covers ? .dontCare : .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
            recorder.drop(target)
            return
        }
        encoder.setRenderPipelineState(linearPipeline)
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        buffer.addCompletedHandler { buffer in
            if buffer.status == .completed { recorder.append(target, at: time) } else { recorder.drop(target) }
        }
        buffer.commit()
    }

    // MARK: Drawing

    /// Draws `texture` into the next drawable (render queue).
    private func draw(_ texture: MTLTexture) {
        // Two draws on the GPU already: this one is dropped, and the newest
        // frame is drawn once one completes.
        guard inFlight.wait(timeout: .now()) == .success else {
            redrawPending = true
            return
        }
        guard let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        let source = PixelSize(width: texture.width, height: texture.height)
        let target = PixelSize(width: drawable.texture.width, height: drawable.texture.height)
        let now = CACurrentMediaTime()
        if target != lastTarget {
            lastTarget = target
            targetChangedAt = now
            upscalers.clearMemoryPressure()
            scheduleSettledRedraw()
        }
        let (options, resizing) = lock.withLock { (self.options, interactiveResize) }
        let settling = now - targetChangedAt < Self.settleTime
        let rect = DisplaySizing.presentationRect(source: source, target: target)
        var path = DisplaySizing.scalingPath(source: source, destination: rect.size, filter: options.filter,
                                             metalFXAvailable: isMetalFXSupported && !upscalers.underMemoryPressure,
                                             interactive: resizing)
        var fallback: ScalerFallback?
        var scaler: SpatialUpscalerCache.Entry?
        if case let .metalFX(output) = path {
            let key = FXKey(input: source, output: output, format: texture.pixelFormat)
            if let entry = upscalers.entry(for: key) {
                scaler = entry
            } else {
                if upscalers.hasFailed(key) {
                    fallback = .failed
                } else if settling {
                    // The drawable is still changing size (an animation): no scaler for a passing size.
                    fallback = .resizing
                } else {
                    fallback = .preparing
                    upscalers.request(key) { [weak self] in self?.redraw() }
                }
                path = .bilinear
            }
        } else if options.filter == .metalFXSpatial, path == .bilinear,
                  case .metalFX = DisplaySizing.scalingPath(source: source, destination: rect.size, filter: .metalFXSpatial,
                                                            metalFXAvailable: true, interactive: false) {
            // MetalFX would apply but cannot now: say why.
            fallback = !isMetalFXSupported ? .unavailable : upscalers.underMemoryPressure ? .memoryPressure : .resizing
        }
        if scaler == nil, fallback == nil { upscalers.noteNoneInUse() }
        let sharpen: Bool = {
            // A scaler on its way or a resize: soft for a moment. A lasting
            // fallback (no MetalFX, a size it refused) is sharpened like bilinear.
            guard options.sharpness > 0, !resizing, !settling,
                  fallback == nil || fallback == .unavailable || fallback == .failed else { return false }
            switch path {
            case .native, .bilinear: return true
            case let .metalFX(output): return output == rect.size
            case .nearest, .downsample: return false
            }
        }()

        // `.native` covers the whole drawable only for the few-pixel gap of a
        // 1:1 frame; a frame aspect-fitted at exactly ×1 (a drag that widened
        // the window) keeps black bars, not edge pixels smeared across them.
        let nativeViewport = target.width - rect.width <= DisplaySizing.widthAlignment && target.height - rect.height <= 2
            ? PixelRect(x: 0, y: 0, width: target.width, height: target.height) : rect
        let origin = SIMD4<Float>(Float(rect.x), Float(rect.y), 0, 0)
        let con = exp2(-2 * (1 - Float(min(options.sharpness, 100)) / 100))
        let sharpening = SIMD4<Float>(Float(rect.x), Float(rect.y), con, 0)
        let encoded: Bool
        switch path {
        case _ where keysOutBlack:
            encoded = pass(buffer, into: drawable.texture, viewport: rect, pipeline: keyedPipeline, texture: texture)
        case let .metalFX(output):
            guard let scaler, let blit = buffer.makeBlitCommandEncoder() else { encoded = false; break }
            // A private copy first: the scaler then reads memory the engine never rewrites.
            blit.copy(from: texture, to: scaler.input)
            blit.endEncoding()
            scaler.scaler.colorTexture = scaler.input
            scaler.scaler.outputTexture = scaler.output
            scaler.scaler.inputContentWidth = source.width
            scaler.scaler.inputContentHeight = source.height
            scaler.scaler.encode(commandBuffer: buffer)
            if output == rect.size {
                encoded = pass(buffer, into: drawable.texture, viewport: rect, pipeline: sharpen ? rcasPipeline : copyPipeline,
                               texture: scaler.output, params: sharpen ? sharpening : origin)
            } else {
                // Beyond MetalFX's ×4: bilinear does the rest.
                encoded = pass(buffer, into: drawable.texture, viewport: rect, pipeline: linearPipeline, texture: scaler.output)
            }
        case .bilinear where sharpen:
            guard let scratch = scratchTexture(rect.size),
                  pass(buffer, into: scratch, clear: false, viewport: PixelRect(x: 0, y: 0, width: rect.width, height: rect.height),
                       pipeline: linearPipeline, texture: texture)
            else { encoded = false; break }
            encoded = pass(buffer, into: drawable.texture, viewport: rect, pipeline: rcasPipeline, texture: scratch, params: sharpening)
        case .bilinear:
            encoded = pass(buffer, into: drawable.texture, viewport: rect, pipeline: linearPipeline, texture: texture)
        case .native:
            // The copy repeats the edge pixels into a gap of a few pixels.
            encoded = pass(buffer, into: drawable.texture, viewport: nativeViewport, pipeline: sharpen ? rcasPipeline : copyPipeline,
                           texture: texture, params: sharpen ? sharpening : origin)
        case .nearest:
            encoded = pass(buffer, into: drawable.texture, viewport: rect, pipeline: nearestPipeline, texture: texture)
        case let .downsample(taps):
            let footprint = SIMD4<Float>(1 / Float(max(rect.width, 1)), 1 / Float(max(rect.height, 1)), Float(taps), 0)
            encoded = pass(buffer, into: drawable.texture, viewport: rect, pipeline: downsamplePipeline, texture: texture,
                           params: footprint)
        }
        guard encoded else {
            inFlight.signal()
            return
        }
        lock.withLock {
            lastPath = path
            lastFallback = fallback
            lastSharpened = sharpen
        }
        buffer.present(drawable)
        buffer.addCompletedHandler { [self] buffer in
            let milliseconds = buffer.gpuEndTime > buffer.gpuStartTime ? (buffer.gpuEndTime - buffer.gpuStartTime) * 1000 : nil
            renderQueue.async { [self] in
                if let milliseconds {
                    lock.withLock { gpuMs = gpuMs.map { $0 * 0.9 + milliseconds * 0.1 } ?? milliseconds }
                }
                inFlight.signal()
                if redrawPending {
                    redrawPending = false
                    redraw()
                }
            }
        }
        buffer.commit()
    }

    /// Draws once more after the drawable size settled, so a static frame
    /// still gets MetalFX and sharpening. One pending redraw follows a whole
    /// resize, however many sizes it passes through (render queue).
    private func scheduleSettledRedraw() {
        guard !settledRedrawScheduled else { return }
        settledRedrawScheduled = true
        let wait = max(targetChangedAt + Self.settleTime - CACurrentMediaTime(), 0) + 0.01
        renderQueue.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            settledRedrawScheduled = false
            if CACurrentMediaTime() - targetChangedAt < Self.settleTime {
                scheduleSettledRedraw()
            } else {
                redraw()
            }
        }
    }

    /// Encodes one full-viewport quad sampling `texture` into `target`.
    private func pass(_ buffer: MTLCommandBuffer, into target: MTLTexture, clear: Bool = true, viewport: PixelRect,
                      pipeline: MTLRenderPipelineState, texture: MTLTexture, params: SIMD4<Float> = .zero) -> Bool {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = clear ? .clear : .dontCare
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: keysOutBlack ? 0 : 1)
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return false }
        var quad = SIMD4<Float>(-1, 1, 2, 2)
        var params = params
        encoder.setRenderPipelineState(pipeline)
        encoder.setViewport(MTLViewport(originX: Double(viewport.x), originY: Double(viewport.y),
                                        width: Double(viewport.width), height: Double(viewport.height), znear: 0, zfar: 1))
        encoder.setVertexBytes(&quad, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        return true
    }

    /// The scratch texture at `size`, made again when the size changes (render queue).
    private func scratchTexture(_ size: PixelSize) -> MTLTexture? {
        if let scratch, scratch.width == size.width, scratch.height == size.height { return scratch }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size.width,
                                                                  height: size.height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        scratch = device.makeTexture(descriptor: descriptor)
        return scratch
    }
}
