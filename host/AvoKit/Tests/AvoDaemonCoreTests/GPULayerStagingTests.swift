import AvoADB
import AvoIO
import AvoKit
import AvoPackages
import AvoShimKit
import AvoTestSupport
import Foundation
import Testing
@testable import AvoDaemonCore

/// FakeEngine that records the GPU layers DaemonCore asks the running Android
/// to take before the next start (VMMEngine forwards them to HostAgent).
final class GPULayerFakeEngine: GPULayerEngine, @unchecked Sendable {
    struct Staged: Equatable {
        var profile: Bool
        var gfxstreamSync: Bool
    }

    let inner = FakeEngine(agent: FakeBridgeAgent(apps: []))
    private let lock = NSLock()
    private var _staged: [Staged] = []
    var staged: [Staged] { lock.withLock { _staged } }
    var name: String { inner.name }
    var exits: AsyncStream<(any Error)?> { inner.exits }

    func start(_ launch: EngineLaunch) async throws { try await inner.start(launch) }
    func stop() async { await inner.stop() }
    func snapshot(to url: URL) async throws { try await inner.snapshot(to: url) }
    func connect(port: UInt32) async throws -> any ByteStream { try await inner.connect(port: port) }
    func stageGPULayers(profile: Bool, gfxstreamSync: Bool) async {
        lock.withLock { _staged.append(Staged(profile: profile, gfxstreamSync: gfxstreamSync)) }
    }
}

@Suite struct GPULayerStagingTests {
    /// The restart these settings need begins with the layers it names, so
    /// they work at once instead of a start later (GuestGPUProfile).
    @Test func graphicsSettingsStageTheLayersTheNextStartNames() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "avo-gpulayers-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AvoPaths(home: root.appending(path: "home"), temporaryDirectory: root.appending(path: "tmp"))
        try FileManager.default.createDirectory(at: paths.desktop, withIntermediateDirectories: true)
        var config = VMConfig()
        config.createDesktopAlias = false
        try config.save(to: paths.config)
        let template = root.appending(path: "AvoShim.app")
        try FileManager.default.createDirectory(at: template.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        let builder = ShimBuilder(template: template, hostApplication: URL(filePath: "/Applications/Avo.app"), directory: paths.shims)
        let engine = GPULayerFakeEngine()
        let image = AndroidImage(schema: 1, version: "17", sdk: 37, kernel: "kernel", initrd: nil, partitions: [],
                                 overlayStock: "", overlayRooted: "", files: [])
        let phone = DeviceProfile(id: "phone", name: "Phone", properties: [:],
                                  hardware: DeviceHardware(gpu: .init(glVendor: "Qualcomm", glRenderer: "Adreno (TM) 750")))
        let core = DaemonCore(.init(paths: paths, engine: engine, adbKey: try ADBKey.generate(),
                                    profiles: DeviceProfileCatalog(profiles: [DeviceProfile(id: DeviceProfile.defaultID, name: "Avo", properties: [:]), phone]),
                                    host: HostInfo(physicalMemoryBytes: 32 << 30, performanceCores: 8, efficiencyCores: 4, isAppleSilicon: true, macOSVersion: "27.0"),
                                    shortcuts: ShortcutManager(builder: builder, paths: paths),
                                    softwareVersion: "test", bootTimeout: .seconds(5), loadImage: { image }))
        let panel = UUID()
        _ = await core.register(panel, role: .controlPanel, proxy: ClientProxy(RecordingClient()))
        var new = await core.configurationSnapshot().config
        // Emulation on, with a profile that has no GPU: only the GPU's own layer.
        new.emulateHardware = true
        _ = try await core.updateConfiguration(new, client: panel)
        #expect(engine.staged == [.init(profile: false, gfxstreamSync: true)])
        // A profile with a GPU: its layers too.
        new.deviceProfileID = "phone"
        _ = try await core.updateConfiguration(new, client: panel)
        #expect(engine.staged.last == .init(profile: true, gfxstreamSync: true))
        // Software rendering: no gfxstream sync layer.
        new.rendererMode = .software
        _ = try await core.updateConfiguration(new, client: panel)
        #expect(engine.staged.last == .init(profile: true, gfxstreamSync: false))
        // Emulation off: nothing to put in (the next start removes the layers).
        new.emulateHardware = false
        _ = try await core.updateConfiguration(new, client: panel)
        #expect(engine.staged.last == .init(profile: false, gfxstreamSync: false))
        // Anything else leaves the layers alone.
        new.addToDock = true
        _ = try await core.updateConfiguration(new, client: panel)
        #expect(engine.staged.count == 4)
    }
}
