import AvoKit
import Foundation
import IOSurface
import os
import Synchronization

/// What the daemon forwards to the App Shim that owns a display.
public enum FrameDelivery: @unchecked Sendable {
    /// New swapchain (first frame or a new size).
    case surfaces(displayID: UInt32, [IOSurface])
    case present(displayID: UInt32, surfaceIndex: Int, sequence: UInt64)
    /// The display's first frame: its window can show.
    case firstFrame(displayID: UInt32)
    /// Android started recording from the microphone.
    case microphone
    /// Where the engine keeps what Android plays (`audio playback …`), for App Shims' recordings.
    case audioTap(AudioTapLocation)
}

/// Deliveries in order for one consumer (VMMEngine.frames). Only a present
/// is ever dropped, for a newer one of its display while it still waits:
/// a busy consumer skips frames but never loses a swapchain, without which
/// the window would keep drawing the old one.
final class FrameDeliveryQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [FrameDelivery] = []
    private var waiting: CheckedContinuation<FrameDelivery?, Never>?
    private var finished = false

    func push(_ delivery: FrameDelivery) {
        lock.withLock {
            guard !finished else { return }
            if let waiting {
                self.waiting = nil
                waiting.resume(returning: delivery)
                return
            }
            if case let .present(display, _, _) = delivery,
               let last = queued.lastIndex(where: { Self.display(of: $0) == display }), case .present = queued[last] {
                queued[last] = delivery
            } else {
                queued.append(delivery)
            }
        }
    }

    /// The next delivery, waiting for one; nil once finished.
    func next() async -> FrameDelivery? {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if !queued.isEmpty {
                    continuation.resume(returning: queued.removeFirst())
                } else if finished {
                    continuation.resume(returning: nil)
                } else {
                    waiting = continuation
                }
            }
        }
    }

    /// The consumer went away (its task was cancelled).
    func finish() {
        lock.withLock {
            finished = true
            queued = []
            waiting?.resume(returning: nil)
            waiting = nil
        }
    }

    private static func display(of delivery: FrameDelivery) -> UInt32? {
        switch delivery {
        case let .surfaces(id, _), let .present(id, _, _), let .firstFrame(id): id
        default: nil
        }
    }
}

/// Turns avo-vmm's shared-memory frames (engine/hvf/vmm/src/frames.rs) into
/// IOSurface swapchains: each new frame is copied into the next of three
/// surfaces, which the App Shim draws with Metal. A display whose window
/// nobody sees (minimized, covered, on another Space, and not recorded) gets
/// no copies: at 1080×2400 and 120 Hz they are over 1 GB/s. When it shows
/// again, the newest frame is copied at once.
final class FrameBridge: @unchecked Sendable {
    private struct Layout {
        let generation: UInt32
        let map: UnsafeMutableRawPointer
        let length: Int
        let width: Int
        let height: Int
        let stride: Int
        let bufferOffset: Int
        let bufferSize: Int
        var surfaces: [IOSurface] = []
        var next = 0
        var announced = false
    }

    private let lock = NSLock()
    private var layouts: [Int: Layout] = [:]
    /// Host display id shown on each scanout.
    private var owners: [Int: UInt32] = [:]
    private var started: Set<UInt32> = []
    /// Displays whose window nobody sees (`setVisible`).
    private var hidden: Set<UInt32> = []
    private let deliver: @Sendable (FrameDelivery) -> Void
    /// The engine's shared memory, removed when it exits (VMMEngine).
    private let sharedMemory: SharedMemoryNames?
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Frames")

    init(sharedMemory: SharedMemoryNames? = nil, deliver: @escaping @Sendable (FrameDelivery) -> Void) {
        self.sharedMemory = sharedMemory
        self.deliver = deliver
    }

    deinit {
        for layout in layouts.values { munmap(layout.map, layout.length) }
    }

    /// Routes `scanout` to a host display (nil when its window closed).
    func assign(scanout: Int, to displayID: UInt32?) {
        lock.withLock {
            if let old = owners[scanout], old != displayID { hidden.remove(old) }
            owners[scanout] = displayID
            if var layout = layouts[scanout] {
                layout.announced = false
                layouts[scanout] = layout
            }
            if let displayID { started.remove(displayID) }
        }
    }

    /// The window of `displayID` became visible or hidden. A hidden one gets
    /// no frames (once it had its first); shown again, it gets the newest.
    func setVisible(_ displayID: UInt32, visible: Bool) {
        let shown = lock.withLock { () -> (scanout: Int, sequence: UInt64)? in
            guard visible else {
                hidden.insert(displayID)
                return nil
            }
            guard hidden.remove(displayID) != nil,
                  let scanout = owners.first(where: { $0.value == displayID })?.key, let layout = layouts[scanout] else { return nil }
            return (scanout, Self.published(layout.map))
        }
        if let shown, shown.sequence > 0 { frame(scanout: shown.scanout, sequence: shown.sequence) }
    }

