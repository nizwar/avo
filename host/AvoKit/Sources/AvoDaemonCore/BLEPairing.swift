import CommonCrypto
import CryptoKit
import Foundation

/// A proxy chip's side of LE pairing (BLEProxyChip): Android pairs with the
/// chip, CoreBluetooth with the device behind it (it pairs by itself when a
/// characteristic needs it). Apps that bond before they use a device
/// (`createBond`) need the first: a chip that refused every pairing left
/// them waiting or failing.
///
/// The chip has no display and no keys, so pairing is LE legacy Just Works
/// (Core 6.0, Vol 3, Part H, 2.3.5.2): a temporary key of zero, the
/// confirm values `c1`, the short-term key `s1`, then, for a bond, a long
/// term key the chip hands Android. That key derives from the chip's
/// address, which derives from the device's CoreBluetooth identifier, so a
/// bond Android keeps still works with the same device's chip after Avo or
/// Android starts again. The link never leaves netsim's air on this Mac.
struct BLEPairing {
    /// SMP codes (Part H, 3.3 and 3.5.5).
    enum Code {
        static let pairingRequest: UInt8 = 0x01
        static let pairingResponse: UInt8 = 0x02
        static let pairingConfirm: UInt8 = 0x03
        static let pairingRandom: UInt8 = 0x04
        static let pairingFailed: UInt8 = 0x05
        static let encryptionInformation: UInt8 = 0x06
        static let centralIdentification: UInt8 = 0x07
    }

    enum Failure {
        static let confirmValueFailed: UInt8 = 0x04
        static let pairingNotSupported: UInt8 = 0x05
        static let encryptionKeySize: UInt8 = 0x06
        static let commandNotSupported: UInt8 = 0x07
        static let unspecifiedReason: UInt8 = 0x08
    }

    /// The peer's address as the connection reported it (type 0 public, 1 random), little-endian.
    struct Address: Equatable, Sendable {
        let type: UInt8
        let bytes: [UInt8]
    }

    /// The bond's long term key and the values that name it.
    struct Key: Equatable, Sendable {
        let ltk: [UInt8]
        let ediv: [UInt8]
        let rand: [UInt8]

        /// The chip's bond key, the same for the same address.
        static func derived(for address: [UInt8]) -> Key {
            let digest = Array(SHA256.hash(data: Data("com.avodroid.ble-proxy.ltk".utf8) + Data(address)))
            return Key(ltk: Array(digest[0..<16]), ediv: Array(digest[16..<18]), rand: Array(digest[18..<26]))
        }
    }

    let local: Address
    let peer: Address
    private(set) var key: Key
    private var request: [UInt8]?
    private var response: [UInt8]?
    private var peerConfirm: [UInt8]?
    private var localRandom: [UInt8] = []
    private var keySize = 16
    /// The short-term key once both randoms are in, until encryption starts with it.
    private(set) var shortTermKey: [UInt8]?
    /// Whether the chip hands Android its key once the link is encrypted.
    private(set) var distributesKey = false

    init(local: Address, peer: Address, key: Key) {
        self.local = local
        self.peer = peer
        self.key = key
    }

