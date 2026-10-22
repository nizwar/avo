import AvoKit
import CoreBluetooth
import Foundation
import os

/// The Mac's Bluetooth LE central (CoreBluetooth) for MacBluetoothBridge:
/// it scans while Android's Bluetooth is on and reaches a device when
/// Android connects to its proxy chip. macOS asks the user for Bluetooth
/// the first time it starts (Avo.app is responsible for the daemon).
/// CoreBluetooth calls back on `queue`, where all of its state lives.
final class MacBluetooth: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.avodroid.bluetooth", qos: .userInitiated)
    private var central: CBCentralManager?
    private var wantsScan = false
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var links: [UUID: MacBluetoothLink] = [:]
    /// What went to the bridge last per device, and when: the same again
    /// goes at most once a second (scanning reports every advertisement).
    private var forwarded: [UUID: (advertisement: BLEAdvertisement, at: ContinuousClock.Instant)] = [:]
    private let onAdvertisement: @Sendable (UUID, BLEAdvertisement, Int) -> Void
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Bluetooth")

    init(onAdvertisement: @escaping @Sendable (UUID, BLEAdvertisement, Int) -> Void) {
        self.onAdvertisement = onAdvertisement
    }

    func startScanning() {
        queue.async { [self] in
            wantsScan = true
            if let central { scan(central) } else { central = CBCentralManager(delegate: self, queue: queue) }
        }
    }

    func stopScanning() {
        queue.async { [self] in
            wantsScan = false
            central?.stopScan()
        }
    }

    /// A new connection to device `id` (on `queue`'s side when used).
    func link(to id: UUID) -> MacBluetoothLink {
        MacBluetoothLink(bluetooth: self, id: id)
    }

    // MARK: Used by MacBluetoothLink, on `queue`

    func connect(_ link: MacBluetoothLink) -> CBPeripheral? {
        guard let central, central.state == .poweredOn else { return nil }
        let peripheral = peripherals[link.id] ?? central.retrievePeripherals(withIdentifiers: [link.id]).first
        guard let peripheral else { return nil }
        links[link.id] = link
        peripheral.delegate = link
        central.connect(peripheral)
        return peripheral
    }

    func disconnect(_ link: MacBluetoothLink, _ peripheral: CBPeripheral) {
        if links[link.id] === link { links[link.id] = nil }
        central?.cancelPeripheralConnection(peripheral)
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: scan(central)
        case .unauthorized: logger.notice("bluetooth: Avo may not use the Mac's Bluetooth (System Settings › Privacy & Security › Bluetooth)")
        case .poweredOff: logger.notice("bluetooth: the Mac's Bluetooth is off")
        default: break
        }
    }

    private func scan(_ central: CBCentralManager) {
        guard wantsScan, central.state == .poweredOn, !central.isScanning else { return }
        // Every advertisement, so names and data stay current.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        peripherals[peripheral.identifier] = peripheral
        let rssi = RSSI.intValue
        // 127: the Mac could not measure it.
        guard rssi < 127 else { return }
        let advertisement = Self.advertisement(advertisementData, name: peripheral.name)
        let now = ContinuousClock.now
        if let last = forwarded[peripheral.identifier], last.advertisement == advertisement, now - last.at < .seconds(1) { return }
        forwarded[peripheral.identifier] = (advertisement, now)
        onAdvertisement(peripheral.identifier, advertisement, rssi)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        links[peripheral.identifier]?.didConnect()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        links[peripheral.identifier]?.ended(error ?? ATTError.unlikelyError)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        links.removeValue(forKey: peripheral.identifier)?.ended(error ?? ATTError.unlikelyError)
    }

    /// CoreBluetooth's advertisement dictionary as BLEAdvertisement.
    static func advertisement(_ data: [String: Any], name: String?) -> BLEAdvertisement {
        var advertisement = BLEAdvertisement()
        advertisement.name = (data[CBAdvertisementDataLocalNameKey] as? String) ?? name
        advertisement.serviceUUIDs = ((data[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []).compactMap(\.bleUUID)
        advertisement.manufacturerData = (data[CBAdvertisementDataManufacturerDataKey] as? Data).map { [UInt8]($0) }
        advertisement.serviceData = ((data[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]) ?? [:])
            .compactMap { uuid, value in uuid.bleUUID.map { BLEAdvertisement.ServiceData(uuid: $0, data: [UInt8](value)) } }
            .sorted { $0.uuid.bytes.lexicographicallyPrecedes($1.uuid.bytes) }
        advertisement.txPower = (data[CBAdvertisementDataTxPowerLevelKey] as? NSNumber).map { Int8(clamping: $0.intValue) }
        advertisement.connectable = (data[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true
        return advertisement
    }
}

extension CBUUID {
    var bleUUID: BLEUUID? { BLEUUID(bigEndian: [UInt8](data)) }
}

/// One connection from the Mac to a device, for one connection from
/// Android to its proxy chip (`GATTRemote`). Operations wait for
/// CoreBluetooth's callbacks; the device's errors come back as ATT errors.
final class MacBluetoothLink: NSObject, GATTRemote, CBPeripheralDelegate, @unchecked Sendable {
    let id: UUID
    private unowned let bluetooth: MacBluetooth
    private var queue: DispatchQueue { bluetooth.queue }
    private var peripheral: CBPeripheral?

    // State on `queue`.
    private enum Target {
        case characteristic(CBCharacteristic)
        case descriptor(CBDescriptor)
    }
    private var targets: [Target] = []
    private var connecting: CheckedContinuation<Void, any Error>?
    private var discovering: (pending: Int, continuation: CheckedContinuation<Void, any Error>)?
    private var reads: [ObjectIdentifier: [CheckedContinuation<[UInt8], any Error>]] = [:]
    private var writes: [ObjectIdentifier: [CheckedContinuation<Void, any Error>]] = [:]
    private var notifyChanges: [ObjectIdentifier: [CheckedContinuation<Void, any Error>]] = [:]
    private var done = false

    let notifications: AsyncStream<(GATTAttributeID, [UInt8])>
    private let notificationSink: AsyncStream<(GATTAttributeID, [UInt8])>.Continuation

    /// How long the Mac may take to connect and find the device's database.
    static let discoveryTimeout: Duration = .seconds(15)

    init(bluetooth: MacBluetooth, id: UUID) {
        self.bluetooth = bluetooth
        self.id = id
        (notifications, notificationSink) = AsyncStream.makeStream(of: (GATTAttributeID, [UInt8]).self)
    }

    // MARK: GATTRemote

    func discover() async throws -> [GATTService] {
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.discoveryTimeout)
            guard let self else { return }
            queue.async { self.ended(ATTError.unlikelyError) }
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                guard !done, let peripheral = bluetooth.connect(self) else {
                    continuation.resume(throwing: ATTError.unlikelyError)
                    return
                }
                self.peripheral = peripheral
                connecting = continuation
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                guard !done, let peripheral else { return continuation.resume(throwing: ATTError.unlikelyError) }
                discovering = (1, continuation)
                peripheral.discoverServices(nil)
            }
        }
        return queue.sync { database() }
    }

    func read(_ attribute: GATTAttributeID) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !done, let peripheral, targets.indices.contains(attribute.raw) else {
                    return continuation.resume(throwing: ATTError.invalidHandle)
                }
                switch targets[attribute.raw] {
                case .characteristic(let characteristic):
                    reads[ObjectIdentifier(characteristic), default: []].append(continuation)
                    peripheral.readValue(for: characteristic)
                case .descriptor(let descriptor):
                    reads[ObjectIdentifier(descriptor), default: []].append(continuation)
                    peripheral.readValue(for: descriptor)
                }
            }
        }
    }

    func write(_ attribute: GATTAttributeID, _ value: [UInt8], withResponse: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                guard !done, let peripheral, targets.indices.contains(attribute.raw) else {
                    return continuation.resume(throwing: ATTError.invalidHandle)
                }
                switch targets[attribute.raw] {
                case .characteristic(let characteristic):
                    guard withResponse else {
                        peripheral.writeValue(Data(value), for: characteristic, type: .withoutResponse)
                        return continuation.resume()
                    }
                    writes[ObjectIdentifier(characteristic), default: []].append(continuation)
                    peripheral.writeValue(Data(value), for: characteristic, type: .withResponse)
                case .descriptor(let descriptor):
                    writes[ObjectIdentifier(descriptor), default: []].append(continuation)
                    peripheral.writeValue(Data(value), for: descriptor)
                }
            }
        }
    }

    func setNotifying(_ characteristic: GATTAttributeID, _ on: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                guard !done, let peripheral, targets.indices.contains(characteristic.raw),
                      case .characteristic(let target) = targets[characteristic.raw] else {
                    return continuation.resume(throwing: ATTError.invalidHandle)
                }
                notifyChanges[ObjectIdentifier(target), default: []].append(continuation)
                peripheral.setNotifyValue(on, for: target)
            }
        }
    }

    func disconnect() {
        queue.async { [self] in
            if let peripheral { bluetooth.disconnect(self, peripheral) }
            ended(ATTError.unlikelyError)
        }
    }

    // MARK: On `queue`

    func didConnect() {
        connecting?.resume()
        connecting = nil
    }

    /// The connection ended (or failed, or timed out): everything waiting fails.
    func ended(_ error: any Error) {
        guard !done else { return }
        done = true
        let failure = (error as? CBATTError).map { ATTError(code: UInt8(clamping: $0.code.rawValue)) } ?? ATTError.unlikelyError
        connecting?.resume(throwing: failure)
        connecting = nil
        discovering?.continuation.resume(throwing: failure)
        discovering = nil
        for list in reads.values { list.forEach { $0.resume(throwing: failure) } }
        for list in writes.values { list.forEach { $0.resume(throwing: failure) } }
        for list in notifyChanges.values { list.forEach { $0.resume(throwing: failure) } }
        reads = [:]
        writes = [:]
        notifyChanges = [:]
        notificationSink.finish()
        if let peripheral { bluetooth.disconnect(self, peripheral) }
    }

    /// The device's database, numbered as `targets` (after discovery).
    private func database() -> [GATTService] {
        targets = []
        return (peripheral?.services ?? []).compactMap { service -> GATTService? in
            guard let uuid = service.uuid.bleUUID else { return nil }
            let characteristics = (service.characteristics ?? []).compactMap { characteristic -> GATTCharacteristic? in
                guard let uuid = characteristic.uuid.bleUUID else { return nil }
                targets.append(.characteristic(characteristic))
                let id = GATTAttributeID(raw: targets.count - 1)
                let descriptors = (characteristic.descriptors ?? []).compactMap { descriptor -> GATTDescriptor? in
                    guard let uuid = descriptor.uuid.bleUUID else { return nil }
                    targets.append(.descriptor(descriptor))
                    return GATTDescriptor(id: GATTAttributeID(raw: targets.count - 1), uuid: uuid)
                }
                // CoreBluetooth's own bits above 0xFF (encryption required) are not the declaration's.
                return GATTCharacteristic(id: id, uuid: uuid, properties: UInt8(characteristic.properties.rawValue & 0xFF),
                                          descriptors: descriptors)
            }
            return GATTService(uuid: uuid, primary: service.isPrimary, characteristics: characteristics)
        }
    }

    private func discovered(_ more: Int, error: (any Error)?) {
        guard var discovering else { return }
        if let error {
            self.discovering = nil
            return discovering.continuation.resume(throwing: (error as? CBATTError).map { ATTError(code: UInt8(clamping: $0.code.rawValue)) } ?? ATTError.unlikelyError)
        }
        discovering.pending += more - 1
        self.discovering = discovering
        if discovering.pending == 0 {
            self.discovering = nil
            discovering.continuation.resume()
        }
    }

    private static func attError(_ error: (any Error)?) -> ATTError? {
        guard let error else { return nil }
        return (error as? CBATTError).map { ATTError(code: UInt8(clamping: $0.code.rawValue)) } ?? .unlikelyError
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        let services = peripheral.services ?? []
        services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
        discovered(services.count, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        // A service the Mac may not look into (encryption) stays empty.
        let characteristics = error == nil ? service.characteristics ?? [] : []
        characteristics.forEach { peripheral.discoverDescriptors(for: $0) }
        discovered(characteristics.count, error: nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: (any Error)?) {
        // A characteristic whose descriptors cannot be read still counts.
        discovered(0, error: nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        let key = ObjectIdentifier(characteristic)
        let value = [UInt8](characteristic.value ?? Data())
        if var waiting = reads[key], !waiting.isEmpty {
            let continuation = waiting.removeFirst()
            reads[key] = waiting
            if let failure = Self.attError(error) { continuation.resume(throwing: failure) } else { continuation.resume(returning: value) }
            return
        }
        // Not asked for: a notification or indication.
        guard error == nil, let index = targets.firstIndex(where: { if case .characteristic(let c) = $0 { c === characteristic } else { false } }) else { return }
        notificationSink.yield((GATTAttributeID(raw: index), value))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: (any Error)?) {
        let key = ObjectIdentifier(descriptor)
        guard var waiting = reads[key], !waiting.isEmpty else { return }
        let continuation = waiting.removeFirst()
        reads[key] = waiting
        if let failure = Self.attError(error) { return continuation.resume(throwing: failure) }
        continuation.resume(returning: Self.bytes(of: descriptor.value))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        finishWrite(ObjectIdentifier(characteristic), error)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: (any Error)?) {
        finishWrite(ObjectIdentifier(descriptor), error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        let key = ObjectIdentifier(characteristic)
        guard var waiting = notifyChanges[key], !waiting.isEmpty else { return }
        let continuation = waiting.removeFirst()
        notifyChanges[key] = waiting
        if let failure = Self.attError(error) { continuation.resume(throwing: failure) } else { continuation.resume() }
    }

    private func finishWrite(_ key: ObjectIdentifier, _ error: (any Error)?) {
        guard var waiting = writes[key], !waiting.isEmpty else { return }
        let continuation = waiting.removeFirst()
        writes[key] = waiting
        if let failure = Self.attError(error) { continuation.resume(throwing: failure) } else { continuation.resume() }
    }

    /// A descriptor's value as CoreBluetooth gives it (Data, NSNumber for
    /// 16-bit ones, String for user descriptions), as its bytes.
    static func bytes(of value: Any?) -> [UInt8] {
        switch value {
        case let data as Data: return [UInt8](data)
        case let string as String: return Array(string.utf8)
        case let number as NSNumber: return le16(UInt16(truncatingIfNeeded: number.intValue))
        default: return []
        }
    }
}
