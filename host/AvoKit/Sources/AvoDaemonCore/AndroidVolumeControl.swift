import AvoKit
import Foundation

// MARK: - Android's media volume (Quick Settings, Settings › Devices)

/// An engine that reads and sets Android's media volume (VMMEngine:
/// HostAgent's `cmd media_session volume`).
protocol VolumeEngine: VMEngine {
    func mediaVolume() async throws -> AndroidVolume
    func setMediaVolume(_ level: Int) async throws -> AndroidVolume
}

extension DaemonCore {
    /// Android's media volume, every app's, for an App Shim's Quick
    /// Settings or the Control Panel; Android has to be running.
    public func androidVolume(client: ClientID) async throws -> AndroidVolume {
        try await volumeEngine(for: client).mediaVolume()
    }

    /// Sets Android's media volume, within its steps.
    public func setAndroidVolume(_ level: Int, client: ClientID) async throws -> AndroidVolume {
        try await volumeEngine(for: client).setMediaVolume(level)
    }

    private func volumeEngine(for client: ClientID) async throws -> any VolumeEngine {
        switch role(of: client) {
        case .controlPanel?, .shim?: break
        default: throw AvoError.unauthorizedCaller
        }
        guard await vm.status.state == .running else { throw AvoError.vmNotRunning }
        guard let engine = deps.engine as? any VolumeEngine else {
            throw AvoError.internalError(String(localized: "Avo cannot set this Android’s volume.", bundle: .avoKit))
        }
        return engine
    }
}
