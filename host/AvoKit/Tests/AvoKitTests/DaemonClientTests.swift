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

    /// A quick question the daemon never answers (it waits on an Android
    /// that stopped answering) ends at its time limit; an answer in time is
    /// the answer, and nothing comes after it.
    @Test func aQuickQuestionEndsAtItsTimeLimit() async throws {
        let started = ContinuousClock.now
        await #expect(throws: AvoError.timedOut(DaemonClient.timedOutOperation)) {
            let _: Int = try await DaemonClient.answer(timeout: .milliseconds(200)) { _ in }
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(AvoError.timedOut(DaemonClient.timedOutOperation).errorDescription == "Avo’s background service timed out.")

        let answered: Int = try await DaemonClient.answer(timeout: .milliseconds(200)) { once in once.resume(with: .success(3)) }
        #expect(answered == 3)
    }

    /// A question the daemon asks Android (an app's permissions, the widgets
    /// it offers) that runs out of time says Android did not respond: the
    /// daemon is there, Android is what kept it.
    @Test func aQuestionForAndroidThatRunsOutBlamesAndroid() async {
        await #expect(throws: AvoError.guestUnavailable) {
            let _: Int = try await DaemonClient.answer(timeout: .milliseconds(200), asksAndroid: true) { _ in }
        }
        #expect(AvoError.guestUnavailable.errorDescription == "Android did not respond.")
    }
}
