import Foundation
import Synchronization
import Testing
@testable import AvoDaemonCore

/// A device behind a proxy chip, without CoreBluetooth: a heart rate
/// monitor (heart rate notifies, body location reads, control point writes).
final class FakeRemote: GATTRemote, Sendable {
    static let measurement = GATTAttributeID(raw: 0)
    static let location = GATTAttributeID(raw: 1)
    static let controlPoint = GATTAttributeID(raw: 2)
    static let services = [
        GATTService(uuid: BLEUUID(0x180D), characteristics: [
            GATTCharacteristic(id: measurement, uuid: BLEUUID(0x2A37), properties: 0x10,
                               descriptors: [GATTDescriptor(id: GATTAttributeID(raw: 3), uuid: BLEUUID(0x2902))]),
            GATTCharacteristic(id: location, uuid: BLEUUID(0x2A38), properties: 0x02),
            GATTCharacteristic(id: controlPoint, uuid: BLEUUID(0x2A39), properties: 0x08),
        ]),
    ]

    struct State {
        var values: [GATTAttributeID: [UInt8]] = [location: [0x01]]
        var writes: [(GATTAttributeID, [UInt8], Bool)] = []
        var notifying: [GATTAttributeID: Bool] = [:]
        var disconnected = false
    }

    let state = Mutex(State())
    let notifications: AsyncStream<(GATTAttributeID, [UInt8])>
    let sink: AsyncStream<(GATTAttributeID, [UInt8])>.Continuation

    init() {
        (notifications, sink) = AsyncStream.makeStream(of: (GATTAttributeID, [UInt8]).self)
    }

    func discover() async throws -> [GATTService] { Self.services }

    func read(_ attribute: GATTAttributeID) async throws -> [UInt8] {
        guard let value = state.withLock({ $0.values[attribute] }) else { throw ATTError.readNotPermitted }
        return value
    }

    func write(_ attribute: GATTAttributeID, _ value: [UInt8], withResponse: Bool) async throws {
        state.withLock { $0.writes.append((attribute, value, withResponse)) }
    }

    func setNotifying(_ characteristic: GATTAttributeID, _ on: Bool) async throws {
        state.withLock { $0.notifying[characteristic] = on }
    }

    func disconnect() {
        state.withLock { $0.disconnected = true }
        sink.finish()
    }
}

@Suite struct BLEAdvertisementTests {
    @Test func uuidsOnTheBaseAreShort() {
        #expect(BLEUUID(bigEndian: [0x18, 0x0D])?.short == 0x180D)
        // A 32-bit UUID and a 128-bit one on the base UUID.
        #expect(BLEUUID(bigEndian: [0x00, 0x00, 0x18, 0x0D])?.short == 0x180D)
        #expect(BLEUUID(bigEndian: [0x00, 0x00, 0x18, 0x0D, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB])?.short == 0x180D)
        let custom = BLEUUID(bigEndian: Array(0..<16))
        #expect(custom?.short == nil && custom?.littleEndian == Array((0..<16).reversed()))
        #expect(BLEUUID(littleEndian: [0x0D, 0x18]) == BLEUUID(0x180D))
        #expect(BLEUUID(0x180D).description == "180D")
        #expect(custom?.description == "00010203-0405-0607-0809-0A0B0C0D0E0F")
    }

    @Test func dataGoesFirstAndTheNameWhereThereIsRoom() {
        var advertisement = BLEAdvertisement()
        advertisement.name = "Polar H10 A1B2C3D4"
        advertisement.serviceUUIDs = [BLEUUID(0x180D)]
        advertisement.manufacturerData = [0x6B, 0x00] + [UInt8](repeating: 0x42, count: 12)
        let (data, response) = advertisement.payloads()
        #expect(Array(data.prefix(3)) == [0x02, 0x01, 0x06])
        #expect(Array(data[3..<7]) == [0x03, 0x03, 0x0D, 0x18])
        #expect(Array(data[7..<9]) == [0x0F, 0xFF])
        // 23 bytes used: the 18-byte name (20 with its header) only fits the scan response.
        #expect(data.count == 23)
        #expect(response == [0x13, 0x09] + Array("Polar H10 A1B2C3D4".utf8))
    }

