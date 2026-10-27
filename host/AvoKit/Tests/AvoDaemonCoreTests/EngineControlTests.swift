import AvoIO
import AvoKit
import Foundation
import Synchronization
import Testing
@testable import AvoDaemonCore

/// avo-vmm's control socket: `ok` to every command but the ones it never
/// answers, as an engine stuck in one would.
private final class StuckEngineSocket: Sendable {
    let path = FileManager.default.temporaryDirectory.appending(path: "avo-ctl-\(UInt32.random(in: 0...UInt32.max)).sock").path
    final class Count: Sendable {
        let value = Mutex(0)
    }

    let connections = Count()
    private let listener: Int32

    init(neverAnswers stuck: String) throws {
        listener = try UnixSocket.listen(path: path)
        let listener = self.listener
        let connections = self.connections
        Thread {
            while let fd = try? UnixSocket.accept(listener) {
                connections.value.withLock { $0 += 1 }
                Thread {
                    var line = Data()
                    var byte: UInt8 = 0
                    while read(fd, &byte, 1) == 1 {
                        guard byte == UInt8(ascii: "\n") else {
                            line.append(byte)
                            continue
                        }
                        if String(decoding: line, as: UTF8.self) != stuck { _ = "ok\n".withCString { write(fd, $0, 3) } }
                        line.removeAll()
                    }
                    close(fd)
                }.start()
            }
        }.start()
    }

    deinit {
        close(listener)
        unlink(path)
    }
}

@Suite struct EngineControlTests {
    /// A command avo-vmm never answers ends in a timeout instead of holding
    /// every command after it, which go on over a new connection.
    @Test func aCommandTheEngineNeverAnswersDoesNotHoldTheOthers() async throws {
        let socket = try StuckEngineSocket(neverAnswers: "pause")
        let control = EngineControl(socketPath: socket.path)
        try await control.send("shake")
        let stuck = Task { try await control.send("pause", timeout: .milliseconds(500)) }
        try await Task.sleep(for: .milliseconds(100))
        // Queued behind it, then answered over a new connection.
        let started = ContinuousClock.now
        try await control.send("resume")
        #expect(ContinuousClock.now - started < .seconds(3))
        // The user reads Android not responding; the log names the command.
        await #expect(throws: AvoError.guestUnavailable) { try await stuck.value }
        #expect(socket.connections.value.withLock { $0 } == 2)
        await control.close()
    }
}
