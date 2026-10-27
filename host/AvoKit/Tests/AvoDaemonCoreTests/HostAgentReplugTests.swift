import AvoADB
import AvoIO
import AvoProtocol
import AvoTestSupport
import Foundation
import Synchronization
import Testing
@testable import AvoDaemonCore

/// Android's displays as the engine's scanouts come and go, with the gap
/// that crashed SurfaceFlinger (`HostAgent.waitForDisplayRemoved`): an
/// unplugged display loses its EDID in SurfaceFlinger's list at once but
/// stays in it until SurfaceFlinger's commit, `commit` later, and in
/// DisplayManager's a little longer. Plugging a scanout inside that gap is
/// what crashed Android, and is recorded as a violation.
private final class AndroidDisplays: Sendable {
    struct Scanout: Sendable {
        var plugged: Bool
        var width: UInt32 = 0
        var height: UInt32 = 0
        var at: ContinuousClock.Instant
        /// Avo's composer: the size before an in-place resize, until Android has the new one.
        var previous: (width: UInt32, height: UInt32, until: ContinuousClock.Instant)?
    }

    static let commit: Duration = .milliseconds(300)
    static let managerLag: Duration = .milliseconds(60)
    static let add: Duration = .milliseconds(80)
    static let reconnect: Duration = .milliseconds(40)
    /// Avo's composer runs (GuestComposer): a plugged scanout takes a new size in place.
    let composerPatched: Bool
    let scanouts = Mutex<[Int: Scanout]>([:])
    let engineLog = Mutex<[String]>([])
    let violations = Mutex<[String]>([])
    /// Every shell command, in order.
    let commands = Mutex<[String]>([])

    init(composerPatched: Bool = false) {
        self.composerPatched = composerPatched
    }

    static func physicalID(_ scanout: Int) -> String { String(4_619_827_124_781_842_688 + UInt64(scanout)) }

    /// avo-vmm's `display <i> off` and `display <i> <w> <h> <hz>` (the rest is not displays).
    func engine(_ line: String) {
        let words = line.split(separator: " ")
        guard words.count >= 3, words[0] == "display", let index = Int(words[1]) else { return }
        engineLog.withLock { $0.append(line) }
        scanouts.withLock { scanouts in
            let now = ContinuousClock.now
            if words[2] == "off" {
                if scanouts[index]?.plugged == true { scanouts[index] = Scanout(plugged: false, at: now) }
                return
            }
            if let old = scanouts[index], !old.plugged, now - old.at < Self.commit {
                violations.withLock { $0.append("scanout \(index) plugged \(now - old.at) after its unplug") }
            }
            let width = UInt32(words[2]) ?? 0
            let height = words.count > 3 ? UInt32(words[3]) ?? 0 : 0
            if composerPatched, var scanout = scanouts[index], scanout.plugged {
                scanout.previous = (scanout.width, scanout.height, now + Self.reconnect)
                scanout.width = width
                scanout.height = height
                scanouts[index] = scanout
                return
            }
            scanouts[index] = Scanout(plugged: true, width: width, height: height, at: now)
        }
    }

    private func current() -> [(index: Int, scanout: Scanout, age: Duration)] {
        let now = ContinuousClock.now
        return scanouts.withLock { $0 }.sorted { $0.key < $1.key }.map { ($0.key, $0.value, now - $0.value.at) }
    }