    @Test func aNameTooLongForEitherIsShortened() {
        var advertisement = BLEAdvertisement()
        advertisement.name = String(repeating: "é", count: 20)
        advertisement.manufacturerData = [UInt8](repeating: 1, count: 26)
        let (data, response) = advertisement.payloads()
        // Flags and the manufacturer data fill the advertising data; the
        // 40-byte name goes to the scan response as 14 whole characters (two bytes each).
        #expect(data.count == 31 && data[4] == 0xFF)
        #expect(response == [29, 0x08] + Array(String(repeating: "é", count: 14).utf8), "type 0x08: shortened")
    }

    @Test func appleContinuityIsNotWorthShowing() {
        var continuity = BLEAdvertisement()
        continuity.manufacturerData = [0x4C, 0x00, 0x10, 0x05, 0x01]
        #expect(continuity.isAppleContinuity)
        #expect(!MacBluetoothBridge.isWorthShowing(continuity))
        var watch = continuity
        watch.name = "Mi Band"
        #expect(MacBluetoothBridge.isWorthShowing(watch))
        #expect(!MacBluetoothBridge.isWorthShowing(BLEAdvertisement()))
    }
}

@Suite struct GATTServerTests {
    let database = ATTDatabase(name: "HRM", services: FakeRemote.services)

    @Test func theDatabaseHasGAPGATTThenTheDevice() {
        let types = database.attributes.map(\.type.description)
        #expect(types == ["2800", "2803", "2A00", "2803", "2A01", // GAP: name, appearance (handles 1-5)
                          "2800", // GATT, empty (6)
                          "2800", "2803", "2A37", "2902", "2803", "2A38", "2803", "2A39"]) // heart rate (7-14)
        // The device's own client configuration descriptor is replaced by the server's.
        #expect(database.attributes[9].value == .configuration(FakeRemote.measurement))
        #expect(database.attributes[6].groupEnd == 14 && database.attributes[0].groupEnd == 5)
        // Characteristic declaration: properties, value handle, UUID.
        #expect(database.attributes[7].value == .fixed([0x10, 9, 0, 0x37, 0x2A]))
    }

    @Test func androidDiscoversTheServices() async {
        let server = GATTServer(database: database, remote: FakeRemote())
        // Read By Group Type, primary services, all handles.
        let services = await server.handle([0x10, 0x01, 0x00, 0xFF, 0xFF, 0x00, 0x28])
        #expect(services == [0x11, 6, 1, 0, 5, 0, 0x00, 0x18, 6, 0, 6, 0, 0x01, 0x18, 7, 0, 14, 0, 0x0D, 0x18])
        // Past the last one: not found.
        #expect(await server.handle([0x10, 0x10, 0x00, 0xFF, 0xFF, 0x00, 0x28]) == [0x01, 0x10, 0x10, 0x00, 0x0A])
        // Read By Type, characteristic declarations of the heart rate service (23-byte MTU: three fit).
        let characteristics = await server.handle([0x08, 0x07, 0x00, 0x0F, 0x00, 0x03, 0x28])
        #expect(characteristics == [0x09, 7, 8, 0, 0x10, 9, 0, 0x37, 0x2A, 11, 0, 0x02, 12, 0, 0x38, 0x2A,
                                    13, 0, 0x08, 14, 0, 0x39, 0x2A])
        // Find Information after the measurement: its configuration descriptor.
        #expect(await server.handle([0x04, 0x0A, 0x00, 0x0A, 0x00]) == [0x05, 0x01, 10, 0, 0x02, 0x29])
        // Find By Type Value: the heart rate service by its UUID.
        #expect(await server.handle([0x06, 0x01, 0x00, 0xFF, 0xFF, 0x00, 0x28, 0x0D, 0x18]) == [0x07, 7, 0, 14, 0])
    }

    @Test func readsAndWritesGoToTheDevice() async {
        let remote = FakeRemote()
        let server = GATTServer(database: database, remote: remote)
        #expect(await server.handle([0x0A, 12, 0]) == [0x0B, 0x01])
        #expect(await server.handle([0x0A, 3, 0]) == [0x0B] + Array("HRM".utf8))
        // Not readable.
        #expect(await server.handle([0x0A, 9, 0]) == [0x01, 0x0A, 9, 0, 0x02])
        #expect(await server.handle([0x12, 14, 0, 0x01]) == [0x13])
        // A write command to a characteristic that only takes requests: written as a request.
        #expect(await server.handle([0x52, 14, 0, 0x02]) == nil)
        #expect(remote.state.withLock { $0.writes.map { [$0.0.raw, Int($0.1[0]), $0.2 ? 1 : 0] } } == [[2, 1, 1], [2, 2, 1]])
        #expect(await server.handle([0x12, 3, 0, 0x41]) == [0x01, 0x12, 3, 0, 0x03], "the name is the server's")
        #expect(await server.handle([0x0A, 99, 0]) == [0x01, 0x0A, 99, 0, 0x01])
    }

    @Test func notificationsFollowTheClientConfiguration() async {
        let remote = FakeRemote()
        let server = GATTServer(database: database, remote: remote)
        #expect(await server.outgoing(FakeRemote.measurement, [0x00, 72]) == nil, "not asked for yet")
        #expect(await server.handle([0x12, 10, 0, 0x01, 0x00]) == [0x13])
        #expect(remote.state.withLock { $0.notifying[FakeRemote.measurement] } == true)
        #expect(await server.handle([0x0A, 10, 0]) == [0x0B, 0x01, 0x00])
        #expect(await server.outgoing(FakeRemote.measurement, [0x00, 72]) == [0x1B, 9, 0, 0x00, 72])
        #expect(await server.handle([0x12, 10, 0, 0x01]) == [0x01, 0x12, 10, 0, 0x0D], "two bytes")
    }

    @Test func mtuAndLongValues() async {
        let remote = FakeRemote()
        remote.state.withLock { $0.values[FakeRemote.location] = Array(0..<40) }
        let server = GATTServer(database: database, remote: remote)
        #expect(await server.handle([0x0A, 12, 0]) == [0x0B] + Array(0..<22))
        #expect(await server.handle([0x0C, 12, 0, 22, 0]) == [0x0D] + Array(22..<40))
        #expect(await server.handle([0x0C, 12, 0, 41, 0]) == [0x01, 0x0C, 12, 0, 0x07])
        #expect(await server.handle([0x02, 0xF7, 0x00]) == [0x03, 0x05, 0x02])
        #expect(await server.mtu == 247)
        #expect(await server.handle([0x0A, 12, 0]) == [0x0B] + Array(0..<40))
        // A long write: two parts, then execute.
        #expect(await server.handle([0x16, 14, 0, 0, 0, 1, 2]) == [0x17, 14, 0, 0, 0, 1, 2])
        #expect(await server.handle([0x16, 14, 0, 2, 0, 3]) == [0x17, 14, 0, 2, 0, 3])
        #expect(await server.handle([0x18, 0x01]) == [0x19])
        #expect(remote.state.withLock { $0.writes.last?.1 } == [1, 2, 3])
        #expect(await server.handle([0x0E, 1, 0, 2, 0]) == [0x01, 0x0E, 1, 0, 0x06], "Read Multiple is not supported")
    }
}

