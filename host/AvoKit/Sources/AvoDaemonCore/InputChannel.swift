import AvoIO
import AvoKit
import AvoProtocol
import Foundation

/// The daemon's end of the Input channel (vsock 6001). Records arrive already
/// encoded from App Shims; the daemon checks that each one is well formed and
/// targets a display the sender owns, then forwards the bytes unchanged.
public actor InputChannel {
    private let stream: any ByteStream
    public private(set) var version: UInt16?
    /// Last measured input round trip (PING record echo).
    public private(set) var lastRoundTrip: Duration?

    private var reader: Task<Void, Never>?
    private var preambleWaiter: CheckedContinuation<[UInt8], any Error>?
    private var earlyPreamble: [UInt8]?
    private var timer: Task<Void, Never>?
    private var pings: [UInt64: ContinuousClock.Instant] = [:]
    private var closed = false

    public init(stream: any ByteStream) {
        self.stream = stream
    }

    public func start(timeout: Duration = .seconds(5)) async throws {
        let stream = self.stream
        reader = Task { [weak self] in
            var buffer: [UInt8] = []
            var decoder: InputRecordDecoder?
            do {
                for try await chunk in stream.incoming {
                    if var active = decoder {
                        active.append(chunk)
                        while let record = try active.next() {
                            if case .ping(let token) = record { await self?.pong(token) }
                        }
                        decoder = active
                        continue
                    }
                    buffer += chunk
                    guard buffer.count >= 8 else { continue }
                    await self?.received(preamble: Array(buffer.prefix(8)))
                    var fresh = InputRecordDecoder()
                    fresh.append(buffer.dropFirst(8))
                    decoder = fresh
                }
            } catch {}
            await self?.close()
        }
        try await stream.write(Data(InputWire.preamble()))
        let peer: [UInt8] = try await withCheckedThrowingContinuation { continuation in
            if let earlyPreamble {
                continuation.resume(returning: earlyPreamble)
            } else if closed {
                continuation.resume(throwing: AvoError.guestUnavailable)
            } else {
                preambleWaiter = continuation
                timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.expirePreamble()
                }
            }
        }
        timer?.cancel()
        version = try InputWire.negotiate(peerPreamble: peer)
    }

    /// Validates and forwards one encoded record. `allowedDisplays` is the set
    /// of displays the sender owns.
    public func forward(_ bytes: Data, allowedDisplays: Set<UInt32>) async throws {
        guard version != nil, !closed else { throw AvoError.vmNotRunning }
        let array = [UInt8](bytes)
        guard let decoded = try InputWire.decode(array[...]), decoded.consumed == array.count, let record = decoded.record else {
            throw AvoError.internalError("malformed input record")
        }
        switch record {
        case .ping:
            throw AvoError.unauthorizedCaller
        default:
            guard let display = Self.displayID(of: record), allowedDisplays.contains(display) else {
                throw AvoError.unauthorizedCaller
            }
        }
        try await stream.write(bytes)
    }

    /// Sends a ping record; the echo updates `lastRoundTrip`.
    public func ping() async throws {
        let token = UInt64.random(in: 1...UInt64.max)
        pings[token] = .now
        try await stream.write(Data(InputWire.encode(.ping(token: token))))
    }

    public func close() {
        guard !closed else { return }
        closed = true
        reader?.cancel()
        timer?.cancel()
        preambleWaiter?.resume(throwing: AvoError.guestUnavailable)
        preambleWaiter = nil
        stream.close()
    }

    private func received(preamble: [UInt8]) {
        if let preambleWaiter {
            preambleWaiter.resume(returning: preamble)
            self.preambleWaiter = nil
        } else {
            earlyPreamble = preamble
        }
    }

    private func expirePreamble() {
        preambleWaiter?.resume(throwing: AvoError.guestUnavailable)
        preambleWaiter = nil
    }

    private func pong(_ token: UInt64) {
        if let start = pings.removeValue(forKey: token) { lastRoundTrip = .now - start }
    }

    static func displayID(of record: InputRecord) -> UInt32? {
        switch record {
        case .touch(let e): e.displayID
        case .key(let e): e.displayID
        case .scroll(let e): e.displayID
        case .text(let display, _): display
        case .mouse(let e): e.displayID
        // Gamepads follow focus: the record names the key window's display,
        // and the guest unplugs the gamepad when that display goes away.
        case .gamepad(let state): state.displayID
        case .ping: nil
        }
    }
}
