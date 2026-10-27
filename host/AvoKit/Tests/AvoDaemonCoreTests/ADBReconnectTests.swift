import AvoADB
import AvoIO
import AvoKit
import AvoTestSupport
import Foundation
import Synchronization
import Testing
@testable import AvoDaemonCore

/// adbd restarting (`adb root` or `adb usb` from the Mac with ADB support
/// on, a crash of adbd) ends every connection to it.
@Suite(.serialized, .timeLimit(.minutes(1))) struct ADBReconnectTests {
    /// The host agent's next request connects again, instead of every
    /// install, drop and app opened failing until Android restarts.
    @Test func theHostAgentConnectsAgainAfterAdbdRestarted() async throws {
        let key = try ADBKey.generate()
        let connections = Mutex<[Int32]>([])
        let agent = HostAgent(engine: EngineControl(socketPath: "/nonexistent/avo-control.sock"), frames: FrameBridge { _ in },
                              adbKey: key) { port in
            let (host, guest) = try UnixSocket.pair()
            if port == HostAgent.adbPort { connections.withLock { $0.append(guest) } }
            let adbd = FakeADBD(fileDescriptor: guest, publicKey: key.publicKey!, maxPayload: 256 * 1024)
            Task {
                await adbd.setShellHandler { command in
                    if command.hasPrefix("getprop sys.boot_completed") { return ("1\n", "", 0) }
                    if command.hasPrefix("cmd wifi status") { return ("Wifi is connected to \"VirtWifi\"\n", "", 0) }
                    if command == "echo hello" { return ("hello\n", "", 0) }
                    return ("", "", 0)
                }
                await adbd.run()
            }
            return FileDescriptorStream(fileDescriptor: host, label: "fake-host-adb")
        }
        try await agent.prepare(deadline: .now + .seconds(30))
        #expect(try await agent.fingerprintShell("echo hello", asRoot: false).output == "hello\n")

        // adbd goes away with its end of the connection.
        let first = try #require(connections.withLock { $0.first })
        Darwin.shutdown(first, SHUT_RDWR)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await agent.fingerprintShell("echo hello", asRoot: false).output == "hello\n")
        #expect(connections.withLock { $0.count } == 2, "one connection made again, shared by every request")
        await agent.shutdown()
    }
}
