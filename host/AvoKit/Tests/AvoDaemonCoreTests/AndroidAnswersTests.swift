import AvoIO
import AvoKit
import AvoTestSupport
import Foundation
import Testing
@testable import AvoDaemonCore

/// The fake engine, telling when Android stops answering as avo-vmm's host agent does.
final class AnsweringEngine: ResponsivenessEngine, @unchecked Sendable {
    let base: FakeEngine
    let responsiveness: AsyncStream<Date?>
    private let sink: AsyncStream<Date?>.Continuation

    init(_ base: FakeEngine) {
        self.base = base
        (responsiveness, sink) = AsyncStream.makeStream(of: Date?.self)
    }

    var name: String { base.name }
    var exits: AsyncStream<(any Error)?> { base.exits }
    func start(_ launch: EngineLaunch) async throws { try await base.start(launch) }
    func stop() async { await base.stop() }
    func snapshot(to url: URL) async throws { try await base.snapshot(to: url) }
    func connect(port: UInt32) async throws -> any ByteStream { try await base.connect(port: port) }

    func report(notRespondingSince since: Date?) { sink.yield(since) }
}

@Suite struct GuestAnswersTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// One question left unanswered is a slow moment; two in a row is an
    /// Android that stopped answering, since the first of them.
    @Test func twoUnansweredQuestionsInARowAreAnAndroidNotResponding() {
        var answers = GuestAnswers()
        #expect(answers.record(answered: false, askedAt: start) == nil)
        #expect(answers.record(answered: true, askedAt: start + 15) == nil, "it answered again in time")
        #expect(answers.record(answered: false, askedAt: start + 30) == nil)
        #expect(answers.record(answered: false, askedAt: start + 45) == .notResponding(since: start + 30))
        // Said once, not at every question after.
        #expect(answers.record(answered: false, askedAt: start + 60) == nil)
        #expect(answers.record(answered: true, askedAt: start + 75) == .responding)
        #expect(answers.record(answered: true, askedAt: start + 90) == nil)
    }

    /// A paused Android answers nothing: the count starts over after it.
    @Test func aPauseStartsTheCountOver() {
        var answers = GuestAnswers()
        _ = answers.record(answered: false, askedAt: start)
        answers.reset()
        #expect(answers.record(answered: false, askedAt: start + 60) == nil)
        #expect(answers.record(answered: false, askedAt: start + 75) == .notResponding(since: start + 60))
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct AndroidNotRespondingTests {
    /// The status says so while Android runs, so the Control Panel can offer
    /// a Restart, and the questions windows and Settings ask at once do not
    /// wait on Android meanwhile.
    @Test func theStatusTellsWhenAndroidStopsAnswering() async throws {
        var answering: AnsweringEngine?
        let harness = try Harness(apps: [], wrap: { base in
            let engine = AnsweringEngine(base)
            answering = engine
            return engine
        })
        defer { harness.cleanUp() }
        let engine = try #require(answering)
        await harness.core.start()
        let (panel, events) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        #expect(await harness.core.status().notRespondingSince == nil)

        let since = Date(timeIntervalSinceNow: -30)
        engine.report(notRespondingSince: since)
        #expect(await eventually { await harness.core.status().notRespondingSince == since })
        #expect(await harness.core.status().isNotResponding)
        // Clients hear of it (XPC carries the date to the second).
        #expect(await events.wait { event in
            guard case .vmStatus(let status) = event, let date = status.notRespondingSince else { return false }
            return abs(date.timeIntervalSince(since)) < 1
        } != nil)
        _ = await harness.core.configurationSnapshot()

        engine.report(notRespondingSince: nil)
        #expect(await eventually { await harness.core.status().notRespondingSince == nil })

        // A report that comes after Android stopped is no status of a stopped Android.
        try await harness.core.stopVM(client: panel)
        engine.report(notRespondingSince: since)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await harness.core.status().notRespondingSince == nil)
        #expect(await harness.core.status().state == .stopped)
    }
}
