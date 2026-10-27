import AvoIO
import AvoKit
import AvoTestSupport
import Foundation
import Testing
@testable import AvoDaemonCore

/// FakeEngine with a media volume, as VMMEngine has through HostAgent.
final class VolumeKeepingEngine: VolumeEngine, @unchecked Sendable {
    let base: FakeEngine
    private let lock = NSLock()
    private var _volume = AndroidVolume(level: 3, maximum: 15)
    var volume: AndroidVolume { lock.withLock { _volume } }

    init(_ base: FakeEngine) {
        self.base = base
    }

    var name: String { base.name }
    var exits: AsyncStream<EngineExit> { base.exits }
    func start(_ launch: EngineLaunch) async throws { try await base.start(launch) }
    func stop() async { await base.stop() }
    func snapshot(to url: URL) async throws { try await base.snapshot(to: url) }
    func connect(port: UInt32) async throws -> any ByteStream { try await base.connect(port: port) }
    func connectSocket(port: UInt32) async throws -> Int32 { try await base.connectSocket(port: port) }
    func mediaVolume() async throws -> AndroidVolume { volume }
    func setMediaVolume(_ level: Int) async throws -> AndroidVolume {
        lock.withLock {
            _volume.level = min(max(level, 0), _volume.maximum)
            return _volume
        }
    }
}

/// Android's media volume from Quick Settings and Settings › Devices.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AndroidVolumeTests {
    @Test func readsWhatAndroidSays() {
        #expect(HostAgent.mediaVolume(from: "[V] Connecting to AudioService\n[V] volume is 3 in range [0..15]\n")
            == AndroidVolume(level: 3, maximum: 15))
        #expect(HostAgent.mediaVolume(from: "volume is 25 in range [0..25]") == AndroidVolume(level: 25, maximum: 25))
        #expect(HostAgent.mediaVolume(from: "Error: no such stream") == nil)
        #expect(HostAgent.mediaVolume(from: "volume is 0 in range [0..0]") == nil)
    }

    @Test func anAppWindowAndTheControlPanelSetIt() async throws {
        var keeping: VolumeKeepingEngine?
        let harness = try Harness(apps: [], wrap: { base in
            let engine = VolumeKeepingEngine(base)
            keeping = engine
            return engine
        })
        defer { harness.cleanUp() }
        let engine = try #require(keeping)
        let (window, _) = await harness.connect(.shim(package: "org.example.game"))
        await #expect(throws: AvoError.vmNotRunning) { _ = try await harness.core.androidVolume(client: window) }

        let (panel, _) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        #expect(try await harness.core.androidVolume(client: window) == AndroidVolume(level: 3, maximum: 15))
        #expect(try await harness.core.setAndroidVolume(15, client: window) == AndroidVolume(level: 15, maximum: 15))
        #expect(try await harness.core.setAndroidVolume(40, client: panel).level == 15)
        #expect(try await harness.core.setAndroidVolume(-2, client: panel).level == 0)
        #expect(engine.volume.level == 0)
        // A connection that never said who it is.
        await #expect(throws: AvoError.unauthorizedCaller) { _ = try await harness.core.setAndroidVolume(9, client: UUID()) }
        #expect(engine.volume.level == 0)
    }
}
