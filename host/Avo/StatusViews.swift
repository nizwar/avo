import AvoKit
import SwiftUI

extension VMState {
    var label: LocalizedStringKey {
        switch self {
        case .notInstalled: "Android not installed"
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: "Running"
        case .suspending: "Pausing"
        case .suspended: "Paused"
        case .stopping: "Stopping"
        case .failed: "Stopped with an error"
        }
    }

    var color: Color {
        switch self {
        case .running: .green
        case .starting, .stopping, .suspending: .orange
        case .failed: .red
        default: .secondary
        }
    }

    var isBusy: Bool { self == .starting || self == .stopping || self == .suspending }
}

/// Formats byte counts the way Finder does.
func formatBytes(_ bytes: Int64?) -> String {
    guard let bytes, bytes > 0 else { return "—" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
