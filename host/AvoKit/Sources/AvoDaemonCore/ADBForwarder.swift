import AvoIO
import AvoKit
import Foundation
import os

/// "ADB support" (System settings): a TCP port on the Mac's loopback that
/// leads to adbd inside Android, so adb, Android Studio or scrcpy on the
/// Mac can control Avo. On port 5555 adb finds it by itself (it scans
/// 5555–5585 for emulators) and lists it as emulator-5554.
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
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "ADB")

    init(connectGuest: @escaping @Sendable () async throws -> Int32) {
        self.connectGuest = connectGuest
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
        do {
            // adb sees a closed connection while Android is off and retries.
            let guest = try await connectGuest()
            let splice = SocketSplice(socket, guest, name: "com.avodroid.adb.splice")
            let id = ObjectIdentifier(splice)
            splices[id] = splice
            // Forget it once both sockets are closed (checked lazily).
            prune()
        } catch {
            close(socket)
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
