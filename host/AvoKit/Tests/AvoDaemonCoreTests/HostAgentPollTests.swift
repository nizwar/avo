import AvoADB
import AvoIO
import AvoProtocol
import AvoTestSupport
import Foundation
import Synchronization
import Testing
@testable import AvoDaemonCore

/// An Android for HostAgent's watches: answers the commands they run over a
/// scripted adbd, with a tiny shell for the ones HostAgent runs together in
/// one shell call (`cmd; echo <marker>; cmd`, `cmd && echo <marker> && cmd`).
private final class ScriptedAndroid: Sendable {
    struct Log: Sendable {
        var commands: [(command: String, at: ContinuousClock.Instant)] = []
    }

    let thirdParty = Mutex("package:/data/app/~~a/dev.example-1/base.apk=dev.example versionCode:1")
    let notifications = Mutex<[(key: String, dump: String)]>([])
    let log = Mutex(Log())
    static let stacks = """
        RootTask id=1 bounds=[0,0][720,1280] displayId=0 userId=0
          taskId=7: com.android.launcher3/com.android.launcher3.uioverrides.QuickstepLauncher bounds=[0,0][720,1280] userId=0 visible=true topActivity=ComponentInfo{com.android.launcher3/com.android.launcher3.uioverrides.QuickstepLauncher}
        RootTask id=20 bounds=[0,0][704,924] displayId=3 userId=0
          taskId=20: dev.example/dev.example.Main bounds=[0,0][704,924] userId=0 visible=true topActivity=ComponentInfo{dev.example/dev.example.Main}
        """

    static func notification(_ package: String, id: Int, title: String, when: Int64) -> (key: String, dump: String) {
        let key = "0|\(package)|\(id)|null|10124"
        let dump = """
            NotificationRecord(0x03368062: pkg=\(package) user=UserHandle{0} id=\(id) tag=null importance=3 key=\(key): Notification(channel=hello flags=AUTO_CANCEL))
              flags=AUTO_CANCEL
                when=\(when)/\(when)
                    android.title=String (\(title))
                    android.text=String (Hello)
            """
        return (key, dump)
    }

    func shell(_ command: String) -> (stdout: String, stderr: String, exit: UInt8) {
        log.withLock { $0.commands.append((command, .now)) }
        guard command.contains("echo avo-") else {
            let (out, code) = simple(command)
            return (out, "", code)
        }
        // Commands joined by `; ` or by ` && ` (never both in one call).
        let chained = command.contains(" && ")
        var output = ""
        var status: UInt8 = 0
        for part in command.components(separatedBy: chained ? " && " : "; ") {
            if part.hasPrefix("echo ") {
                output += String(part.dropFirst(5)) + "\n"
                status = 0
            } else {
                let (out, code) = simple(part)
                output += out
                status = code
            }
            if chained, status != 0 { break }
        }
        return (output, "", status)
    }

