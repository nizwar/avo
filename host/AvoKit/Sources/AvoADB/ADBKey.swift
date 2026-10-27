import Foundation
import Security

public enum ADBKeyError: Error, Equatable, Sendable {
    case invalidPEM
    case invalidDER(String)
    case security(String)
    case unsupportedKeySize(Int)
}

/// The RSA key the daemon authenticates to adbd with.
///
/// Stored as PKCS#8 PEM (the same format as `~/.android/adbkey`). Under
/// crosvm the image trusts the matching public key, which the daemon hands
/// to the guest at boot (avo_config). Under avo-vmm, adbd in the stock
/// userdebug image asks no key, and its vsock port is this user's only:
/// ADB support's TCP port asks clients for one instead (ADBAuthGate).
public struct ADBKey: @unchecked Sendable {
    let privateKey: SecKey

    init(privateKey: SecKey) {
        self.privateKey = privateKey
    }

    public var publicKey: SecKey? { SecKeyCopyPublicKey(privateKey) }

    public static func generate() throws -> ADBKey {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw ADBKeyError.security(error.map { String(describing: $0.takeRetainedValue()) } ?? "key generation failed")
        }
        return ADBKey(privateKey: key)
    }

    /// Loads a PEM key (PKCS#8 `PRIVATE KEY` or PKCS#1 `RSA PRIVATE KEY`).
    public init(pem: String) throws {
        let lines = pem.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let begin = lines.firstIndex(where: { $0.hasPrefix("-----BEGIN ") }),
              let end = lines.lastIndex(where: { $0.hasPrefix("-----END ") }), begin < end,
              let der = Data(base64Encoded: lines[(begin + 1)..<end].joined()) else {
            throw ADBKeyError.invalidPEM
        }
        let pkcs1 = lines[begin].contains("RSA PRIVATE KEY") ? der : try DER.unwrapPKCS8(der)
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
            throw ADBKeyError.security(error.map { String(describing: $0.takeRetainedValue()) } ?? "invalid key")
        }
        privateKey = key
    }

    public static func load(from url: URL) throws -> ADBKey {
        try ADBKey(pem: String(contentsOf: url, encoding: .utf8))
    }

    /// Loads the key at `url`, creating it (mode 0600) when missing.
    public static func loadOrCreate(at url: URL) throws -> ADBKey {
        if FileManager.default.fileExists(atPath: url.path) { return try load(from: url) }
        let key = try generate()
        try key.save(to: url)
        return key
    }

    public func pem() throws -> String {
        var error: Unmanaged<CFError>?
        guard let pkcs1 = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
            throw ADBKeyError.security(error.map { String(describing: $0.takeRetainedValue()) } ?? "export failed")
        }
        let base64 = DER.wrapPKCS8(pkcs1).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN PRIVATE KEY-----\n\(base64)\n-----END PRIVATE KEY-----\n"
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(try pem().utf8), attributes: [.posixPermissions: 0o600])
    }

    /// Signs an AUTH token. adbd verifies it with RSA_verify(NID_sha1, token),
    /// i.e. the token is treated as an already-computed SHA-1 digest.
    public func sign(token: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureDigestPKCS1v15SHA1, token as CFData, &error) as Data? else {
            throw ADBKeyError.security(error.map { String(describing: $0.takeRetainedValue()) } ?? "signing failed")
        }
        return signature
    }

    /// The public key in Android's format: base64 of the mincrypt `RSAPublicKey`
    /// struct, optionally followed by a space and a comment (`user@host`).
    public func androidPublicKey(comment: String? = nil) throws -> String {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { throw ADBKeyError.security("no public key") }
        var error: Unmanaged<CFError>?
        guard let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw ADBKeyError.security(error.map { String(describing: $0.takeRetainedValue()) } ?? "export failed")
        }
        let (modulus, exponent) = try DER.rsaPublicKey(pkcs1)
        let encoded = try AndroidRSAPublicKey.encode(modulus: modulus, exponent: exponent).base64EncodedString()
        return comment.map { "\(encoded) \($0)" } ?? encoded
    }
}

/// mincrypt's RSAPublicKey: { u32 len; u32 n0inv; u32 n[len]; u32 rr[len]; i32 exponent }
/// with little-endian words, where rr = (2^(32*len))^2 mod n.
enum AndroidRSAPublicKey {
    static func encode(modulus: [UInt8], exponent: [UInt8]) throws -> Data {
        var bigEndian = modulus
        while bigEndian.first == 0 { bigEndian.removeFirst() }
        guard bigEndian.count == 256 else { throw ADBKeyError.unsupportedKeySize(bigEndian.count * 8) }
        let words = 64
        // Little-endian 32-bit words of n.
        var n = [UInt32](repeating: 0, count: words)
        for i in 0..<words {
            let start = bigEndian.count - (i + 1) * 4
            n[i] = UInt32(bigEndian[start]) << 24 | UInt32(bigEndian[start + 1]) << 16
                | UInt32(bigEndian[start + 2]) << 8 | UInt32(bigEndian[start + 3])
        }

        // n0inv = -1 / n[0] mod 2^32 (Newton iteration; n is odd).
        var inverse: UInt32 = n[0]
        for _ in 0..<5 { inverse = inverse &* (2 &- n[0] &* inverse) }
        let n0inv = 0 &- inverse

        // rr = 2^(2 * 2048) mod n by repeated doubling.
        var r = [UInt32](repeating: 0, count: words + 1)
        r[0] = 1
        for _ in 0..<(2 * 32 * words) {
            var carry: UInt32 = 0
            for i in 0...words {
                let next = r[i] >> 31
                r[i] = r[i] << 1 | carry
                carry = next
            }
            if !lessThan(r, n) { subtract(&r, n) }
        }

        var exponentValue: UInt32 = 0
        for byte in exponent { exponentValue = exponentValue << 8 | UInt32(byte) }

        var out = Data(capacity: 8 + 2 * 4 * words + 4)
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        append(UInt32(words))
        append(n0inv)
        n.forEach(append)
        r.prefix(words).forEach(append)
        append(exponentValue)
        return out
    }

