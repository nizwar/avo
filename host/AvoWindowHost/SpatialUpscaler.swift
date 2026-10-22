import AvoKit
import Foundation
import Metal
import MetalFX
import os

/// One MetalFX spatial scaler's sizes. A scaler is built for exactly one
/// input size, output size and pixel format.
struct FXKey: Hashable, Sendable {
    let input: PixelSize
    let output: PixelSize
    let format: MTLPixelFormat
}

/// The MetalFX spatial scalers of one window, with their textures.
///
/// Building a scaler takes milliseconds to tens of milliseconds, so it never
/// happens on the render queue: `request` builds on a queue of its own and
/// the renderer draws bilinearly until the entry is there. Only the newest
/// requested key waits, so a resize that passes through many sizes builds at
/// most one stale scaler.
///
/// Everything except the build runs on the render queue given to `init`.
final class SpatialUpscalerCache: @unchecked Sendable {
    struct Entry {
        let scaler: any MTLFXSpatialScaler
        /// Private copy of Android's frame: the scaler never reads the shared
        /// IOSurface, which the engine starts rewriting three frames later.
        let input: MTLTexture
        let output: MTLTexture
    }

    private let device: MTLDevice
    private let queue: DispatchQueue
    private let fxQueue = DispatchQueue(label: "com.avodroid.render.metalfx", qos: .userInitiated)
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Rendering")
    private var entries: [FXKey: Entry] = [:]
    private var lastUsed: [FXKey: TimeInterval] = [:]
    /// The entry the last draw used: never evicted. Nil once a draw needs no scaler.
    private var currentKey: FXKey?
    /// Keys MetalFX refused, until the swapchain changes (`clearFailures`).
    private var failed: Set<FXKey> = []
    private var building: FXKey?
    /// The `generation` `building` started in: a build from before `releaseAll` is dropped.
    private var buildingGeneration = 0
    /// Called once `building` is in (render queue only).
    private var buildingCompletion: (() -> Void)?
    private var pending: (key: FXKey, completion: () -> Void)?
    /// Bumped by `releaseAll`, so a build that finishes afterwards is dropped.
    private var generation = 0
    private var sweepScheduled = false
    private var pressureSource: DispatchSourceMemoryPressure?
    /// The system reported critical memory pressure: no scaler is built
    /// until the renderer's destination changes (`clearMemoryPressure`).
    private(set) var underMemoryPressure = false

    /// An entry unused for this long is freed, unless it is the current one.
    private static let inactiveLifetime: TimeInterval = 5
    /// The current entry plus one previous (going back and forth between two sizes).
    private static let maximumEntries = 2

