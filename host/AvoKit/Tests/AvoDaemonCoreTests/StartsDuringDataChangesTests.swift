import AvoIO
import AvoKit
import AvoProtocol
import AvoTestSupport
import Foundation
import Testing
@testable import AvoDaemonCore

/// The fake engine, which powers Android off at once but takes a while to
/// return from its stop (avo-vmm ending after Android's power off).
final class LingeringStopEngine: VMEngine, @unchecked Sendable {
    let base: FakeEngine
    let lingers: Duration

    init(_ base: FakeEngine, lingers: Duration) {
        self.base = base
        self.lingers = lingers
    }

    var name: String { base.name }
    var exits: AsyncStream<EngineExit> { base.exits }
    func start(_ launch: EngineLaunch) async throws { try await base.start(launch) }
    func snapshot(to url: URL) async throws { try await base.snapshot(to: url) }
    func connect(port: UInt32) async throws -> any ByteStream { try await base.connect(port: port) }

    func stop() async {
        await base.stop()
        let delay = lingers
        await Task.detached { try? await Task.sleep(for: delay) }.value
    }
}

/// A start that comes while Android stops (an app opened from the Dock,
/// Start pressed again): it begins once the stop is over, and none begins
/// on the data Reset Android erases or a restore swaps.
@Suite(.serialized, .timeLimit(.minutes(1))) struct StartsDuringDataChangesTests {
    private static func writeData(_ text: String, in paths: AvoPaths) throws {
        try FileManager.default.createDirectory(at: paths.dataDisks, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: paths.dataDisk)
        try Data("key \(text)".utf8).write(to: paths.dataDisks.appending(path: "metadata.img"))
    }

    /// The stop's end said "stopped" over the engine of a start that came
    /// meanwhile; that start now waits for it.
    @Test func aStartDuringAStopBeginsOnceTheStopIsOver() async throws {
        let harness = try Harness(apps: [], wrap: { LingeringStopEngine($0, lingers: .seconds(1)) })
        defer { harness.cleanUp() }
        try Self.writeData("v1", in: harness.paths)
        let vm = harness.core.vm
        let settings = VMManager.Settings(config: VMConfig(), profile: nil)
        try await vm.ensureRunning(settings)
        let stop = Task { await vm.stop() }
        #expect(await eventually { await vm.status.state == .stopping })
        try await vm.ensureRunning(settings)
        await stop.value
        #expect(await vm.status.state == .running)
        #expect(harness.engine.isRunning)
        #expect(harness.engine.launches.count == 2)
    }

    /// Reset Android while something starts Android during its stop: the
    /// start is refused, and the reset erases data no engine runs on.
    @Test func resetAndroidRefusesAStartUntilItIsDone() async throws {
        let harness = try Harness(apps: [], wrap: { LingeringStopEngine($0, lingers: .seconds(1)) })
        defer { harness.cleanUp() }
        try Self.writeData("v1", in: harness.paths)
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        let reset = Task { try await harness.core.resetAndroid(client: panel) }
        #expect(await eventually { await harness.core.status().state == .stopping })
        await #expect(throws: DaemonCore.refusal(during: .reset)) { try await harness.core.startVM(client: panel) }
        try await reset.value
        #expect(!FileManager.default.fileExists(atPath: harness.paths.dataDisk.path))
        #expect(!harness.engine.isRunning)
        #expect(await harness.core.status().state == .stopped)
        #expect(harness.engine.launches.count == 1)
        // Once it is done, Android starts on its fresh data.
        try await harness.core.startVM(client: panel)
        #expect(await harness.core.status().state == .running)
    }

    /// A restore while something starts Android during its stop: the start
    /// is refused, the checkpoint's data comes back, and Android, which ran,
    /// starts again on it.
    @Test func aRestoreRefusesAStartUntilItsDataIsInPlace() async throws {
        let harness = try Harness(apps: [], wrap: { LingeringStopEngine($0, lingers: .seconds(1)) })
        defer { harness.cleanUp() }
        try Self.writeData("v1", in: harness.paths)
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        let clean = try await harness.core.createCheckpoint(named: nil, client: panel)
        try await harness.core.startVM(client: panel)
        try Self.writeData("v2", in: harness.paths)
        let restore = Task { try await harness.core.restoreCheckpoint(clean.id, client: panel) }
        #expect(await eventually { await harness.core.status().state == .stopping })
        await #expect(throws: DaemonCore.refusal(during: .restore)) { try await harness.core.startVM(client: panel) }
        // Nor a second change of the data meanwhile.
        await #expect(throws: DaemonCore.refusal(during: .restore)) { try await harness.core.resetAndroid(client: panel) }
        try await restore.value
        #expect(try String(contentsOf: harness.paths.dataDisk, encoding: .utf8) == "v1")
        #expect(await harness.core.status().state == .running)
        #expect(harness.engine.launches.count == 2)
    }
}