    /// The answer to an SMP PDU from Android, if any.
    mutating func received(_ pdu: [UInt8], random: () -> [UInt8] = { (0..<16).map { _ in UInt8.random(in: .min ... .max) } }) -> [UInt8]? {
        guard let code = pdu.first else { return nil }
        switch code {
        case Code.pairingRequest where pdu.count == 7:
            reset()
            let (authentication, maxKeySize, responderKeys) = (pdu[3], Int(pdu[4]), pdu[6])
            guard maxKeySize >= 7 else { return Self.failed(Failure.encryptionKeySize) }
            keySize = min(maxKeySize, 16)
            let bonding = authentication & 0x03 == 0x01
            distributesKey = bonding && responderKeys & 0x01 != 0
            // No input, no output; no OOB data; bonding as asked, no MITM, no
            // Secure Connections (legacy Just Works); Android hands nothing,
            // the chip its encryption key.
            let answer: [UInt8] = [Code.pairingResponse, 0x03, 0x00, bonding ? 0x01 : 0x00, UInt8(keySize), 0x00,
                                   distributesKey ? 0x01 : 0x00]
            request = pdu
            response = answer
            return answer
        case Code.pairingConfirm where pdu.count == 17:
            guard let request, let response else { return Self.failed(Failure.unspecifiedReason) }
            peerConfirm = Array(pdu[1...])
            localRandom = random()
            return [Code.pairingConfirm] + Self.c1(Self.zeroKey, localRandom, request: request, response: response,
                                                   initiator: peer, responder: local)
        case Code.pairingRandom where pdu.count == 17:
            guard let request, let response, let peerConfirm else { return Self.failed(Failure.unspecifiedReason) }
            let peerRandom = Array(pdu[1...])
            guard Self.c1(Self.zeroKey, peerRandom, request: request, response: response, initiator: peer, responder: local) == peerConfirm else {
                reset()
                return Self.failed(Failure.confirmValueFailed)
            }
            shortTermKey = Self.masked(Self.s1(Self.zeroKey, localRandom, peerRandom), size: keySize)
            return [Code.pairingRandom] + localRandom
        case Code.pairingFailed:
            reset()
            return nil
        case Code.pairingRequest, Code.pairingConfirm, Code.pairingRandom:
            return Self.failed(Failure.unspecifiedReason)
        default:
            // Keys Android hands out (none are asked for), and anything else.
            return nil
        }
    }

    /// The key for Android's LE Long Term Key Request: the short-term key
    /// while pairing (Rand and EDIV zero), else the bond's key when Android
    /// names it.
    func key(rand: [UInt8], ediv: [UInt8]) -> [UInt8]? {
        if let shortTermKey, rand.allSatisfy({ $0 == 0 }), ediv.allSatisfy({ $0 == 0 }) { return shortTermKey }
        return rand == key.rand && ediv == key.ediv ? Self.masked(key.ltk, size: keySize) : nil
    }

    /// The link is encrypted: the PDUs that hand Android the bond's key,
    /// once, after pairing with a short-term key.
    mutating func encrypted() -> [[UInt8]] {
        guard shortTermKey != nil else { return [] }
        shortTermKey = nil
        defer { distributesKey = false }
        guard distributesKey else { return [] }
        return [[Code.encryptionInformation] + Self.masked(key.ltk, size: keySize),
                [Code.centralIdentification] + key.ediv + key.rand]
    }

    private mutating func reset() {
        request = nil
        response = nil
        peerConfirm = nil
        shortTermKey = nil
        distributesKey = false
    }

    static func failed(_ reason: UInt8) -> [UInt8] { [Code.pairingFailed, reason] }

    static let zeroKey = [UInt8](repeating: 0, count: 16)

    /// A key shortened to `size` bytes: the most significant ones zero.
    static func masked(_ key: [UInt8], size: Int) -> [UInt8] {
        key.enumerated().map { $0.offset < size ? $0.element : 0 }
    }

    // MARK: Security functions (Part H, 2.2), little-endian as SMP carries them

    /// AES-128 of `data` with `key`, both little-endian.
    static func e(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        let key = Array(key.reversed()), data = Array(data.reversed())
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                             key, 16, nil, data, 16, &out, 16, &moved)
        precondition(status == kCCSuccess && moved == 16, "AES-128 failed")
        return out.reversed()
    }

    /// The confirm value generation function: `r` with both pairing PDUs
    /// (opcode first, as sent) and both addresses.
    static func c1(_ key: [UInt8], _ r: [UInt8], request: [UInt8], response: [UInt8],
                   initiator: Address, responder: Address) -> [UInt8] {
        let p1 = [initiator.type, responder.type] + request + response
        let p2 = responder.bytes + initiator.bytes + [0, 0, 0, 0]
        let first = e(key, zip(r, p1).map { $0 ^ $1 })
        return e(key, zip(first, p2).map { $0 ^ $1 })
    }

    /// The key generation function: the low halves of `r2`, then of `r1`.
    static func s1(_ key: [UInt8], _ r1: [UInt8], _ r2: [UInt8]) -> [UInt8] {
        e(key, Array(r2[0..<8]) + Array(r1[0..<8]))
    }
}
