import Foundation

/// Bridges a synchronous producer (reading and inflating a ZIP entry) to an
/// async consumer (writing to the guest) with backpressure: the producer
/// blocks while `capacity` chunks are waiting, so a multi-gigabyte OBB never
/// sits in memory.
public final class ChunkPipe: AsyncSequence, @unchecked Sendable {
    public typealias Element = Data

    private let lock = NSLock()
    private var chunks: [Data] = []
    private var waiter: CheckedContinuation<Data?, any Error>?
    private var completion: Result<Void, any Error>?
    private var cancelled = false
    private let space: DispatchSemaphore
    private let capacity: Int

    /// Starts `produce` on its own thread. `send` blocks when the pipe is full
    /// and throws `CancellationError` once the consumer has gone away.
    public init(capacity: Int = 4, produce: @escaping @Sendable (_ send: (Data) throws -> Void) throws -> Void) {
        self.capacity = capacity
        space = DispatchSemaphore(value: capacity)
        let thread = Thread { [self] in
            do {
                try produce { try self.push($0) }
                self.finish(.success(()))
            } catch {
                self.finish(.failure(error))
            }
        }
        thread.name = "com.avodroid.chunkpipe"
        thread.start()
    }

    private func push(_ data: Data) throws {
        space.wait()
        lock.lock()
        if cancelled {
            lock.unlock()
            throw CancellationError()
        }
        if let waiter {
            self.waiter = nil
            lock.unlock()
            space.signal()
            waiter.resume(returning: data)
        } else {
            chunks.append(data)
            lock.unlock()
        }
    }

    private func finish(_ result: Result<Void, any Error>) {
        lock.lock()
        completion = completion ?? result
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        guard let waiter else { return }
        switch result {
        case .success: waiter.resume(returning: nil)
        case .failure(let error): waiter.resume(throwing: error)
        }
    }

    /// Stops the producer (it sees CancellationError on its next send).
    public func cancel() {
        lock.lock()
        cancelled = true
        let waiter = self.waiter
        self.waiter = nil
        chunks.removeAll()
        lock.unlock()
        for _ in 0...capacity { space.signal() }
        waiter?.resume(throwing: CancellationError())
    }

    func next() async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
                lock.lock()
                if !chunks.isEmpty {
                    let chunk = chunks.removeFirst()
                    lock.unlock()
                    space.signal()
                    continuation.resume(returning: chunk)
                } else if let completion {
                    lock.unlock()
                    switch completion {
                    case .success: continuation.resume(returning: nil)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                } else if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            cancel()
        }
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let pipe: ChunkPipe
        public mutating func next() async throws -> Data? { try await pipe.next() }
    }

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(pipe: self) }

    /// The pipe as an AsyncThrowingStream (pull-driven, keeps backpressure).
    public func stream() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream(unfolding: { [self] in try await self.next() })
    }
}