    private func simple(_ command: String) -> (String, UInt8) {
        if command.hasPrefix("getprop sys.boot_completed") { return ("1\n", 0) }
        if command.hasPrefix("getprop init.svc.bugreport") { return ("stopped\n", 0) }
        if command.hasPrefix("cmd package list packages -3") { return (thirdParty.withLock { $0 } + "\n", 0) }
        if command.hasPrefix("cmd package list packages -s") {
            return ("package:/system/priv-app/Settings/Settings.apk=com.android.settings versionCode:36\n", 0)
        }
        if command.hasPrefix("cmd activity stack list") || command.hasPrefix("am stack list") { return (Self.stacks + "\n", 0) }
        if command.hasPrefix("cmd notification list") {
            return (notifications.withLock { $0.map(\.key) }.joined(separator: "\n") + "\n", 0)
        }
        if command.hasPrefix("cmd notification get ") {
            let key = command.dropFirst("cmd notification get ".count).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            return ((notifications.withLock { $0.first { $0.key == key }?.dump } ?? "") + "\n", 0)
        }
        if command.hasPrefix("cmd wifi status") { return ("Wifi is connected to \"VirtWifi\"\n", 0) }
        // System Status' part of the look (GuestActivity).
        if command.hasPrefix("ps -A -o PID,PPID,UID,TIME+,RSS,NAME") {
            return ("  PID  PPID   UID    TIME+   RSS NAME\n    1     0     0  0:01.20 10840 init\n"
                    + " 4321   598 10123  0:12.00 180000 dev.example\n", 0)
        }
        if command.hasPrefix("grep -sE ") {
            return ("/proc/stat:cpu  100 0 50 800 10 0 0 0 0 0\n/proc/stat:cpu0 50 0 25 400 5 0 0 0 0 0\n"
                    + "/proc/meminfo:MemTotal:        4012000 kB\n/proc/meminfo:MemAvailable:    2006000 kB\n"
                    + "/proc/1/oom_score_adj:-1000\n/proc/4321/oom_score_adj:0\n", 0)
        }
        if command.hasPrefix("dumpsys SurfaceFlinger --display-id") {
            return ("Display 4619827551948147201 (HWC display 1): port=1 pnpId=GGL displayName=\"Avo\"\n"
                    + "Display 4619827551948147202 (HWC display 2): port=2 pnpId=GGL displayName=\"Avo\"\n", 0)
        }
        if command.hasPrefix("cmd display get-displays") {
            return (#"Display id 3: DisplayInfo{"Built-in Screen", displayId 3, uniqueId "local:4619827551948147201", app 704 x 924}"# + "\n"
                    + #"Display id 4: DisplayInfo{"HDMI Screen", displayId 4, uniqueId "local:4619827551948147202", app 704 x 924}"# + "\n", 0)
        }
        // The Mac state helper (MacState.focusDisplayCommand).
        if let range = command.range(of: "com.avodroid.macstate.Main focus-display ") {
            return ("focused task 20 on display \(command[range.upperBound...])\n", 0)
        }
        if command.hasPrefix("cmd package resolve-activity") { return ("dev.example/dev.example.Main\n", 0) }
        if command.hasPrefix("am start") { return ("Starting: Intent { cmp=dev.example/.Main }\n", 0) }
        return ("", 0)
    }

    func commands(since start: ContinuousClock.Instant = .now - .seconds(3600)) -> [String] {
        log.withLock { $0.commands.filter { $0.at >= start }.map(\.command) }
    }

    /// The watches' looks (`HostAgent.lookAround`).
    func looks(since start: ContinuousClock.Instant = .now - .seconds(3600)) -> Int {
        commands(since: start).filter { $0.hasPrefix("cmd activity stack list;") }.count
    }
}

/// avo-vmm's control socket, answering `ok` to every command.
private final class FakeEngineSocket: @unchecked Sendable {
    let path = FileManager.default.temporaryDirectory.appending(path: "avo-ctl-\(UInt32.random(in: 0...UInt32.max)).sock").path
    private let listener: Int32

