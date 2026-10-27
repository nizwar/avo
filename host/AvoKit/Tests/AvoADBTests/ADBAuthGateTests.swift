import AvoIO
import AvoTestSupport
import Foundation
import Security
import Testing
@testable import AvoADB

private func fixture(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
}

@Suite struct ADBPublicKeyTests {
    @Test func checksSignaturesOfAdbPubkeyOutput() throws {
        // test_adbkey.pub was produced by `adb pubkey test_adbkey` (platform-tools 37).
        let line = try String(contentsOf: fixture("test_adbkey.pub"), encoding: .utf8)
        let trusted = try ADBPublicKey(android: line + " user@mac")
        let token = Data((0..<20).map { UInt8($0 * 7) })
        let key = try ADBKey.load(from: fixture("test_adbkey"))
        #expect(trusted.verifies(try key.sign(token: token), of: token))
        #expect(!trusted.verifies(try key.sign(token: token), of: Data(repeating: 1, count: 20)))
        #expect(!trusted.verifies(try ADBKey.generate().sign(token: token), of: token))
    }

    @Test func readsAKeyFileAndSkipsWhatIsNotAKey() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "avo-adbkey-\(UUID()).pub")
        defer { try? FileManager.default.removeItem(at: url) }
        let second = try ADBKey.generate().androidPublicKey(comment: "other@mac")
        try ("garbage\n" + (try String(contentsOf: fixture("test_adbkey.pub"), encoding: .utf8)) + "\n" + second + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(ADBPublicKey.load(from: url).count == 2)
        #expect(ADBPublicKey.load(from: url.appending(path: "missing")).isEmpty)
        #expect(throws: ADBKeyError.self) { try ADBPublicKey(android: "AAAA") }
    }
}

@Suite struct ADBAuthGateTests {
    /// The gate on one end of a socket pair, the client on the other.
    private func gate(trusting keys: [ADBPublicKey], timeout: Duration = .seconds(5))
        throws -> (client: Int32, admitted: Task<ADBAuthGate.Admission, any Error>) {
        let (client, device) = try UnixSocket.pair()
        let admitted = Task.detached { try ADBAuthGate.admit(device, keys: keys, timeout: timeout) }
        return (client, admitted)
    }

    @Test func admitsAClientThatSignsWithATrustedKey() async throws {
        let key = try ADBKey.load(from: fixture("test_adbkey"))
        let (fd, admitted) = try gate(trusting: [try ADBPublicKey(android: try key.androidPublicKey())])
        let client = ADBConnection(transport: FileDescriptorStream(fileDescriptor: fd), key: key, keyComment: "avo@test")
        let connecting = Task { try await client.connect(timeout: .seconds(5)) }
        let admission = try await admitted.value
        #expect(admission.connect.command == .connect)
        #expect(String(decoding: admission.connect.payload, as: UTF8.self).hasPrefix("host::features="))
        #expect(admission.leftover.isEmpty)
        connecting.cancel()
        await client.close()
    }

    @Test func refusesAKeyItDoesNotKnow() async throws {
        let trusted = try ADBPublicKey(android: try ADBKey.load(from: fixture("test_adbkey")).androidPublicKey())
        let (fd, admitted) = try gate(trusting: [trusted])
        // adb signs with its key, and offers it once the signature is refused.
        let client = ADBConnection(transport: FileDescriptorStream(fileDescriptor: fd), key: try ADBKey.generate(), keyComment: "stranger@mac")
        let connecting = Task { try await client.connect(timeout: .seconds(5)) }
        await #expect(throws: ADBAuthGate.Refusal.unknownKey("stranger@mac")) { try await admitted.value }
        connecting.cancel()
        await client.close()
    }

    @Test func refusesWhatIsNotADB() async throws {
        let (fd, admitted) = try gate(trusting: [])
        _ = Array("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        await #expect(throws: ADBAuthGate.Refusal.notADB) { try await admitted.value }
        close(fd)
    }

    @Test func givesUpOnASilentClient() async throws {
        let (fd, admitted) = try gate(trusting: [], timeout: .milliseconds(200))
        await #expect(throws: ADBAuthGate.Refusal.timedOut) { try await admitted.value }
        close(fd)
    }
}
