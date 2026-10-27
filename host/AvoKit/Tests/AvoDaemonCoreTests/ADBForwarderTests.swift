import AvoADB
import AvoIO
import AvoTestSupport
import Foundation
import Security
import Testing
@testable import AvoDaemonCore

/// ADB support's port with adbd behind it as inside Android: asking no key.
@Suite struct ADBForwarderTests {
    private final class Guests: @unchecked Sendable {
        private let lock = NSLock()
        private var devices: [FakeADBD] = []
        var count: Int { lock.withLock { devices.count } }
        func add(_ device: FakeADBD) { lock.withLock { devices.append(device) } }
    }

    /// A forwarder trusting `trusted`, listening on a free port.
    private func forwarder(trusting trusted: ADBKey, guests: Guests) async throws -> (ADBForwarder, UInt16, URL) {
        let keys = FileManager.default.temporaryDirectory.appending(path: "avo-adbkey-\(UUID()).pub")
        try (try trusted.androidPublicKey(comment: "user@mac") + "\n").write(to: keys, atomically: true, encoding: .utf8)
        let forwarder = ADBForwarder(connectGuest: {
            let (near, far) = try UnixSocket.pair()
            // Asked no key: any one does.
            let device = FakeADBD(fileDescriptor: far, publicKey: trusted.publicKey!, authMode: .none)
            await device.setShellHandler { command in command == "echo hi" ? ("hi\n", "", 0) : ("", "", 1) }
            guests.add(device)
            Task { await device.run() }
            return near
        }, trustedKeys: keys)
        for _ in 0..<20 {
            let port = UInt16.random(in: 40000...60000)
            await forwarder.update(enabled: true, port: Int(port))
            if case .listening = await forwarder.state { return (forwarder, port, keys) }
        }
        throw POSIXError(.EADDRINUSE)
    }

    private func connect(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw POSIXError(.ECONNREFUSED) }
        return fd
    }

    @Test func adbWithThisMacsKeyReachesAndroid() async throws {
        let key = try ADBKey.generate()
        let guests = Guests()
        let (forwarder, port, keys) = try await forwarder(trusting: key, guests: guests)
        defer { try? FileManager.default.removeItem(at: keys) }
        let client = ADBConnection(transport: FileDescriptorStream(fileDescriptor: try connect(port: port)), key: key, keyComment: "user@mac")
        // adbd's own answer to the client's CNXN, through the splice.
        let info = try await client.connect(timeout: .seconds(5))
        #expect(info.properties["ro.product.device"] == "avo_arm64")
        #expect(try await client.shell("echo hi").output == "hi\n")
        #expect(guests.count == 1)
        await client.close()
        await forwarder.update(enabled: false, port: Int(port))
    }

    @Test func anotherKeyNeverReachesAndroid() async throws {
        let guests = Guests()
        let (forwarder, port, keys) = try await forwarder(trusting: try ADBKey.generate(), guests: guests)
        defer { try? FileManager.default.removeItem(at: keys) }
        let client = ADBConnection(transport: FileDescriptorStream(fileDescriptor: try connect(port: port)), key: try ADBKey.generate(), keyComment: "app@mac")
        await #expect(throws: (any Error).self) { try await client.connect(timeout: .seconds(5)) }
        #expect(guests.count == 0)
        await client.close()
        await forwarder.update(enabled: false, port: Int(port))
    }
}

/// Against a running avo-vmm with Android booted (AVO_LIVE_TEST_VM, as
/// PauseLiveTests): the Android SDK's own adb reaches Android through ADB
/// support's port with the key it trusts, and with another key is refused.
/// A private adb server (its own port, its own key folders) leaves the
/// Mac's adb and ~/.android alone.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AVO_LIVE_TEST_VM"] != nil), .serialized)
struct ADBSupportLiveTests {
    private let adbPath = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Android/sdk/platform-tools/adb").path

    private func adb(_ arguments: [String], home: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: adbPath)
        process.arguments = ["-P", "5099"] + arguments
        // adb keeps its key in $HOME/.android; no emulator ports scanned.
        process.environment = ["HOME": home.path, "ADB_LOCAL_TRANSPORT_MAX_PORT": "5554"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test(.timeLimit(.minutes(2))) func theSDKsAdbNeedsTheTrustedKey() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["AVO_LIVE_TEST_VM"])
        #expect(FileManager.default.changeCurrentDirectoryPath(directory))
        let root = FileManager.default.temporaryDirectory.appending(path: "avo-adb-live-\(UUID())")
        let trusted = root.appending(path: "trusted"), stranger = root.appending(path: "stranger")
        for home in [trusted, stranger] {
            let keys = home.appending(path: ".android")
            try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
            #expect(try adb(["keygen", keys.appending(path: "adbkey").path], home: home).status == 0)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let forwarder = ADBForwarder(connectGuest: {
            try VsockBridge.connectSocket(socketPath: "runtime/vsock.sock", port: HostAgent.adbPort)
        }, trustedKeys: trusted.appending(path: ".android/adbkey.pub"))
        var port = 0
        for _ in 0..<20 {
            port = Int.random(in: 40000...60000)
            await forwarder.update(enabled: true, port: port)
            if case .listening = await forwarder.state { break }
        }
        let serial = "127.0.0.1:\(port)"

        _ = try adb(["connect", serial], home: trusted)
        let shell = try adb(["-s", serial, "shell", "echo through-avo"], home: trusted)
        #expect(shell.output.contains("through-avo"), "\(shell.output)")
        _ = try adb(["kill-server"], home: trusted)

        _ = try adb(["connect", serial], home: stranger)
        let refused = try adb(["-s", serial, "shell", "echo through-avo"], home: stranger)
        #expect(refused.status != 0 && !refused.output.contains("through-avo"), "\(refused.output)")
        _ = try adb(["kill-server"], home: stranger)
        await forwarder.update(enabled: false, port: port)
    }
}
