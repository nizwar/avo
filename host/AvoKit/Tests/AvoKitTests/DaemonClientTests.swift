import Foundation
import os
import Testing
@testable import AvoKit

/// A daemon call answers its caller once (DaemonClient.answer), and at once
/// when the caller's task is cancelled, whatever the daemon does.
@Suite(.timeLimit(.minutes(1))) struct DaemonClientTests {
    /// XPC may call both the reply and the error handler: the first counts.
    @Test func aCallIsAnsweredOnce() async throws {
        let value: Int = try await DaemonClient.answer { once in
            once.resume(with: .success(7))
            once.resume(with: .failure(AvoError.daemonUnreachable("gone")))
        }
        #expect(value == 7)
    }

    /// A daemon that never answers holds a caller only until its task is
    /// cancelled (a time limit).
    @Test func aCancelledCallerStopsWaiting() async {
        let call = Task { () async throws -> Int in
            try await DaemonClient.answer { _ in }
        }
        try? await Task.sleep(for: .milliseconds(50))
        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
    }

    /// Cancelled before it began: the call is not made.
    @Test func aCallerCancelledAlreadyMakesNoCall() async {
        let made = OSAllocatedUnfairLock(initialState: false)
        let call = Task { () async throws -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DaemonClient.answer { once in
                made.withLock { $0 = true }
                once.resume(with: .success(1))
            }
        }
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(!made.withLock { $0 })
    }
}
