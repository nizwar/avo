import AvoKit
import Foundation

// MARK: - Shake (an app window's Device menu)

/// An engine that shakes the phone (VMMEngine: the engine's `shake`, which
/// swings Android's accelerometer for a second).
protocol ShakeEngine: VMEngine {
    func shake() async throws
}

extension DaemonCore {
    /// Shakes the phone for a second, for an App Shim's Device menu or the
    /// Control Panel; Android has to be running.
    public func shakeDevice(client: ClientID) async throws {
        switch role(of: client) {
        case .controlPanel?, .shim?: break
        default: throw AvoError.unauthorizedCaller
        }
        guard await vm.status.state == .running else { throw AvoError.vmNotRunning }
        guard let engine = deps.engine as? any ShakeEngine else {
            throw AvoError.internalError(String(localized: "This Android cannot be shaken.", bundle: .avoKit))
        }
        try await engine.shake()
    }
}
