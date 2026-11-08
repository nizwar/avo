import Foundation
import Testing
@testable import AvoDaemonCore

/// An Android Wi-Fi for GuestWiFi.join, on a clock that only the join's
/// sleeps move.
private final class FakeWiFi {
    var now = Duration.zero
    var commands: [(String, Duration)] = []
    /// When Android joins by itself (nil: never).
    var joinsAt: Duration?
    /// How long a join takes once asked (nil: never).
    var joinsAfterAsk: Duration?
    var askedAt: Duration?
    var scanSeenFrom = Duration.zero
    var enabledFrom = Duration.zero
    var turnedOffAt: Duration?

    func shell(_ command: String) -> String? {
        commands.append((command, now))
        switch command {
        case GuestWiFi.statusCommand:
            if let off = turnedOffAt, now >= off { return "Wifi is disabled\n" }
            guard now >= enabledFrom else { return "Wifi is disabled\n" }
            if let at = joinsAt, now >= at { return "Wifi is enabled\nWifi is connected to \"VirtWifi\"\n" }
            if let asked = askedAt, let after = joinsAfterAsk, now >= asked + after {
                return "Wifi is enabled\nWifi is connected to \"VirtWifi\"\n"
            }
            return "Wifi is enabled\nWifi is not connected\n"
        case GuestWiFi.scanResultsCommand:
            return now >= scanSeenFrom ? "BSSID  Frequency  RSSI  Age(sec)  SSID  Flags\n02:00:00:00:01:00  2437  -50  0.1  VirtWifi  [ESS]\n" : "\n"
        case GuestWiFi.connectCommand:
            if askedAt == nil { askedAt = now }
            return ""
        default:
            return ""
        }
    }

    var asks: [Duration] { commands.filter { $0.0 == GuestWiFi.connectCommand }.map(\.1) }

    func join(firstTime: Bool, cancelAfter: Duration? = nil) async -> GuestWiFi.Outcome {
        await GuestWiFi.join(firstTime: firstTime) { self.shell($0) } sleep: { duration in
            if let limit = cancelAfter, self.now >= limit { return false }
            self.now += duration
            return true
        }
    }
}

@MainActor
struct GuestWiFiTests {
    @Test func readsAndroidsStatus() {
        #expect(GuestWiFi.status("Wifi is enabled\nWifi is connected to \"VirtWifi\"\n") == .connected)
        #expect(GuestWiFi.status("Wifi is enabled\nWifi scanning is always available\nWifi is not connected\n") == .disconnected)
        #expect(GuestWiFi.status("Wifi is disabled\n") == .disabled)
        #expect(GuestWiFi.status(nil) == .unknown)
        #expect(GuestWiFi.status("cmd: Can't find service: wifi\n") == .unknown)
    }

    @Test func aStartThatJoinsByItselfIsLeftAlone() async {
        let wifi = FakeWiFi()
        wifi.joinsAt = .seconds(4)
        #expect(await wifi.join(firstTime: false) == .joined(asks: 0))
        #expect(wifi.asks.isEmpty)
    }

    /// Issue #19: Wi-Fi on, VirtWifi saved, and Android never joins it by itself again.
    @Test func aStartThatStaysDisconnectedAsksAfterTheGrace() async {
        let wifi = FakeWiFi()
        wifi.joinsAfterAsk = .seconds(8)
        #expect(await wifi.join(firstTime: false) == .joined(asks: 1))
        #expect(wifi.asks == [.seconds(10)])
    }

    @Test func asksAgainWithAGrowingWaitUntilAndroidJoins() async {
        let wifi = FakeWiFi()
        wifi.joinsAt = .seconds(100)
        #expect(await wifi.join(firstTime: false) == .joined(asks: 3))
        // 10 s of grace, then 15 s, then 30 s (the slow looks round up to 3 s).
        #expect(wifi.asks.count == 3)
        #expect(wifi.asks[0] == .seconds(10))
        #expect(wifi.asks[1] == .seconds(25))
        #expect(wifi.asks[2] >= .seconds(55) && wifi.asks[2] <= .seconds(58))
    }

    @Test func theFirstStartAsksAsSoonAsAndroidSeesTheAccessPoint() async {
        let wifi = FakeWiFi()
        wifi.scanSeenFrom = .seconds(3)
        wifi.joinsAfterAsk = .seconds(2)
        #expect(await wifi.join(firstTime: true) == .joined(asks: 1))
        #expect(wifi.asks == [.seconds(4)])
        #expect(wifi.commands.contains { $0.0 == GuestWiFi.scanCommand })
    }

    @Test func wiFiTurnedOnLateIsWaitedFor() async {
        let wifi = FakeWiFi()
        wifi.enabledFrom = .seconds(6)
        wifi.joinsAt = .seconds(8)
        #expect(await wifi.join(firstTime: false) == .joined(asks: 0))
    }

    @Test func wiFiTurnedOffInAndroidIsRespected() async {
        let wifi = FakeWiFi()
        wifi.turnedOffAt = .seconds(12)
        #expect(await wifi.join(firstTime: false) == .turnedOff)
        #expect(wifi.asks.count == 1)
    }

    @Test func givesUpAfterTheLimitAndStopsWhenCancelled() async {
        let never = FakeWiFi()
        #expect(await never.join(firstTime: false) == .gaveUp)
        #expect(never.now <= GuestWiFi.Timing().limit + .seconds(3))
        // About 5 minutes with a doubling wait capped at a minute: a handful of asks, not hundreds.
        #expect(never.asks.count >= 5 && never.asks.count <= 8)

        let cancelled = FakeWiFi()
        #expect(await cancelled.join(firstTime: false, cancelAfter: .seconds(5)) == .cancelled)
        #expect(cancelled.asks.isEmpty)
    }
}
