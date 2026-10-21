import AvoKit
import Foundation
import os

/// The Mac's Bluetooth LE devices for Android (docs/engine.md, "Bluetooth").
/// Android's controller is a chip in netsim's virtual air; while Android's
/// Bluetooth is on, the Mac scans (MacBluetooth) and each device worth
/// showing gets a chip of its own in the same air (BLEProxyChip), so
/// Android's apps find it, connect to it and use its GATT services through
/// the Mac. Classic Bluetooth (headsets, older controllers) has no way
/// through: macOS lets apps reach LE devices only.
///
/// At most `limit` devices at a time, the first worth showing as they come:
/// a named device, or one with services or data apps look for, not Apple's
/// own Continuity chatter. A device the Mac has not heard for `stale` goes
/// away again, unless Android is connected to it.
actor MacBluetoothBridge {
    static let limit = 12
    static let stale: Duration = .seconds(30)

    private struct Proxy {
        let chip: BLEProxyChip
        var lastSeen: ContinuousClock.Instant
    }

    private let port: UInt16
    private var bluetooth: MacBluetooth?
    /// Android's Bluetooth is on, Settings › Devices shares the Mac's devices,
    /// and both together (the Mac scans only then).
    private var androidOn = false
    private var sharing: Bool
    private var on = false
    private var proxies: [UUID: Proxy] = [:]
    /// Devices whose chip is being set up.
    private var starting: Set<UUID> = []
    private var pruning: Task<Void, Never>?
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Bluetooth")

    /// `port`: netsimd's HCI port (avo-vmm's `bluetooth hci` event).
    init(port: UInt16, sharing: Bool = true) {
        self.port = port
        self.sharing = sharing
    }

    /// Android's Bluetooth turned on or off: the Mac scans only meanwhile.
    func setAndroidBluetooth(_ on: Bool) async {
        androidOn = on
        await apply()
    }

    /// Settings › Devices › Share this Mac's Bluetooth devices.
    func setSharing(_ on: Bool) async {
        sharing = on
        await apply()
    }

    private func apply() async {
        let on = androidOn && sharing
        guard on != self.on else { return }
        self.on = on
        if on {
            let bluetooth = self.bluetooth ?? MacBluetooth { [weak self] id, advertisement, rssi in
                Task { await self?.seen(id, advertisement, rssi: rssi) }
            }
            self.bluetooth = bluetooth
            bluetooth.startScanning()
            pruning = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    await self?.prune()
                }
            }
            logger.notice("bluetooth: Android's Bluetooth is on; the Mac shares its LE devices")
        } else {
            bluetooth?.stopScanning()
            pruning?.cancel()
            pruning = nil
            let chips = proxies.values.map(\.chip)
            proxies = [:]
            for chip in chips { await chip.close() }
        }
    }

    func stop() async {
        androidOn = false
        await apply()
    }

    /// Whether Android would care about this device.
    static func isWorthShowing(_ advertisement: BLEAdvertisement) -> Bool {
        if advertisement.isAppleContinuity { return false }
        return advertisement.name?.isEmpty == false || !advertisement.serviceUUIDs.isEmpty
            || !advertisement.serviceData.isEmpty || advertisement.manufacturerData != nil
    }

    private func seen(_ id: UUID, _ advertisement: BLEAdvertisement, rssi: Int) async {
        guard on else { return }
        if var proxy = proxies[id] {
            proxy.lastSeen = .now
            proxies[id] = proxy
            await proxy.chip.update(advertisement)
            return
        }
        guard !starting.contains(id), proxies.count + starting.count < Self.limit, Self.isWorthShowing(advertisement),
              let bluetooth else { return }
        starting.insert(id)
        defer { starting.remove(id) }
        do {
            let chip = BLEProxyChip(chip: try HCIChip.connect(port: port), id: id, advertisement: advertisement) {
                bluetooth.link(to: id)
            }
            try await chip.start()
            guard on else { return await chip.close() }
            proxies[id] = Proxy(chip: chip, lastSeen: .now)
            logger.debug("bluetooth: \(advertisement.name ?? id.uuidString, privacy: .public) is in Android's air")
        } catch {
            logger.error("bluetooth: no chip for \(advertisement.name ?? id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func prune() async {
        let now = ContinuousClock.now
        for (id, proxy) in proxies where now - proxy.lastSeen > Self.stale {
            guard await !proxy.chip.isConnected else { continue }
            proxies[id] = nil
            await proxy.chip.close()
        }
    }
}
