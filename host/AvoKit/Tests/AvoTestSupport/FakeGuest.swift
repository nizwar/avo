import AvoDaemonCore
import AvoIO
import AvoKit
import AvoProtocol
import CoreGraphics
import Foundation
import ImageIO
import Security

/// A Bridge Agent stand-in that speaks the real Control protocol, mirroring
/// what guest/bridge-agent does in Android.
public actor FakeBridgeAgent {
    public private(set) var received: [Avo_V1_Envelope] = []
    public private(set) var apps: [Avo_V1_AppInfo]
    public var sdk: UInt32 = 36
    public var protocolVersion: UInt32 = 1
    public var minimumProtocolVersion: UInt32 = 1
    private var streams: [FileDescriptorStream] = []
    private var current: FileDescriptorStream?
    /// Launches Android has not answered yet (`holdLaunches`).
    private var heldLaunches: [(Avo_V1_Envelope, FileDescriptorStream)]?

    public init(apps: [Avo_V1_AppInfo]) {
        self.apps = apps
    }

    public func setProtocol(version: UInt32, minimum: UInt32) {
        protocolVersion = version
        minimumProtocolVersion = minimum
    }

    /// Serves one Control connection (the agent accepts a new one after each reconnect).
    public func serve(_ stream: FileDescriptorStream) async {
        streams.append(stream)
        current = stream
        var decoder = ControlFrameDecoder()
        do {
            for try await chunk in stream.incoming {
                decoder.append(chunk)
                while let envelope = try decoder.next() { await handle(envelope, on: stream) }
            }
        } catch {}
    }

    private func send(_ envelope: Avo_V1_Envelope, on stream: FileDescriptorStream) async {
        try? await stream.write(ControlFraming.encode(envelope))
    }

    private func reply(_ request: Avo_V1_Envelope, on stream: FileDescriptorStream, status: Avo_V1_Reply.Status = .ok) async {
        var reply = Avo_V1_Reply()
        reply.status = status
        await send(Avo_V1_Envelope(.reply(reply), requestID: request.requestID), on: stream)
    }

    private func handle(_ envelope: Avo_V1_Envelope, on stream: FileDescriptorStream) async {
        received.append(envelope)
        switch envelope.payload {
        case .hello?:
            var hello = Avo_V1_Hello()
            hello.protocolVersion = protocolVersion
            hello.minProtocolVersion = minimumProtocolVersion
            hello.softwareVersion = "avo-image fake"
            hello.androidSdk = sdk
            hello.deviceProfileID = DeviceProfile.defaultID
            await send(Avo_V1_Envelope(.hello(hello)), on: stream)
        case .ping(let ping)?:
            var pong = Avo_V1_Pong()
            pong.nonce = ping.nonce
            await send(Avo_V1_Envelope(.pong(pong), requestID: envelope.requestID), on: stream)
        case .listApps?:
            var list = Avo_V1_AppList()
            list.apps = apps
            await send(Avo_V1_Envelope(.appList(list), requestID: envelope.requestID), on: stream)
        case .launch?:
            if heldLaunches != nil {
                heldLaunches?.append((envelope, stream))
            } else {
                await answerLaunch(envelope, on: stream)
            }
        case .uninstall(let uninstall)?:
            await reply(envelope, on: stream)
            apps.removeAll { $0.package == uninstall.package }
            var removed = Avo_V1_AppRemoved()
            removed.package = uninstall.package
            await send(Avo_V1_Envelope(.appRemoved(removed)), on: stream)
        case .getPermissions(let request)?:
            var list = Avo_V1_PermissionList()
            list.package = request.package
            var camera = Avo_V1_Permission()
            camera.name = "android.permission.CAMERA"
            camera.label = "Camera"
            camera.runtime = true
            list.permissions = [camera]
            await send(Avo_V1_Envelope(.permissionList(list), requestID: envelope.requestID), on: stream)
        default:
            if envelope.requestID != 0 { await reply(envelope, on: stream) }
        }
    }

    private func answerLaunch(_ envelope: Avo_V1_Envelope, on stream: FileDescriptorStream) async {
        guard case .launch(let launch)? = envelope.payload else { return }
        guard apps.contains(where: { $0.package == launch.package }) else {
            await reply(envelope, on: stream, status: .notFound)
            return
        }
        await reply(envelope, on: stream)
        var ready = Avo_V1_DisplayReady()
        ready.displayID = launch.displayID
        ready.package = launch.package
        await send(Avo_V1_Envelope(.displayReady(ready)), on: stream)
    }

    /// Launches wait for `releaseLaunches` (an app still starting, its window
    /// "Starting…"), while other requests are answered, as Android's host
    /// side answers them meanwhile.
    public func holdLaunches() {
        if heldLaunches == nil { heldLaunches = [] }
    }

    /// Answers the launches held so far, and every later one at once.
    public func releaseLaunches() async {
        let held = heldLaunches ?? []
        heldLaunches = nil
        for (envelope, stream) in held { await answerLaunch(envelope, on: stream) }
    }

    /// What ListApps answers from now on, without an event (Android's own
    /// view changing, as when apps resolve again after an unlock).
    public func setApps(_ apps: [Avo_V1_AppInfo]) {
        self.apps = apps
    }

    /// Simulates PACKAGE_ADDED.
    public func install(_ app: Avo_V1_AppInfo) async {
        apps.removeAll { $0.package == app.package }
        apps.append(app)
        var installed = Avo_V1_AppInstalled()
        installed.app = app
        if let current { await send(Avo_V1_Envelope(.appInstalled(installed)), on: current) }
    }

    /// Sends any guest event.
    public func emit(_ payload: Avo_V1_Envelope.OneOf_Payload) async {
        if let current { await send(Avo_V1_Envelope(payload), on: current) }
    }

    /// The agent goes away (it crashed): the Control connection closes.
    public func dropConnection() {
        current?.close()
    }

    public func requests<T>(_ extract: (Avo_V1_Envelope.OneOf_Payload) -> T?) -> [T] {
        received.compactMap { $0.payload.flatMap(extract) }
    }

    public static func app(_ package: String, label: String, launchable: Bool = true) -> Avo_V1_AppInfo {
        var info = Avo_V1_AppInfo()
        info.package = package
        info.label = label
        info.versionName = "1.0"
        info.versionCode = 1
        info.launchable = launchable
        info.iconPng = FakeIcon.png
        return info
    }
}

