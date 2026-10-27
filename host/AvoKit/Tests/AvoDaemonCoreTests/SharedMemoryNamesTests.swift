import AvoKit
import Foundation
import Testing
@testable import AvoDaemonCore

/// The engine's frames and sound in shared memory (engine/hvf/vmm/src/shm.rs):
/// named in its events, opened by name, removed when the engine exits.
@Suite struct SharedMemoryNamesTests {
    @Test func aLocationIsSharedMemoryOrAPath() {
        #expect(SharedMemory.name(of: "shm:/avo.123.0.4") == "/avo.123.0.4")
        #expect(SharedMemory.name(of: "/Users/me/Library/Application Support/Avo/vm/frames/scanout-0-1.frames") == nil)
        #expect(SharedMemory.name(of: "shm:") == nil)
        #expect(SharedMemory.name(of: "shm:avo.no.slash") == nil)
    }

    @Test func aMissingNameDoesNotOpenAndAPathStillDoes() throws {
        errno = 0
        #expect(SharedMemory.openForReading("shm:/avo.0.missing") == -1)
        #expect(errno == ENOENT)
        #expect(SharedMemory.openForReading("shm:no-slash") == -1)
        let file = FileManager.default.temporaryDirectory.appending(path: "avo-shm-\(UUID().uuidString)")
        try Data("AVOF".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let fd = SharedMemory.openForReading(file.path)
        #expect(fd >= 0)
        if fd >= 0 { close(fd) }
    }

    @Test func theBridgeNotesWhatTheEngineSharesAndTheExitRemovesIt() {
        let names = SharedMemoryNames()
        let bridge = FrameBridge(sharedMemory: names) { _ in }
        bridge.handle("frames 0 3 1080 2400 4320 0 shm:/avo.4242.0.3")
        bridge.handle("audio playback 42 shm:/avo.4242.audio")
        // Paths from an older engine are files, not shared memory.
        bridge.handle("frames 1 4 1 1 4 0 /tmp/avo test/scanout-1-4.frames")
        bridge.handle("frame 0 1")
        #expect(names.noted == ["/avo.4242.0.3", "/avo.4242.audio"])
        names.removeAll()
        #expect(names.noted.isEmpty)
    }

    @Test func theRingStillReachesTheShimsFromSharedMemory() {
        let taps = Taps()
        let bridge = FrameBridge(sharedMemory: SharedMemoryNames()) { if case .audioTap(let location) = $0 { taps.add(location) } }
        bridge.handle("audio playback 7 shm:/avo.99.audio")
        #expect(taps.all == [AudioTapLocation(path: "shm:/avo.99.audio", epoch: 7)])
    }

    private final class Taps: @unchecked Sendable {
        private let lock = NSLock()
        private var taps: [AudioTapLocation] = []
        func add(_ tap: AudioTapLocation) { lock.withLock { taps.append(tap) } }
        var all: [AudioTapLocation] { lock.withLock { taps } }
    }
}
