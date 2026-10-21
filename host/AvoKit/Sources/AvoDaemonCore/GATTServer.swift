import Foundation

// The GATT database of a real Bluetooth LE device, served to Android over a
// proxy chip's attribute channel (BLEProxyChip). The device is reached
// through `GATTRemote` (MacBluetoothLink: CoreBluetooth), which does the
// device's own discovery, reads, writes and notifications; the server only
// numbers the attributes and answers Android's ATT requests (Core 6.0,
// Vol 3, Parts F and G).

/// A characteristic or descriptor of the remote device, numbered by it.
struct GATTAttributeID: Hashable, Sendable {
    let raw: Int
}

struct GATTDescriptor: Equatable, Sendable {
    let id: GATTAttributeID
    let uuid: BLEUUID
}

struct GATTCharacteristic: Equatable, Sendable {
    let id: GATTAttributeID
    let uuid: BLEUUID
    /// The declaration's properties (0x02 read, 0x04 write without response,
    /// 0x08 write, 0x10 notify, 0x20 indicate, …).
    let properties: UInt8
    var descriptors: [GATTDescriptor] = []
}

struct GATTService: Equatable, Sendable {
    let uuid: BLEUUID
    var primary = true
    var characteristics: [GATTCharacteristic] = []
}

/// An ATT error code (Vol 3, Part F, 3.4.1.1). CoreBluetooth's
/// CBATTError codes are the same numbers.
struct ATTError: Error, Equatable {
    let code: UInt8

    static let invalidHandle = ATTError(code: 0x01)
    static let readNotPermitted = ATTError(code: 0x02)
    static let writeNotPermitted = ATTError(code: 0x03)
    static let requestNotSupported = ATTError(code: 0x06)
    static let invalidOffset = ATTError(code: 0x07)
    static let attributeNotFound = ATTError(code: 0x0A)
    static let invalidAttributeValueLength = ATTError(code: 0x0D)
    static let unlikelyError = ATTError(code: 0x0E)
    static let unsupportedGroupType = ATTError(code: 0x10)
}

/// The real device behind a proxy chip.
protocol GATTRemote: AnyObject, Sendable {
    /// Connects and discovers every service, characteristic and descriptor.
    func discover() async throws -> [GATTService]
    func read(_ attribute: GATTAttributeID) async throws -> [UInt8]
    func write(_ attribute: GATTAttributeID, _ value: [UInt8], withResponse: Bool) async throws
    func setNotifying(_ characteristic: GATTAttributeID, _ on: Bool) async throws
    /// Values the device notifies or indicates. It finishes when the device
    /// disconnects.
    var notifications: AsyncStream<(GATTAttributeID, [UInt8])> { get }
    func disconnect()
}

/// The attributes Android sees, numbered from 1: GAP (with the device's
/// name), GATT, then the device's services. A characteristic that notifies
/// or indicates gets the client configuration descriptor the server
/// answers itself (CoreBluetooth turns notifications on, not a written descriptor).
struct ATTDatabase {
    enum Value: Equatable {
        case fixed([UInt8])
        case characteristic(GATTAttributeID, properties: UInt8)
        case descriptor(GATTAttributeID)
        /// The client configuration descriptor of this characteristic.
        case configuration(GATTAttributeID)
    }

    struct Attribute: Equatable {
        let handle: UInt16
        let type: BLEUUID
        let value: Value
        /// A service declaration's last handle.
        var groupEnd: UInt16 = 0
    }

    static let primaryService = BLEUUID(0x2800)
    static let secondaryService = BLEUUID(0x2801)
    static let characteristic = BLEUUID(0x2803)
    static let clientConfiguration = BLEUUID(0x2902)

    private(set) var attributes: [Attribute] = []

