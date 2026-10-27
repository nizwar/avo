import AvoIO
import Foundation
import Security
import AvoADB

/// A scripted adbd on the other end of a socket pair: real message framing,
/// real RSA signature verification, shell v2, exec with stdin and sync push.
public actor FakeADBD {
    public enum AuthMode: Sendable {
        case none
        case signature
        /// Rejects the first signature and accepts once the public key arrives.
        case requirePublicKey
    }

    public struct Pushed: Equatable, Sendable {
        public let mode: String
        public let data: Data
    }

    public let stream: FileDescriptorStream
    private let publicKey: SecKey
    private let authMode: AuthMode
    private let maxPayload: UInt32
    private var decoder = ADBMessageDecoder()
    private var token = Data()
    private var nextID: UInt32 = 100
    private var execInputs: [UInt32: (command: String, expected: Int, received: Data)] = [:]
    private var syncBuffers: [UInt32: Data] = [:]
    private var remoteOf: [UInt32: UInt32] = [:]

    public var shellHandler: @Sendable (String) -> (stdout: String, stderr: String, exit: UInt8) = { _ in ("", "", 0) }
    /// An Android that stopped answering: services adbd never takes (no
    /// OKAY), and shell commands that start but never end.
    public var neverOpens: @Sendable (String) -> Bool = { _ in false }
    public var neverEnds: @Sendable (String) -> Bool = { _ in false }
    /// Why a push to a path fails (a full storage), or nil when it does not.
    public var pushFailure: @Sendable (String) -> String? = { _ in nil }
    public private(set) var shellCommands: [String] = []
    public private(set) var execWrites: [(command: String, data: Data)] = []
    public private(set) var pushed: [String: Pushed] = [:]
    public private(set) var receivedPublicKey: String?
    public private(set) var signaturesVerified = 0

    public init(fileDescriptor: Int32, publicKey: SecKey, authMode: AuthMode = .signature, maxPayload: UInt32 = 4096) {
        stream = FileDescriptorStream(fileDescriptor: fileDescriptor, label: "fake-adbd")
        self.publicKey = publicKey
        self.authMode = authMode
        self.maxPayload = maxPayload
    }

    public func setShellHandler(_ handler: @escaping @Sendable (String) -> (stdout: String, stderr: String, exit: UInt8)) {
        shellHandler = handler
    }

    public func setPushFailure(_ failure: @escaping @Sendable (String) -> String?) {
        pushFailure = failure
    }

    public func setStalls(neverOpens: @escaping @Sendable (String) -> Bool = { _ in false },
                          neverEnds: @escaping @Sendable (String) -> Bool = { _ in false }) {
        self.neverOpens = neverOpens
        self.neverEnds = neverEnds
    }

    public func run() async {
        do {
            for try await chunk in stream.incoming {
                decoder.append(chunk)
                while let message = try decoder.next() { try await handle(message) }
            }
        } catch {}
    }

    private func send(_ message: ADBMessage) async {
        try? await stream.write(message.encoded())
    }

    private func sendBanner() async {
        let banner = "device::ro.product.name=avo_arm64;ro.product.model=Avo Virtual Device;ro.product.device=avo_arm64;features=shell_v2,cmd,fixed_push_mkdir,stat_v2"
        await send(ADBMessage(.connect, ADBMessage.version, maxPayload, Data(banner.utf8)))
    }

    private func sendToken() async {
        token = Data((0..<20).map { _ in UInt8.random(in: 0...255) })
        await send(ADBMessage(.auth, ADBMessage.AuthType.token.rawValue, 0, token))
    }

    private func handle(_ message: ADBMessage) async throws {
        switch message.command {
        case .connect:
            if authMode == .none { await sendBanner() } else { await sendToken() }
        case .auth:
            switch ADBMessage.AuthType(rawValue: message.arg0) {
            case .signature:
                let valid = SecKeyVerifySignature(publicKey, .rsaSignatureDigestPKCS1v15SHA1,
                                                  token as CFData, message.payload as CFData, nil)
                if valid { signaturesVerified += 1 }
                if valid && authMode == .signature { await sendBanner() } else { await sendToken() }
            case .rsaPublicKey:
                receivedPublicKey = String(decoding: message.payload.prefix { $0 != 0 }, as: UTF8.self)
                await sendBanner()
            default:
                break
            }
        case .open:
            let service = String(decoding: message.payload.prefix { $0 != 0 }, as: UTF8.self)
            let local = nextID
            nextID += 1
            let remote = message.arg0
            remoteOf[local] = remote
            if neverOpens(service) { return }
            if service.hasPrefix("shell,v2,raw:") {
                await send(ADBMessage(.okay, local, remote))
                let command = String(service.dropFirst("shell,v2,raw:".count))
                shellCommands.append(command)
                if neverEnds(command) { return }
                let (out, err, code) = shellHandler(command)
                var payload = Data()
                func packet(_ id: UInt8, _ data: Data) {
                    payload.append(id)
                    withUnsafeBytes(of: UInt32(data.count).littleEndian) { payload.append(contentsOf: $0) }
                    payload.append(data)
                }
                if !out.isEmpty { packet(1, Data(out.utf8)) }
                if !err.isEmpty { packet(2, Data(err.utf8)) }
                packet(3, Data([code]))
                await send(ADBMessage(.write, local, remote, payload))
            } else if service.hasPrefix("exec:") {
                let command = String(service.dropFirst("exec:".count))
                let parts = command.split(separator: " ")
                let size = parts.firstIndex(of: "-S").flatMap { Int(parts[$0 + 1]) } ?? 0
                execInputs[local] = (command, size, Data())
                await send(ADBMessage(.okay, local, remote))
                if size == 0 { await finishExec(local) }
            } else if service == "sync:" {
                syncBuffers[local] = Data()
                await send(ADBMessage(.okay, local, remote))
            } else {
                await send(ADBMessage(.close, 0, remote))
            }
        case .write:
            let local = message.arg1
            guard let remote = remoteOf[local] else { return }
            precondition(message.payload.count <= Int(maxPayload), "client exceeded max payload")
            await send(ADBMessage(.okay, local, remote))
            if var exec = execInputs[local] {
                exec.received.append(message.payload)
                execInputs[local] = exec
                if exec.received.count >= exec.expected { await finishExec(local) }
            } else if syncBuffers[local] != nil {
                syncBuffers[local]!.append(message.payload)
                await processSync(local)
            }
        case .close:
            remoteOf[message.arg1] = nil
        default:
            break
        }
    }

    private func finishExec(_ local: UInt32) async {
        guard let exec = execInputs.removeValue(forKey: local), let remote = remoteOf[local] else { return }
        execWrites.append((exec.command, exec.received))
        let reply = exec.command.contains("install-write") ? "Success: streamed \(exec.received.count) bytes\n" : "ok\n"
        await send(ADBMessage(.write, local, remote, Data(reply.utf8)))
        await send(ADBMessage(.close, local, remote))
    }

    private var currentPath: (path: String, mode: String)?
    private var currentData = Data()

    private func processSync(_ local: UInt32) async {
        guard let remote = remoteOf[local] else { return }
        while var buffer = syncBuffers[local], buffer.count >= 8 {
            let id = String(decoding: buffer.prefix(4), as: UTF8.self)
            let b = buffer.startIndex
            let length = Int(buffer[b + 4]) | Int(buffer[b + 5]) << 8 | Int(buffer[b + 6]) << 16 | Int(buffer[b + 7]) << 24
            let bodyLength = id == "DONE" || id == "QUIT" ? 0 : length
            guard buffer.count >= 8 + bodyLength else { return }
            let body = buffer.subdata(in: (b + 8)..<(b + 8 + bodyLength))
            buffer.removeSubrange(b..<(b + 8 + bodyLength))
            syncBuffers[local] = buffer
            switch id {
            case "SEND":
                let spec = String(decoding: body, as: UTF8.self)
                let comma = spec.lastIndex(of: ",")!
                currentPath = (String(spec[..<comma]), String(spec[spec.index(after: comma)...]))
                currentData = Data()
            case "DATA":
                currentData.append(body)
            case "DONE":
                if let currentPath, let failure = pushFailure(currentPath.path) {
                    var fail = Data("FAIL".utf8)
                    withUnsafeBytes(of: UInt32(failure.utf8.count).littleEndian) { fail.append(contentsOf: $0) }
                    fail.append(Data(failure.utf8))
                    await send(ADBMessage(.write, local, remote, fail))
                    continue
                }
                if let currentPath { pushed[currentPath.path] = Pushed(mode: currentPath.mode, data: currentData) }
                var okay = Data("OKAY".utf8)
                okay.append(contentsOf: [0, 0, 0, 0])
                await send(ADBMessage(.write, local, remote, okay))
            case "QUIT":
                await send(ADBMessage(.close, local, remote))
                return
            default:
                return
            }
        }
    }
}
