import Foundation
import Testing
@testable import AvoDaemonCore

/// Bytes from a number written most significant first, as the
/// specification's examples are, little-endian as SMP carries them.
private func le(_ hex: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        bytes.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return bytes.reversed()
}

@Suite struct BLEPairingTests {
    /// Core 6.0, Vol 3, Part H, 2.2.3 and 2.2.4.
    @Test func securityFunctionsMatchTheSpecification() {
        let confirm = BLEPairing.c1(BLEPairing.zeroKey, le("5783D52156AD6F0E6388274EC6702EE0"),
                                    request: le("07071000000101"), response: le("05000800000302"),
                                    initiator: .init(type: 1, bytes: le("A1A2A3A4A5A6")),
                                    responder: .init(type: 0, bytes: le("B1B2B3B4B5B6")))
        #expect(confirm == le("1E1E3FEF878988EAD2A74DC5BEF13B86"))
        let key = BLEPairing.s1(BLEPairing.zeroKey, le("000F0E0D0C0B0A091122334455667788"), le("010203040506070899AABBCCDDEEFF00"))
        #expect(key == le("9A1FE1F0E8B0F49B5B4216AE796DA062"))
    }

    /// Android's side of Just Works, against the chip's.
    @Test func androidPairsAndBonds() throws {
        let chipAddress: [UInt8] = [1, 2, 3, 4, 5, 0xC6]
        let android = BLEPairing.Address(type: 0, bytes: [0x11, 0x22, 0x33, 0x44, 0x55, 0x66])
        let chip = BLEPairing.Address(type: 1, bytes: chipAddress)
        var pairing = BLEPairing(local: chip, peer: android, key: .derived(for: chipAddress))
        // Bonding, MITM and Secure Connections asked for; Android would hand its keys, and take the chip's.
        let request: [UInt8] = [0x01, 0x04, 0x00, 0x0D, 0x10, 0x07, 0x07]
        let answer = pairing.received(request)
        let response = try #require(answer)
        #expect(response == [0x02, 0x03, 0x00, 0x01, 0x10, 0x00, 0x01], "Just Works, legacy, bonding, the chip's key only")
        let androidRandom = [UInt8](repeating: 0x42, count: 16)
        let androidConfirm = BLEPairing.c1(BLEPairing.zeroKey, androidRandom, request: request, response: response,
                                           initiator: android, responder: chip)
        let confirmAnswer = pairing.received([0x03] + androidConfirm) { [UInt8](repeating: 0x17, count: 16) }
        let randomAnswer = pairing.received([0x04] + androidRandom)
        let chipConfirm = try #require(confirmAnswer)
        let chipRandom = try #require(randomAnswer)
        #expect(chipRandom == [0x04] + [UInt8](repeating: 0x17, count: 16))
        // Android checks the chip's confirm value.
        #expect(Array(chipConfirm.dropFirst()) == BLEPairing.c1(BLEPairing.zeroKey, Array(chipRandom.dropFirst()), request: request,
                                                                response: response, initiator: android, responder: chip))
        let stk = BLEPairing.s1(BLEPairing.zeroKey, Array(chipRandom.dropFirst()), androidRandom)
        #expect(pairing.key(rand: [UInt8](repeating: 0, count: 8), ediv: [0, 0]) == stk)
        let keys = pairing.encrypted()
        let bond = BLEPairing.Key.derived(for: chipAddress)
        #expect(keys == [[0x06] + bond.ltk, [0x07] + bond.ediv + bond.rand])
        #expect(pairing.encrypted().isEmpty, "once")
        // The next connection's encryption, with the bond's key.
        #expect(pairing.key(rand: bond.rand, ediv: bond.ediv) == bond.ltk)
        #expect(BLEPairing(local: chip, peer: android, key: .derived(for: chipAddress)).key(rand: bond.rand, ediv: bond.ediv) == bond.ltk,
                "after a restart too")
        #expect(pairing.key(rand: [9, 9, 9, 9, 9, 9, 9, 9], ediv: [1, 2]) == nil)
    }

    @Test func aWrongConfirmValueFailsAndShortKeysAreRefused() throws {
        let chip = BLEPairing.Address(type: 1, bytes: [1, 2, 3, 4, 5, 0xC6])
        var pairing = BLEPairing(local: chip, peer: .init(type: 0, bytes: [1, 1, 1, 1, 1, 1]), key: .derived(for: chip.bytes))
        _ = pairing.received([0x01, 0x03, 0x00, 0x01, 0x10, 0x00, 0x01])
        _ = pairing.received([0x03] + [UInt8](repeating: 0xAB, count: 16))
        #expect(pairing.received([0x04] + [UInt8](repeating: 0x01, count: 16)) == [0x05, 0x04])
        #expect(pairing.key(rand: [UInt8](repeating: 0, count: 8), ediv: [0, 0]) == nil)
        #expect(pairing.received([0x01, 0x03, 0x00, 0x01, 0x06, 0x00, 0x01]) == [0x05, 0x06])
        // Pairing without bonding: no key handed out.
        var once = BLEPairing(local: chip, peer: .init(type: 0, bytes: [1, 1, 1, 1, 1, 1]), key: .derived(for: chip.bytes))
        #expect(once.received([0x01, 0x03, 0x00, 0x00, 0x10, 0x00, 0x01]) == [0x02, 0x03, 0x00, 0x00, 0x10, 0x00, 0x00])
    }
}
