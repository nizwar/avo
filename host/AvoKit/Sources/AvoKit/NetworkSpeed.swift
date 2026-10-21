import Foundation

/// How fast Android's network is (Settings › Devices › Network): the Mac's
/// own speed, or the typical speed and delay of a mobile network type, for
/// trying an app on a slow connection. avo-vmm limits the link between
/// Android and the Mac (`network`, engine/hvf/vmm/src/link.rs).
public enum NetworkSpeed: String, Codable, CaseIterable, Sendable {
    case full, nr, lte, hspa, umts, edge, gprs

    /// Down and up in kbit/s and the added round trip in ms (all 0: no limit).
    public var limits: (downKbps: Int, upKbps: Int, latencyMs: Int) {
        switch self {
        case .full: (0, 0, 0)
        case .nr: (200_000, 50_000, 20)
        case .lte: (30_000, 10_000, 50)
        case .hspa: (7_200, 2_000, 80)
        case .umts: (1_920, 384, 150)
        case .edge: (237, 118, 300)
        case .gprs: (80, 40, 500)
        }
    }

    /// avo-vmm's control command for it.
    public var engineCommand: String {
        let (down, up, latency) = limits
        return self == .full ? "network off" : "network \(down) \(up) \(latency)"
    }

    /// What a phone's status bar shows for it.
    public var badge: String {
        switch self {
        case .full: ""
        case .nr: "5G"
        case .lte: "4G"
        case .hspa: "H+"
        case .umts: "3G"
        case .edge: "E"
        case .gprs: "G"
        }
    }
}

/// The mobile network Android's modem is on (Settings › Devices › Mobile
/// network): what the status bar shows, and what apps read as the network
/// type. Its speed is Network speed's (NetworkSpeed), set on its own.
/// Android shows HSPA as 3G (its "H" needs a SystemUI overlay) and LTE as
/// 4G once the host agent set the SIM's carrier configuration.
public enum MobileNetworkType: String, Codable, CaseIterable, Sendable {
    case gprs, edge, umts, hspa, lte, nr

    /// What a phone's status bar shows for it.
    public var badge: String {
        switch self {
        case .gprs: "G"
        case .edge: "E"
        case .umts, .hspa: "3G"
        case .lte: "4G"
        case .nr: "5G"
        }
    }

    /// The network speed that usually goes with it.
    public var typicalSpeed: NetworkSpeed {
        switch self {
        case .gprs: .gprs
        case .edge: .edge
        case .umts: .umts
        case .hspa: .hspa
        case .lte: .lte
        case .nr: .nr
        }
    }
}

extension VMConfig {
    /// avo-vmm's control command for the modem: no SIM, or a SIM on this network.
    public var cellularCommand: String {
        cellularEnabled ? "cellular \(mobileNetworkType.rawValue) \(min(max(cellularSignal, 0), 4))" : "cellular off"
    }
}
