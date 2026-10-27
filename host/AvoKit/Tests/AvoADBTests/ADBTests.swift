import AvoIO
import AvoTestSupport
import Foundation
import Security
import Testing
@testable import AvoADB

private func fixture(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
}

@Suite struct ADBKeyTests {
    @Test func publicKeyMatchesAdbPubkeyOutput() throws {
        // test_adbkey.pub was produced by `adb pubkey test_adbkey` (platform-tools 37).
        let key = try ADBKey.load(from: fixture("test_adbkey"))
        let expected = try String(contentsOf: fixture("test_adbkey.pub"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(try key.androidPublicKey() == expected)
        #expect(try key.androidPublicKey(comment: "avo@mac") == expected + " avo@mac")
    }

    @Test func pemRoundTripAndPermissions() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "avo-adbkey-\(UUID())")
        defer { try? FileManager.default.removeItem(at: url) }
        let created = try ADBKey.loadOrCreate(at: url)
        let loaded = try ADBKey.loadOrCreate(at: url)
        #expect(try created.androidPublicKey() == loaded.androidPublicKey())
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try String(contentsOf: url, encoding: .utf8).hasPrefix("-----BEGIN PRIVATE KEY-----\n"))
    }

    @Test func signsTokensAsSHA1Digests() throws {
        let key = try ADBKey.load(from: fixture("test_adbkey"))
        let token = Data((0..<20).map(UInt8.init))
        let signature = try key.sign(token: token)
        #expect(signature.count == 256)
        let publicKey = try #require(SecKeyCopyPublicKey(key.privateKey))
        #expect(SecKeyVerifySignature(publicKey, .rsaSignatureDigestPKCS1v15SHA1, token as CFData, signature as CFData, nil))
    }

    @Test func rejectsGarbage() {
        #expect(throws: ADBKeyError.invalidPEM) { try ADBKey(pem: "not a key") }
    }
}

@Suite struct ADBMessageTests {
    @Test func headerLayout() {
        let message = ADBMessage(.open, 1, 0, Data("shell:\0".utf8))
        let bytes = [UInt8](message.encoded())
        #expect(bytes.count == 24 + 7)
        #expect(Array(bytes[0..<4]) == Array("OPEN".utf8))
        #expect(Array(bytes[12..<16]) == [7, 0, 0, 0])
        #expect(Array(bytes[16..<20]) == [0, 0, 0, 0]) // no checksum in v0x01000001
        #expect(Array(bytes[20..<24]) == [~UInt8(ascii: "O"), ~UInt8(ascii: "P"), ~UInt8(ascii: "E"), ~UInt8(ascii: "N")])
        let legacy = [UInt8](message.encoded(withChecksum: true))
        let sum = Data("shell:\0".utf8).reduce(UInt32(0)) { $0 + UInt32($1) }
        #expect(Array(legacy[16..<20]) == withUnsafeBytes(of: sum.littleEndian) { Array($0) })
    }

    @Test func decoderReassemblesAndValidates() throws {
        var decoder = ADBMessageDecoder()
        let a = ADBMessage(.write, 3, 4, Data(repeating: 7, count: 100))
        let b = ADBMessage(.okay, 4, 3)
        for byte in a.encoded() + b.encoded() { decoder.append(Data([byte])) }
        #expect(try decoder.next() == a)
        #expect(try decoder.next() == b)
        #expect(try decoder.next() == nil)

        var corrupt = ADBMessageDecoder()
        var bytes = b.encoded()
        bytes[20] ^= 0xFF
        corrupt.append(bytes)
        #expect(throws: ADBError.badMagic) { try corrupt.next() }
    }

    @Test func parsesDeviceBanner() {
        let info = ADBConnection.parseBanner(ADBMessage(.connect, 0x0100_0001, 1 << 20,
            Data("device::ro.product.model=Avo;ro.product.device=avo_arm64;features=shell_v2,cmd".utf8)))
        #expect(info.systemType == "device")
        #expect(info.properties["ro.product.model"] == "Avo")
        #expect(info.features == ["shell_v2", "cmd"])
        #expect(info.maxPayload == ADBMessage.maxPayload) // capped to ours
    }

    @Test func sessionIDParsing() {
        #expect(ADBConnection.sessionID("Success: created install session [1234567]\n") == 1_234_567)
        #expect(ADBConnection.sessionID("Error: something") == nil)
        #expect(ADBConnection.shellQuote("it's") == "'it'\\''s'")
    }
}

