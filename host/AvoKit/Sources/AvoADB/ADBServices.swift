import Foundation

public struct ShellResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public var output: String { String(decoding: stdout, as: UTF8.self) }
    public var errorOutput: String { String(decoding: stderr, as: UTF8.self) }
    public var succeeded: Bool { exitCode == 0 }
}

/// Shell protocol v2 packet ids (adb/shell_protocol.h).
enum ShellPacket: UInt8 {
    case stdin = 0, stdout = 1, stderr = 2, exit = 3, closeStdin = 4, windowSizeChange = 5
}

extension ADBConnection {
    /// How long a shell command may take unless its caller says otherwise:
    /// one that Android never finishes (it stopped answering) must not hold
    /// its caller, and whatever waits behind it, for good.
    public static let shellTimeout: Duration = .seconds(60)

    /// Runs a command with the shell v2 protocol (separate stdout/stderr and an exit code).
    /// `timeout` nil: as long as it takes (commands with their own limit).
    public func shell(_ command: String, timeout: Duration? = ADBConnection.shellTimeout) async throws -> ShellResult {
        let stream = try await open("shell,v2,raw:" + command)
        let started = SuspendingClock.now
        // Closing the stream ends the read below; the Mac sleeping is no time the command had.
        let timer = timeout.map { limit in
            Task {
                try await Task.sleep(for: limit, clock: .suspending)
                await stream.close()
            }
        }
        defer { timer?.cancel() }
        var buffer = Data()
        var stdout = Data()
        var stderr = Data()
        var exitCode: Int32?
        reading: for try await chunk in stream.incoming {
            buffer.append(chunk)
            while buffer.count >= 5 {
                let base = buffer.startIndex
                let id = buffer[base]
                let length = Int(buffer[base + 1]) | Int(buffer[base + 2]) << 8 | Int(buffer[base + 3]) << 16 | Int(buffer[base + 4]) << 24
                guard buffer.count >= 5 + length else { break }
                let payload = buffer.subdata(in: (base + 5)..<(base + 5 + length))
                buffer.removeSubrange(base..<(base + 5 + length))
                switch ShellPacket(rawValue: id) {
                case .stdout: stdout.append(payload)
                case .stderr: stderr.append(payload)
                case .exit:
                    exitCode = Int32(payload.first ?? 255)
                    break reading
                default: break
                }
            }
        }
        await stream.close()
        guard let exitCode else {
            if let timeout, SuspendingClock.now - started >= timeout {
                throw ADBError.timedOut("\(command): no answer from Android in \(timeout)")
            }
            throw ADBError.shell("\(command): stream closed without an exit status")
        }
        return ShellResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }

    /// Runs `command` with the raw `exec:` service, streaming `input` to its
    /// stdin, and returns everything it wrote to stdout.
    public func exec<Input: AsyncSequence>(_ command: String, input: Input) async throws -> Data
    where Input.Element == Data {
        let stream = try await open("exec:" + command)
        async let output = stream.readAll()
        do {
            for try await chunk in input { try await stream.write(chunk) }
        } catch {
            await stream.close()
            _ = try? await output
            throw error
        }
        let result = try await output
        await stream.close()
        return result
    }

    public func exec(_ command: String) async throws -> Data {
        try await exec(command, input: EmptyDataSequence())
    }

    // MARK: Sync (file push)

    /// Pushes a file with the sync protocol. Parent directories are created by
    /// adbd (`fixed_push_mkdir`).
    public func push<Input: AsyncSequence>(_ input: Input, to remotePath: String, mode: UInt32 = 0o644,
                                           modificationTime: Date = Date(),
                                           progress: (@Sendable (UInt64) -> Void)? = nil) async throws
    where Input.Element == Data {
        guard remotePath.utf8.count <= 1024 else { throw ADBError.sync("path too long") }
        let stream = try await open("sync:")
        var replies = stream.incoming.makeAsyncIterator()
        func request(_ id: String, _ value: UInt32, _ data: Data = Data()) -> Data {
            var out = Data(id.utf8)
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
            out.append(data)
            return out
        }
        let pathAndMode = Data("\(remotePath),\(0o100000 | mode)".utf8)
        var pending = request("SEND", UInt32(pathAndMode.count), pathAndMode)
        let batch = max(maxPayload, 64 * 1024 + 8)
        var sent: UInt64 = 0
        for try await chunk in input {
            var offset = chunk.startIndex
            while offset < chunk.endIndex {
                let end = min(offset + 64 * 1024, chunk.endIndex)
                pending.append(request("DATA", UInt32(end - offset), chunk.subdata(in: offset..<end)))
                offset = end
                if pending.count + 64 * 1024 + 8 > batch {
                    try await stream.write(pending)
                    pending.removeAll(keepingCapacity: true)
                }
            }
            sent += UInt64(chunk.count)
            progress?(sent)
        }
        pending.append(request("DONE", UInt32(modificationTime.timeIntervalSince1970)))
        try await stream.write(pending)

        // Reply: "OKAY" + u32 0, or "FAIL" + u32 length + message.
        var reply = Data()
        while reply.count < 8 {
            guard let chunk = try await replies.next() else { throw ADBError.sync("no reply for \(remotePath)") }
            reply.append(chunk)
        }
        let id = String(decoding: reply.prefix(4), as: UTF8.self)
        if id == "FAIL" {
            let length = Int(reply[reply.startIndex + 4]) | Int(reply[reply.startIndex + 5]) << 8
            while reply.count < 8 + length, let chunk = try await replies.next() { reply.append(chunk) }
            let message = String(decoding: reply.dropFirst(8).prefix(length), as: UTF8.self)
            await stream.close()
            throw ADBError.sync("\(remotePath): \(message)")
        }
        guard id == "OKAY" else {
            await stream.close()
            throw ADBError.sync("unexpected reply \(id)")
        }
        try await stream.write(request("QUIT", 0))
        await stream.close()
    }

