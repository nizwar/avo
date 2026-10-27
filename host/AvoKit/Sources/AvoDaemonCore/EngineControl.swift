import AvoIO
import AvoKit
import Foundation

/// Client of avo-vmm's control socket (engine/hvf/vmm/src/control.rs): one
/// text command per line, answered with `ok` or `error <message>`.
public actor EngineControl {
    private let path: String
    private var stream: FileDescriptorStream?
    private var reader: LineReader?
    /// One command at a time: answers come back in order on one connection,
    /// and its reader must not be awaited by two tasks (the actor is
    /// reentrant at every await).
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(socketPath: String) {
        self.path = socketPath
    }

    private func connection() throws -> (FileDescriptorStream, LineReader) {
        if let stream, let reader { return (stream, reader) }
        let fd = try UnixSocket.connect(path: path)
        let stream = FileDescriptorStream(fileDescriptor: fd, label: "avo-vmm-control")
        let reader = LineReader(stream)
        self.stream = stream
        self.reader = reader
        return (stream, reader)
    }

    /// How long avo-vmm has to answer a command (its `pause` itself gives
    /// the vCPUs 5 s to stop).
    public static let commandTimeout: Duration = .seconds(15)

    /// Sends one command and waits for its answer; commands go in the order sent.
    public func send(_ command: String, timeout: Duration = EngineControl.commandTimeout) async throws {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        }
        busy = true
        defer {
            if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        }
        let (stream, reader) = try connection()
        // A command avo-vmm never answers would hold every one after it: its
        // connection closes (a late answer must not be taken for the next
        // command's), which ends the wait below. The Mac sleeping is no time it had.
        let started = SuspendingClock.now
        let timer = Task {
            try? await Task.sleep(for: timeout, clock: .suspending)
            if !Task.isCancelled { stream.close() }
        }
        defer { timer.cancel() }
        do {
            try await stream.write(Data((command + "\n").utf8))
            guard let line = try await reader.next() else { throw IOError.closed }
            if line.hasPrefix("error") {
                throw AvoError.internalError("avo-vmm: \(command): \(line.dropFirst(6))")
            }
        } catch {
            // A broken connection is reopened on the next command.
            if !(error is AvoError) {
                stream.close()
                if self.stream === stream {
                    self.stream = nil
                    self.reader = nil
                }
            }
            if SuspendingClock.now - started >= timeout { throw AvoError.timedOut("avo-vmm: \(command)") }
            throw error
        }
    }

    public func close() {
        stream?.close()
        stream = nil
        reader = nil
    }

    /// A separate connection that receives `frames` and `frame` events.
    public nonisolated func events() throws -> AsyncThrowingStream<String, any Error> {
        let fd = try UnixSocket.connect(path: path)
        let stream = FileDescriptorStream(fileDescriptor: fd, label: "avo-vmm-events")
        let reader = LineReader(stream)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await stream.write(Data("subscribe\n".utf8))
                    guard try await reader.next() == "ok" else { throw AvoError.internalError("avo-vmm refused the subscription") }
                    while let line = try await reader.next() {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                stream.close()
            }
            continuation.onTermination = { _ in
                task.cancel()
                stream.close()
            }
        }
    }
}

/// Splits a byte stream into lines.
final class LineReader: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<Data, any Error>.AsyncIterator
    private var buffer = Data()
    private let lock = NSLock()

    init(_ stream: any ByteStream) {
        iterator = stream.incoming.makeAsyncIterator()
    }

    /// The next line without its newline; nil at end of stream.
    func next() async throws -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0a) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            guard let chunk = try await iterator.next() else {
                if buffer.isEmpty { return nil }
                defer { buffer.removeAll() }
                return String(decoding: buffer, as: UTF8.self)
            }
            buffer.append(chunk)
        }
    }
}
