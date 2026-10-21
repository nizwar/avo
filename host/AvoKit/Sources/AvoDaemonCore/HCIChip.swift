import AvoIO
import Foundation

/// One chip in netsim's air, driven as its host over netsimd's HCI port
/// (H4 over TCP; engine/hvf/vmm/src/bluetooth.rs). Each connection to the
/// port is a new chip. Commands go one at a time and return their Command
/// Complete parameters; every other event, and the ACL data that comes in,
/// arrive on `packets` in order.
actor HCIChip {
    enum Packet: Sendable, Equatable {
        case event(code: UInt8, parameters: [UInt8])
        /// `boundary`: the packet boundary flag (0b10 starts an L2CAP frame, 0b01 continues one).
        case acl(handle: UInt16, boundary: UInt8, data: [UInt8])
    }

    struct CommandFailed: Error, Equatable, CustomStringConvertible {
        let opcode: UInt16
        let status: UInt8
        var description: String { String(format: "HCI command 0x%04x failed with status 0x%02x", opcode, status) }
    }

    nonisolated let packets: AsyncStream<Packet>
    private let packetSink: AsyncStream<Packet>.Continuation
    private let stream: FileDescriptorStream
    private var reader: Task<Void, Never>?
    private var pending: (opcode: UInt16, continuation: CheckedContinuation<[UInt8], any Error>)?
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var closed = false
    /// How long a command may take: netsim answers at once.
    private static let commandTimeout: Duration = .seconds(5)

    /// A new chip on netsimd's HCI port on this Mac.
    static func connect(port: UInt16) throws -> HCIChip {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IOError.posix(op: "socket", code: errno) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else {
            let code = errno
            Darwin.close(fd)
            throw IOError.posix(op: "connect to netsimd", code: code)
        }
        var on: Int32 = 1
        _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        return HCIChip(stream: FileDescriptorStream(fileDescriptor: fd, label: "dev.avo.bluetooth.chip"))
    }

    init(stream: FileDescriptorStream) {
        self.stream = stream
        (packets, packetSink) = AsyncStream.makeStream(of: Packet.self)
    }

    /// Starts reading the chip's packets (once).
    func start() {
        guard reader == nil else { return }
        reader = Task { [weak self, stream] in
            var input = StreamReader(stream)
            do {
                while !Task.isCancelled {
                    let indicator = try await input.read(exactly: 1)[0]
                    switch indicator {
                    case 0x04:
                        let header = try await input.read(exactly: 2)
                        let parameters = [UInt8](try await input.read(exactly: Int(header[1])))
                        await self?.received(event: header[0], parameters)
                    case 0x02:
                        let header = [UInt8](try await input.read(exactly: 4))
                        let length = Int(header[2]) | Int(header[3]) << 8
                        let data = [UInt8](try await input.read(exactly: length))
                        let handle = (UInt16(header[0]) | UInt16(header[1]) << 8) & 0x0FFF
                        await self?.deliver(.acl(handle: handle, boundary: (header[1] >> 4) & 0x3, data: data))
                    default:
                        throw IOError.handshake(String(format: "HCI packet type 0x%02x", indicator))
                    }
                }
            } catch {}
            await self?.close()
        }
    }

    /// Sends a command and returns its Command Complete parameters after
    /// the status (or nothing, for a command answered with Command Status).
    /// Throws `CommandFailed` for a status other than success.
    @discardableResult
    func command(_ opcode: UInt16, _ parameters: [UInt8] = []) async throws -> [UInt8] {
        while busy { await withCheckedContinuation { waiting.append($0) } }
        busy = true
        defer {
            busy = false
            if !waiting.isEmpty { waiting.removeFirst().resume() }
        }
        guard !closed else { throw IOError.closed }
        let packet = [0x01, UInt8(opcode & 0xFF), UInt8(opcode >> 8), UInt8(parameters.count)] + parameters
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.commandTimeout)
            await self?.fail(opcode, IOError.timedOut(String(format: "HCI command 0x%04x", opcode)))
        }
        defer { timeout.cancel() }
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], any Error>) in
            pending = (opcode, continuation)
            Task { [stream] in
                do { try await stream.write(Data(packet)) } catch { self.fail(opcode, error) }
            }
        }
        guard let status = response.first else { return [] }
        guard status == 0 else { throw CommandFailed(opcode: opcode, status: status) }
        return Array(response.dropFirst())
    }

    /// Sends ACL data (`boundary` 0b00 starts an L2CAP frame, 0b01 continues one).
    func send(acl handle: UInt16, boundary: UInt8, _ data: [UInt8]) async throws {
        guard !closed else { throw IOError.closed }
        let header: [UInt8] = [0x02, UInt8(handle & 0xFF), UInt8(handle >> 8 & 0x0F) | boundary << 4,
                               UInt8(data.count & 0xFF), UInt8(data.count >> 8)]
        try await stream.write(Data(header + data))
    }

    /// Ends the chip: netsim takes it out of the air.
    func close() {
        guard !closed else { return }
        closed = true
        reader?.cancel()
        stream.close()
        packetSink.finish()
        if let pending {
            self.pending = nil
            pending.continuation.resume(throwing: IOError.closed)
        }
    }

    private func received(event code: UInt8, _ parameters: [UInt8]) {
        switch code {
        case 0x0E where parameters.count >= 3:
            // Command Complete: credits, opcode, return parameters (status first).
            let opcode = UInt16(parameters[1]) | UInt16(parameters[2]) << 8
            if opcode != 0 { finish(opcode, Array(parameters.dropFirst(3))) }
        case 0x0F where parameters.count >= 4:
            // Command Status: status, credits, opcode.
            let opcode = UInt16(parameters[2]) | UInt16(parameters[3]) << 8
            if opcode != 0 { finish(opcode, [parameters[0]]) }
        default:
            deliver(.event(code: code, parameters: parameters))
        }
    }

    private func deliver(_ packet: Packet) {
        packetSink.yield(packet)
    }

    private func finish(_ opcode: UInt16, _ response: [UInt8]) {
        guard let pending, pending.opcode == opcode else { return }
        self.pending = nil
        pending.continuation.resume(returning: response)
    }

    private func fail(_ opcode: UInt16, _ error: any Error) {
        guard let pending, pending.opcode == opcode else { return }
        self.pending = nil
        pending.continuation.resume(throwing: error)
    }
}

/// HCI opcodes the proxy chips send (Core 6.0, Vol 4, Part E, 7).
enum HCIOpcode {
    static let disconnect: UInt16 = 0x0406
    static let setEventMask: UInt16 = 0x0C01
    static let reset: UInt16 = 0x0C03
    static let readBufferSize: UInt16 = 0x1005
    static let leSetEventMask: UInt16 = 0x2001
    static let leReadBufferSize: UInt16 = 0x2002
    static let leSetRandomAddress: UInt16 = 0x2005
    static let leSetAdvertisingParameters: UInt16 = 0x2006
    static let leSetAdvertisingData: UInt16 = 0x2008
    static let leSetScanResponseData: UInt16 = 0x2009
    static let leSetAdvertisingEnable: UInt16 = 0x200A
    static let leSetScanParameters: UInt16 = 0x200B
    static let leSetScanEnable: UInt16 = 0x200C
    static let leCreateConnection: UInt16 = 0x200D
    static let leLongTermKeyRequestNegativeReply: UInt16 = 0x201B
}
