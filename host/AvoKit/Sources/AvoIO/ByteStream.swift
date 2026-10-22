import Dispatch
import Foundation

public enum IOError: Error, Equatable, Sendable, CustomStringConvertible {
    case posix(op: String, code: Int32)
    case closed
    case timedOut(String)
    case handshake(String)
    case pathTooLong(String)

    public var description: String {
        switch self {
        case let .posix(op, code): "\(op): \(String(cString: strerror(code)))"
        case .closed: "stream closed"
        case .timedOut(let what): "\(what) timed out"
        case .handshake(let detail): "handshake failed: \(detail)"
        case .pathTooLong(let path): "socket path too long: \(path)"
        }
    }

    static func errno(_ op: String) -> IOError { .posix(op: op, code: Foundation.errno) }
}

/// A bidirectional byte stream with a single reader.
public protocol ByteStream: AnyObject, Sendable {
    /// Bytes as they arrive. Finishes at end of stream, throws on error.
    /// Only one task may iterate it.
    var incoming: AsyncThrowingStream<Data, any Error> { get }
    /// Writes all of `data`; writes complete in the order they were issued.
    func write(_ data: Data) async throws
    func close()
}

/// A ByteStream over a socket or pipe file descriptor, driven by DispatchIO.
public final class FileDescriptorStream: ByteStream, @unchecked Sendable {
    public let incoming: AsyncThrowingStream<Data, any Error>
    private let channel: DispatchIO
    private let queue: DispatchQueue

    /// Takes ownership of `fileDescriptor`; it is closed when the stream closes.
    public init(fileDescriptor: Int32, label: String = "com.avodroid.io") {
        Self.disableSIGPIPE(fileDescriptor)
        let queue = DispatchQueue(label: label)
        self.queue = queue
        channel = DispatchIO(type: .stream, fileDescriptor: fileDescriptor, queue: queue) { _ in
            Darwin.close(fileDescriptor)
        }
        channel.setLimit(lowWater: 1)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        incoming = stream
        channel.read(offset: 0, length: Int.max, queue: queue) { done, data, error in
            if let data, !data.isEmpty { continuation.yield(Data(data)) }
            if done {
                if error != 0 && error != ECANCELED {
                    continuation.finish(throwing: IOError.posix(op: "read", code: error))
                } else {
                    continuation.finish()
                }
            }
        }
    }

    public func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        let payload = data.withUnsafeBytes { DispatchData(bytes: $0) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            channel.write(offset: 0, data: payload, queue: queue) { done, _, error in
                guard done else { return }
                if error == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error == ECANCELED ? IOError.closed : IOError.posix(op: "write", code: error))
                }
            }
        }
    }

    public func close() {
        channel.close(flags: .stop)
    }

    /// Writes to a closed socket must fail with EPIPE instead of killing the process.
    static func disableSIGPIPE(_ fd: Int32) {
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }
}

/// Collects bytes from a ByteStream for protocols that read fixed-size frames.
public struct StreamReader {
    private var iterator: AsyncThrowingStream<Data, any Error>.AsyncIterator
    private var buffer = Data()

    public init(_ stream: any ByteStream) {
        iterator = stream.incoming.makeAsyncIterator()
    }

    /// Exactly `count` bytes, or `IOError.closed` if the stream ends first.
    public mutating func read(exactly count: Int) async throws -> Data {
        while buffer.count < count {
            guard let chunk = try await iterator.next() else { throw IOError.closed }
            buffer.append(chunk)
        }
        let result = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(result)
    }

    /// Whatever is buffered or the next chunk; nil at end of stream.
    public mutating func readAvailable() async throws -> Data? {
        if !buffer.isEmpty {
            defer { buffer.removeAll() }
            return buffer
        }
        return try await iterator.next()
    }
}
