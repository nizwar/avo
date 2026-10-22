import Foundation

/// Thin wrappers over BSD sockets for AF_UNIX stream sockets.
public enum UnixSocket {
    /// Darwin's sockaddr_un.sun_path holds 104 bytes including the terminator.
    public static let maxPathLength = 103

    public static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IOError.errno("socket") }
        do {
            try withAddress(path) { address, length in
                if Darwin.connect(fd, address, length) != 0 { throw IOError.errno("connect \(path)") }
            }
        } catch {
            close(fd)
            throw error
        }
        FileDescriptorStream.disableSIGPIPE(fd)
        return fd
    }

    /// Binds and listens on `path`, replacing a stale socket file.
    public static func listen(path: String, backlog: Int32 = 16) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IOError.errno("socket") }
        unlink(path)
        do {
            try withAddress(path) { address, length in
                if bind(fd, address, length) != 0 { throw IOError.errno("bind \(path)") }
            }
            guard Darwin.listen(fd, backlog) == 0 else { throw IOError.errno("listen") }
        } catch {
            close(fd)
            throw error
        }
        return fd
    }

    /// Blocks until a client connects.
    public static func accept(_ listener: Int32) throws -> Int32 {
        while true {
            let fd = Darwin.accept(listener, nil, nil)
            if fd >= 0 {
                FileDescriptorStream.disableSIGPIPE(fd)
                return fd
            }
            if errno != EINTR { throw IOError.errno("accept") }
        }
    }

    public static func pair() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw IOError.errno("socketpair") }
        // A write to an end whose peer closed fails with EPIPE instead of killing the process.
        FileDescriptorStream.disableSIGPIPE(fds[0])
        FileDescriptorStream.disableSIGPIPE(fds[1])
        return (fds[0], fds[1])
    }

    private static func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Void) throws {
        let bytes = Array(path.utf8)
        guard bytes.count <= maxPathLength else { throw IOError.pathTooLong(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    // MARK: Blocking helpers with timeouts (used before handing a socket to DispatchIO)

    static func waitReadable(_ fd: Int32, deadline: ContinuousClock.Instant) throws {
        while true {
            let remaining = deadline - .now
            guard remaining > .zero else { throw IOError.timedOut("socket read") }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let millis = Int32(min(remaining.components.seconds * 1000 + remaining.components.attoseconds / 1_000_000_000_000_000, 60_000))
            let result = poll(&descriptor, 1, max(millis, 1))
            if result > 0 { return }
            if result < 0 && errno != EINTR { throw IOError.errno("poll") }
        }
    }

    /// Reads one `\n`-terminated line byte by byte, so no bytes after the line are consumed.
    static func readLine(_ fd: Int32, deadline: ContinuousClock.Instant, limit: Int = 256) throws -> String {
        var bytes: [UInt8] = []
        while bytes.count < limit {
            try waitReadable(fd, deadline: deadline)
            var byte: UInt8 = 0
            let n = Darwin.read(fd, &byte, 1)
            if n == 0 { throw IOError.closed }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw IOError.errno("read")
            }
            if byte == UInt8(ascii: "\n") { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
        throw IOError.handshake("line too long")
    }

    static func writeAll(_ fd: Int32, _ data: [UInt8]) throws {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, data.count - offset) }
            if n < 0 {
                if errno == EINTR { continue }
                throw IOError.errno("write")
            }
            offset += n
        }
    }
}

/// Connects to guest vsock ports through the engine's Unix socket, using
/// Firecracker's hybrid vsock convention:
///
///     -> CONNECT <port>\n
///     <- OK <host-side port>\n
///     ... raw stream ...
public enum VsockBridge {
    public static func connect(socketPath: String, port: UInt32, timeout: Duration = .seconds(5)) throws -> FileDescriptorStream {
        let fd = try connectSocket(socketPath: socketPath, port: port, timeout: timeout)
        return FileDescriptorStream(fileDescriptor: fd, label: "com.avodroid.vsock.\(port)")
    }

    /// The connected socket itself (blocking); the caller closes it.
    public static func connectSocket(socketPath: String, port: UInt32, timeout: Duration = .seconds(5)) throws -> Int32 {
        let fd = try UnixSocket.connect(path: socketPath)
        do {
            let deadline = ContinuousClock.now + timeout
            try UnixSocket.writeAll(fd, Array("CONNECT \(port)\n".utf8))
            let reply = try UnixSocket.readLine(fd, deadline: deadline)
            guard reply.hasPrefix("OK ") else { throw IOError.handshake("engine replied \"\(reply)\" for port \(port)") }
        } catch {
            close(fd)
            throw error
        }
        return fd
    }
}