    init() throws {
        listener = try UnixSocket.listen(path: path)
        let listener = self.listener
        Thread {
            while let fd = try? UnixSocket.accept(listener) {
                Thread {
                    var byte: UInt8 = 0
                    while read(fd, &byte, 1) == 1 {
                        if byte == UInt8(ascii: "\n") { _ = "ok\n".withCString { write(fd, $0, 3) } }
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

/// HostAgent's watches against a scripted adbd: what they ask Android
/// every 2 s (the look) and every 3 s (the package poll).
@Suite(.serialized, .timeLimit(.minutes(1))) struct HostAgentPollTests {
    private func readyAgent(_ android: ScriptedAndroid, engine: String = "/nonexistent/avo-control.sock") async throws -> HostAgent {
        let key = try ADBKey.generate()
        let agent = HostAgent(engine: EngineControl(socketPath: engine), frames: FrameBridge { _ in }, adbKey: key) { _ in
            let (host, guest) = try UnixSocket.pair()
            let adbd = FakeADBD(fileDescriptor: guest, publicKey: key.publicKey!, maxPayload: 256 * 1024)
            Task {
                await adbd.setShellHandler { android.shell($0) }
                await adbd.run()
            }
            return FileDescriptorStream(fileDescriptor: host, label: "fake-host-adb")
        }
        try await agent.prepare(deadline: .now + .seconds(30))
        return agent
    }

    /// The Mac's end of the Control channel: everything HostAgent sends.
    private func control(_ agent: HostAgent) throws -> (FileDescriptorStream, Received) {
        let (hostFD, guestFD) = try UnixSocket.pair()
        let guest = FileDescriptorStream(fileDescriptor: guestFD, label: "agent-control")
        let host = FileDescriptorStream(fileDescriptor: hostFD, label: "test-control")
        Task { await agent.serveControl(guest) }
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
        return (host, received)
    }

    private final class Received: Sendable {
        let envelopes = Mutex<[Avo_V1_Envelope]>([])

        func contains(_ match: (Avo_V1_Envelope.OneOf_Payload?) -> Bool) -> Bool {
            envelopes.withLock { $0.contains { match($0.payload) } }
        }
    }

    /// Every three seconds: launcher activities are asked for only when an
    /// app was installed or updated, and both package lists come in one call.
    @Test func asksForLaunchersOnlyWhenAnAppChanged() async throws {
        let android = ScriptedAndroid()
        let agent = try await readyAgent(android)
        func count(_ prefix: String) -> Int { android.commands().filter { $0.hasPrefix(prefix) }.count }
        let launchers = "cmd package query-activities"
        let lists = "cmd package list packages -3"

        // Polls that find the same packages ask nothing more (the second
        // poll's listing comes after all of the first one).
        let listings = count(lists)
        #expect(await eventually(timeout: .seconds(15)) { count(lists) > listings + 1 })
        #expect(count(launchers) == 0)
        // One call a poll, with both lists.
        #expect(!android.commands().contains { $0.hasPrefix("cmd package list packages -s") || $0.hasPrefix("pm list packages") })

        // An update: the next poll asks.
        android.thirdParty.withLock { $0 = "package:/data/app/~~a/dev.example-2/base.apk=dev.example versionCode:2" }
        #expect(await eventually(timeout: .seconds(10)) { count(launchers) > 0 })
        await agent.shutdown()
    }

    /// Every two seconds, without windows: the tasks, the notification list
    /// and the bug report state in one call; the notifications of the Mac's
    /// apps in one more, but only when one is new or was read long enough
    /// ago (before: every look, and before that one call per notification).
    @Test func aLookReadsNewNotificationsAndTheOthersNowAndThen() async throws {
        let android = ScriptedAndroid()
        android.notifications.withLock {
            $0 = [ScriptedAndroid.notification("dev.example", id: 1, title: "First", when: 1_792_264_925_339),
                  ScriptedAndroid.notification("dev.example", id: 2, title: "Second", when: 1_792_264_925_340),
                  // Not one of the Mac's apps: never asked about.
                  ScriptedAndroid.notification("com.other", id: 3, title: "Other", when: 1_792_264_925_341)]
        }
        let agent = try await readyAgent(android)
        let (control, received) = try control(agent)
        _ = control
        func posted() -> [String] {
            received.envelopes.withLock { $0.compactMap { if case .notification(let n)? = $0.payload { n.title } else { nil } } }
        }
        // The notifications reach the Mac as before, once each.
        #expect(await eventually(timeout: .seconds(10)) { posted().count == 2 })
        #expect(Set(posted()) == ["First", "Second"])

        // Both were read in one call that asked about the app's two only.
        let first = android.commands().filter { $0.hasPrefix("cmd notification get ") }
        #expect(first.count == 1)
        #expect(first.allSatisfy { $0.components(separatedBy: "cmd notification get ").count - 1 == 2 && !$0.contains("com.other") })

        // Looks that find the same two read neither again for a while.
        let start = ContinuousClock.now
        #expect(await eventually(timeout: .seconds(10)) { android.looks(since: start) >= 2 })
        let commands = android.commands(since: start)
        #expect(!commands.contains { $0.hasPrefix("cmd notification get ") })
        // Nothing of the look on its own any more.
        #expect(!commands.contains { ["am stack list", "cmd activity stack list", "cmd notification list", "getprop init.svc.bugreport"].contains($0) })
        #expect(posted().count == 2, "an unchanged notification is not posted again")

        // A new one is read at the next look, and only it.
        let added = ContinuousClock.now
        android.notifications.withLock { $0.append(ScriptedAndroid.notification("dev.example", id: 4, title: "Third", when: 1_792_264_925_342)) }
        #expect(await eventually(timeout: .seconds(5)) { posted().contains("Third") })
        let reads = android.commands(since: added).filter { $0.hasPrefix("cmd notification get ") }
        #expect(reads.count == 1 && reads[0].components(separatedBy: "cmd notification get ").count - 1 == 1)

        // An update under the same key reaches the Mac once it is read again.
        android.notifications.withLock { $0[0] = ScriptedAndroid.notification("dev.example", id: 1, title: "First again", when: 1_792_264_999_999) }
        #expect(await eventually(timeout: HostAgent.notificationReread + .seconds(5)) { posted().contains("First again") })
        await agent.shutdown()
    }

    /// With a window open, its task watch takes the look: one listing of the
    /// tasks every two seconds instead of two (one for each watch).
    @Test func aWindowAddsNoListing() async throws {
        let android = ScriptedAndroid()
        let socket = try FakeEngineSocket()
        let agent = try await readyAgent(android, engine: socket.path)
        let (control, received) = try control(agent)
        var launch = Avo_V1_Launch()
        launch.package = "dev.example"
        launch.displayID = 1
        launch.width = 704
        launch.height = 924
        launch.dpi = 320
        launch.refreshRate = 60
        try await control.write(ControlFraming.encode(Avo_V1_Envelope(.launch(launch), requestID: 1)))
        #expect(await eventually(timeout: .seconds(10)) {
            received.contains { if case .displayReady? = $0 { true } else { false } }
        })
        // Past the moment a new display gets (3 s), so the watch looks at its tasks.
        try await Task.sleep(for: .seconds(3.5))
        let start = ContinuousClock.now
        try await Task.sleep(for: .seconds(6.5))
        let commands = android.commands(since: start)
        let listings = commands.filter { $0.hasPrefix("cmd activity stack list") || $0.hasPrefix("am stack list") }.count
        // Three or four 2-second ticks: one listing each.
        #expect((2...4).contains(listings), "\(listings) listings of the tasks in 6.5 s")
        // The window's task is there: it stays open.
        #expect(!received.contains { if case .taskClosed? = $0 { true } else { false } })
        await agent.shutdown()
    }

    /// The Mac's key window takes Android's input focus: the helper focuses
    /// the task on its display, and only when another display has it.
    @Test func theKeyWindowTakesAndroidsFocus() async throws {
        let android = ScriptedAndroid()
        let socket = try FakeEngineSocket()
        let agent = try await readyAgent(android, engine: socket.path)
        let (control, received) = try control(agent)
        func replied(_ id: UInt64) -> Bool {
            received.envelopes.withLock { $0.contains { $0.requestID == id && $0.reply.status == .ok } }
        }
        // Two windows (Android displays 3 and 4); the last one opened has the focus.
        for id: UInt32 in [1, 2] {
            var launch = Avo_V1_Launch()
            launch.package = "dev.example"
            launch.displayID = id
            launch.width = 704
            launch.height = 924
            launch.dpi = 320
            launch.refreshRate = 60
            try await control.write(ControlFraming.encode(Avo_V1_Envelope(.launch(launch), requestID: UInt64(id))))
            #expect(await eventually(timeout: .seconds(10)) { replied(UInt64(id)) })
        }
        func focusCalls() -> [String] { android.commands().filter { $0.contains("com.avodroid.macstate.Main focus-display") } }
        func focus(_ id: UInt32, request: UInt64) async throws {
            var focus = Avo_V1_FocusDisplay()
            focus.displayID = id
            try await control.write(ControlFraming.encode(Avo_V1_Envelope(.focusDisplay(focus), requestID: request)))
            #expect(await eventually(timeout: .seconds(10)) { replied(request) })
        }

        // The first window becomes the key window.
        try await focus(1, request: 10)
        #expect(focusCalls() == [MacState.focusDisplayCommand(3)])
        // Again (it has it): nothing to do.
        try await focus(1, request: 11)
        #expect(focusCalls().count == 1)
        // Back to the second one; a display that is not there asks nothing.
        try await focus(2, request: 12)
        try await focus(9, request: 13)
        #expect(focusCalls() == [MacState.focusDisplayCommand(3), MacState.focusDisplayCommand(4)])
        await agent.shutdown()
    }

    /// While System Status watches, Android's processes come with the look
    /// itself: no shell call more, and none of it once it stops watching.
    @Test func systemStatusRidesAlongWithTheLook() async throws {
        let android = ScriptedAndroid()
        let agent = try await readyAgent(android)
        let samples = Mutex<[GuestActivity.Sample]>([])
        await agent.sampleProcesses { sample in samples.withLock { $0.append(sample) } }
        let start = ContinuousClock.now
        #expect(await eventually(timeout: .seconds(10)) { samples.withLock { $0.count } >= 2 })
        let sample = try #require(samples.withLock { $0.last })
        #expect(sample.processes.map(\.name) == ["init", "dev.example"])
        #expect(sample.processes.last?.oomScoreAdj == 0)
        #expect(sample.memoryTotal == 4_012_000 * 1024)
        let commands = android.commands(since: start)
        #expect(commands.filter { $0.hasPrefix("cmd activity stack list;") }.allSatisfy { $0.contains("; ps -A -o ") })
        #expect(!commands.contains { $0.hasPrefix("ps ") || $0.hasPrefix("grep ") })

        await agent.sampleProcesses(nil)
        try await Task.sleep(for: .seconds(0.5))
        let after = ContinuousClock.now
        #expect(await eventually(timeout: .seconds(10)) { android.looks(since: after) >= 1 })
        #expect(!android.commands(since: after).contains { $0.contains("ps -A") })
        await agent.shutdown()
    }

    @Test func splitsTheOutputsOfOneShellCall() {
        #expect(HostAgent.sections(of: "a\nb\navo-1\n\navo-1\nc\n", marker: "avo-1") == ["a\nb", "", "c\n"])
        #expect(HostAgent.sections(of: "only", marker: "avo-1") == ["only"])
        #expect(HostAgent.shellMarker() != HostAgent.shellMarker())
    }
}
