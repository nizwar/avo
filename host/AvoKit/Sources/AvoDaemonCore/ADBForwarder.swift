import AvoADB
import AvoIO
import AvoKit
import Foundation
import os

/// "ADB support" (System settings): a TCP port on the Mac's loopback that
/// leads to adbd inside Android, so adb, Android Studio or scrcpy on the
/// Mac can control Avo. On port 5555 adb finds it by itself (it scans
/// 5555–5585 for emulators) and lists it as emulator-5554.
///
/// adbd inside Android asks no key, and any app on the Mac can reach the
/// port: a client goes on only once it has signed a token with adb's own
/// key on this Mac, which adb, Android Studio and scrcpy share
/// (ADBAuthGate). Its CNXN then goes to adbd, which answers it.
actor ADBForwarder {
    enum State: Equatable, Sendable {
        case off
        case listening(port: Int)
        case failed(port: Int, String)
    }

    private(set) var state = State.off
    private var listener: LoopbackListener?
    private var splices: [ObjectIdentifier: SocketSplice] = [:]
    private let connectGuest: @Sendable () async throws -> Int32
    /// Read for each connection: adb makes it the first time it runs.
    private let trustedKeys: URL
    /// Refused keys, said once each (adb's server looks for emulators
    /// every few seconds).
    private var refusedKeys: Set<String> = []
    /// Handshakes under way, each on a thread of its own for up to
    /// `ADBAuthGate`'s 10 seconds: past `maxHandshakes`, a new connection
    /// is closed at once.
    private var handshakes = 0
    private static let maxHandshakes = 8
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "ADB")

    init(connectGuest: @escaping @Sendable () async throws -> Int32,
         trustedKeys: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".android/adbkey.pub")) {
        self.connectGuest = connectGuest
        self.trustedKeys = trustedKeys
    }

    /// Listens on `port` when enabled; closes the port (and the
    /// connections through it) when disabled.
    func update(enabled: Bool, port: Int) {
        let wanted: Int? = enabled ? port : nil
        if case .listening(let current) = state, current == wanted { return }
        listener?.close()
        listener = nil
        for splice in splices.values { splice.cancel() }
        splices.removeAll()
        guard let port = wanted, let tcpPort = UInt16(exactly: port) else {
            state = .off
            return
        }
        do {
            listener = try LoopbackListener(port: tcpPort, label: "com.avodroid.adb") { [weak self] socket in
                Task { await self?.accepted(socket) }
            }
            state = .listening(port: port)
            logger.notice("ADB support listening on 127.0.0.1:\(port)")
        } catch {
            let message = String(localized: "Port \(port) is already in use by another app. Choose another port.", bundle: .avoKit)
            state = .failed(port: port, message)
            logger.error("ADB support cannot listen on \(port): \(String(describing: error), privacy: .public)")
        }
    }

    private func accepted(_ socket: Int32) async {
        guard listener != nil else {
            close(socket)
            return
        }
        guard handshakes < Self.maxHandshakes else {
            close(socket)
            return
        }
        let keys = ADBPublicKey.load(from: trustedKeys)
        handshakes += 1
        let admission: ADBAuthGate.Admission
        do {
            admission = try await Self.admit(socket, keys: keys)
            handshakes -= 1
        } catch {
            handshakes -= 1
            close(socket)
            refused(error as? ADBAuthGate.Refusal, keys: keys.count)
            return
        }
        // Turned off meanwhile.
        guard listener != nil else {
            close(socket)
            return
        }
        do {
            // adb sees a closed connection while Android is off and retries.
            let guest = try await connectGuest()
            guard Self.write(admission.connect.encoded(withChecksum: true) + admission.leftover, to: guest) else {
                close(socket)
                close(guest)
                return
            }
            let splice = SocketSplice(socket, guest, name: "com.avodroid.adb.splice")
            let id = ObjectIdentifier(splice)
            splices[id] = splice
            // Forget it once both sockets are closed (checked lazily).
            prune()
        } catch {
            close(socket)
        }
    }

    private func refused(_ refusal: ADBAuthGate.Refusal?, keys: Int) {
        switch refusal {
        case .unknownKey(let comment)?:
            guard refusedKeys.insert(comment).inserted else { return }
            logger.notice("ADB support refused a client whose key (\(comment, privacy: .public)) is not adb's on this Mac (\(keys) key(s) in ~/.android/adbkey.pub)")
        default:
            logger.info("ADB support closed a connection: \(String(describing: refusal), privacy: .public)")
        }
    }

    /// The handshake waits on the client's socket: on a thread of its own,
    /// not one the daemon's tasks share.
    private static func admit(_ socket: Int32, keys: [ADBPublicKey]) async throws -> ADBAuthGate.Admission {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                do {
                    continuation.resume(returning: try ADBAuthGate.admit(socket, keys: keys))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.name = "com.avodroid.adb.handshake"
            thread.start()
        }
    }

    /// Writes all of `data` to the guest's socket.
    private static func write(_ data: Data, to socket: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let count = Darwin.write(socket, buffer.baseAddress! + sent, buffer.count - sent)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }

    /// Connections through the port now (adb, Android Studio, scrcpy): Pause
    /// When Idle leaves Android running for them.
    func sessionCount() -> Int {
        prune()
        return splices.count
    }

    private func prune() {
        splices = splices.filter { !$0.value.isFinished }
    }
}