@Suite struct BLEProxyChipTests {
    @Test func addressesAreRandomStaticAndStable() {
        let id = UUID(uuidString: "6F0B0B8C-1D2E-4F3A-9B8C-7D6E5F4A3B2C")!
        let address = BLEProxyChip.address(for: id)
        #expect(address.count == 6 && address[5] & 0xC0 == 0xC0)
        #expect(BLEProxyChip.address(for: id) == address)
        #expect(BLEProxyChip.address(for: UUID()) != address)
    }

    @Test func signalingRequestsAreRefused() {
        // Connection Parameter Update Request → rejected.
        #expect(BLEProxyChip.signalingReply([0x12, 7, 8, 0, 6, 0, 12, 0, 0, 0, 0xF4, 1]) == [0x13, 7, 2, 0, 1, 0])
        // LE Credit Based Connection Request → SPSM not supported.
        #expect(BLEProxyChip.signalingReply([0x14, 3, 10, 0, 0x80, 0, 0x40, 0, 0xF7, 0, 0xF7, 0, 10, 0]) == [0x15, 3, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0])
        #expect(BLEProxyChip.signalingReply([0x0A, 5, 2, 0, 2, 0]) == [0x01, 5, 2, 0, 0, 0], "not understood")
        #expect(BLEProxyChip.signalingReply([0x01, 5, 2, 0, 0, 0]) == nil)
    }
}

