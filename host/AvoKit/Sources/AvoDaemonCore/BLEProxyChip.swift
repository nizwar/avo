import AvoKit
import Foundation
import os

/// One Bluetooth LE device the Mac sees, as a chip in netsim's air that
/// Android scans for and connects to (MacBluetoothBridge). The chip
/// advertises what the device advertises, from a random static address of
/// its own (the device's own address is CoreBluetooth's secret). When
/// Android connects, the Mac connects to the device (`GATTRemote`) and the
/// chip serves its GATT database over L2CAP's attribute channel
/// (GATTServer); the device's notifications follow. Pairing is refused
/// ("pairing not supported"): CoreBluetooth pairs with the device itself.
actor BLEProxyChip {
    nonisolated let address: [UInt8]
    private let chip: HCIChip
    private let name: String
    private let makeRemote: @Sendable () -> any GATTRemote
    private var advertisement: BLEAdvertisement
    private var loop: Task<Void, Never>?
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Bluetooth")

    // The connection from Android.
    private var connection: UInt16?
    private var server: GATTServer?
    private var remote: (any GATTRemote)?
    private var notifications: Task<Void, Never>?
    /// The L2CAP frame coming in, across ACL packets.
    private var incoming: [UInt8] = []

    // Flow control: the controller's LE ACL buffers.
    private var aclLength = 27
    private var credits = 1
    private var waiting: [[UInt8]] = []

    /// L2CAP fixed channels (Core 6.0, Vol 3, Part A, 2.1).
    static let attributeChannel: UInt16 = 0x0004
    static let signalingChannel: UInt16 = 0x0005
    static let securityChannel: UInt16 = 0x0006

    /// `id` names the device: its address derives from it, so it stays the same.
    init(chip: HCIChip, id: UUID, advertisement: BLEAdvertisement, remote: @escaping @Sendable () -> any GATTRemote) {
        self.chip = chip
        self.address = Self.address(for: id)
        self.advertisement = advertisement
        self.name = advertisement.name ?? ""
        self.makeRemote = remote
    }

    /// A random static address (top two bits set), little-endian as HCI carries it.
    static func address(for id: UUID) -> [UInt8] {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        var address = (0..<6).map { index in bytes[index] ^ bytes[index + 6] ^ bytes[(index + 12) % 16] }
        address[5] |= 0xC0
        // All ones or all zeros in the random part are not allowed.
        if address[0..<5].allSatisfy({ $0 == 0xFF }) || (address[0..<5].allSatisfy({ $0 == 0 }) && address[5] == 0xC0) { address[0] ^= 0x5A }
        return address
    }

    /// Sets the chip up and starts advertising.
    func start() async throws {
        await chip.start()
        loop = Task { [weak self, chip] in
            for await packet in chip.packets { await self?.received(packet) }
            await self?.chipEnded()
        }
        try await chip.command(HCIOpcode.reset)
        // Everything as after reset, plus LE Meta events (bit 61).
        try await chip.command(HCIOpcode.setEventMask, [0xFF, 0xFF, 0xFB, 0xFF, 0x07, 0xF8, 0xBF, 0x3D])
        // Connection complete, advertising report, connection update, remote features, long term key request.
        try await chip.command(HCIOpcode.leSetEventMask, [0x1F, 0, 0, 0, 0, 0, 0, 0])
        let buffers = try await chip.command(HCIOpcode.leReadBufferSize)
        if buffers.count >= 3, buffers[0] | buffers[1] != 0 {
            aclLength = Int(buffers[0]) | Int(buffers[1]) << 8
            credits = max(Int(buffers[2]), 1)
        } else {
            // No LE buffers of their own: the shared ones.
            let shared = try await chip.command(HCIOpcode.readBufferSize)
            if shared.count >= 7 {
                aclLength = Int(shared[0]) | Int(shared[1]) << 8
                credits = max(Int(shared[3]) | Int(shared[4]) << 8, 1)
            }
        }
        try await chip.command(HCIOpcode.leSetRandomAddress, address)
        try await advertise()
    }

    /// The device advertises something new (its name, its data).
    func update(_ advertisement: BLEAdvertisement) async {
        guard advertisement != self.advertisement else { return }
        self.advertisement = advertisement
        guard connection == nil else { return }
        let (data, response) = advertisement.payloads()
        _ = try? await chip.command(HCIOpcode.leSetAdvertisingData, Self.padded(data))
        _ = try? await chip.command(HCIOpcode.leSetScanResponseData, Self.padded(response))
    }

    var isConnected: Bool { connection != nil }

    /// Takes the chip out of netsim's air (the device went away).
    func close() async {
        loop?.cancel()
        endConnection()
        await chip.close()
    }

    // MARK: Advertising

    private func advertise() async throws {
        let (data, response) = advertisement.payloads()
        // 100 ms; connectable (ADV_IND), or scannable only (ADV_SCAN_IND); from the random address; all channels.
        let interval = le16(0x00A0)
        try await chip.command(HCIOpcode.leSetAdvertisingParameters,
                               interval + interval + [advertisement.connectable ? 0x00 : 0x02, 0x01, 0x00]
                               + [UInt8](repeating: 0, count: 6) + [0x07, 0x00])
        try await chip.command(HCIOpcode.leSetAdvertisingData, Self.padded(data))
        try await chip.command(HCIOpcode.leSetScanResponseData, Self.padded(response))
        try await chip.command(HCIOpcode.leSetAdvertisingEnable, [0x01])
    }

    /// Length, then the data padded to 31 bytes.
    static func padded(_ data: [UInt8]) -> [UInt8] {
        [UInt8(data.count)] + data + [UInt8](repeating: 0, count: BLEAdvertisement.capacity - data.count)
    }

    // MARK: Events

    private func received(_ packet: HCIChip.Packet) async {
        switch packet {
        case .event(0x3E, let parameters):
            await leMeta(parameters)
        case .event(0x05, let parameters) where parameters.count >= 4:
            // Disconnection Complete: status, handle, reason.
            guard parameters[0] == 0, UInt16(parameters[1]) | UInt16(parameters[2]) << 8 == connection else { return }
            endConnection()
            // Legacy advertising stops with a connection: again, for the next one.
            _ = try? await chip.command(HCIOpcode.leSetAdvertisingEnable, [0x01])
        case .event(0x13, let parameters) where !parameters.isEmpty:
            // Number Of Completed Packets: handle and count per handle.
            for index in 0..<Int(parameters[0]) where 1 + index * 4 + 3 < parameters.count {
                credits += Int(parameters[1 + index * 4 + 2]) | Int(parameters[1 + index * 4 + 3]) << 8
            }
            await flush()
        case .acl(let handle, let boundary, let data) where handle == connection:
            if boundary == 0b01 { incoming += data } else { incoming = data }
            guard incoming.count >= 4 else { return }
            let length = Int(incoming[0]) | Int(incoming[1]) << 8
            guard incoming.count >= 4 + length else { return }
            let channel = UInt16(incoming[2]) | UInt16(incoming[3]) << 8
            let payload = Array(incoming[4..<4 + length])
            incoming = []
            await l2cap(channel, payload)
        default:
            break
        }
    }

    private func leMeta(_ parameters: [UInt8]) async {
        guard let subevent = parameters.first else { return }
        switch subevent {
        case 0x01 where parameters.count >= 4 && parameters[1] == 0:
            // LE Connection Complete: Android connected.
            let handle = UInt16(parameters[2]) | UInt16(parameters[3]) << 8
            await connected(handle)
        case 0x05 where parameters.count >= 3:
            // LE Long Term Key Request: there is no key (nothing was paired).
            _ = try? await chip.command(HCIOpcode.leLongTermKeyRequestNegativeReply, Array(parameters[1...2]))
        default:
            break
        }
    }

    /// Connects the Mac to the device and serves its database. Android's
    /// requests wait meanwhile (they queue up behind this event).
    private func connected(_ handle: UInt16) async {
        connection = handle
        incoming = []
        let remote = makeRemote()
        self.remote = remote
        do {
            let services = try await remote.discover()
            guard connection == handle else { return }
            let server = GATTServer(database: ATTDatabase(name: name, services: services), remote: remote)
            self.server = server
            notifications = Task { [weak self] in
                for await (characteristic, value) in remote.notifications {
                    guard let pdu = await server.outgoing(characteristic, value) else { continue }
                    await self?.send(Self.attributeChannel, pdu)
                }
                // The device went away: so does Android's connection to it.
                await self?.disconnectAndroid()
            }
        } catch {
            logger.error("bluetooth: \(self.name, privacy: .public) did not connect on the Mac: \(String(describing: error), privacy: .public)")
            await disconnectAndroid()
        }
    }

    private func endConnection() {
        connection = nil
        server = nil
        notifications?.cancel()
        notifications = nil
        remote?.disconnect()
        remote = nil
        incoming = []
        waiting = []
    }

    private func disconnectAndroid() async {
        guard let connection else { return }
        // Remote user terminated connection.
        _ = try? await chip.command(HCIOpcode.disconnect, le16(connection) + [0x13])
    }

    private func chipEnded() {
        endConnection()
    }

    // MARK: L2CAP

    private func l2cap(_ channel: UInt16, _ payload: [UInt8]) async {
        switch channel {
        case Self.attributeChannel:
            guard let server, let response = await server.handle(payload) else { return }
            await send(Self.attributeChannel, response)
        case Self.securityChannel where payload.first == 0x01:
            // Pairing Request: Pairing Failed, pairing not supported.
            await send(Self.securityChannel, [0x05, 0x05])
        case Self.signalingChannel:
            if let reply = Self.signalingReply(payload) { await send(Self.signalingChannel, reply) }
        default:
            break
        }
    }

    /// The answer to an LE signaling request (Core 6.0, Vol 3, Part A, 4):
    /// connections on a PSM are refused, anything else not understood.
    static func signalingReply(_ payload: [UInt8]) -> [UInt8]? {
        guard payload.count >= 4 else { return nil }
        let (code, identifier) = (payload[0], payload[1])
        switch code {
        case 0x06 where payload.count >= 8:
            // Disconnection Request: confirmed (destination and source CIDs back).
            return [0x07, identifier] + le16(4) + Array(payload[4..<8])
        case 0x12:
            // Connection Parameter Update Request: rejected.
            return [0x13, identifier] + le16(2) + le16(0x0001)
        case 0x14:
            // LE Credit Based Connection Request: SPSM not supported.
            return [0x15, identifier] + le16(10) + [UInt8](repeating: 0, count: 8) + le16(0x0002)
        case 0x17 where payload.count >= 12:
            // Credit Based Connection Request: SPSM not supported for all of them.
            let channels = (payload.count - 12) / 2
            return [0x18, identifier] + le16(UInt16(8 + 2 * channels)) + [UInt8](repeating: 0, count: 6) + le16(0x0002)
                + [UInt8](repeating: 0, count: 2 * channels)
        case 0x01, 0x07, 0x13, 0x15, 0x16, 0x18, 0x1A:
            // Rejects and responses: nothing to answer.
            return nil
        default:
            // Command Reject, command not understood.
            return [0x01, identifier] + le16(2) + le16(0x0000)
        }
    }

    /// Sends an L2CAP frame in ACL packets the controller's buffers take.
    private func send(_ channel: UInt16, _ payload: [UInt8]) async {
        guard let connection else { return }
        let frame = le16(UInt16(payload.count)) + le16(channel) + payload
        var offset = 0
        while offset < frame.count {
            let part = Array(frame[offset..<min(offset + aclLength, frame.count)])
            // Handle and flags travel with each queued part (0b00 starts the frame, 0b01 continues it).
            waiting.append(le16(connection | UInt16(offset == 0 ? 0b00 : 0b01) << 12) + part)
            offset += aclLength
        }
        await flush()
    }

    private func flush() async {
        while credits > 0, !waiting.isEmpty {
            let packet = waiting.removeFirst()
            credits -= 1
            let header = UInt16(packet[0]) | UInt16(packet[1]) << 8
            try? await chip.send(acl: header & 0x0FFF, boundary: UInt8(header >> 12), Array(packet[2...]))
        }
    }
}
