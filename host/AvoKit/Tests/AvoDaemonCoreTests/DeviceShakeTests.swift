import AvoIO
import AvoKit
import AvoTestSupport
import Foundation
import Testing
@testable import AvoDaemonCore

/// FakeEngine that counts shakes, as VMMEngine sends the engine's `shake`.
final class ShakingEngine: ShakeEngine, @unchecked Sendable {
    let base: FakeEngine
    private let lock = NSLock()
    private var _shakes = 0
    var shakes: Int { lock.withLock { _shakes } }

    init(_ base: FakeEngine) {
        self.base = base
    }

    var name: String { base.name }
    var exits: AsyncStream<(any Error)?> { base.exits }
    func start(_ launch: EngineLaunch) async throws { try await base.start(launch) }
    func stop() async { await base.stop() }
    func snapshot(to url: URL) async throws { try await base.snapshot(to: url) }
    func connect(port: UInt32) async throws -> any ByteStream { try await base.connect(port: port) }
    func connectSocket(port: UInt32) async throws -> Int32 { try await base.connectSocket(port: port) }
    func shake() async throws { lock.withLock { _shakes += 1 } }
}

/// An app window's Device › Shake: the phone shaken once Android runs, for
/// Avo's own windows and Control Panel only.
@Suite(.serialized, .timeLimit(.minutes(1))) struct DeviceShakeTests {
    @Test func anAppWindowShakesTheRunningPhone() async throws {
        var shaking: ShakingEngine?
        let harness = try Harness(apps: [], wrap: { base in
            let engine = ShakingEngine(base)
            shaking = engine
            return engine
        })
        defer { harness.cleanUp() }
        let engine = try #require(shaking)
        let (window, _) = await harness.connect(.shim(package: "org.example.game"))
        await #expect(throws: AvoError.vmNotRunning) { try await harness.core.shakeDevice(client: window) }
        #expect(engine.shakes == 0)

        let (panel, _) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        try await harness.core.shakeDevice(client: window)
        try await harness.core.shakeDevice(client: panel)
        #expect(engine.shakes == 2)
        // A connection that never said who it is.
        await #expect(throws: AvoError.unauthorizedCaller) { try await harness.core.shakeDevice(client: UUID()) }
        #expect(engine.shakes == 2)
    }
}
