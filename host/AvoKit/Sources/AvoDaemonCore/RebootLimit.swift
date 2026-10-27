import Foundation

/// Android rebooting itself before it gets ready, again and again (a start
/// it cannot get through: a broken update of its own, a module that crashes
/// it): avo-vmm ends at each reboot and the daemon starts Android again
/// (`DaemonCore.androidRebooted`). Three such starts within ten minutes are
/// tried; the next reboot leaves Android stopped. Once Android is ready, its
/// reboots count anew.
struct RebootLimit: Sendable {
    static let starts = 3
    static let window: Duration = .seconds(10 * 60)

    /// The reboots since Android was last ready, within the window.
    private(set) var reboots: [ContinuousClock.Instant] = []

    /// A reboot at `now`: whether Android starts again.
    mutating func reboot(at now: ContinuousClock.Instant) -> Bool {
        reboots.removeAll { now - $0 >= Self.window }
        reboots.append(now)
        return reboots.count <= Self.starts
    }

    /// Android got ready (or stays stopped now).
    mutating func ready() {
        reboots.removeAll()
    }
}
