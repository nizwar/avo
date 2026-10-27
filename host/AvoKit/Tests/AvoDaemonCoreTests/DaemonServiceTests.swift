import AvoKit
import AvoTestSupport
import Foundation
import Testing
@testable import AvoDaemonCore

/// The daemon's XPC side, over an in-process connection: this test process
/// passes for a development build's own process (`CallerPolicy.development`).
@Suite(.serialized, .timeLimit(.minutes(1))) struct DaemonServiceTests {
    final class Peer: @unchecked Sendable {
        let connection: NSXPCConnection
        let daemon: any AvoDaemonXPC

        init(_ listener: NSXPCListener) throws {
            connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
            connection.remoteObjectInterface = AvoXPC.daemonInterface()
            connection.exportedInterface = AvoXPC.clientInterface()
            connection.exportedObject = RecordingClient()
            connection.resume()
            daemon = try #require(connection.remoteObjectProxy as? any AvoDaemonXPC)
        }

        func hello(_ role: ClientHello.Role = .controlPanel) async throws -> DaemonHello {
            let request = AvoXPC.encode(ClientHello(role: role, version: "test"))
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                daemon.hello(request) { data, error in
                    if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? AvoError.unauthorizedCaller) }
                }
            }
            return try AvoXPC.decode(DaemonHello.self, from: data)
        }

        func status() async -> Data {
            await withCheckedContinuation { continuation in daemon.status { continuation.resume(returning: $0) } }
        }

        func stopVM() async -> NSError? {
            await withCheckedContinuation { continuation in daemon.stopVM { continuation.resume(returning: $0) } }
        }
    }

    static func service(_ harness: Harness) -> (DaemonService, NSXPCListener) {
        let listener = NSXPCListener.anonymous()
        // The test runner's own folder stands for the app bundle.
        let runner = (Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])).deletingLastPathComponent()
        let service = DaemonService(core: harness.core, policy: .development(appBundle: runner), listener: listener)
        service.resume()
        return (service, listener)
    }

    /// Before its hello a connection gets nothing: no status, no apps, no
    /// action (a call sent then would escape the code requirement the hello sets).
    @Test func nothingIsAnsweredBeforeAValidHello() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (service, listener) = Self.service(harness)
        _ = service
        let peer = try Peer(listener)
        defer { peer.connection.invalidate() }

        #expect((try? AvoXPC.decode(VMStatus.self, from: await peer.status())) == nil)
        #expect(await peer.stopVM()?.code == AvoXPC.nsError(AvoError.unauthorizedCaller).code)

        let hello = try await peer.hello()
        #expect(hello.status.state == .stopped)
        #expect(try AvoXPC.decode(VMStatus.self, from: await peer.status()).state == .stopped)
        #expect(await peer.stopVM() == nil)
        // A second hello is refused.
        await #expect(throws: (any Error).self) { try await peer.hello() }
    }

    /// A client that goes while its hello is checked is not left behind
    /// (a ghost Control Panel kept Android from pausing when idle for good).
    @Test func aClientGoneDuringItsHelloIsNotLeftRegistered() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (service, listener) = Self.service(harness)
        _ = service
        for _ in 0..<20 {
            let peer = try Peer(listener)
            let request = AvoXPC.encode(ClientHello(role: .controlPanel, version: "test"))
            peer.daemon.hello(request) { _, _ in }
            peer.connection.invalidate()
        }
        #expect(await eventually { await harness.core.autoPauseBlockers().windows == 0 })
    }
}
