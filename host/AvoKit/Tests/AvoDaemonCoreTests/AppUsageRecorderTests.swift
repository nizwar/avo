import AvoKit
import AvoTestSupport
import Foundation
import Testing
@testable import AvoDaemonCore

@Suite struct AppUsageRecorderTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Pontianak")!
        calendar.firstWeekday = 2
        return calendar
    }()

    static func date(_ day: Int, _ hour: Int, _ minute: Int = 0, second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
    }

    static let game = "com.garena.game.df"

    @Test func timeOnScreenMakesSessions() throws {
        var recorder = AppUsageRecorder(url: nil, calendar: Self.calendar)
        let start = Self.date(18, 10)
        recorder.opened(display: 1, package: Self.game, at: start)
        #expect(recorder.usage[Self.game]?.isOnScreen == true)
        #expect(recorder.anyOnScreen)
        // Minimized after 10 minutes, back 2 minutes later: the same session.
        recorder.visibility(display: 1, visible: false, at: start + 600)
        recorder.visibility(display: 1, visible: true, at: start + 720)
        recorder.closed(display: 1, at: start + 1320)
        let first = try #require(recorder.usage[Self.game])
        #expect(first.days == [AppUsage.Day(date: "2026-10-18", foregroundSeconds: 1200, sessions: 1)])
        #expect(first.lastOpened == start)
        #expect(first.lastActive == start + 1320)
        #expect(!first.isOnScreen && first.accountedUntil == nil)
        #expect(!recorder.anyOnScreen)

        // An hour later: a new session.
        recorder.opened(display: 2, package: Self.game, at: start + 4920)
        recorder.closed(display: 2, at: start + 5040)
        let second = try #require(recorder.usage[Self.game])
        #expect(second.days == [AppUsage.Day(date: "2026-10-18", foregroundSeconds: 1320, sessions: 2)])
        #expect(second.lastOpened == start + 4920)
    }

    @Test func windowsOfOneAppCountOnce() throws {
        var recorder = AppUsageRecorder(url: nil, calendar: Self.calendar)
        let start = Self.date(18, 10)
        recorder.opened(display: 1, package: Self.game, at: start)
        recorder.opened(display: 2, package: Self.game, at: start + 600)
        recorder.closed(display: 1, at: start + 1800)
        recorder.closed(display: 2, at: start + 2400)
        // Another app at the same time has its own time.
        recorder.opened(display: 3, package: "com.avodroid.hello", at: start + 300)
        recorder.visibility(display: 3, visible: false, at: start + 360)
        let game = try #require(recorder.usage[Self.game])
        #expect(game.days.first?.foregroundSeconds == 2400)
        #expect(game.days.first?.sessions == 1)
        #expect(recorder.usage["com.avodroid.hello"]?.days.first?.foregroundSeconds == 60)
        // Unknown displays and repeated states change nothing.
        recorder.visibility(display: 9, visible: true, at: start + 2500)
        recorder.closed(display: 9, at: start + 2500)
        recorder.visibility(display: 3, visible: false, at: start + 2500)
        #expect(recorder.usage["com.avodroid.hello"]?.days.first?.foregroundSeconds == 60)
    }

    @Test func framesCountWhileOnScreen() throws {
        var recorder = AppUsageRecorder(url: nil, calendar: Self.calendar)
        let start = Self.date(18, 20)
        recorder.opened(display: 1, package: Self.game, at: start)
        for _ in 0..<600 { recorder.framePresented(display: 1) }
        recorder.visibility(display: 1, visible: false, at: start + 10)
        for _ in 0..<50 { recorder.framePresented(display: 1) } // Android draws nothing anybody sees.
        recorder.visibility(display: 1, visible: true, at: start + 20)
        for _ in 0..<570 { recorder.framePresented(display: 1) }
        recorder.closed(display: 1, at: start + 30)
        recorder.framePresented(display: 1) // gone
        let day = try #require(recorder.usage[Self.game]?.days.first)
        #expect(day.frames == 1170)
        #expect(day.foregroundSeconds == 20)
    }

    @Test func flushingKeepsTimeAcrossMidnight() throws {
        var recorder = AppUsageRecorder(url: nil, calendar: Self.calendar)
        recorder.opened(display: 1, package: Self.game, at: Self.date(18, 23, 50))
        let changed = recorder.flush(at: Self.date(19, 0, 5))
        #expect(changed)
        let flushed = try #require(recorder.usage[Self.game])
        #expect(flushed.isOnScreen)
        #expect(flushed.accountedUntil == Self.date(19, 0, 5))
        #expect(flushed.days.map(\.foregroundSeconds) == [600, 300])
        #expect(recorder.lastFlush == Self.date(19, 0, 5))

        recorder.closed(display: 1, at: Self.date(19, 0, 20))
        let closed = try #require(recorder.usage[Self.game])
        #expect(closed.days == [AppUsage.Day(date: "2026-10-18", foregroundSeconds: 600, sessions: 1),
                                AppUsage.Day(date: "2026-10-19", foregroundSeconds: 1200, sessions: 0)])
        // What the Library shows: Sunday and Monday are in different weeks.
        let monday = closed.week(containing: Self.date(19, 12), now: Self.date(19, 12), calendar: Self.calendar)
        #expect(monday.seconds == 1200 && monday.sessions == 0)
    }

    @Test func androidStoppingClosesEveryWindow() {
        var recorder = AppUsageRecorder(url: nil, calendar: Self.calendar)
        let start = Self.date(18, 9)
        recorder.opened(display: 1, package: Self.game, at: start)
        recorder.opened(display: 2, package: "com.avodroid.hello", at: start)
        recorder.closedAll(at: start + 90)
        #expect(!recorder.anyOnScreen)
        #expect(recorder.usage.values.allSatisfy { !$0.isOnScreen && $0.days.first?.foregroundSeconds == 90 })
    }

    @Test func savedRecordsSurviveARestart() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "avo-usage-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "usage.json")
        var recorder = AppUsageRecorder(url: url, calendar: Self.calendar)
        let start = Self.date(18, 15)
        recorder.opened(display: 1, package: Self.game, at: start)
        recorder.flush(at: start + 120)
        recorder.save()
        #expect(!recorder.unsaved)

        // The daemon went away while the game was on screen: the time up to
        // the last flush stays, and its session ended there.
        let restarted = AppUsageRecorder(url: url, calendar: Self.calendar)
        let game = try #require(restarted.usage[Self.game])
        #expect(game.days == [AppUsage.Day(date: "2026-10-18", foregroundSeconds: 120, sessions: 1)])
        #expect(!game.isOnScreen)
        #expect(game.lastActive == start + 120)
        #expect(game.lastOpened == start)

        // A damaged file starts over instead of stopping the daemon.
        try Data("{".utf8).write(to: url)
        #expect(AppUsageRecorder(url: url, calendar: Self.calendar).usage.isEmpty)
    }

    @Test func oldDaysAndRemovedAppsGo() throws {
        var recorder = AppUsageRecorder(url: nil, calendar: Self.calendar)
        let start = Self.date(18, 10)
        recorder.opened(display: 1, package: Self.game, at: start)
        recorder.closed(display: 1, at: start + 60)
        // 200 days later the old day is dropped by the next flush.
        let later = Self.calendar.date(byAdding: .day, value: 200, to: start)!
        recorder.opened(display: 2, package: Self.game, at: later)
        recorder.flush(at: later + 30)
        let game = try #require(recorder.usage[Self.game])
        #expect(game.days.count == 1)
        #expect(game.days.first?.date == AppUsage.dayKey(later, calendar: Self.calendar))

        recorder.closed(display: 2, at: later + 60)
        recorder.opened(display: 3, package: "com.avodroid.hello", at: later + 60)
        recorder.forget(Self.game)
        #expect(recorder.usage[Self.game] == nil)
        #expect(recorder.usage["com.avodroid.hello"] != nil)
        recorder.forgetAll()
        #expect(recorder.usage.isEmpty)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct AppUsageDaemonTests {
    @Test func windowsBecomeUsageForTheControlPanel() async throws {
        let harness = try Harness(apps: [FakeBridgeAgent.app("org.fdroid.fdroid", label: "F-Droid")])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, events) = await harness.connect(.controlPanel)
        let (shim, _) = await harness.connect(.shim(package: "org.fdroid.fdroid"))

        let display = try await harness.core.openDisplay(OpenDisplayRequest(package: "org.fdroid.fdroid", width: 824, height: 1784, dpi: 320),
                                                         client: shim)
        // The Control Panel hears that F-Droid is on screen.
        #expect(await events.wait { event in
            if case .appUsage(let list) = event { list.contains { $0.package == "org.fdroid.fdroid" && $0.isOnScreen } } else { false }
        } != nil)
        for _ in 0..<5 { await harness.core.enginePresent(display, surfaceIndex: 0, sequence: 1) }
        try await Task.sleep(for: .milliseconds(30))
        await harness.core.setDisplayVisible(display, visible: false, client: shim)

        let usage = try #require(try await harness.core.appUsage(client: panel).first { $0.package == "org.fdroid.fdroid" })
        #expect(usage.lastOpened != nil)
        #expect(!usage.isOnScreen)
        let day = try #require(usage.days.first)
        #expect(day.sessions == 1)
        #expect(day.foregroundSeconds > 0)
        #expect(day.frames == 5)

        // Saved next to the other daemon state.
        let saved = try AvoXPC.decode([AppUsage].self, from: Data(contentsOf: harness.paths.usage))
        #expect(saved.map(\.package) == ["org.fdroid.fdroid"])
        #expect(saved.first?.days.first?.sessions == 1)

        // Only the Control Panel asks.
        await #expect(throws: AvoError.unauthorizedCaller) { try await harness.core.appUsage(client: shim) }

        // Uninstalling the app forgets its usage.
        await harness.core.disconnect(shim)
        try await harness.core.uninstall("org.fdroid.fdroid", client: panel)
        #expect(await eventually { (try? await harness.core.appUsage(client: panel))?.isEmpty == true })
    }

    /// A window out of sight is minimized; one run in the background (its
    /// blue light) is in the background, as the menu bar and Library say.
    @Test func runningInTheBackgroundIsNotMinimized() async throws {
        let harness = try Harness(apps: [FakeBridgeAgent.app("org.fdroid.fdroid", label: "F-Droid")])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (shim, _) = await harness.connect(.shim(package: "org.fdroid.fdroid"))
        let display = try await harness.core.openDisplay(OpenDisplayRequest(package: "org.fdroid.fdroid", width: 824, height: 1784, dpi: 320),
                                                         client: shim)
        await harness.core.setDisplayVisible(display, visible: false, client: shim)
        #expect(await harness.core.appActivity()["org.fdroid.fdroid"] == .minimized)
        await harness.core.setDisplayInBackground(display, inBackground: true, client: shim)
        #expect(await harness.core.appActivity()["org.fdroid.fdroid"] == .background)
        await harness.core.setDisplayInBackground(display, inBackground: false, client: shim)
        await harness.core.setDisplayVisible(display, visible: true, client: shim)
        #expect(await harness.core.appActivity()["org.fdroid.fdroid"] == .open)
    }
}
