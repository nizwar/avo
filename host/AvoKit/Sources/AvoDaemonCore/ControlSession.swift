import AvoIO
import AvoKit
import AvoProtocol
import Foundation
import os

/// The daemon's end of the Control channel (vsock 6000) to the Bridge Agent.
///
/// Requests carry a request id and resolve when the matching `Reply` or typed
/// response arrives; everything else is delivered on `events`.
public actor ControlSession {
    public typealias Payload = Avo_V1_Envelope.OneOf_Payload

    public let events: AsyncStream<Payload>
    private let eventSink: AsyncStream<Payload>.Continuation
    private let stream: any ByteStream
    private let softwareVersion: String
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Control")

    private var decoder = ControlFrameDecoder()
    private var nextRequestID: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<Avo_V1_Envelope, any Error>] = [:]
    private var timers: [UInt64: Task<Void, Never>] = [:]
    private var helloWaiter: CheckedContinuation<Avo_V1_Hello, any Error>?
    private var receivedHello: Avo_V1_Hello?
    private var tasks: [Task<Void, Never>] = []
    private var closedError: (any Error)?
    /// Android is paused: the keepalive waits (`holdKeepalive`).
    private var keepaliveHeld = false
    private var keepaliveWaiter: CheckedContinuation<Void, Never>?

    public private(set) var guestHello: Avo_V1_Hello?
    public private(set) var negotiatedVersion: UInt32?

    public init(stream: any ByteStream, softwareVersion: String) {
        self.stream = stream
        self.softwareVersion = softwareVersion
        (events, eventSink) = AsyncStream.makeStream(of: Payload.self, bufferingPolicy: .bufferingNewest(1024))
    }

    /// Exchanges Hello messages and negotiates the protocol version.
    public func start(timeout: Duration = .seconds(10)) async throws -> Avo_V1_Hello {
        startReading()
        try await write(Avo_V1_Envelope(.hello(AvoProtocol.hostHello(softwareVersion: softwareVersion))))
        let hello: Avo_V1_Hello = try await withCheckedThrowingContinuation { continuation in
            // The guest may have answered while the write was in flight.
            if let receivedHello {
                continuation.resume(returning: receivedHello)
                return
            }
            if let closedError {
                continuation.resume(throwing: closedError)
                return
            }
            helloWaiter = continuation
            timers[0] = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expireHello()
            }
        }
        timers.removeValue(forKey: 0)?.cancel()
        switch AvoProtocol.negotiate(host: AvoProtocol.hostHello(softwareVersion: softwareVersion), guest: hello) {
        case .success(let version):
            negotiatedVersion = version
            guestHello = hello
            startKeepalive()
            return hello
        case .failure(let error):
            var goodbye = Avo_V1_Goodbye()
            goodbye.reason = .incompatibleVersion
            goodbye.message = error.description
            try? await write(Avo_V1_Envelope(.goodbye(goodbye)))
            close(error: AvoError.guestIncompatible(error.description))
            throw AvoError.guestIncompatible(error.description)
        }
    }

    /// Sends a request and waits for its reply. `Reply` messages with a
    /// non-OK status become errors.
    @discardableResult
    public func request(_ payload: Payload, timeout: Duration = .seconds(30)) async throws -> Avo_V1_Envelope {
        if let closedError { throw closedError }
        let id = nextRequestID
        nextRequestID += 1
        let envelope = Avo_V1_Envelope(payload, requestID: id)
        let reply: Avo_V1_Envelope = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timers[id] = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expire(id, AvoError.timedOut(envelope.payloadName))
            }
            Task { await self.writeOrFail(envelope, id: id) }
        }
        if case .reply(let result)? = reply.payload, result.status != .ok {
            throw Self.error(for: result)
        }
        return reply
    }

    /// Sends a message without waiting for a reply.
    public func send(_ payload: Payload) async throws {
        try await write(Avo_V1_Envelope(payload))
    }

    public func close(error: (any Error)? = nil) {
        guard closedError == nil else { return }
        let reason = error ?? AvoError.guestUnavailable
        closedError = reason
        helloWaiter?.resume(throwing: reason)
        helloWaiter = nil
        for continuation in pending.values { continuation.resume(throwing: reason) }
        pending.removeAll()
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
        eventSink.finish()
        for task in tasks { task.cancel() }
        keepaliveWaiter?.resume()
        keepaliveWaiter = nil
        stream.close()
    }

    public var isOpen: Bool { closedError == nil }

    /// While Android is paused the keepalive waits: a paused Android's agent
    /// has nothing to say, and pinging it would only wake the Mac.
    public func holdKeepalive(_ held: Bool) {
        keepaliveHeld = held
        guard !held, let waiter = keepaliveWaiter else { return }
        keepaliveWaiter = nil
        waiter.resume()
    }

    private func keepaliveTurn() async {
        guard keepaliveHeld, closedError == nil else { return }
        await withCheckedContinuation { keepaliveWaiter = $0 }
    }

    // MARK: Typed helpers

    public func listApps(includeIcons: Bool) async throws -> [Avo_V1_AppInfo] {
        var request = Avo_V1_ListApps()
        request.includeIcons = includeIcons
        let reply = try await self.request(.listApps(request), timeout: .seconds(60))
        guard case .appList(let list)? = reply.payload else { throw AvoError.internalError("expected AppList") }
        return list.apps
    }

    public func permissions(for package: String) async throws -> [Avo_V1_Permission] {
        var request = Avo_V1_GetPermissions()
        request.package = package
        let reply = try await self.request(.getPermissions(request))
        guard case .permissionList(let list)? = reply.payload else { throw AvoError.internalError("expected PermissionList") }
        return list.permissions
    }

    // MARK: Internals

    private func write(_ envelope: Avo_V1_Envelope) async throws {
        try await stream.write(ControlFraming.encode(envelope))
    }

    private func writeOrFail(_ envelope: Avo_V1_Envelope, id: UInt64) async {
        do {
            try await write(envelope)
        } catch {
            expire(id, error)
        }
    }

    private func expire(_ id: UInt64, _ error: any Error) {
        timers.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func expireHello() {
        helloWaiter?.resume(throwing: AvoError.timedOut("Bridge Agent hello"))
        helloWaiter = nil
    }

    private func startReading() {
        guard tasks.isEmpty else { return }
        let stream = self.stream
        tasks.append(Task { [weak self] in
            do {
                for try await chunk in stream.incoming {
                    guard let self else { return }
                    try await self.receive(chunk)
                }
                await self?.close(error: AvoError.guestUnavailable)
            } catch {
                await self?.close(error: error)
            }
        })
    }

    private func startKeepalive() {
        tasks.append(Task { [weak self] in
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, await self.isOpen else { return }
                await self.keepaliveTurn()
                guard await self.isOpen else { return }
                var ping = Avo_V1_Ping()
                ping.nonce = UInt64.random(in: 1...UInt64.max)
                do {
                    _ = try await self.request(.ping(ping), timeout: .seconds(5))
                    misses = 0
                } catch {
                    misses += 1
                    if misses >= 3 {
                        await self.close(error: AvoError.guestUnavailable)
                        return
                    }
                }
            }
        })
    }

    private func receive(_ chunk: Data) throws {
        decoder.append(chunk)
        while let envelope = try decoder.next() { handle(envelope) }
    }

    private func handle(_ envelope: Avo_V1_Envelope) {
        if envelope.requestID != 0, let continuation = pending.removeValue(forKey: envelope.requestID) {
            timers.removeValue(forKey: envelope.requestID)?.cancel()
            continuation.resume(returning: envelope)
            return
        }
        switch envelope.payload {
        case .hello(let hello)?:
            if let helloWaiter {
                helloWaiter.resume(returning: hello)
                self.helloWaiter = nil
            } else {
                receivedHello = hello
            }
        case .goodbye(let goodbye)?:
            logger.notice("guest said goodbye: \(goodbye.message, privacy: .public)")
            close(error: goodbye.reason == .incompatibleVersion ? AvoError.guestIncompatible(goodbye.message) : AvoError.guestUnavailable)
        case .ping(let ping)?:
            var pong = Avo_V1_Pong()
            pong.nonce = ping.nonce
            let reply = Avo_V1_Envelope(.pong(pong), requestID: envelope.requestID)
            Task { try? await self.write(reply) }
        case let payload?:
            eventSink.yield(payload)
        case nil:
            break
        }
    }

    static func error(for reply: Avo_V1_Reply) -> AvoError {
        switch reply.status {
        case .notFound: .packageNotFound(reply.message)
        case .unsupported: .internalError(String(localized: "Android does not support this: \(reply.message)", bundle: .avoKit))
        default: .internalError(reply.message.isEmpty ? String(localized: "Android reported an error.", bundle: .avoKit) : reply.message)
        }
    }
}