@Suite struct ADBConnectionTests {
    private func pair(authMode: FakeADBD.AuthMode = .signature, maxPayload: UInt32 = 4096) throws -> (ADBConnection, FakeADBD, Task<Void, Never>) {
        let key = try ADBKey.load(from: fixture("test_adbkey"))
        let (a, b) = try UnixSocket.pair()
        let device = FakeADBD(fileDescriptor: b, publicKey: SecKeyCopyPublicKey(key.privateKey)!, authMode: authMode, maxPayload: maxPayload)
        let task = Task { await device.run() }
        let client = ADBConnection(transport: FileDescriptorStream(fileDescriptor: a), key: key, keyComment: "avo@test")
        return (client, device, task)
    }

    @Test func authenticatesWithSignature() async throws {
        let (client, device, task) = try pair()
        defer { task.cancel() }
        let info = try await client.connect(timeout: .seconds(5))
        #expect(info.properties["ro.product.device"] == "avo_arm64")
        #expect(info.features.contains("shell_v2"))
        #expect(await device.signaturesVerified == 1)
        #expect(await device.receivedPublicKey == nil)
        await client.close()
    }

    @Test func offersPublicKeyWhenSignatureIsRejected() async throws {
        let (client, device, task) = try pair(authMode: .requirePublicKey)
        defer { task.cancel() }
        _ = try await client.connect(timeout: .seconds(5))
        let expected = try String(contentsOf: fixture("test_adbkey.pub"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) + " avo@test"
        #expect(await device.receivedPublicKey == expected)
        await client.close()
    }

    @Test func connectsWithoutAuth() async throws {
        let (client, _, task) = try pair(authMode: .none)
        defer { task.cancel() }
        _ = try await client.connect(timeout: .seconds(5))
        await client.close()
    }

    @Test func shellV2SeparatesStreamsAndExitCode() async throws {
        let (client, device, task) = try pair()
        defer { task.cancel() }
        await device.setShellHandler { command in
            command == "getprop ro.build.version.sdk" ? ("36\n", "", 0) : ("", "not found\n", 127)
        }
        _ = try await client.connect(timeout: .seconds(5))
        let sdk = try await client.shell("getprop ro.build.version.sdk")
        #expect(sdk.output == "36\n" && sdk.exitCode == 0)
        let missing = try await client.shell("nope")
        #expect(missing.exitCode == 127 && missing.errorOutput == "not found\n")
        await client.close()
    }

    /// An Android that stopped answering holds no caller for good, and the
    /// connection goes on serving the commands after it.
    @Test func aCommandAndroidNeverFinishesTimesOut() async throws {
        let (client, device, task) = try pair()
        defer { task.cancel() }
        await device.setShellHandler { _ in ("ok\n", "", 0) }
        await device.setStalls(neverEnds: { $0 == "dumpsys window" })
        _ = try await client.connect(timeout: .seconds(5))
        let started = ContinuousClock.now
        await #expect(throws: ADBError.self) { try await client.shell("dumpsys window", timeout: .milliseconds(300)) }
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(try await client.shell("echo ok").output == "ok\n")
        await client.close()
    }

    @Test func aStreamAdbdNeverTakesTimesOut() async throws {
        let (client, device, task) = try pair()
        defer { task.cancel() }
        await device.setStalls(neverOpens: { $0.hasPrefix("sync:") })
        _ = try await client.connect(timeout: .seconds(5))
        await #expect(throws: ADBError.self) { try await client.open("sync:", timeout: .milliseconds(300)) }
        #expect(try await client.shell("true").exitCode == 0)
        await client.close()
    }

    /// The caller gave up (a window closed, a deadline passed): it stops
    /// waiting at once instead of when adbd answers.
    @Test func aCancelledCallerStopsWaitingForAdbd() async throws {
        let (client, device, task) = try pair()
        defer { task.cancel() }
        await device.setStalls(neverOpens: { $0.hasPrefix("shell,v2,raw:getprop") })
        _ = try await client.connect(timeout: .seconds(5))
        let waiting = Task { try await client.shell("getprop sys.boot_completed") }
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(ContinuousClock.now - started < .seconds(2))
        await client.close()
    }

    @Test func refusedServiceThrows() async throws {
        let (client, _, task) = try pair()
        defer { task.cancel() }
        _ = try await client.connect(timeout: .seconds(5))
        await #expect(throws: ADBError.streamRefused("bogus:")) { try await client.open("bogus:") }
        await client.close()
    }

    @Test func installsSplitAPKsWithSessionCommands() async throws {
        let (client, device, task) = try pair(maxPayload: 4096)
        defer { task.cancel() }
        await device.setShellHandler { command in
            if command.hasPrefix("pm install-create") { return ("Success: created install session [777]\n", "", 0) }
            if command == "pm install-commit 777" { return ("Success\n", "", 0) }
            return ("", "unexpected \(command)", 1)
        }
        _ = try await client.connect(timeout: .seconds(5))
        let base = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0) })
        let split = Data(repeating: 0xAB, count: 5_000)
        let parts = [base, split].enumerated().map { index, bytes in
            ADBConnection.InstallPart(name: index == 0 ? "base.apk" : "split_config.arm64_v8a.apk", size: UInt64(bytes.count)) {
                ChunkPipe(capacity: 2) { send in
                    // Odd chunk sizes to exercise re-chunking to maxPayload.
                    var offset = 0
                    while offset < bytes.count {
                        let end = min(offset + 1_337, bytes.count)
                        try send(bytes.subdata(in: offset..<end))
                        offset = end
                    }
                }.stream()
            }
        }
        let progress = ProgressLog()
        try await client.install(parts) { done, total in progress.record(done, total) }

        #expect(await device.shellCommands == ["pm install-create -r -S 15000", "pm install-commit 777"])
        let writes = await device.execWrites
        #expect(writes.map(\.command) == [
            "cmd package install-write -S 10000 777 'base.apk' -",
            "cmd package install-write -S 5000 777 'split_config.arm64_v8a.apk' -",
        ])
        #expect(writes.map(\.data) == [base, split])
        #expect(progress.last?.0 == 15_000 && progress.last?.1 == 15_000)
        await client.close()
    }

    @Test func abandonsSessionWhenCommitFails() async throws {
        let (client, device, task) = try pair()
        defer { task.cancel() }
        await device.setShellHandler { command in
            if command.hasPrefix("pm install-create") { return ("Success: created install session [9]\n", "", 0) }
            if command.hasPrefix("pm install-commit") { return ("Failure [INSTALL_FAILED_NO_MATCHING_ABIS]\n", "", 1) }
            return ("Success\n", "", 0)
        }
        _ = try await client.connect(timeout: .seconds(5))
        let part = ADBConnection.InstallPart(name: "base.apk", size: 3) {
            AsyncThrowingStream { continuation in
                continuation.yield(Data([1, 2, 3]))
                continuation.finish()
            }
        }
        let sessions = SessionLog()
        await #expect(throws: ADBError.install("Failure [INSTALL_FAILED_NO_MATCHING_ABIS]")) {
            try await client.install([part], session: { sessions.record($0, $1) })
        }
        #expect(await device.shellCommands.last == "pm install-abandon 9")
        #expect(sessions.entries == ["9 open", "9 closed"], "Android answered the abandon")
        await client.close()
    }

    /// The connection goes before the abandon: the session is one Android
    /// may still keep, and its caller hears it opened only.
    @Test func aSessionTheAbandonCannotReachStaysOpen() async throws {
        let (client, device, task) = try pair()
        defer { task.cancel() }
        await device.setShellHandler { command in
            command.hasPrefix("pm install-create") ? ("Success: created install session [5]\n", "", 0) : ("Success\n", "", 0)
        }
        await device.setStalls(neverEnds: { $0.hasPrefix("pm install-commit") })
        _ = try await client.connect(timeout: .seconds(5))
        let part = ADBConnection.InstallPart(name: "base.apk", size: 3) {
            AsyncThrowingStream { continuation in
                continuation.yield(Data([1, 2, 3]))
                continuation.finish()
            }
        }
        let sessions = SessionLog()
        let install = Task { try await client.install([part], session: { sessions.record($0, $1) }) }
        let deadline = ContinuousClock.now + .seconds(5)
        while await !device.shellCommands.contains("pm install-commit 5"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await client.close()
        await #expect(throws: (any Error).self) { try await install.value }
        #expect(sessions.entries == ["5 open"])
    }

    @Test func pushesFilesWithSync() async throws {
        let (client, device, task) = try pair(maxPayload: 256 * 1024)
        defer { task.cancel() }
        _ = try await client.connect(timeout: .seconds(5))
        let obb = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        let path = "/sdcard/Android/obb/com.avodroid.fixture/main.42.com.avodroid.fixture.obb"
        try await client.push(ChunkPipe { send in
            var offset = 0
            while offset < obb.count {
                let end = min(offset + 100_000, obb.count)
                try send(obb.subdata(in: offset..<end))
                offset = end
            }
        }, to: path)
        let pushed = await device.pushed[path]
        #expect(pushed?.data == obb)
        #expect(pushed?.mode == String(0o100644))
        await client.close()
    }
}

final class SessionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [String] = []
    var entries: [String] { lock.withLock { _entries } }
    func record(_ session: Int, _ open: Bool) { lock.withLock { _entries.append("\(session) \(open ? "open" : "closed")") } }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(UInt64, UInt64)] = []

    func record(_ done: UInt64, _ total: UInt64) {
        lock.withLock { entries.append((done, total)) }
    }

    var last: (UInt64, UInt64)? { lock.withLock { entries.last } }
}