    init(name: String, services: [GATTService]) {
        var service = begin(GATTService(uuid: BLEUUID(0x1800)))
        addFixed(BLEUUID(0x2A00), properties: 0x02, Array(name.utf8))
        addFixed(BLEUUID(0x2A01), properties: 0x02, [0x00, 0x00])
        end(service)
        end(begin(GATTService(uuid: BLEUUID(0x1801))))
        // CoreBluetooth keeps GAP and GATT to itself; anything else passes.
        for remote in services where remote.uuid != BLEUUID(0x1800) && remote.uuid != BLEUUID(0x1801) {
            service = begin(remote)
            for characteristic in remote.characteristics {
                let declaration = nextHandle
                attributes.append(Attribute(handle: declaration, type: Self.characteristic,
                                            value: .fixed([characteristic.properties] + le16(declaration + 1) + characteristic.uuid.littleEndian)))
                attributes.append(Attribute(handle: nextHandle, type: characteristic.uuid,
                                            value: .characteristic(characteristic.id, properties: characteristic.properties)))
                for descriptor in characteristic.descriptors where descriptor.uuid != Self.clientConfiguration {
                    attributes.append(Attribute(handle: nextHandle, type: descriptor.uuid, value: .descriptor(descriptor.id)))
                }
                if characteristic.properties & 0x30 != 0 {
                    attributes.append(Attribute(handle: nextHandle, type: Self.clientConfiguration, value: .configuration(characteristic.id)))
                }
            }
            end(service)
        }
    }

    func attribute(_ handle: UInt16) -> Attribute? {
        guard handle >= 1, Int(handle) <= attributes.count else { return nil }
        return attributes[Int(handle) - 1]
    }

    /// The value handle of a characteristic of the device.
    func valueHandle(of characteristic: GATTAttributeID) -> UInt16? {
        attributes.first { if case .characteristic(characteristic, _) = $0.value { true } else { false } }?.handle
    }

    func inRange(_ start: UInt16, _ end: UInt16) -> ArraySlice<Attribute> {
        guard start >= 1, start <= end, Int(start) <= attributes.count else { return [] }
        return attributes[Int(start) - 1..<min(Int(end), attributes.count)]
    }

    private var nextHandle: UInt16 { UInt16(attributes.count + 1) }

    /// Adds a service's declaration; its attributes follow until `end`.
    private mutating func begin(_ service: GATTService) -> Int {
        attributes.append(Attribute(handle: nextHandle, type: service.primary ? Self.primaryService : Self.secondaryService,
                                    value: .fixed(service.uuid.littleEndian)))
        return attributes.count - 1
    }

    private mutating func end(_ declaration: Int) {
        attributes[declaration].groupEnd = UInt16(attributes.count)
    }

    private mutating func addFixed(_ uuid: BLEUUID, properties: UInt8, _ value: [UInt8]) {
        let declaration = nextHandle
        attributes.append(Attribute(handle: declaration, type: Self.characteristic,
                                    value: .fixed([properties] + le16(declaration + 1) + uuid.littleEndian)))
        attributes.append(Attribute(handle: nextHandle, type: uuid, value: .fixed(value)))
    }
}

func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }

private func readLE16(_ bytes: ArraySlice<UInt8>, at offset: Int) -> UInt16? {
    let index = bytes.startIndex + offset
    guard index + 1 < bytes.endIndex else { return nil }
    return UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
}

