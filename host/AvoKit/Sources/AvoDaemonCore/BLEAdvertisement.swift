import Foundation

/// A Bluetooth UUID: 16-bit when it is on the Bluetooth Base UUID
/// (0000xxxx-0000-1000-8000-00805F9B34FB), else 128-bit.
struct BLEUUID: Hashable, Sendable, CustomStringConvertible {
    /// Big-endian: 2 or 16 bytes.
    let bytes: [UInt8]

    private static let base: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
                                        0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB]

    init(_ short: UInt16) {
        bytes = [UInt8(short >> 8), UInt8(short & 0xFF)]
    }

    /// From big-endian bytes as CoreBluetooth gives them (CBUUID.data: 2, 4 or 16).
    init?(bigEndian: [UInt8]) {
        // 32-bit UUIDs are on the base UUID too.
        let full = bigEndian.count == 4 ? bigEndian + Array(Self.base[4...]) : bigEndian
        switch full.count {
        case 2:
            bytes = full
        case 16:
            let onBase = Array(full[4...]) == Array(Self.base[4...]) && full[0] == 0 && full[1] == 0
            bytes = onBase ? Array(full[2..<4]) : full
        default:
            return nil
        }
    }

    /// From the little-endian bytes ATT carries (2 or 16).
    init?(littleEndian: [UInt8]) {
        guard littleEndian.count == 2 || littleEndian.count == 16 else { return nil }
        self.init(bigEndian: littleEndian.reversed())
    }

    var littleEndian: [UInt8] { bytes.reversed() }
    var short: UInt16? { bytes.count == 2 ? UInt16(bytes[0]) << 8 | UInt16(bytes[1]) : nil }

    var description: String {
        if let short { return String(format: "%04X", short) }
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound)..<hex.index(hex.startIndex, offsetBy: range.upperBound)])
        }
        return parts.joined(separator: "-")
    }
}

/// What a Bluetooth LE device advertises, as CoreBluetooth reports it
/// (CoreBluetooth gives no raw bytes), and the advertising data and scan
/// response a proxy chip sends for it (Core Specification Supplement, Part A).
struct BLEAdvertisement: Equatable, Sendable {
    struct ServiceData: Equatable, Sendable {
        let uuid: BLEUUID
        let data: [UInt8]
    }

    var name: String?
    var serviceUUIDs: [BLEUUID] = []
    /// Company identifier first (little-endian), as advertised.
    var manufacturerData: [UInt8]?
    var serviceData: [ServiceData] = []
    var txPower: Int8?
    var connectable = true

    /// The most each of the two may hold (legacy advertising).
    static let capacity = 31

    /// Apple's own devices (Continuity: iPhones, Macs, AirPods cases) fill
    /// the air around any Mac and mean nothing to Android apps.
    var isAppleContinuity: Bool {
        guard let manufacturerData, manufacturerData.count >= 2, manufacturerData[0] == 0x4C, manufacturerData[1] == 0x00 else { return false }
        return name == nil && serviceUUIDs.isEmpty && serviceData.isEmpty
    }

    /// The advertising data and the scan response: flags first, then the
    /// services, manufacturer data, service data, power and name, each in
    /// the first that has room (a name too long for both is shortened).
    func payloads() -> (advertising: [UInt8], scanResponse: [UInt8]) {
        var advertising: [UInt8] = []
        var scanResponse: [UInt8] = []
        func place(_ structure: [UInt8]) -> Bool {
            if advertising.count + structure.count <= Self.capacity {
                advertising += structure
            } else if scanResponse.count + structure.count <= Self.capacity {
                scanResponse += structure
            } else {
                return false
            }
            return true
        }
        func structure(_ type: UInt8, _ data: [UInt8]) -> [UInt8] { [UInt8(data.count + 1), type] + data }

        // LE General Discoverable, BR/EDR not supported.
        _ = place(structure(0x01, [0x06]))
        let short = serviceUUIDs.filter { $0.short != nil }
        let long = serviceUUIDs.filter { $0.short == nil }
        for (uuids, complete, incomplete) in [(short, UInt8(0x03), UInt8(0x02)), (long, UInt8(0x07), UInt8(0x06))] where !uuids.isEmpty {
            // As many as fit, marked incomplete when some do not.
            var list = uuids
            while !list.isEmpty, !place(structure(list.count == uuids.count ? complete : incomplete, list.flatMap(\.littleEndian))) {
                list.removeLast()
            }
        }
        if let manufacturerData { _ = place(structure(0xFF, manufacturerData)) }
        for item in serviceData {
            _ = place(structure(item.uuid.short != nil ? 0x16 : 0x21, item.uuid.littleEndian + item.data))
        }
        if let txPower { _ = place(structure(0x0A, [UInt8(bitPattern: txPower)])) }
        if let name, !name.isEmpty, !place(structure(0x09, Array(name.utf8))) {
            // Shortened, whole characters only.
            let room = max(Self.capacity - advertising.count, Self.capacity - scanResponse.count) - 2
            var shortened = ""
            for character in name {
                guard shortened.utf8.count + String(character).utf8.count <= room else { break }
                shortened.append(character)
            }
            if !shortened.isEmpty { _ = place(structure(0x08, Array(shortened.utf8))) }
        }
        return (advertising, scanResponse)
    }
}
