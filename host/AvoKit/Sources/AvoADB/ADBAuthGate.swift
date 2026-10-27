import Darwin
import Foundation
import Security

/// A public key in Android's format (an `adbkey.pub` line: base64 of
/// mincrypt's `RSAPublicKey`, then a comment), which checks the signatures
/// an adb client makes of AUTH tokens.
public struct ADBPublicKey: @unchecked Sendable {
    private let key: SecKey

    public init(android line: String) throws {
        guard let field = line.split(whereSeparator: { $0 == " " || $0 == "\0" || $0.isNewline }).first,
              let data = Data(base64Encoded: String(field)) else {
            throw ADBKeyError.invalidDER("not an Android public key")
        }
        let (modulus, exponent) = try AndroidRSAPublicKey.decode(data)
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(DER.pkcs1PublicKey(modulus: modulus, exponent: exponent) as CFData,
                                             attributes as CFDictionary, &error) else {
            throw ADBKeyError.security(error.map { String(describing: $0.takeRetainedValue()) } ?? "not an RSA key")
        }
        self.key = key
    }

    /// The keys of an `adbkey.pub` file, one per line: none when it is
    /// missing (adb makes it the first time it runs).
    public static func load(from url: URL) -> [ADBPublicKey] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { try? ADBPublicKey(android: String($0)) }
    }

    /// `signature` is this key's of `token`, made as adb makes it:
    /// RSA_sign(NID_sha1), the token taken as an already-computed SHA-1 digest.
    public func verifies(_ signature: Data, of token: Data) -> Bool {
        SecKeyVerifySignature(key, .rsaSignatureDigestPKCS1v15SHA1, token as CFData, signature as CFData, nil)
    }
}

/// The device's half of ADB's AUTH handshake, for a connection Avo hands
/// on to adbd. adbd inside Android (a userdebug build, ro.adb.secure unset)
/// asks no key, so ADB support asks, as a phone does, before anything
/// reaches Android: the client proves it holds one of the trusted keys by
/// signing a fresh token. adb signs with each key it has in turn, then
/// offers its public key for the user to accept; a key that only offers
/// itself is refused, as there is nobody in Android to ask.
public enum ADBAuthGate {
    public struct Admission: Sendable {
        /// The client's CNXN, for adbd to answer.
        public var connect: ADBMessage
        /// What the client sent after its last message (nothing from adb,
        /// which waits for the device's CNXN).
        public var leftover: Data
    }

    public enum Refusal: Error, Equatable, Sendable {
        /// Something other than an adb client, or one that broke off.
        case notADB
        /// A client with none of the trusted keys; its public key's comment
        /// (adb's is `user@host`).
        case unknownKey(String)
        case timedOut
        case closed
    }

    /// Blocks until the client on `socket` signs a token with one of `keys`,
    /// or throws why it may not go on. The socket stays open either way.
    public static func admit(_ socket: Int32, keys: [ADBPublicKey], timeout: Duration = .seconds(10)) throws(Refusal) -> Admission {
        var reader = Reader(socket: socket, deadline: .now + timeout)
        let connect = try reader.next()
        guard connect.command == .connect else { throw .notADB }
        // adb has a few keys at most: more tries than that are not adb.
        for _ in 0..<16 {
            var token = Data(count: 20)
            let made = token.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 20, $0.baseAddress!) }
            guard made == errSecSuccess else { throw .closed }
            try reader.send(ADBMessage(.auth, ADBMessage.AuthType.token.rawValue, 0, token))
            let reply = try reader.next()
            guard reply.command == .auth else { throw .notADB }
            switch reply.arg0 {
            case ADBMessage.AuthType.signature.rawValue:
                if keys.contains(where: { $0.verifies(reply.payload, of: token) }) {
                    return Admission(connect: connect, leftover: reader.buffered)
                }
            case ADBMessage.AuthType.rsaPublicKey.rawValue:
                let offered = String(decoding: reply.payload.prefix { $0 != 0 }, as: UTF8.self)
                let comment = offered.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                throw .unknownKey(comment.trimmingCharacters(in: .whitespacesAndNewlines))
            default:
                throw .notADB
            }
        }
        throw .notADB
    }

    /// Messages from the client's socket, with what follows them kept.
    private struct Reader {
        let socket: Int32
        let deadline: ContinuousClock.Instant
        private var decoder = ADBMessageDecoder()

        init(socket: Int32, deadline: ContinuousClock.Instant) {
            self.socket = socket
            self.deadline = deadline
            // A CNXN, a signature or a public key: small.
            decoder.maxPayload = 64 * 1024
        }

        var buffered: Data { decoder.buffered }

        mutating func next() throws(Refusal) -> ADBMessage {
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                do {
                    if let message = try decoder.next() { return message }
                } catch {
                    throw .notADB
                }
                try wait(for: Int16(POLLIN))
                let count = read(socket, &chunk, chunk.count)
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                guard count > 0 else { throw .closed }
                decoder.append(Data(chunk[0..<count]))
            }
        }

        func send(_ message: ADBMessage) throws(Refusal) {
            // The checksum: clients from before 0x01000001 want it, later ones ignore it.
            let bytes = [UInt8](message.encoded(withChecksum: true))
            var sent = 0
            while sent < bytes.count {
                try wait(for: Int16(POLLOUT))
                let count = bytes[sent...].withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                guard count > 0 else { throw .closed }
                sent += count
            }
        }

        private func wait(for events: Int16) throws(Refusal) {
            while true {
                let left = deadline - .now
                guard left > .zero else { throw .timedOut }
                let (seconds, attoseconds) = left.components
                let milliseconds = max(1, min(Int64(Int32.max), seconds * 1000 + attoseconds / 1_000_000_000_000_000))
                var descriptor = pollfd(fd: socket, events: events, revents: 0)
                let ready = poll(&descriptor, 1, Int32(milliseconds))
                // Ready, or hung up: the read or write that follows says which.
                if ready > 0 { return }
                if ready < 0, errno != EINTR { throw .closed }
            }
        }
    }
}
