import Foundation

/// Android's Wi-Fi at a start: the "VirtWifi" access point that virt_wifi
/// makes of eth2 (engine/hvf/vmm/src/cuttlefish.rs), which is the engine's
/// network (net.rs).
///
/// Android joins a saved network by itself only while its network selection
/// lets it. A network whose check for internet access failed (Android asks
/// connectivitycheck.gstatic.com, which some countries block, or the Mac was
/// offline when it asked) is taken out of that selection, and the reason is
/// kept across restarts: from the next start on Android stays on "Wi-Fi on,
/// not connected" with VirtWifi saved, and only a connection asked for by
/// hand brings it back (issue #19). So at every start the join is checked:
/// a start that does not find Android on Wi-Fi after `grace` asks for
/// VirtWifi itself, as `cmd wifi connect-network` (what Settings does on a
/// tap: it also lets the network be selected again), and asks again with a
/// growing wait until Android is on it.
enum GuestWiFi {
    static let ssid = "VirtWifi"
    static let statusCommand = "cmd wifi status"
    static let scanResultsCommand = "cmd wifi list-scan-results"
    static let scanCommand = "cmd wifi start-scan"
    static let connectCommand = "cmd wifi connect-network \(ssid) open"

    enum Status: Equatable {
        case connected
        /// On, and joined to nothing.
        case disconnected
        case disabled
        /// No answer, or one this does not know.
        case unknown
    }

    /// `cmd wifi status`: "Wifi is enabled" / "Wifi is disabled", then
    /// "Wifi is connected to \"VirtWifi\"" or "Wifi is not connected".
    static func status(_ output: String?) -> Status {
        guard let output else { return .unknown }
        if output.contains("Wifi is connected") { return .connected }
        if output.contains("Wifi is disabled") { return .disabled }
        if output.contains("Wifi is enabled") || output.contains("Wifi is not connected") { return .disconnected }
        return .unknown
    }

    enum Outcome: Equatable {
        /// Android joined by itself (`asks` 0) or after Avo asked `asks` times.
        case joined(asks: Int)
        /// Wi-Fi stayed off in Android: the user turned it off there.
        case turnedOff
        case gaveUp
        case cancelled
    }

    struct Timing: Sendable {
        /// How long a start that has joined before waits for Android to join
        /// by itself before asking.
        var grace: Duration = .seconds(10)
        /// The wait before the first ask again; it doubles, up to `maxRetry`.
        var retry: Duration = .seconds(15)
        var maxRetry: Duration = .seconds(60)
        /// Looks while the start is young, then slower ones.
        var fastPoll: Duration = .seconds(1)
        var slowPoll: Duration = .seconds(3)
        var fastFor: Duration = .seconds(30)
        /// Wi-Fi still off this long after Avo turned it on: someone turned it off.
        var offFor: Duration = .seconds(30)
        var limit: Duration = .seconds(300)
    }

    /// Follows Android until it is on Wi-Fi. `firstTime`: this data disk has
    /// never been on VirtWifi, so there is nothing to join by itself and the
    /// first ask goes out as soon as Android sees the access point.
    /// `shell` returns nil when Android did not answer; `sleep` returns
    /// false once the wait was cancelled.
    static func join(isolation: isolated (any Actor)? = #isolation,
                     firstTime: Bool, timing: Timing = Timing(),
                     shell: (String) async -> String?,
                     sleep: (Duration) async -> Bool) async -> Outcome {
        var elapsed = Duration.zero
        var nextAsk = firstTime ? .zero : timing.grace
        var retry = timing.retry
        var asks = 0
        while elapsed <= timing.limit {
            switch status(await shell(statusCommand)) {
            case .connected:
                return .joined(asks: asks)
            case .disabled where elapsed >= timing.offFor:
                return .turnedOff
            case .disabled:
                break
            case .disconnected, .unknown:
                guard elapsed >= nextAsk else { break }
                if await shell(scanResultsCommand)?.contains(ssid) == true {
                    _ = await shell(connectCommand)
                    asks += 1
                    nextAsk = elapsed + retry
                    retry = min(retry * 2, timing.maxRetry)
                } else {
                    // Not seen yet: a scan finds it sooner than Android's own.
                    _ = await shell(scanCommand)
                    nextAsk = elapsed + timing.fastPoll * 2
                }
            }
            let poll = elapsed < timing.fastFor ? timing.fastPoll : timing.slowPoll
            guard await sleep(poll) else { return .cancelled }
            elapsed += poll
        }
        return .gaveUp
    }
}
