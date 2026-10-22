import AvoIO
import Foundation
import os

/// A client connection to adbd over any byte stream (the guest's vsock port
/// 5555 in production). Streams are multiplexed with classic ADB flow control:
/// each WRTE waits for the peer's OKAY before the next one is sent.
public actor ADBConnection {
    public struct DeviceInfo: Sendable, Equatable {
        public let version: UInt32
        public let maxPayload: UInt32
        public let systemType: String
        public let properties: [String: String]
        public let features: Set<String>
    }

    /// Features we advertise. `delayed_ack` is deliberately absent: it switches
    /// adbd to windowed flow control, which this client does not implement.
    public static let hostFeatures = ["shell_v2", "cmd", "stat_v2", "ls_v2", "fixed_push_mkdir", "abb_exec", "abb"]

    private let transport: any ByteStream
    private let key: ADBKey
    private let keyComment: String
    private let logger = Logger(subsystem: "com.avodroid", category: "ADB")

    private var decoder = ADBMessageDecoder()
    private var outgoing: AsyncStream<Data>.Continuation?
    private var tasks: [Task<Void, Never>] = []
    private var handshake: CheckedContinuation<DeviceInfo, any Error>?
    private var signatureSent = false
    private var publicKeySent = false
    private(set) public var device: DeviceInfo?
    private var nextLocalID: UInt32 = 1
    private var streams: [UInt32: StreamState] = [:]
    private var failure: (any Error)?

    final class StreamState {
        let service: String
        var remoteID: UInt32?
        var opening: CheckedContinuation<Void, any Error>?
        var pendingWrite: CheckedContinuation<Void, any Error>?
        let inbox: AsyncThrowingStream<Data, any Error>.Continuation
        let incoming: AsyncThrowingStream<Data, any Error>

        init(service: String) {
            self.service = service
            (incoming, inbox) = AsyncThrowingStream.makeStream(of: Data.self)
        }
    }

    public init(transport: any ByteStream, key: ADBKey, keyComment: String = "avo@\(ProcessInfo.processInfo.hostName)") {
        self.transport = transport
        self.key = key
        self.keyComment = keyComment
    }

    // MARK: Lifecycle

    /// Performs the CNXN/AUTH handshake.
    public func connect(timeout: Duration = .seconds(30)) async throws -> DeviceInfo {
        if let device { return device }
        startIO()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.failHandshake(ADBError.handshakeTimedOut)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            handshake = continuation
            let banner = "host::features=" + Self.hostFeatures.joined(separator: ",")
            send(ADBMessage(.connect, ADBMessage.version, ADBMessage.maxPayload, Data(banner.utf8)))
        }
    }

    public func close() {
        fail(ADBError.connectionClosed)
        transport.close()
    }

    private func startIO() {
        guard tasks.isEmpty else { return }
        let (queue, continuation) = AsyncStream.makeStream(of: Data.self)
        outgoing = continuation
        let transport = self.transport
        tasks.append(Task { [weak self] in
            do {
                for await data in queue { try await transport.write(data) }
            } catch {
                await self?.fail(error)
            }
        })
        tasks.append(Task { [weak self] in
            do {
                for try await chunk in transport.incoming {
                    guard let self else { return }
                    try await self.receive(chunk)
                }
                await self?.fail(ADBError.connectionClosed)
            } catch {
                await self?.fail(error)
            }
        })
    }

    private func send(_ message: ADBMessage) {
        let legacy = (device?.version ?? ADBMessage.version) < ADBMessage.version
        outgoing?.yield(message.encoded(withChecksum: legacy))
    }

    private func fail(_ error: any Error) {
        guard failure == nil else { return }
        failure = error
        handshake?.resume(throwing: error)
        handshake = nil
        for state in streams.values {
            state.opening?.resume(throwing: error)
            state.pendingWrite?.resume(throwing: error)
            state.inbox.finish(throwing: error)
        }
        streams.removeAll()
        outgoing?.finish()
        for task in tasks { task.cancel() }
    }

    private func failHandshake(_ error: any Error) {
        guard handshake != nil else { return }
        fail(error)
    }

    // MARK: Incoming messages

    private func receive(_ chunk: Data) throws {
        decoder.append(chunk)
        while let message = try decoder.next() { try handle(message) }
    }

    private func handle(_ message: ADBMessage) throws {
        switch message.command {
        case .connect:
            let info = Self.parseBanner(message)
            device = info
            decoder.maxPayload = max(info.maxPayload, ADBMessage.maxPayload)
            handshake?.resume(returning: info)
            handshake = nil
        case .auth:
            guard message.arg0 == ADBMessage.AuthType.token.rawValue else { return }
            if !signatureSent {
                signatureSent = true
                send(ADBMessage(.auth, ADBMessage.AuthType.signature.rawValue, 0, try key.sign(token: message.payload)))
            } else if !publicKeySent {
                // Signature rejected: offer the public key (adbd may ask the user).
                publicKeySent = true
                let publicKey = try key.androidPublicKey(comment: keyComment) + "\0"
                send(ADBMessage(.auth, ADBMessage.AuthType.rsaPublicKey.rawValue, 0, Data(publicKey.utf8)))
            }
        case .okay:
            guard let state = streams[message.arg1] else { return }
            if state.remoteID == nil {
                state.remoteID = message.arg0
                state.opening?.resume()
                state.opening = nil
            } else {
                state.pendingWrite?.resume()
                state.pendingWrite = nil
            }
        case .write:
            guard let state = streams[message.arg1] else {
                send(ADBMessage(.close, 0, message.arg0))
                return
            }
            state.inbox.yield(message.payload)
            send(ADBMessage(.okay, message.arg1, message.arg0))
        case .close:
            guard let state = streams.removeValue(forKey: message.arg1) else { return }
            if let opening = state.opening {
                opening.resume(throwing: ADBError.streamRefused(state.service))
            }
            state.pendingWrite?.resume(throwing: ADBError.streamClosed)
            state.inbox.finish()
        case .sync, .open, .startTLS:
            throw ADBError.unexpected("\(message.command)")
        }
    }

    static func parseBanner(_ message: ADBMessage) -> DeviceInfo {
        let banner = String(decoding: message.payload.prefix { $0 != 0 }, as: UTF8.self)
        let parts = banner.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        var properties: [String: String] = [:]
        var features = Set<String>()
        if parts.count == 3 {
            for pair in parts[2].split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                if kv[0] == "features" {
                    features = Set(kv[1].split(separator: ",").map(String.init))
                } else {
                    properties[String(kv[0])] = String(kv[1])
                }
            }
        }
        return DeviceInfo(version: min(message.arg0, ADBMessage.version),
                          maxPayload: min(message.arg1, ADBMessage.maxPayload),
                          systemType: parts.first.map(String.init) ?? "",
                          properties: properties, features: features)
    }

    // MARK: Streams

    /// Opens a service such as `shell,v2,raw:ls`, `exec:cmd package list packages` or `sync:`.
    public func open(_ service: String) async throws -> ADBStream {
        if let failure { throw failure }
        guard device != nil else { throw ADBError.unexpected("open before connect") }
        let localID = nextLocalID
        nextLocalID &+= 1
        let state = StreamState(service: service)
        streams[localID] = state
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            state.opening = continuation
            send(ADBMessage(.open, localID, 0, Data((service + "\0").utf8)))
        }
        return ADBStream(connection: self, localID: localID, incoming: state.incoming)
    }

    func write(_ data: Data, localID: UInt32) async throws {
        let maxPayload = Int(device?.maxPayload ?? ADBMessage.maxPayload)
        var offset = data.startIndex
        while offset < data.endIndex {
            if let failure { throw failure }
            guard let state = streams[localID], let remoteID = state.remoteID else { throw ADBError.streamClosed }
            let end = min(offset + maxPayload, data.endIndex)
            let chunk = data.subdata(in: offset..<end)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                state.pendingWrite = continuation
                send(ADBMessage(.write, localID, remoteID, chunk))
            }
            offset = end
        }
    }

    func closeStream(localID: UInt32) {
        guard let state = streams.removeValue(forKey: localID) else { return }
        send(ADBMessage(.close, localID, state.remoteID ?? 0))
        state.pendingWrite?.resume(throwing: ADBError.streamClosed)
        state.inbox.finish()
    }

    public var maxPayload: Int { Int(device?.maxPayload ?? ADBMessage.maxPayload) }
}

/// One open ADB stream.
public final class ADBStream: Sendable {
    let connection: ADBConnection
    let localID: UInt32
    /// Data the device wrote to the stream; finishes when it closes the stream.
    public let incoming: AsyncThrowingStream<Data, any Error>

    init(connection: ADBConnection, localID: UInt32, incoming: AsyncThrowingStream<Data, any Error>) {
        self.connection = connection
        self.localID = localID
        self.incoming = incoming
    }

    public func write(_ data: Data) async throws {
        try await connection.write(data, localID: localID)
    }

    public func close() async {
        await connection.closeStream(localID: localID)
    }

    /// Reads until the device closes the stream.
    public func readAll(limit: Int = 64 << 20) async throws -> Data {
        var result = Data()
        for try await chunk in incoming {
            result.append(chunk)
            if result.count > limit { throw ADBError.unexpected("stream output exceeds \(limit) bytes") }
        }
        return result
    }
}