    /// `dumpsys SurfaceFlinger --display-id`
    func surfaceFlinger() -> String {
        var lines = [#"Display 4619827259835644672 (HWC display 0): port=0 pnpId=GGL displayName="EMU_display_0""#]
        for (index, scanout, age) in current() {
            if scanout.plugged, age >= Self.add {
                lines.append(#"Display \#(Self.physicalID(index)) (HWC display \#(index)): port=\#(index) pnpId=GGL displayName="EMU_display_\#(index)""#)
            } else if !scanout.plugged, age < Self.commit {
                lines.append("Display \(Self.physicalID(index)) (HWC display \(index)): no display identification data")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `cmd display get-displays`
    func displayManager() -> String {
        var lines = [#"Display id 0: DisplayInfo{"Built-in Screen", displayId 0, uniqueId "local:4619827259835644672", app 720 x 1280}"#]
        for (index, scanout, age) in current() where scanout.plugged ? age >= Self.add : age < Self.commit + Self.managerLag {
            let id = 100 + index
            var (width, height) = (scanout.width, scanout.height)
            if let previous = scanout.previous, ContinuousClock.now < previous.until { (width, height) = (previous.width, previous.height) }
            lines.append(#"Display id \#(id): DisplayInfo{"Built-in Screen", displayId \#(id), app \#(width) x \#(height), supportedModes [{id=\#(id), width=\#(width), height=\#(height), fps=60.0}], uniqueId "local:\#(Self.physicalID(index))"}"#)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `am stack list`: the app on every display Android has.
    func stacks() -> String {
        var lines = ["RootTask id=1 bounds=[0,0][720,1280] displayId=0 userId=0",
                     "  taskId=7: com.android.launcher3/.Launcher bounds=[0,0][720,1280] userId=0 visible=true"]
        for (index, scanout, age) in current() where scanout.plugged && age >= Self.add {
            lines.append("RootTask id=\(200 + index) bounds=[0,0][\(scanout.width),\(scanout.height)] displayId=\(100 + index) userId=0")
            lines.append("  taskId=\(200 + index): dev.example/dev.example.Main bounds=[0,0][\(scanout.width),\(scanout.height)] userId=0 visible=true")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func shell(_ command: String) -> (stdout: String, stderr: String, exit: UInt8) {
        commands.withLock { $0.append(command) }
        guard command.contains("; echo avo-") else { return (simple(command), "", 0) }
        var output = ""
        for part in command.components(separatedBy: "; ") {
            output += part.hasPrefix("echo ") ? String(part.dropFirst(5)) + "\n" : simple(part)
        }
        return (output, "", 0)
    }

    private func simple(_ command: String) -> String {
        if command.hasPrefix("getprop sys.boot_completed") { return "1\n" }
        if command.hasPrefix("getprop ro.build.version.sdk") { return "37\n" }
        if command.hasPrefix("getprop init.svc.bugreport") { return "stopped\n" }
        if command.hasPrefix("sha256sum \(GuestComposer.binary)"), composerPatched {
            return "\(GuestComposer.builds[0].patchedSHA256)  \(GuestComposer.binary)\n"
        }
        if command.hasPrefix("dumpsys SurfaceFlinger --display-id") { return surfaceFlinger() }
        if command.hasPrefix("cmd display get-displays") { return displayManager() }
        if command.hasPrefix("cmd activity stack list") || command.hasPrefix("am stack list") { return stacks() }
        if command.hasPrefix("cmd package list packages -3") {
            return "package:/data/app/~~a/dev.example-1/base.apk=dev.example versionCode:1\n"
        }
        if command.hasPrefix("cmd package resolve-activity") { return "dev.example/dev.example.Main\n" }
        if command.hasPrefix("am start") { return "Starting: Intent { cmp=dev.example/.Main }\n" }
        // Android's media index takes a file in (MediaProvider's scan_file).
        if command.hasPrefix("content call --uri content://media/ --method scan_file") {
            return "Result: Bundle[{android.intent.extra.STREAM=content://media/external_primary/file/1000000042}]\n"
        }
        return ""
    }
}

/// avo-vmm's control socket: every line goes to the model, answered `ok`.
private final class ModelEngineSocket: @unchecked Sendable {
    let path = FileManager.default.temporaryDirectory.appending(path: "avo-replug-\(UInt32.random(in: 0...UInt32.max)).sock").path
    private let listener: Int32

    init(_ android: AndroidDisplays) throws {
        listener = try UnixSocket.listen(path: path)
        let listener = self.listener
        Thread {
            while let fd = try? UnixSocket.accept(listener) {
                Thread {
                    var line: [UInt8] = []
                    var byte: UInt8 = 0
                    while read(fd, &byte, 1) == 1 {
                        guard byte == UInt8(ascii: "\n") else {
                            line.append(byte)
                            continue
                        }
                        android.engine(String(decoding: line, as: UTF8.self))
                        line = []
                        _ = "ok\n".withCString { write(fd, $0, 3) }
                    }
                    close(fd)
                }.start()
            }
        }.start()
    }

    deinit {
        close(listener)
        unlink(path)
    }
}

/// HostAgent's re-plugs, closes and launches against that model: no scanout
/// is ever plugged again before Android has let go of its display.
@Suite(.serialized, .timeLimit(.minutes(1))) struct HostAgentReplugTests {
    private final class Received: Sendable {
        let envelopes = Mutex<[Avo_V1_Envelope]>([])

        func replied(_ requestID: UInt64) -> Avo_V1_Reply? {
            envelopes.withLock { list in
                list.lazy.compactMap { envelope -> Avo_V1_Reply? in
                    guard envelope.requestID == requestID, case .reply(let reply)? = envelope.payload else { return nil }
                    return reply
                }.first
            }
        }
    }

    private struct Session {
        let agent: HostAgent
        let control: FileDescriptorStream
        let received: Received
        let engine: ModelEngineSocket

        /// Sends one request and waits for its reply.
        func request(_ payload: Avo_V1_Envelope.OneOf_Payload, id: UInt64) async throws -> Avo_V1_Reply? {
            try await send(payload, id: id)
            _ = await eventually(timeout: .seconds(20)) { received.replied(id) != nil }
            return received.replied(id)
        }

        func send(_ payload: Avo_V1_Envelope.OneOf_Payload, id: UInt64) async throws {
            try await control.write(ControlFraming.encode(Avo_V1_Envelope(payload, requestID: id)))
        }
    }

    private func start(_ android: AndroidDisplays) async throws -> Session {
        let engine = try ModelEngineSocket(android)
        let key = try ADBKey.generate()
        let agent = HostAgent(engine: EngineControl(socketPath: engine.path), frames: FrameBridge { _ in }, adbKey: key) { _ in
            let (host, guest) = try UnixSocket.pair()
            let adbd = FakeADBD(fileDescriptor: guest, publicKey: key.publicKey!, maxPayload: 256 * 1024)
            Task {
                await adbd.setShellHandler { android.shell($0) }
                await adbd.run()
            }
            return FileDescriptorStream(fileDescriptor: host, label: "fake-host-adb")
        }
        try await agent.prepare(deadline: .now + .seconds(30))
        let (hostFD, guestFD) = try UnixSocket.pair()
        let host = FileDescriptorStream(fileDescriptor: hostFD, label: "test-control")
        Task { await agent.serveControl(FileDescriptorStream(fileDescriptor: guestFD, label: "agent-control")) }
        let received = Received()
        Task {
            var decoder = ControlFrameDecoder()
            do {
                for try await chunk in host.incoming {
                    decoder.append(chunk)
                    while let envelope = try decoder.next() { received.envelopes.withLock { $0.append(envelope) } }
                }
            } catch {}
        }
        return Session(agent: agent, control: host, received: received, engine: engine)
    }

    private static func launch(_ displayID: UInt32, _ width: UInt32, _ height: UInt32) -> Avo_V1_Envelope.OneOf_Payload {
        var launch = Avo_V1_Launch()
        launch.package = "dev.example"
        launch.displayID = displayID
        launch.width = width
        launch.height = height
        launch.dpi = 320
        launch.refreshRate = 60
        return .launch(launch)
    }

    private static func resize(_ displayID: UInt32, _ width: UInt32, _ height: UInt32) -> Avo_V1_Envelope.OneOf_Payload {
        var resize = Avo_V1_Resize()
        resize.displayID = displayID
        resize.width = width
        resize.height = height
        return .resize(resize)
    }

    private static func close(_ displayID: UInt32) -> Avo_V1_Envelope.OneOf_Payload {
        var close = Avo_V1_Close()
        close.displayID = displayID
        return .close(close)
    }

    /// A rotation re-plugs only once SurfaceFlinger dropped the old display,
    /// and a burst of them (a portrait activity over a landscape game, the
    /// window turned back and forth) goes one re-plug at a time to the newest.
    @Test func replugWaitsForAndroidToLetGo() async throws {
        let android = AndroidDisplays()
        let session = try await start(android)
        #expect(try await session.request(Self.launch(1, 1280, 720), id: 1)?.status == .ok)
        #expect(try await session.request(Self.resize(1, 720, 1280), id: 2)?.status == .ok)
        // The burst: three turns sent at once.
        try await session.send(Self.resize(1, 1280, 720), id: 3)
        try await session.send(Self.resize(1, 720, 1280), id: 4)
        try await session.send(Self.resize(1, 1600, 720), id: 5)
        #expect(await eventually(timeout: .seconds(20)) { (3...5).allSatisfy { session.received.replied($0) != nil } })

        #expect(android.violations.withLock { $0 } == [])
        let log = android.engineLog.withLock { $0 }
        #expect(Array(log.prefix(3)) == ["display 1 1280 720 60", "display 1 off", "display 1 720 1280 60"])
        #expect(log.last == "display 1 1600 720 60")
        // Unplug, plug, unplug, plug…: never two of either in a row.
        #expect(zip(log, log.dropFirst()).allSatisfy { $0.hasSuffix(" off") != $1.hasSuffix(" off") })
        #expect(log.filter { $0.hasSuffix(" off") }.count <= 3)
        await session.agent.shutdown()
    }

    /// With Avo's composer a resize keeps the display: no unplug, the same
    /// Android display, and the app stays on it.
    @Test func avosComposerResizesInPlace() async throws {
        let android = AndroidDisplays(composerPatched: true)
        let session = try await start(android)
        #expect(try await session.request(Self.launch(1, 1280, 720), id: 1)?.status == .ok)
        #expect(try await session.request(Self.resize(1, 720, 1280), id: 2)?.status == .ok)
        try await session.send(Self.resize(1, 1280, 720), id: 3)
        try await session.send(Self.resize(1, 1600, 720), id: 4)
        #expect(await eventually(timeout: .seconds(20)) { (3...4).allSatisfy { session.received.replied($0) != nil } })

        let log = android.engineLog.withLock { $0 }
        #expect(!log.contains { $0.hasSuffix(" off") })
        #expect(log.first == "display 1 1280 720 60" && log.last == "display 1 1600 720 60")
        #expect(android.displayManager().contains("Display id 101: DisplayInfo{\"Built-in Screen\", displayId 101, app 1600 x 720"))
        await session.agent.shutdown()
    }

    /// Android scales a display's density with its new mode: a rotated
    /// window (720 × 1280 after 1280 × 720) gets the density Avo asks for set
    /// again, or the app lays out at twice it.
    @Test func aResizeInPlaceSetsTheDensityAgain() async throws {
        let android = AndroidDisplays(composerPatched: true)
        let session = try await start(android)
        #expect(try await session.request(Self.launch(1, 1280, 720), id: 1)?.status == .ok)
        let before = android.commands.withLock { $0.filter { $0.hasPrefix("wm density 320 -d ") }.count }
        #expect(try await session.request(Self.resize(1, 720, 1280), id: 2)?.status == .ok)
        let after = android.commands.withLock { $0.filter { $0.hasPrefix("wm density 320 -d ") }.count }
        #expect(after == before + 1)
        #expect(!android.engineLog.withLock { $0 }.contains { $0.hasSuffix(" off") }, "still in place")
        await session.agent.shutdown()
    }

    /// Files dropped on a window (in Downloads already) go to its app: the
    /// media index names the first, and ACTION_SEND starts on the window's
    /// display with a read of it.
    @Test func droppedFilesGoToTheWindowsApp() async throws {
        let android = AndroidDisplays()
        let session = try await start(android)
        #expect(try await session.request(Self.launch(1, 1280, 720), id: 1)?.status == .ok)
        var share = Avo_V1_ShareFiles()
        share.displayID = 1
        share.paths = ["/sdcard/Download/photo (2).jpg", "/sdcard/Download/notes.txt"]
        share.mimeTypes = ["image/jpeg", "text/plain"]
        #expect(try await session.request(.shareFiles(share), id: 2)?.status == .ok)
        let commands = android.commands.withLock { $0 }
        #expect(commands.contains(GuestSharedFolder.scanCommand("/sdcard/Download/photo (2).jpg")))
        #expect(commands.last { $0.contains("android.intent.action.SEND") }
            == HostAgent.shareCommand(uri: "content://media/external_primary/file/1000000042", type: "image/jpeg",
                                      package: "dev.example", display: 101))

        // A display Android does not have shares nothing.
        share.displayID = 9
        #expect(try await session.request(.shareFiles(share), id: 3)?.status == .failed)
        await session.agent.shutdown()
    }

    /// A window opened right after another closed takes another scanout; the
    /// closed one is taken again once Android has let it go.
    @Test func closedScanoutIsReusedOnlyOnceAndroidLetGo() async throws {
        let android = AndroidDisplays()
        let session = try await start(android)
        #expect(try await session.request(Self.launch(1, 1280, 720), id: 1)?.status == .ok)
        #expect(try await session.request(Self.close(1), id: 2)?.status == .ok)
        #expect(try await session.request(Self.launch(2, 720, 1280), id: 3)?.status == .ok)
        try await Task.sleep(for: AndroidDisplays.commit + AndroidDisplays.managerLag + .milliseconds(300))
        #expect(try await session.request(Self.launch(3, 1280, 720), id: 4)?.status == .ok)

        #expect(android.violations.withLock { $0 } == [])
        #expect(android.engineLog.withLock { $0 } == ["display 1 1280 720 60", "display 1 off",
                                                      "display 2 720 1280 60", "display 1 1280 720 60"])
        await session.agent.shutdown()
    }
}