    /// (modulus, exponent), big-endian, from the struct `encode` writes
    /// (an `adbkey.pub` line, base64-decoded).
    static func decode(_ data: Data) throws -> (modulus: [UInt8], exponent: [UInt8]) {
        let bytes = [UInt8](data)
        func word(_ index: Int) -> UInt32 {
            let at = index * 4
            return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        guard bytes.count >= 4 else { throw ADBKeyError.invalidDER("not an Android public key") }
        let words = Int(word(0))
        guard words == 64 else { throw ADBKeyError.unsupportedKeySize(words * 32) }
        guard bytes.count == 8 + 2 * 4 * words + 4 else { throw ADBKeyError.invalidDER("not an Android public key") }
        // n[0] is the least significant word.
        var modulus: [UInt8] = []
        for i in (0..<words).reversed() {
            let value = word(2 + i)
            modulus += [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        }
        let e = word(2 + 2 * words)
        var exponent = [UInt8(e >> 24), UInt8(e >> 16 & 0xFF), UInt8(e >> 8 & 0xFF), UInt8(e & 0xFF)]
        while exponent.count > 1, exponent.first == 0 { exponent.removeFirst() }
        return (modulus, exponent)
    }

    /// r (words + 1) < n (words), comparing as unsigned big integers.
    private static func lessThan(_ r: [UInt32], _ n: [UInt32]) -> Bool {
        if r[n.count] != 0 { return false }
        for i in stride(from: n.count - 1, through: 0, by: -1) where r[i] != n[i] {
            return r[i] < n[i]
        }
        return false
    }

    private static func subtract(_ r: inout [UInt32], _ n: [UInt32]) {
        var borrow: UInt64 = 0
        for i in 0..<r.count {
            let subtrahend = UInt64(i < n.count ? n[i] : 0) + borrow
            let minuend = UInt64(r[i])
            if minuend >= subtrahend {
                r[i] = UInt32(minuend - subtrahend)
                borrow = 0
            } else {
                r[i] = UInt32(minuend + (1 << 32) - subtrahend)
                borrow = 1
            }
        }
    }
}

/// Just enough DER to move RSA keys between PKCS#1 and PKCS#8.
enum DER {
    private static let rsaAlgorithm: [UInt8] = [
        0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00,
    ]

    struct Element {
        let tag: UInt8
        let content: ArraySlice<UInt8>
        let end: Int
    }

    static func element(_ bytes: [UInt8], at start: Int) throws -> Element {
        guard start + 2 <= bytes.count else { throw ADBKeyError.invalidDER("truncated") }
        let tag = bytes[start]
        var length = Int(bytes[start + 1])
        var offset = start + 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, offset + count <= bytes.count else { throw ADBKeyError.invalidDER("bad length") }
            length = 0
            for i in 0..<count { length = length << 8 | Int(bytes[offset + i]) }
            offset += count
        }
        guard offset + length <= bytes.count else { throw ADBKeyError.invalidDER("content past end") }
        return Element(tag: tag, content: bytes[offset..<(offset + length)], end: offset + length)
    }

    static func unwrapPKCS8(_ der: Data) throws -> Data {
        let bytes = [UInt8](der)
        let outer = try element(bytes, at: 0)
        guard outer.tag == 0x30 else { throw ADBKeyError.invalidDER("expected SEQUENCE") }
        let version = try element(bytes, at: outer.content.startIndex)
        let algorithm = try element(bytes, at: version.end)
        let key = try element(bytes, at: algorithm.end)
        guard version.tag == 0x02, algorithm.tag == 0x30, key.tag == 0x04 else {
            throw ADBKeyError.invalidDER("not a PKCS#8 private key")
        }
        return Data(key.content)
    }

    static func wrapPKCS8(_ pkcs1: Data) -> Data {
        let body = [0x02, 0x01, 0x00] + rsaAlgorithm + [0x04] + length(pkcs1.count) + [UInt8](pkcs1)
        return Data([0x30] + length(body.count) + body)
    }

    /// A PKCS#1 RSAPublicKey, as SecKeyCreateWithData takes it.
    static func pkcs1PublicKey(modulus: [UInt8], exponent: [UInt8]) -> Data {
        func integer(_ value: [UInt8]) -> [UInt8] {
            var content = value
            while content.count > 1, content.first == 0 { content.removeFirst() }
            if let first = content.first, first & 0x80 != 0 { content.insert(0, at: 0) }
            return [0x02] + length(content.count) + content
        }
        let body = integer(modulus) + integer(exponent)
        return Data([0x30] + length(body.count) + body)
    }

    /// (modulus, exponent) from a PKCS#1 RSAPublicKey.
    static func rsaPublicKey(_ der: Data) throws -> ([UInt8], [UInt8]) {
        let bytes = [UInt8](der)
        let sequence = try element(bytes, at: 0)
        let modulus = try element(bytes, at: sequence.content.startIndex)
        let exponent = try element(bytes, at: modulus.end)
        guard sequence.tag == 0x30, modulus.tag == 0x02, exponent.tag == 0x02 else {
            throw ADBKeyError.invalidDER("not an RSA public key")
        }
        return (Array(modulus.content), Array(exponent.content))
    }

    private static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
}