    /// One event line from the engine:
    /// `frames <scanout> <generation> <width> <height> <stride> <format> <location…>`,
    /// `frame <scanout> <sequence>`, `frames-off <scanout>`, `microphone`
    /// or `audio playback <epoch> <location…>`. A location is `shm:<name>`
    /// (SharedMemory), or a path from an older engine.
    func handle(_ line: String) {
        let words = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: false).map(String.init)
        switch words.first {
        case "frames" where words.count == 8:
            guard let scanout = Int(words[1]), let generation = UInt32(words[2]) else { return }
            sharedMemory?.note(words[7])
            mapLayout(scanout: scanout, generation: generation, path: words[7])
        case "frame" where words.count >= 3:
            guard let scanout = Int(words[1]), let sequence = UInt64(words[2]) else { return }
            frame(scanout: scanout, sequence: sequence)
        case "microphone":
            deliver(.microphone)
        case "audio":
            if let location = AudioTapLocation(event: line) {
                sharedMemory?.note(location.path)
                deliver(.audioTap(location))
            }
        case "frames-off" where words.count >= 2:
            // Unplugged: let go of its memory and surfaces now, not when the scanout is reused.
            guard let scanout = Int(words[1]) else { return }
            let old = lock.withLock { layouts.removeValue(forKey: scanout) }
            if let old { munmap(old.map, old.length) }
        default:
            break
        }
    }

    private func mapLayout(scanout: Int, generation: UInt32, path: String) {
        let fd = SharedMemory.openForReading(path)
        guard fd >= 0 else {
            logger.error("cannot open \(path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
            return
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 4096 else { return }
        let length = Int(info.st_size)
        guard let map = mmap(nil, length, PROT_READ, MAP_SHARED, fd, 0), map != MAP_FAILED else { return }
        let header = map.assumingMemoryBound(to: UInt8.self)
        guard header[0] == 0x41, header[1] == 0x56, header[2] == 0x4f, header[3] == 0x46 else { // "AVOF"
            munmap(map, length)
            return
        }
        let field = { (offset: Int) -> Int in Int(map.load(fromByteOffset: offset, as: UInt32.self).littleEndian) }
        let layout = Layout(generation: generation, map: map, length: length, width: field(12), height: field(16),
                            stride: field(20), bufferOffset: field(32), bufferSize: field(36))
        let width = layout.width
        let height = layout.height
        // Header format 0 is BGRA, 1 RGBA: the surfaces keep the bytes as they are.
        let rgba = field(24) == 1
        let surfaces = (0..<3).compactMap { _ in Self.makeSurface(width: width, height: height, rgba: rgba) }
        guard surfaces.count == 3 else {
            munmap(map, length)
            return
        }
        var withSurfaces = layout
        withSurfaces.surfaces = surfaces
        let old = lock.withLock { () -> Layout? in
            defer { layouts[scanout] = withSurfaces }
            return layouts[scanout]
        }
        if let old { munmap(old.map, old.length) }
    }

    private static func makeSurface(width: Int, height: Int, rgba: Bool) -> IOSurface? {
        let bytesPerRow = (width * 4 + 63) / 64 * 64
        let properties: [IOSurfacePropertyKey: any Sendable] = [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .bytesPerRow: bytesPerRow,
            .allocSize: bytesPerRow * height,
            .pixelFormat: rgba ? 0x5247_4241 : 0x4247_5241, // 'RGBA' or 'BGRA'
        ]
        return IOSurface(properties: properties)
    }

    /// How many frames the engine published so far on each scanout, whether
    /// or not anyone sees them (System Status' frame rates).
    func publishedFrames() -> [Int: UInt64] {
        lock.withLock { layouts.mapValues { Self.published($0.map) } }
    }

    /// The sequence of the newest published frame (header offset 48; 0: none yet).
    private static func published(_ map: UnsafeMutableRawPointer) -> UInt64 {
        let value = UInt64(littleEndian: map.load(fromByteOffset: 48, as: UInt64.self))
        atomicMemoryFence(ordering: .acquiring)
        return value
    }

    private func frame(scanout: Int, sequence: UInt64) {
        // Copy under the lock: a new layout may unmap the old one.
        let result: (UInt32, [IOSurface]?, Int, Bool)? = lock.withLock {
            guard var layout = layouts[scanout], let displayID = owners[scanout] else { return nil }
            // Nobody sees it: its first frame still goes (the window shows on it).
            if hidden.contains(displayID), started.contains(displayID) { return nil }
            // Behind newer frames (the event pump fell behind): their events
            // follow, and the newest one is copied then.
            let published = Self.published(layout.map)
            guard published <= sequence else { return nil }
            let latest = Int(layout.map.load(fromByteOffset: 40, as: UInt32.self).littleEndian)
            guard latest < 3 else { return nil }
            let surface = layout.surfaces[layout.next]
            let source = layout.map.advanced(by: layout.bufferOffset + latest * layout.bufferSize)
            surface.lock(options: [], seed: nil)
            let target = surface.baseAddress
            let targetStride = surface.bytesPerRow
            let row = layout.width * 4
            for y in 0..<layout.height {
                target.advanced(by: y * targetStride).copyMemory(from: source.advanced(by: y * layout.stride), byteCount: row)
            }
            surface.unlock(options: [], seed: nil)
            // The engine writes a buffer again two frames after it was the
            // newest: past that, this copy may be torn. The surface is filled
            // again with the next frame, whose event follows.
            atomicMemoryFence(ordering: .acquiring)
            guard Self.published(layout.map) <= published + 1 else { return nil }
            let index = layout.next
            layout.next = (layout.next + 1) % layout.surfaces.count
            let announce = !layout.announced
            layout.announced = true
            layouts[scanout] = layout
            let first = !started.contains(displayID)
            started.insert(displayID)
            return (displayID, announce ? layout.surfaces : nil, index, first)
        }
        guard let (displayID, surfaces, index, first) = result else { return }
        if let surfaces { deliver(.surfaces(displayID: displayID, surfaces)) }
        deliver(.present(displayID: displayID, surfaceIndex: index, sequence: sequence))
        if first { deliver(.firstFrame(displayID: displayID)) }
    }
}
