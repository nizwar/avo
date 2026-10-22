import AvoKit
import Foundation
import Testing
@testable import AvoDaemonCore

/// Graphics › Clear GPU cache: the engine's Metal shader cache in
/// ~/Library/Caches/Avo/gpu-cache (engine/hvf/vmm/src/virtio/gpu/cache.rs).
@Suite(.serialized, .timeLimit(.minutes(1))) struct GPUCacheTests {
    private static func fill(_ home: URL) throws {
        let metal = GPUCache.directory(home: home)
            .appending(path: "emulator-37.1.11_moltenvk_apple-m4-pro_macos-26a434/metal/32024", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: metal, withIntermediateDirectories: true)
        try Data(count: 3000).write(to: metal.appending(path: "libraries.data"))
        try Data(count: 100).write(to: metal.appending(path: "libraries.list"))
    }

    @Test func statusAndClearMeasureAndEmptyTheFolder() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "avo-gpu-cache-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = GPUCache.directory(home: home)
        #expect(folder.path.hasSuffix("Library/Caches/Avo/gpu-cache"))
        // Nothing yet: nothing to clear either.
        #expect(GPUCache.status(home: home) == GPUCacheStatus(path: folder.path, bytes: 0))
        #expect(try GPUCache.clear(home: home) == GPUCacheStatus(path: folder.path, bytes: 0, clearedBytes: 0))

        try Self.fill(home)
        #expect(GPUCache.status(home: home).bytes == 3100)
        #expect(try GPUCache.clear(home: home) == GPUCacheStatus(path: folder.path, bytes: 0, clearedBytes: 3100))
        // The folder itself stays; what was in it is gone.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func onlyTheControlPanelSeesOrClearsIt() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        try Self.fill(harness.paths.home)
        let (panel, _) = await harness.connect(.controlPanel)
        let (shim, _) = await harness.connect(.shim(package: "com.avodroid.hello"))
        await #expect(throws: AvoError.self) { try await harness.core.clearGPUCache(client: shim) }
        await #expect(throws: AvoError.self) { try await harness.core.gpuCacheStatus(client: shim) }
        #expect(try await harness.core.gpuCacheStatus(client: panel).bytes == 3100)
        #expect(try await harness.core.clearGPUCache(client: panel).clearedBytes == 3100)
        #expect(try await harness.core.gpuCacheStatus(client: panel).bytes == 0)
    }
}