    init(device: MTLDevice, queue: DispatchQueue) {
        self.device = device
        self.queue = queue
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let event = source?.data else { return }
            if event.contains(.critical) {
                releaseAll()
                underMemoryPressure = true
            } else if event.contains(.warning) {
                releaseInactive()
            }
        }
        source.activate()
        pressureSource = source
    }

    deinit { pressureSource?.cancel() }

    /// The built entry for `key`, marking it as the one in use.
    func entry(for key: FXKey) -> Entry? {
        guard let entry = entries[key] else { return nil }
        lastUsed[key] = Self.now()
        currentKey = key
        return entry
    }

    func hasFailed(_ key: FXKey) -> Bool { failed.contains(key) }

    /// The last draw took another path (1:1, another filter): the entry it
    /// used goes after `inactiveLifetime` too, instead of holding its
    /// textures (tens of megabytes in full screen) for as long as the window is open.
    func noteNoneInUse() {
        guard currentKey != nil else { return }
        currentKey = nil
        scheduleSweep()
    }

    /// Builds the entry for `key` in the background and calls `completion` on
    /// the render queue once it is there. A newer request replaces one still
    /// waiting; one already building finishes. Also the full-screen pre-warm:
    /// the renderer decides when a size is settled enough to ask for.
    func request(_ key: FXKey, completion: @escaping () -> Void) {
        guard entries[key] == nil, !failed.contains(key), !underMemoryPressure else { return }
        if building == key, buildingGeneration == generation {
            // Already building (a pre-warm): the newest caller hears when it is in.
            buildingCompletion = completion
            return
        }
        pending = (key, completion)
        startNext()
    }

    /// The swapchain changed: sizes MetalFX refused may work for the new one.
    func clearFailures() { failed.removeAll() }

    /// The destination changed after critical memory pressure: scalers may be built again.
    func clearMemoryPressure() { underMemoryPressure = false }

    /// Frees every scaler and texture (the window is hidden, or memory is critical).
    func releaseAll() {
        entries.removeAll()
        lastUsed.removeAll()
        currentKey = nil
        pending = nil
        generation += 1
    }

    /// Frees every entry but the one in use.
    func releaseInactive() {
        for key in entries.keys where key != currentKey {
            entries[key] = nil
            lastUsed[key] = nil
        }
    }

    // MARK: Building

    private func startNext() {
        guard building == nil, let next = pending else { return }
        pending = nil
        building = next.key
        buildingGeneration = generation
        buildingCompletion = next.completion
        let key = next.key
        let generation = generation
        fxQueue.async { [self] in
            // Handed over to the render queue; nothing else holds it.
            nonisolated(unsafe) let built = build(key)
            queue.async { [self] in
                let completion = buildingCompletion
                building = nil
                buildingCompletion = nil
                if self.generation == generation {
                    if let built {
                        insert(built, for: key)
                    } else {
                        failed.insert(key)
                    }
                    completion?()
                }
                startNext()
            }
        }
    }

    /// On `fxQueue`.
    private func build(_ key: FXKey) -> Entry? {
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = key.input.width
        descriptor.inputHeight = key.input.height
        descriptor.outputWidth = key.output.width
        descriptor.outputHeight = key.output.height
        // The IOSurface's own byte order in and out: no conversion pass.
        descriptor.colorTextureFormat = key.format
        descriptor.outputTextureFormat = key.format
        // Android's frames are gamma-encoded sRGB.
        descriptor.colorProcessingMode = .perceptual
        guard let scaler = descriptor.makeSpatialScaler(device: device) else {
            logger.error("""
                MetalFX cannot scale \(key.input.width)×\(key.input.height) to \
                \(key.output.width)×\(key.output.height) (format \(key.format.rawValue))
                """)
            return nil
        }
        func texture(_ size: PixelSize, usage: MTLTextureUsage) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: key.format, width: size.width,
                                                                      height: size.height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = usage
            return device.makeTexture(descriptor: descriptor)
        }
        // The final pass reads the output, so both get `.shaderRead` on top of what MetalFX asks for.
        guard let input = texture(key.input, usage: scaler.colorTextureUsage.union(.shaderRead)),
              let output = texture(key.output, usage: scaler.outputTextureUsage.union(.shaderRead))
        else {
            logger.error("cannot allocate MetalFX textures for \(key.output.width)×\(key.output.height)")
            return nil
        }
        return Entry(scaler: scaler, input: input, output: output)
    }

    private func insert(_ entry: Entry, for key: FXKey) {
        entries[key] = entry
        lastUsed[key] = Self.now()
        // Over the limit: the least recently used entries go, never the current one.
        while entries.count > Self.maximumEntries,
              let oldest = lastUsed.filter({ $0.key != currentKey && $0.key != key }).min(by: { $0.value < $1.value })?.key {
            entries[oldest] = nil
            lastUsed[oldest] = nil
        }
        scheduleSweep()
    }

    /// Frees entries other than the current one after `inactiveLifetime`
    /// without use, even when no frame is drawn meanwhile.
    private func scheduleSweep() {
        guard !sweepScheduled, entries.keys.contains(where: { $0 != currentKey }) else { return }
        sweepScheduled = true
        queue.asyncAfter(deadline: .now() + Self.inactiveLifetime) { [weak self] in
            guard let self else { return }
            sweepScheduled = false
            let cutoff = Self.now() - Self.inactiveLifetime
            for (key, used) in lastUsed where key != currentKey && used <= cutoff {
                entries[key] = nil
                lastUsed[key] = nil
            }
            scheduleSweep()
        }
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}
