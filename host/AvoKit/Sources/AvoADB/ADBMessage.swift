import Foundation

/// One ADB transport message: a 24-byte header and an optional payload.
public struct ADBMessage: Equatable, Sendable {
    public enum Command: UInt32, Sendable {
        case sync = 0x434E_5953  // SYNC (obsolete)
        case connect = 0x4E58_4E43 // CNXN
        case auth = 0x4854_5541  // AUTH
        case open = 0x4E45_504F  // OPEN
        case okay = 0x5941_4B4F  // OKAY
        case close = 0x4553_4C43 // CLSE
        case write = 0x4554_5257 // WRTE
        case startTLS = 0x534C_5453 // STLS
    }

    public enum AuthType: UInt32, Sendable {
        case token = 1
        case signature = 2
        case rsaPublicKey = 3
    }

    /// Protocol version with checksums skipped.
    public static let version: UInt32 = 0x0100_0001
    public static let versionMinimum: UInt32 = 0x0100_0000
    /// Largest payload we accept; the peer's CNXN may lower it.
    public static let maxPayload: UInt32 = 256 * 1024
    public static let headerLength = 24

    public var command: Command
    public var arg0: UInt32
    public var arg1: UInt32
    public var payload: Data

    public init(_ command: Command, _ arg0: UInt32, _ arg1: UInt32, _ payload: Data = Data()) {
        self.command = command
        self.arg0 = arg0
        self.arg1 = arg1
        self.payload = payload
    }

    /// Serializes the message. Peers older than 0x01000001 need the payload
    /// checksum (a plain byte sum, not a CRC).
    public func encoded(withChecksum: Bool = false) -> Data {
        var out = Data(capacity: Self.headerLength + payload.count)
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        append(command.rawValue)
        append(arg0)
        append(arg1)
        append(UInt32(payload.count))
        append(withChecksum ? payload.reduce(UInt32(0)) { $0 &+ UInt32($1) } : 0)
        append(command.rawValue ^ 0xFFFF_FFFF)
        out.append(payload)
        return out
    }
}

public enum ADBError: Error, Equatable, Sendable, CustomStringConvertible {
    case badMagic
    case unknownCommand(UInt32)
    case payloadTooLarge(UInt32)
    case authenticationRejected
    case handshakeTimedOut
    case unexpected(String)
    case streamRefused(String)
    case streamClosed
    case connectionClosed
    case shell(String)
    case sync(String)
    case install(String)

    public var description: String {
        switch self {
        case .badMagic: "corrupt ADB message"
        case .unknownCommand(let c): "unknown ADB command \(String(format: "0x%08x", c))"
        case .payloadTooLarge(let n): "ADB payload of \(n) bytes is too large"
        case .authenticationRejected: "adbd rejected the key"
        case .handshakeTimedOut: "adbd did not finish the handshake (is the key authorized?)"
        case .unexpected(let detail): "unexpected ADB message: \(detail)"
        case .streamRefused(let service): "adbd refused \(service)"
        case .streamClosed: "ADB stream closed"
        case .connectionClosed: "ADB connection closed"
        case .shell(let detail): "shell: \(detail)"
        case .sync(let detail): "sync: \(detail)"
        case .install(let detail): detail
        }
    }
}

/// Incremental decoder for the ADB transport.
public struct ADBMessageDecoder: Sendable {
    private var buffer = Data()
    public var maxPayload: UInt32 = 1024 * 1024

    public init() {}

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// What arrived after the messages taken so far.
    public var buffered: Data { buffer }

    public mutating func next() throws(ADBError) -> ADBMessage? {
        guard buffer.count >= ADBMessage.headerLength else { return nil }
        let base = buffer.startIndex
        func word(_ index: Int) -> UInt32 {
            let offset = base + index * 4
            return UInt32(buffer[offset]) | UInt32(buffer[offset + 1]) << 8
                | UInt32(buffer[offset + 2]) << 16 | UInt32(buffer[offset + 3]) << 24
        }
        let rawCommand = word(0)
        guard word(5) == rawCommand ^ 0xFFFF_FFFF else { throw .badMagic }
        guard let command = ADBMessage.Command(rawValue: rawCommand) else { throw .unknownCommand(rawCommand) }
        let length = word(3)
        guard length <= maxPayload else { throw .payloadTooLarge(length) }
        let total = ADBMessage.headerLength + Int(length)
        guard buffer.count >= total else { return nil }
        let payload = buffer.subdata(in: (base + ADBMessage.headerLength)..<(base + total))
        let message = ADBMessage(command, word(1), word(2), payload)
        buffer.removeSubrange(base..<(base + total))
        return message
    }
}
