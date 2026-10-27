import Foundation

/// How long the Mac slept between two looks: the time that passed
/// (ContinuousClock, which counts sleep) less the time it was awake
/// (SuspendingClock, which does not, like the counter Android's clock follows).
struct MacSleep: Sendable {
    private var passed = ContinuousClock.now
    private var awake = SuspendingClock.now

    /// The sleep since the last look (or since this was made), and a new look from now.
    mutating func slept(passed now: ContinuousClock.Instant = .now, awake awakeNow: SuspendingClock.Instant = .now) -> Duration {
        defer {
            passed = now
            awake = awakeNow
        }
        return max(.zero, (now - passed) - (awakeNow - awake))
    }
}