/// Answers Android's ATT requests for one connection, one at a time.
actor GATTServer {
    let database: ATTDatabase
    private let remote: any GATTRemote
    /// The connection's ATT MTU (23 until Android exchanges it).
    private(set) var mtu = 23
    static let serverMTU = 517
    /// Client configuration per characteristic (bit 0 notify, bit 1 indicate).
    private var configuration: [GATTAttributeID: UInt16] = [:]
    /// The whole value of each attribute last read, for Read Blob.
    private var lastRead: [UInt16: [UInt8]] = [:]
    private var prepared: [(handle: UInt16, offset: Int, value: [UInt8])] = []

    init(database: ATTDatabase, remote: any GATTRemote) {
        self.database = database
        self.remote = remote
    }

    /// The response to `pdu`, or nil for a command (and a confirmation).
    func handle(_ pdu: [UInt8]) async -> [UInt8]? {
        guard let opcode = pdu.first else { return nil }
        let body = pdu.dropFirst()
        do {
            switch opcode {
            case 0x02: return exchangeMTU(body)
            case 0x04: return try findInformation(body)
            case 0x06: return try findByTypeValue(body)
            case 0x08: return try await readByType(body)
            case 0x0A: return try await read(body, blob: false)
            case 0x0C: return try await read(body, blob: true)
            case 0x10: return try readByGroupType(body)
            case 0x12: return try await write(body, withResponse: true)
            case 0x16: return try prepareWrite(body)
            case 0x18: return try await executeWrite(body)
            case 0x52:
                _ = try? await write(body, withResponse: false)
                return nil
            case 0x1E: return nil
            default:
                // Commands (bit 6) get no answer; other requests are not supported.
                if opcode & 0x40 != 0 { return nil }
                throw ATTError.requestNotSupported
            }
        } catch {
            let code = (error as? ATTError)?.code ?? ATTError.unlikelyError.code
            return [0x01, opcode] + le16(readLE16(body, at: 0) ?? 0) + [code]
        }
    }

    /// The PDU for a value the device notified or indicated, as Android asked
    /// for it (nil when it did not).
    func outgoing(_ characteristic: GATTAttributeID, _ value: [UInt8]) -> [UInt8]? {
        guard let handle = database.valueHandle(of: characteristic), let configured = configuration[characteristic] else { return nil }
        let opcode: UInt8 = configured & 0x1 != 0 ? 0x1B : configured & 0x2 != 0 ? 0x1D : 0
        guard opcode != 0 else { return nil }
        return [opcode] + le16(handle) + value.prefix(mtu - 3)
    }

    // MARK: Requests

    private func exchangeMTU(_ body: ArraySlice<UInt8>) -> [UInt8] {
        if let client = readLE16(body, at: 0) { mtu = max(23, min(Int(client), Self.serverMTU)) }
        return [0x03] + le16(UInt16(Self.serverMTU))
    }

    private func range(_ body: ArraySlice<UInt8>) throws -> (UInt16, UInt16) {
        guard let start = readLE16(body, at: 0), let end = readLE16(body, at: 2), start >= 1, start <= end else {
            throw ATTError.invalidHandle
        }
        return (start, end)
    }

    private func findInformation(_ body: ArraySlice<UInt8>) throws -> [UInt8] {
        let (start, end) = try range(body)
        let found = database.inRange(start, end)
        guard let first = found.first else { throw ATTError.attributeNotFound }
        let format: UInt8 = first.type.short != nil ? 0x01 : 0x02
        var response: [UInt8] = [0x05, format]
        for attribute in found where (attribute.type.short != nil) == (format == 0x01) {
            let entry = le16(attribute.handle) + attribute.type.littleEndian
            guard response.count + entry.count <= mtu else { break }
            response += entry
        }
        return response
    }

    private func findByTypeValue(_ body: ArraySlice<UInt8>) throws -> [UInt8] {
        let (start, end) = try range(body)
        guard let type = readLE16(body, at: 4) else { throw ATTError.invalidHandle }
        let value = Array(body.dropFirst(6))
        var response: [UInt8] = [0x07]
        for attribute in database.inRange(start, end) where attribute.type == BLEUUID(type) && attribute.value == .fixed(value) {
            guard response.count + 4 <= mtu else { break }
            response += le16(attribute.handle) + le16(attribute.groupEnd == 0 ? attribute.handle : attribute.groupEnd)
        }
        guard response.count > 1 else { throw ATTError.attributeNotFound }
        return response
    }

    private func readByType(_ body: ArraySlice<UInt8>) async throws -> [UInt8] {
        let (start, end) = try range(body)
        guard let type = BLEUUID(littleEndian: Array(body.dropFirst(4))) else { throw ATTError.invalidHandle }
        let found = database.inRange(start, end).filter { $0.type == type }
        guard let first = found.first else { throw ATTError.attributeNotFound }
        guard case .fixed = first.value else {
            // Read Using Characteristic UUID: the first one only.
            let value = try await value(of: first)
            let entry = Array(value.prefix(min(mtu - 4, 253)))
            return [0x09, UInt8(entry.count + 2)] + le16(first.handle) + entry
        }
        var response: [UInt8] = [0x09, 0]
        var length: Int?
        for attribute in found {
            guard case .fixed(let value) = attribute.value else { break }
            let entry = le16(attribute.handle) + value.prefix(min(mtu - 4, 253))
            if let length, entry.count != length { break }
            guard response.count + entry.count <= mtu else { break }
            length = entry.count
            response += entry
        }
        response[1] = UInt8(length ?? 0)
        return response
    }

    private func readByGroupType(_ body: ArraySlice<UInt8>) throws -> [UInt8] {
        let (start, end) = try range(body)
        guard let type = BLEUUID(littleEndian: Array(body.dropFirst(4))) else { throw ATTError.invalidHandle }
        guard type == ATTDatabase.primaryService || type == ATTDatabase.secondaryService else { throw ATTError.unsupportedGroupType }
        var response: [UInt8] = [0x11, 0]
        var length: Int?
        for attribute in database.inRange(start, end) where attribute.type == type {
            guard case .fixed(let uuid) = attribute.value else { continue }
            let entry = le16(attribute.handle) + le16(attribute.groupEnd) + uuid
            if let length, entry.count != length { break }
            guard response.count + entry.count <= mtu else { break }
            length = entry.count
            response += entry
        }
        guard let length else { throw ATTError.attributeNotFound }
        response[1] = UInt8(length)
        return response
    }

    private func read(_ body: ArraySlice<UInt8>, blob: Bool) async throws -> [UInt8] {
        guard let handle = readLE16(body, at: 0), let attribute = database.attribute(handle) else { throw ATTError.invalidHandle }
        let offset = blob ? Int(readLE16(body, at: 2) ?? 0) : 0
        let value: [UInt8]
        if blob, offset > 0, let cached = lastRead[handle] {
            value = cached
        } else {
            value = try await self.value(of: attribute)
            lastRead[handle] = value
        }
        guard offset <= value.count else { throw ATTError.invalidOffset }
        return [blob ? 0x0D : 0x0B] + value[offset...].prefix(mtu - 1)
    }

    private func value(of attribute: ATTDatabase.Attribute) async throws -> [UInt8] {
        switch attribute.value {
        case .fixed(let value): return value
        case .characteristic(let id, let properties):
            guard properties & 0x02 != 0 else { throw ATTError.readNotPermitted }
            return try await remote.read(id)
        case .descriptor(let id): return try await remote.read(id)
        case .configuration(let id): return le16(configuration[id] ?? 0)
        }
    }

    private func write(_ body: ArraySlice<UInt8>, withResponse: Bool) async throws -> [UInt8] {
        guard let handle = readLE16(body, at: 0), let attribute = database.attribute(handle) else { throw ATTError.invalidHandle }
        try await write(attribute, Array(body.dropFirst(2)), withResponse: withResponse)
        return [0x13]
    }

    private func write(_ attribute: ATTDatabase.Attribute, _ value: [UInt8], withResponse: Bool) async throws {
        lastRead[attribute.handle] = nil
        switch attribute.value {
        case .fixed: throw ATTError.writeNotPermitted
        case .characteristic(let id, let properties):
            guard properties & (withResponse ? 0x08 : 0x0C) != 0 else { throw ATTError.writeNotPermitted }
            // A command to a characteristic that only takes requests is one (the device refuses the other kind).
            try await remote.write(id, value, withResponse: withResponse || properties & 0x04 == 0)
        case .descriptor(let id):
            try await remote.write(id, value, withResponse: true)
        case .configuration(let id):
            guard value.count == 2 else { throw ATTError.invalidAttributeValueLength }
            let bits = UInt16(value[0]) | UInt16(value[1]) << 8
            try await remote.setNotifying(id, bits & 0x3 != 0)
            configuration[id] = bits
        }
    }

    private func prepareWrite(_ body: ArraySlice<UInt8>) throws -> [UInt8] {
        guard let handle = readLE16(body, at: 0), let offset = readLE16(body, at: 2) else { throw ATTError.invalidHandle }
        guard database.attribute(handle) != nil else { throw ATTError.invalidHandle }
        prepared.append((handle, Int(offset), Array(body.dropFirst(4))))
        return [0x17] + body
    }

    private func executeWrite(_ body: ArraySlice<UInt8>) async throws -> [UInt8] {
        let queue = prepared
        prepared = []
        guard body.first == 0x01 else { return [0x19] }
        // Long writes: each attribute's parts joined in order of offset.
        for handle in Array(Set(queue.map(\.handle))).sorted() {
            var value: [UInt8] = []
            for part in queue.filter({ $0.handle == handle }).sorted(by: { $0.offset < $1.offset }) {
                guard part.offset <= value.count else { throw ATTError.invalidOffset }
                value = Array(value.prefix(part.offset)) + part.value
            }
            guard let attribute = database.attribute(handle) else { throw ATTError.invalidHandle }
            try await write(attribute, value, withResponse: true)
        }
        return [0x19]
    }
}
