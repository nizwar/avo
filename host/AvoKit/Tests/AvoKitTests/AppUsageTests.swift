import Foundation
import Testing
@testable import AvoKit

@Suite struct AppUsageTests {
    /// Weeks start on Monday, in a fixed time zone with a daylight saving change.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        calendar.firstWeekday = 2
        return calendar
    }()

    static func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func dayKeysRoundTrip() {
        let calendar = Self.calendar
        #expect(AppUsage.dayKey(Self.date(18, 23, 59), calendar: calendar) == "2026-10-18")
        #expect(AppUsage.dayKey(Self.date(19, 0, 1), calendar: calendar) == "2026-10-19")
        #expect(AppUsage.date(ofDayKey: "2026-10-18", calendar: calendar) == Self.date(18))
        #expect(AppUsage.date(ofDayKey: "not a day", calendar: calendar) == nil)
    }

    @Test func timeIsCutAtMidnight() {
        let parts = AppUsage.split(from: Self.date(18, 23, 50), to: Self.date(19, 0, 20), calendar: Self.calendar)
        #expect(parts.map(\.day) == [Self.date(18), Self.date(19)])
        #expect(parts.map(\.seconds) == [600, 1200])
        // The night the clocks go back has 25 hours.
        let long = AppUsage.split(from: Self.date(25, 0, 0), to: Self.date(26, 0, 0), calendar: Self.calendar)
        #expect(long.map(\.seconds) == [25 * 3600])
        #expect(AppUsage.split(from: Self.date(18, 10), to: Self.date(18, 10), calendar: Self.calendar).isEmpty)
    }

    @Test func weekRunsFromTheFirstWeekday() {
        let usage = AppUsage(package: "com.garena.game.df", days: [
            AppUsage.Day(date: "2026-10-11", foregroundSeconds: 7200, sessions: 3, frames: 100), // Sunday before
            AppUsage.Day(date: "2026-10-12", foregroundSeconds: 24 * 60, sessions: 1, frames: 24 * 60 * 57),
            AppUsage.Day(date: "2026-10-16", foregroundSeconds: 90 * 60, sessions: 3, frames: 90 * 60 * 57),
            AppUsage.Day(date: "2026-10-18", foregroundSeconds: 42 * 60, sessions: 2, frames: 0),
        ])
        let week = usage.week(containing: Self.date(18, 12), now: Self.date(18, 12), calendar: Self.calendar)
        #expect(week.days.count == 7)
        #expect(week.days.first?.start == Self.date(12))
        #expect(week.days.last?.start == Self.date(18))
        #expect(week.days.map(\.seconds) == [1440, 0, 0, 0, 5400, 0, 2520])
        #expect(week.seconds == 9360)
        #expect(week.sessions == 6)
        #expect(week.secondsPerSession == 1560)
        // Frames per second only over the days that counted frames.
        #expect(week.averageFPS == 57)
        #expect(week.busiestDay?.start == Self.date(16))

        let previous = usage.week(containing: Self.date(11, 12), now: Self.date(18, 12), calendar: Self.calendar)
        #expect(previous.seconds == 7200)
        #expect(week.change(from: previous) == 0.3)
        // Nothing to compare with.
        let empty = UsageWeek(days: [])
        #expect(week.change(from: empty) == nil)
        #expect(empty.averageFPS == nil && empty.secondsPerSession == nil && empty.busiestDay == nil)
    }

    @Test func timeOnScreenNowCounts() {
        // On screen since 23:30, accounted until 23:40; it is 00:15 now.
        let usage = AppUsage(package: "com.avodroid.hello", days: [AppUsage.Day(date: "2026-10-14", foregroundSeconds: 600, sessions: 1)],
                             lastOpened: Self.date(14, 23, 30), lastActive: Self.date(14, 23, 30),
                             foregroundSince: Self.date(14, 23, 30), accountedUntil: Self.date(14, 23, 40))
        let now = Self.date(15, 0, 15)
        let week = usage.week(containing: now, now: now, calendar: Self.calendar)
        #expect(week.days[2].seconds == 600 + 1200) // Wednesday: accounted, then 20 minutes to midnight
        #expect(week.days[3].seconds == 900) // Thursday: 15 minutes
        #expect(usage.totalSeconds(now: now) == 2700)
        #expect(usage.isOnScreen)
        #expect(usage.lastUsed(now: now) == now)

        var closed = usage
        closed.foregroundSince = nil
        closed.accountedUntil = nil
        #expect(closed.totalSeconds(now: now) == 600)
        #expect(closed.lastUsed(now: now) == Self.date(14, 23, 30))
    }

    @Test func usageTravelsToTheControlPanel() throws {
        let usage = [AppUsage(package: "com.garena.game.df", days: [AppUsage.Day(date: "2026-10-18", foregroundSeconds: 61.5, sessions: 1, frames: 3500)],
                              lastOpened: Self.date(18, 9), lastActive: Self.date(18, 9, 1))]
        let event = DaemonEvent.appUsage(usage)
        #expect(try AvoXPC.decode(DaemonEvent.self, from: AvoXPC.encode(event)) == event)
        #expect(AvoPaths(home: URL(filePath: "/Users/me")).usage.path == "/Users/me/Library/Application Support/Avo/usage.json")
    }
}