/// Collects Input channel records after the preamble exchange.
public actor FakeInputSink {
    public private(set) var records: [InputRecord] = []

    public init() {}

    public func serve(_ stream: FileDescriptorStream) async {
        var buffer: [UInt8] = []
        var negotiated = false
        var decoder = InputRecordDecoder()
        do {
            for try await chunk in stream.incoming {
                if negotiated {
                    decoder.append(chunk)
                } else {
                    buffer += chunk
                    guard buffer.count >= 8 else { continue }
                    try await stream.write(Data(InputWire.preamble()))
                    negotiated = true
                    decoder.append(buffer.dropFirst(8))
                }
                while let record = try decoder.next() { records.append(record) }
            }
        } catch {}
    }
}

/// An engine that boots instantly and wires vsock ports to in-process fakes.
public final class FakeEngine: VMEngine, @unchecked Sendable {
    public let name = "fake"
    public let exits: AsyncStream<(any Error)?>
    private let exitSink: AsyncStream<(any Error)?>.Continuation
    public let agent: FakeBridgeAgent
    public let input = FakeInputSink()
    public let adbPublicKey: SecKey?
    public private(set) var adbd: FakeADBD?
    private let lock = NSLock()
    private var running = false
    private var stopped = 0
    public private(set) var launches: [EngineLaunch] = []
    public var refuseControlConnections = 0
    /// How long a start takes, cancelled or not (avo-vmm's own start before
    /// it hands its process over: a stop meanwhile does not end it).
    public var startDelay: Duration = .zero
    public var isRunning: Bool { lock.withLock { running } }
    public var stops: Int { lock.withLock { stopped } }
    /// Shell handler installed on the fake adbd before it serves anything.
    public var adbShellHandler: (@Sendable (String) -> (stdout: String, stderr: String, exit: UInt8))?

    public init(agent: FakeBridgeAgent, adbPublicKey: SecKey? = nil) {
        self.agent = agent
        self.adbPublicKey = adbPublicKey
        (exits, exitSink) = AsyncStream.makeStream(of: (any Error)?.self)
    }

    public func start(_ launch: EngineLaunch) async throws {
        let delay = lock.withLock { startDelay }
        if delay > .zero { await Task.detached { try? await Task.sleep(for: delay) }.value }
        lock.withLock {
            launches.append(launch)
            running = true
        }
    }

    public func stop() async {
        lock.withLock {
            running = false
            stopped += 1
        }
        exitSink.yield(nil)
    }

    public func snapshot(to url: URL) async throws {
        try Data("snapshot".utf8).write(to: url)
    }

    /// Simulates the engine process exiting with `error` (nil: a clean exit).
    public func exit(_ error: (any Error)?) {
        lock.withLock { running = false }
        exitSink.yield(error)
    }

    /// Simulates a crash of the engine process.
    public func crash() {
        lock.withLock { running = false }
        exitSink.yield(AvoError.vmStartFailed("engine crashed"))
    }

    public func connect(port: UInt32) async throws -> any ByteStream {
        let refuse: Bool = lock.withLock {
            guard running else { return true }
            if port == AvoProtocol.Port.control && refuseControlConnections > 0 {
                refuseControlConnections -= 1
                return true
            }
            return false
        }
        if refuse { throw IOError.handshake("port \(port) not listening yet") }
        let (host, guest) = try UnixSocket.pair()
        switch port {
        case AvoProtocol.Port.control:
            let agent = self.agent
            let stream = FileDescriptorStream(fileDescriptor: guest, label: "fake-guest-control")
            Task { await agent.serve(stream) }
        case AvoProtocol.Port.input:
            let input = self.input
            let stream = FileDescriptorStream(fileDescriptor: guest, label: "fake-guest-input")
            Task { await input.serve(stream) }
        case AvoProtocol.Port.adb:
            guard let adbPublicKey else {
                close(host)
                close(guest)
                throw IOError.handshake("no adbd")
            }
            let device = FakeADBD(fileDescriptor: guest, publicKey: adbPublicKey, maxPayload: 256 * 1024)
            let handler = lock.withLock { () -> (@Sendable (String) -> (stdout: String, stderr: String, exit: UInt8))? in
                adbd = device
                return adbShellHandler
            }
            Task {
                if let handler { await device.setShellHandler(handler) }
                await device.run()
            }
        default:
            close(host)
            close(guest)
            throw IOError.handshake("nothing on port \(port)")
        }
        return FileDescriptorStream(fileDescriptor: host, label: "fake-host-\(port)")
    }
}

public enum FakeIcon {
    /// A 4x4 green PNG.
    public static let png: Data = {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }()
}
