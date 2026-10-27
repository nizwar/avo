import AvoADB
import AvoIO
import AvoKit
import AvoProtocol
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

        func startVM() async -> NSError? {
            await withCheckedContinuation { continuation in daemon.startVM { continuation.resume(returning: $0) } }
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

    /// Stop pressed while Android starts: the start's call fails as a start
    /// called off, which the clients tell apart and say nothing of, not
    /// with a CancellationError's "The operation couldn't be completed".
    @Test func aStartAStopCalledOffSaysSo() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        // Android wrote its data before: its start has the usual time.
        try harness.paths.createDirectories()
        try Data([1]).write(to: harness.paths.dataDisk)
        await harness.core.start()
        let (service, listener) = Self.service(harness)
        _ = service
        let peer = try Peer(listener)
        defer { peer.connection.invalidate() }
        _ = try await peer.hello()

        harness.engine.refuseControlConnections = Int.max
        let start = Task { await peer.startVM() }
        #expect(await eventually { await harness.core.status().detail == "Waiting for Android to boot" })
        #expect(await peer.stopVM() == nil)
        let error = try #require(await start.value)
        #expect(AvoXPC.avoError(error) == .startCalledOff)
        #expect(error.localizedDescription == "Android was stopped before it was ready.")
        #expect(AvoError.reported(CancellationError()) == .startCalledOff)
    }

    /// ADB's failures reach the user in plain words (a file dropped on a
    /// window, the widgets Android offers, an install's game data), not as
    /// "The operation couldn't be completed. (AvoADB.ADBError error 12.)".
    @Test func adbFailuresSayWhatHappenedInAndroid() {
        let timedOut = AvoXPC.nsError(AvoError.reported(ADBError.timedOut("adbd did not open shell:cmd appwidget")))
        #expect(timedOut.localizedDescription == "Android did not respond.")
        #expect(AvoXPC.avoError(timedOut) == .internalError("Android did not respond."))
        #expect(ADBError.connectionClosed.localizedDescription == "Android closed the connection before Avo was done.")
        // adbd's refusal of a file: the reason Android gave, without the path or adbd's words.
        #expect(ADBError.sync("/sdcard/Download/a: b.png: couldn't create file: No space left on device").localizedDescription
            == "Android could not save the file: No space left on device.")
        #expect(ADBError.sync("no reply for /sdcard/Download/a.png").localizedDescription == "Android could not save the file.")
        // PackageManager's codes stay for InstallPipeline.friendly.
        #expect(ADBError.install("Failure [INSTALL_FAILED_OLDER_SDK]").localizedDescription == "Failure [INSTALL_FAILED_OLDER_SDK]")
        #expect(ADBError.streamClosed.description == "ADB stream closed", "the logs keep the protocol's words")
    }

    /// The sockets' failures likewise, not "(AvoIO.IOError error 0.)": what
    /// happened, with the system's reason where there is one.
    @Test func socketFailuresSayWhatHappened() {
        let refused = IOError.posix(op: "connect", code: ECONNREFUSED)
        #expect(refused.localizedDescription == "Avo could not reach Android (Connection refused).")
        #expect(AvoError.reported(refused) == .internalError("Avo could not reach Android (Connection refused)."))
        #expect(IOError.timedOut("socket read").localizedDescription == "Android did not respond.")
        #expect(IOError.closed.localizedDescription == "Android closed the connection before Avo was done.")
        #expect(refused.description == "connect: Connection refused", "the logs keep the call")
    }

    /// A request Android did not answer in time says what was being done,
    /// not the protocol's name for it ("launch timed out."); the requests
    /// nobody waits on read as Android not responding.
    @Test func androidsTimeoutsSayWhatWasBeingDone() {
        #expect(ControlSession.timedOut(.launch(Avo_V1_Launch())).localizedDescription == "Opening the app timed out.")
        #expect(ControlSession.timedOut(.getPermissions(Avo_V1_GetPermissions())).localizedDescription
            == "Reading the app’s permissions timed out.")
        #expect(ControlSession.timedOut(.ping(Avo_V1_Ping())) == .guestUnavailable)
    }
}