    // MARK: Package installation

    /// One APK of an install session.
    public struct InstallPart: Sendable {
        public let name: String
        public let size: UInt64
        /// Produces the APK bytes; called once.
        public let content: @Sendable () -> AsyncThrowingStream<Data, any Error>

        public init(name: String, size: UInt64, content: @escaping @Sendable () -> AsyncThrowingStream<Data, any Error>) {
            self.name = name
            self.size = size
            self.content = content
        }
    }

    /// Installs APKs with `pm install-create` / `install-write` / `install-commit`,
    /// abandoning the session on failure. `progress` receives bytes written.
    /// `session` hears of the session once Android created it (`open`), and
    /// again once Android committed or abandoned it: one it hears of only
    /// once, Android may still keep, with what was written to it (the
    /// connection went before the abandon).
    public func install(_ parts: [InstallPart], options: [String] = ["-r"],
                        progress: (@Sendable (UInt64, UInt64) -> Void)? = nil,
                        session report: (@Sendable (_ session: Int, _ open: Bool) -> Void)? = nil) async throws {
        let total = parts.reduce(UInt64(0)) { $0 + $1.size }
        let create = try await shell("pm install-create \(options.joined(separator: " ")) -S \(total)")
        guard let session = Self.sessionID(create.output) else {
            throw ADBError.install(Self.failure(create) ?? "could not create an install session")
        }
        report?(session, true)
        do {
            var written: UInt64 = 0
            for part in parts {
                let name = Self.shellQuote(part.name)
                let base = written
                let counter = ByteCounter()
                let counted = part.content().map { chunk -> Data in
                    counter.count += UInt64(chunk.count)
                    progress?(base + counter.count, total)
                    return chunk
                }
                let output = try await exec("cmd package install-write -S \(part.size) \(session) \(name) -", input: counted)
                let text = String(decoding: output, as: UTF8.self)
                guard text.contains("Success") else { throw ADBError.install(Self.trimmed(text, fallback: "install-write failed")) }
                written += part.size
            }
            // Android checks and optimizes the app first: minutes for a large game.
            let commit = try await shell("pm install-commit \(session)", timeout: .seconds(15 * 60))
            guard commit.output.contains("Success") else {
                throw ADBError.install(Self.failure(commit) ?? "install-commit failed")
            }
            report?(session, false)
        } catch {
            // Android answered: the session is gone (a failed commit ends it too).
            if (try? await shell("pm install-abandon \(session)")) != nil { report?(session, false) }
            throw error
        }
    }

    /// "Success: created install session [1234567]" -> 1234567
    static func sessionID(_ output: String) -> Int? {
        guard let open = output.firstIndex(of: "["), let close = output[open...].firstIndex(of: "]") else { return nil }
        return Int(output[output.index(after: open)..<close])
    }

    static func failure(_ result: ShellResult) -> String? {
        let text = (result.output + result.errorOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func trimmed(_ text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// Single-quotes an argument for the device shell.
    public static func shellQuote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// An empty async sequence of Data, for exec without stdin.
struct EmptyDataSequence: AsyncSequence, Sendable {
    typealias Element = Data
    struct AsyncIterator: AsyncIteratorProtocol {
        mutating func next() async throws -> Data? { nil }
    }
    func makeAsyncIterator() -> AsyncIterator { AsyncIterator() }
}

/// Running byte count for a single consumer.
final class ByteCounter: @unchecked Sendable {
    var count: UInt64 = 0
}