/// A proxy chip in a real netsim, seen and used by another chip playing
/// Android: `AVO_NETSIMD=~/Library/Android/sdk/emulator/netsimd swift test --filter ProxyChipInNetsim`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["AVO_NETSIMD"] != nil), .timeLimit(.minutes(1)))
struct ProxyChipInNetsim {
    @Test func androidFindsConnectsAndReads() async throws {
        let (netsimd, port) = try startNetsimd()
        defer { netsimd.terminate() }
        var chip: HCIChip?
        for _ in 0..<100 where chip == nil {
            chip = try? HCIChip.connect(port: port)
            if chip == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        var advertisement = BLEAdvertisement()
        advertisement.name = "Fake HRM"
        advertisement.serviceUUIDs = [BLEUUID(0x180D)]
        let remote = FakeRemote()
        let proxy = BLEProxyChip(chip: try #require(chip), id: UUID(), advertisement: advertisement) { remote }
        try await proxy.start()

        // Android: scan until the proxy shows up.
        let android = try HCIChip.connect(port: port)
        await android.start()
        try await android.command(HCIOpcode.reset)
        try await android.command(HCIOpcode.setEventMask, [0xFF, 0xFF, 0xFB, 0xFF, 0x07, 0xF8, 0xBF, 0x3D])
        try await android.command(HCIOpcode.leSetEventMask, [0x1F, 0, 0, 0, 0, 0, 0, 0])
        try await android.command(HCIOpcode.leSetScanParameters, [0x01, 0x10, 0x00, 0x10, 0x00, 0x00, 0x00])
        try await android.command(HCIOpcode.leSetScanEnable, [0x01, 0x00])
        var events = android.packets.makeAsyncIterator()
        var heard: [UInt8] = []
        while heard.isEmpty, let packet = await events.next() {
            // LE Advertising Report: subevent, count, event type, address type, address, length, data, RSSI.
            if case .event(0x3E, let p) = packet, p.first == 0x02, p.count > 11, Array(p[4..<10]) == proxy.address,
               let name = String(bytes: Self.field(0x09, in: Array(p[11..<11 + Int(p[10])])) ?? [], encoding: .utf8) {
                heard = Array(name.utf8)
            }
        }
        #expect(String(decoding: heard, as: UTF8.self) == "Fake HRM")
        try await android.command(HCIOpcode.leSetScanEnable, [0x00, 0x00])

        // Connect to the proxy's random address.
        try await android.command(HCIOpcode.leCreateConnection,
                                  le16(0x0010) + le16(0x0010) + [0x00, 0x01] + proxy.address
                                  + [0x00] + le16(0x0018) + le16(0x0028) + le16(0) + le16(0x0100) + le16(0) + le16(0))
        var handle: UInt16?
        while handle == nil, let packet = await events.next() {
            if case .event(0x3E, let p) = packet, p.first == 0x01, p[1] == 0 { handle = UInt16(p[2]) | UInt16(p[3]) << 8 }
        }
        let connection = try #require(handle)

        // ATT over L2CAP: services, then the body location.
        func request(_ pdu: [UInt8]) async throws -> [UInt8] {
            try await android.send(acl: connection, boundary: 0b00, le16(UInt16(pdu.count)) + le16(4) + pdu)
            var frame: [UInt8] = []
            while let packet = await events.next() {
                guard case .acl(connection, let boundary, let data) = packet else { continue }
                frame = boundary == 0b01 ? frame + data : data
                if frame.count >= 4, frame.count >= 4 + (Int(frame[0]) | Int(frame[1]) << 8) { return Array(frame[4...]) }
            }
            return []
        }
        let services = try await request([0x10, 0x01, 0x00, 0xFF, 0xFF, 0x00, 0x28])
        #expect(services.first == 0x11 && services.suffix(2) == [0x0D, 0x18])
        #expect(try await request([0x0A, 12, 0]) == [0x0B, 0x01])
        await proxy.close()
        await android.close()
    }

    /// One AD structure's data from advertising data.
    static func field(_ type: UInt8, in data: [UInt8]) -> [UInt8]? {
        var index = 0
        while index < data.count, data[index] > 0 {
            let length = Int(data[index])
            if index + length < data.count + 1, data[index + 1] == type { return Array(data[index + 2..<min(index + 1 + length, data.count)]) }
            index += length + 1
        }
        return nil
    }

    func startNetsimd() throws -> (Process, UInt16) {
        let port = UInt16.random(in: 20000...40000)
        let directory = FileManager.default.temporaryDirectory.appending(path: "avo-netsim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(filePath: ProcessInfo.processInfo.environment["AVO_NETSIMD"]!)
        process.arguments = ["--no-cli-ui", "--no-web-ui", "--logtostderr", "--instance", "1", "--hci-port", "\(port)",
                             "--debug-no-network", "--debug-no-guest-to-host-mdns"]
        process.environment = ["TMPDIR": directory.path]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        return (process, port)
    }
}
