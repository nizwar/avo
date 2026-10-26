import AvoKit
import SwiftUI

/// An app page's "This week": time on screen per day, against last week,
/// and the frame rate and sessions behind it (the daemon's AppUsage).
struct AppUsageCard: View {
    let usage: AppUsage?
    let palette: IconPalette
    /// Games show their frame rate; apps their last use.
    let isGame: Bool
    /// The numbers roll up from zero and the bars grow once the card is there.
    @State private var revealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Redraws once a minute while the app is on screen.
        TimelineView(.periodic(from: .now, by: usage?.isOnScreen == true ? 60 : 3600)) { context in
            content(now: context.date)
        }
        .onAppear { revealed = true }
        .animation(reduceMotion ? Haze.Motion.fade : Haze.Motion.count.delay(0.2), value: revealed)
    }

    /// Zero until revealed.
    private func shown(_ value: Double) -> Double { revealed || reduceMotion ? value : 0 }

    private func content(now: Date) -> some View {
        let calendar = Calendar.current
        let week = usage?.week(containing: now, now: now, calendar: calendar) ?? Self.emptyWeek(now: now, calendar: calendar)
        let previous = calendar.date(byAdding: .day, value: -7, to: now).flatMap { usage?.week(containing: $0, now: now, calendar: calendar) }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 4) {
                    Text("This week").font(.mona(15, 600))
                    HelpButton("This week", "Time with a window of the app on screen: open, not minimized, covered or on another Space. A return within five minutes continues the session.")
                }
                Spacer()
                Text(Self.range(week, calendar: calendar)).font(.mona(12)).foregroundStyle(Haze.textTertiary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(formatPlayTime(shown(week.seconds)))
                    .font(.hubot(34, 750))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: shown(week.seconds)))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let previous, let change = week.change(from: previous) {
                    Text(Self.changeText(change))
                        .font(.mona(12))
                        .foregroundStyle(change >= 0 ? Haze.positive : Haze.textTertiary)
                        .lineLimit(1)
                        .opacity(revealed ? 1 : 0)
                }
            }
            bars(week, calendar: calendar)
            HStack(alignment: .top, spacing: 10) {
                if isGame {
                    stat(week.averageFPS.map { Text("\(Int(shown($0).rounded())) FPS") } ?? Text(verbatim: "–"), "Average",
                         rolling: week.averageFPS.map(shown))
                } else {
                    stat(Text(usage?.lastUsed(now: now).map { formatAgo($0, now: now) } ?? "–"), "Last used")
                }
                stat(Text(Int(shown(Double(week.sessions))), format: .number), "Sessions", rolling: shown(Double(week.sessions)))
                stat(Text(week.secondsPerSession.map { formatPlayTime(shown($0)) } ?? "–"), "Per session",
                     rolling: week.secondsPerSession.map(shown))
            }
            .padding(.top, 4)
        }
    }

    /// A bar per day, the busiest in the app's colour.
    private func bars(_ week: UsageWeek, calendar: Calendar) -> some View {
        let top = max(week.days.map(\.seconds).max() ?? 0, 1)
        let busiest = week.busiestDay?.start
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return HStack(alignment: .bottom, spacing: 10) {
            ForEach(Array(week.days.enumerated()), id: \.element.id) { index, day in
                VStack(spacing: 6) {
                    // Each bar grows to its height, one after another.
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(day.start == busiest ? Haze.tint(palette.accent) : Haze.accent.opacity(0.55))
                        .frame(height: max(4, (shown(day.seconds) / top * 80).rounded()))
                        .animation(reduceMotion ? nil : Haze.Motion.count.delay(0.2 + Double(index) * 0.035), value: revealed)
                    Text(verbatim: symbols[calendar.component(.weekday, from: day.start) - 1])
                        .font(.mona(11))
                        .foregroundStyle(Haze.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .help(Text(day.start, format: .dateTime.weekday(.wide)) + Text(verbatim: ": ") + Text(formatPlayTime(day.seconds)))
            }
        }
        .frame(height: 104, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Time on screen per day"))
        .accessibilityValue(Text(week.days.map { "\($0.start.formatted(.dateTime.weekday(.wide))): \(formatPlayTime($0.seconds))" }.joined(separator: ", ")))
    }

    private func stat(_ value: Text, _ label: LocalizedStringKey, rolling number: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            value.font(.mona(18, 600)).lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(number.map { .numericText(value: $0) } ?? .identity)
            Text(label).font(.mona(12)).foregroundStyle(Haze.textTertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Mon – Sun" in the user's calendar.
    static func range(_ week: UsageWeek, calendar: Calendar) -> String {
        guard let first = week.days.first?.start, let last = week.days.last?.start else { return "" }
        let symbols = calendar.shortStandaloneWeekdaySymbols
        return "\(symbols[calendar.component(.weekday, from: first) - 1]) – \(symbols[calendar.component(.weekday, from: last) - 1])"
    }

    /// "+38% vs last week".
    static func changeText(_ change: Double) -> String {
        let percent = change.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always()))
        return String(localized: "\(percent) vs last week")
    }

    static func emptyWeek(now: Date, calendar: Calendar) -> UsageWeek {
        AppUsage(package: "").week(containing: now, now: now, calendar: calendar)
    }
}
