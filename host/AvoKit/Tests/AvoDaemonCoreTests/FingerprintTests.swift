@testable import AvoADB
import AvoIO
import AvoKit
import Foundation
import Testing
@testable import AvoDaemonCore

/// Outputs recorded on AOSP Cuttlefish 16373615 (Android 17, userdebug).
enum RecordedFingerprintOutput {
    static let helperStatus = """
        sensor 5
        active 0
        lockout 0
        lock 3
        strongauth 0
        finger 1 UmlnaHQgdGh1bWI=
        finger 7 RmluZ2VyIDE=
        end 2
        """

    static func dump(operation: String, accept: Int = 1, reject: Int = 1, count: Int = 2, lockout: Int = 0) -> String {
        """
        Dumping for sensorId: 5, provider: FingerprintProvider
        Fps state: 0
        {"service":"FingerprintProvider\\/default","prints":[{"id":0,"count":\(count),"accept":\(accept),"reject":\(reject),"acquire":0,"lockout":\(lockout),"permanentLockout":0,"acceptCrypto":0,"rejectCrypto":0,"acquireCrypto":0}]}
        HAL deaths since last reboot: 0
        ---AuthSessionCoordinator logs begin---

        Permanent Lockouts

        ---AuthSessionCoordinator logs end  ---
        Dump of BiometricScheduler BiometricScheduler
        Type: 3
        Current operation: \(operation)
        Pending operations: 0
        """
    }

    static let appAuthentication = "{[14] com.android.server.biometrics.sensors.fingerprint.aidl.FingerprintAuthenticationClient, proto=3, owner=com.avodroid.fptest, cookie=1060455472, requestId=1, userId=0}, State: 2"
    static let lockScreen = "{[18] com.android.server.biometrics.sensors.fingerprint.aidl.FingerprintAuthenticationClient, proto=3, owner=com.android.systemui, cookie=0, requestId=1, userId=0}, State: 2"
    static let settingsEnrollment = "{[24] com.android.server.biometrics.sensors.fingerprint.aidl.FingerprintEnrollClient, proto=2, owner=com.android.settings, cookie=0, requestId=3, userId=0}, State: 2"
    static let removal = "{[20] com.android.server.biometrics.sensors.fingerprint.aidl.FingerprintRemovalClient, proto=4, owner=com.android.shell, cookie=0, requestId=-1, userId=0}, State: 2"
}

@Suite struct GuestFingerprintTests {
    @Test func readsTheHelpersStatus() {
        let status = GuestFingerprints.helperStatus(RecordedFingerprintOutput.helperStatus)
        #expect(status.sensor == 5)
        #expect(!status.active)
        #expect(status.lockout == .none)
        #expect(status.credentialType == 3)
        #expect(status.strongAuth == 0)
        #expect(status.fingers == [Fingerprint(id: 1, name: "Right thumb"), Fingerprint(id: 7, name: "Finger 1")])
        #expect(status.complete)

        let cut = GuestFingerprints.helperStatus("sensor 5\nactive 1\nlockout 2\nlock -1\nstrongauth 1\nfinger 3 \n")
        #expect(cut.active && cut.lockout == .permanent && cut.credentialType == -1 && cut.strongAuth == 1)
        #expect(cut.fingers == [Fingerprint(id: 3, name: "")])
        #expect(!cut.complete)
        #expect(GuestFingerprints.helperStatus("sensor -1\nend 0").sensor == nil)
        #expect(GuestFingerprints.helperStatus("error java.lang.SecurityException: denied").error == "java.lang.SecurityException: denied")
    }

    @Test func readsTheStatusScriptsSections() {
        let output = """
            debuggable=1
            halstart=true
            virtualapex=1
            virtual=null
            enrolled=1,7
            next=8:100,100,100:true
            \(GuestFingerprints.dumpMarker)
            \(RecordedFingerprintOutput.dump(operation: RecordedFingerprintOutput.lockScreen))
            \(GuestFingerprints.helperMarker)
            \(RecordedFingerprintOutput.helperStatus)
            """
        let report = GuestFingerprints.report(output)
        #expect(report.facts == GuestFingerprints.Facts(debuggable: true, virtualSensor: true, virtualEnabled: false,
                                                        sensorEnrollments: [1, 7]))
        #expect(report.dump.request == FingerprintRequest(purpose: .authenticate, package: "com.android.systemui"))
        #expect(report.dump.stats == GuestFingerprints.Stats(count: 2, accept: 1, reject: 1))
        #expect(report.helper.fingers.count == 2)
        #expect(!report.helperMissing)
        #expect(GuestFingerprints.availability(report) == .ready)
        #expect(!GuestFingerprints.credentialRequired(report))

        let missing = GuestFingerprints.report("debuggable=1\nenrolled=\nnext=\n\(GuestFingerprints.dumpMarker)\n\(GuestFingerprints.helperMarker)\n\(GuestFingerprints.helperMissingMarker)\n")
        #expect(missing.helperMissing)
        #expect(missing.facts.sensorEnrollments.isEmpty)
    }

    @Test func availabilityFollowsTheSensorAndTheScreenLock() {
        var report = GuestFingerprints.Report()
        report.facts = GuestFingerprints.Facts(debuggable: true, virtualSensor: true)
        report.helper = GuestFingerprints.helperStatus(RecordedFingerprintOutput.helperStatus)
        #expect(GuestFingerprints.availability(report) == .ready)
        report.helper.credentialType = -1
        #expect(GuestFingerprints.availability(report) == .noScreenLock)
        report.helper.credentialType = nil  // Android did not say: it refuses by itself if need be
        #expect(GuestFingerprints.availability(report) == .ready)
        report.facts.debuggable = false     // a user build: no virtual sensor to drive
        #expect(GuestFingerprints.availability(report) == .unsupported)
        report.facts.debuggable = true
        report.facts.virtualSensor = false
        #expect(GuestFingerprints.availability(report) == .unsupported)
        report.facts.virtualSensor = true
        report.helper.sensor = nil
        #expect(GuestFingerprints.availability(report) == .unsupported)
    }

    @Test func strongAuthFlagsThatHoldFingerprintsBack() {
        var report = GuestFingerprints.Report()
        for (flags, required) in [(0, false), (0x1, true), (0x4, false), (0x8, true), (0x10, true), (0x100, false), (0x5, true)] {
            report.helper.strongAuth = flags
            #expect(GuestFingerprints.credentialRequired(report) == required, "flags \(flags)")
        }
    }

    @Test func findsWhatAsksForAFinger() {
        let app = GuestFingerprints.sensorDump(RecordedFingerprintOutput.dump(operation: RecordedFingerprintOutput.appAuthentication))
        #expect(app.request == FingerprintRequest(purpose: .authenticate, package: "com.avodroid.fptest"))
        #expect(app.stats == GuestFingerprints.Stats(count: 2, accept: 1, reject: 1, lockout: 0, permanentLockout: 0))
        let enroll = GuestFingerprints.sensorDump(RecordedFingerprintOutput.dump(operation: RecordedFingerprintOutput.settingsEnrollment))
        #expect(enroll.request == FingerprintRequest(purpose: .enroll, package: "com.android.settings"))
        #expect(GuestFingerprints.sensorDump(RecordedFingerprintOutput.dump(operation: RecordedFingerprintOutput.removal)).request == nil)
        #expect(GuestFingerprints.sensorDump(RecordedFingerprintOutput.dump(operation: "null")).request == nil)
        // Not started yet (waiting in the queue): nothing to touch.
        let queued = RecordedFingerprintOutput.appAuthentication.replacingOccurrences(of: "State: 2", with: "State: 0")
        #expect(GuestFingerprints.sensorDump(RecordedFingerprintOutput.dump(operation: queued)).request == nil)
        #expect(GuestFingerprints.sensorDump("").stats == nil)
        // Another user's counts are not ours.
        let other = #"{"service":"FingerprintProvider\/virtual","prints":[{"id":10,"count":1,"accept":4}]}"#
        #expect(GuestFingerprints.sensorDump(other).stats == nil)
    }

    @Test func touchOutcomesFromTheCounts() {
        let before = GuestFingerprints.Stats(count: 2, accept: 1, reject: 1)
        var after = before
        #expect(GuestFingerprints.touchOutcome(.authenticate, before: before, after: after) == nil)
        after.accept = 2
        #expect(GuestFingerprints.touchOutcome(.authenticate, before: before, after: after) == .recognized)
        after = before
        after.reject = 2
        #expect(GuestFingerprints.touchOutcome(.authenticate, before: before, after: after) == .notRecognized)
        after.lockout = 1  // the fifth wrong finger
        #expect(GuestFingerprints.touchOutcome(.authenticate, before: before, after: after) == .lockedOut)
        after = before
        after.permanentLockout = 1
        #expect(GuestFingerprints.touchOutcome(.authenticate, before: before, after: after) == .lockedOut)
        after = before
        #expect(GuestFingerprints.touchOutcome(.enroll, before: before, after: after) == nil)
        after.count = 3
        #expect(GuestFingerprints.touchOutcome(.enroll, before: before, after: after) == .enrolled)
    }

    @Test func newIDsStayClearOfEveryKnownOne() {
        #expect(GuestFingerprints.newID(avoiding: []) == 1)
        #expect(GuestFingerprints.newID(avoiding: [1, 2, 2]) == 3)
        // Above the sensor's ids too, and those of a finger on its way out.
        #expect(GuestFingerprints.newID(avoiding: [2, 9]) == 10)
    }

    @Test func mergesAvosFingersWithAndroids() {
        let name = { (n: Int) in "Finger \(n)" }
        let fingers = [Fingerprint(id: 1, name: "Right thumb"), Fingerprint(id: 2, name: "Left index finger"),
                       Fingerprint(id: 3, name: "Left thumb", enrolled: false), Fingerprint(id: 4, name: "Gone")]
        // Renamed in Android's Settings (2), removed there (4), one Avo has no finger for (7), one Android never had (3).
        let android = [Fingerprint(id: 1, name: "Right thumb"), Fingerprint(id: 2, name: "Left index"), Fingerprint(id: 7, name: "Finger 1")]
        let merged = GuestFingerprints.merge(android: android, fingers: fingers,
                                             androidNames: [1: "Right thumb", 2: "Left index finger", 4: "Gone"], removing: [], defaultName: name)
        #expect(merged.fingers == [Fingerprint(id: 1, name: "Right thumb"), Fingerprint(id: 2, name: "Left index"),
                                   Fingerprint(id: 3, name: "Left thumb", enrolled: false), Fingerprint(id: 4, name: "Gone", enrolled: false),
                                   Fingerprint(id: 7, name: "Finger 1")])
        #expect(merged.renames.isEmpty)
        #expect(merged.androidNames == [1: "Right thumb", 2: "Left index", 7: "Finger 1"])

        // Settings just added 3 (Android's "Finger 1", a name Avo never saw), 1 was renamed in Avo while
        // Android was stopped: Avo's names go to Android.
        let added = GuestFingerprints.merge(android: [Fingerprint(id: 3, name: "Finger 1"), Fingerprint(id: 1, name: "Right thumb")],
                                            fingers: [Fingerprint(id: 1, name: "Jempol kanan"), Fingerprint(id: 3, name: "Left thumb", enrolled: false)],
                                            androidNames: [1: "Right thumb"], removing: [], defaultName: name)
        #expect(added.fingers == [Fingerprint(id: 1, name: "Jempol kanan"), Fingerprint(id: 3, name: "Left thumb")])
        #expect(added.renames == [Fingerprint(id: 1, name: "Jempol kanan"), Fingerprint(id: 3, name: "Left thumb")])
        #expect(added.androidNames == [1: "Right thumb", 3: "Finger 1"])

        // A name Android changed that another finger has: Avo's stays.
        let taken = GuestFingerprints.merge(android: [Fingerprint(id: 1, name: "Left thumb")],
                                            fingers: [Fingerprint(id: 1, name: "Right thumb"), Fingerprint(id: 2, name: "Left thumb", enrolled: false)],
                                            androidNames: [1: "Right thumb"], removing: [], defaultName: name)
        #expect(taken.fingers.map(\.name) == ["Right thumb", "Left thumb"])
        #expect(taken.renames == [Fingerprint(id: 1, name: "Right thumb")])

        // Nobody named it: "Finger N", not one that is taken; one on its way out stays out.
        let anonymous = GuestFingerprints.merge(android: [Fingerprint(id: 5, name: "Finger 1"), Fingerprint(id: 6, name: " "), Fingerprint(id: 8, name: "Old")],
                                                fingers: [], androidNames: [:], removing: [8], defaultName: name)
        #expect(anonymous.fingers == [Fingerprint(id: 5, name: "Finger 1"), Fingerprint(id: 6, name: "Finger 2")])
        #expect(anonymous.renames == [Fingerprint(id: 6, name: "Finger 2")])
        #expect(anonymous.androidNames == [5: "Finger 1", 6: " "])
    }

    @Test func readsFingerprintFilesFromBeforeAvoKeptItsOwnFingers() throws {
        let old = #"{"fingers":[{"id":1,"name":"Right thumb"},{"id":7,"name":"Finger 1"}]}"#
        let store = try JSONDecoder().decode(FingerprintStore.self, from: Data(old.utf8))
        #expect(store.fingers == [Fingerprint(id: 1, name: "Right thumb"), Fingerprint(id: 7, name: "Finger 1")])
        #expect(store.androidNames == [1: "Right thumb", 7: "Finger 1"])
        #expect(store.removing.isEmpty)
        let new = FingerprintStore(fingers: [Fingerprint(id: 2, name: "Left thumb", enrolled: false)], androidNames: [3: "x"], removing: [3])
        #expect(try JSONDecoder().decode(FingerprintStore.self, from: JSONEncoder().encode(new)) == new)
    }

    @Test func commandsAsRunOnAndroid() {
        let helper = GuestFingerprints.helperPath
        #expect(helper.hasPrefix("/data/local/tmp/avo-fingerprint-") && helper.hasSuffix(".jar"))
        #expect(GuestFingerprints.checksum("abc") == "1a47e90b")
        #expect(GuestFingerprints.helperJar != nil)
        let run = "CLASSPATH=\(helper) app_process / com.avodroid.fingerprint.Main"
        let check = "[ -s \(helper) ] || { echo avo-fingerprint-helper-missing; exit 97; }"
        #expect(GuestFingerprints.renameScript(id: 7, name: "Kelingking kiri") == "\(check); \(run) rename 7 S2VsaW5na2luZyBraXJp 0")
        #expect(GuestFingerprints.removeScript(id: 7) == "\(check); \(run) remove 7 0")
        #expect(GuestFingerprints.touchScript(id: 2) == "setprop vendor.fingerprint.virtual.enrollment_hit 2 && cmd fingerprint fingerdown")
        #expect(GuestFingerprints.touchScript(id: 0) == "setprop vendor.fingerprint.virtual.enrollment_hit 0 && cmd fingerprint fingerdown")
        #expect(GuestFingerprints.enrollScript(id: 3) == "setprop vendor.fingerprint.virtual.next_enrollment 3:100,100,100:true && "
            + "setprop vendor.fingerprint.virtual.enrollment_hit 3 && cmd fingerprint fingerdown")
        #expect(GuestFingerprints.prepareScript == [
            "[ \"$(settings get secure biometric_fingerprint_virtual_enabled)\" = 1 ] || settings put secure biometric_fingerprint_virtual_enabled 1",
            "[ -n \"$(getprop persist.vendor.fingerprint.virtual.lockout_enable)\" ] || setprop persist.vendor.fingerprint.virtual.lockout_enable true",
            "[ -n \"$(getprop persist.vendor.fingerprint.virtual.lockout_timed_threshold)\" ] || setprop persist.vendor.fingerprint.virtual.lockout_timed_threshold 5",
            "[ -n \"$(getprop persist.vendor.fingerprint.virtual.lockout_timed_duration)\" ] || setprop persist.vendor.fingerprint.virtual.lockout_timed_duration 30000",
        ].joined(separator: "; "))
        #expect(GuestFingerprints.statusScript.hasSuffix("\(check); \(run) status 0"))
        #expect(GuestFingerprints.statusScript.contains("echo enrolled=$(getprop persist.vendor.fingerprint.virtual.enrollments)"))
        #expect(GuestFingerprints.cancelCommand == "input -d 0 keyevent 4")
        // Names never reach the shell as text: Base64 only.
        #expect(!GuestFingerprints.renameScript(id: 1, name: "'; reboot; '").contains("reboot"))
    }
}

// MARK: - FingerprintCenter against a simulated Android

/// Android's fingerprint stack as the scripts see it: the sensor's
/// enrollments, Android's named list, the virtual setting, the screen lock
/// and what asks for a finger.
actor SimulatedFingerprintAndroid: FingerprintGuest {
    var sensor: [Int] = []
    var android: [Fingerprint] = []
    var virtualEnabled = false
    var next: Int?
    var credentialType = 3
    var strongAuth = 0
    var lockout = 0
    var helperInstalled = false
    var request: FingerprintRequest?
    var stats = GuestFingerprints.Stats()
    var wrongInARow = 0
    private(set) var commands: [String] = []
    private(set) var pushes = 0

    func set(request: FingerprintRequest?) { self.request = request }
    func set(credentialType: Int) { self.credentialType = credentialType }
    func set(android: [Fingerprint], sensor: [Int]) { self.android = android; self.sensor = sensor }

    func fingerprintPush(_ data: Data, to path: String) async throws {
        #expect(path == GuestFingerprints.helperPath)
        #expect(!data.isEmpty)
        pushes += 1
        helperInstalled = true
    }

    func fingerprintShell(_ command: String, asRoot: Bool) async throws -> ShellResult {
        commands.append(command)
        var output = ""
        var status: Int32 = 0
        if command.contains(GuestFingerprints.helperPath), command.hasPrefix("[ -s") || command.contains("; [ -s"), !helperInstalled {
            // The status script prints its first sections before the check.
            if command == GuestFingerprints.statusScript { output = facts() + "\(GuestFingerprints.dumpMarker)\n" + dump() + "\(GuestFingerprints.helperMarker)\n" }
            return ShellResult(exitCode: GuestFingerprints.helperMissingStatus, stdout: Data((output + GuestFingerprints.helperMissingMarker + "\n").utf8), stderr: Data())
        }
        if command == GuestFingerprints.statusScript {
            output = facts() + "\(GuestFingerprints.dumpMarker)\n" + dump() + "\(GuestFingerprints.helperMarker)\n" + helperStatus()
        } else if command.hasPrefix("[ \"$(settings get secure") {
            #expect(asRoot)
            virtualEnabled = true
        } else if command.contains("Main rename") {
            output = rename(command)
        } else if command.contains("Main remove") {
            let id = Int(command.components(separatedBy: "Main remove ")[1].prefix { $0 != " " })!
            android.removeAll { $0.id == id }
            sensor.removeAll { $0 == id }
            output = helperStatus()
        } else if command.hasPrefix("setprop vendor.fingerprint.virtual.next_enrollment") || command.hasPrefix("setprop vendor.fingerprint.virtual.enrollment_hit") {
            #expect(asRoot)
            if command.hasPrefix("setprop vendor.fingerprint.virtual.next_enrollment") {
                next = Int(command.components(separatedBy: "next_enrollment ")[1].prefix { $0 != ":" })
            }
            let hit = Int(command.components(separatedBy: "enrollment_hit ")[1].prefix { $0 != " " })!
            // `cmd fingerprint fingerdown` does nothing without the virtual setting.
            if virtualEnabled { touch(hit) }
        } else if command == GuestFingerprints.dumpCommand {
            output = dump()
        } else if command == GuestFingerprints.cancelCommand {
            request = nil
        }
        return ShellResult(exitCode: status, stdout: Data(output.utf8), stderr: Data())
    }

    private func rename(_ command: String) -> String {
        guard command.contains("Main rename") else { return helperStatus() }
        let parts = command.components(separatedBy: "Main rename ")[1].split(separator: " ")
        let id = Int(parts[0])!
        let name = String(decoding: Data(base64Encoded: String(parts[1]))!, as: UTF8.self)
        guard let index = android.firstIndex(where: { $0.id == id }) else { return helperStatus() + "error no fingerprint \(id)\n" }
        android[index].name = name
        return helperStatus()
    }

    private func touch(_ hit: Int) {
        guard let request else { return }
        switch request.purpose {
        case .enroll:
            // Android names it from its own template.
            let id = next ?? 99
            sensor.append(id)
            android.append(Fingerprint(id: id, name: "Finger \(android.count + 1)"))
            stats.count = android.count
            next = nil
            self.request = nil
        case .authenticate:
            if hit > 0, sensor.contains(hit), android.contains(where: { $0.id == hit }) {
                stats.accept += 1
                wrongInARow = 0
                self.request = nil
            } else {
                stats.reject += 1
                wrongInARow += 1
                if wrongInARow >= 5 {
                    stats.lockout += 1
                    lockout = 1
                    self.request = nil
                }
            }
        }
    }

    private func facts() -> String {
        "debuggable=1\nhalstart=true\nvirtualapex=1\nvirtual=\(virtualEnabled ? "1" : "null")\nenrolled=\(sensor.map(String.init).joined(separator: ","))\n"
            + "next=\(next.map { "\($0):100,100,100:true" } ?? "")\n"
    }

    private func dump() -> String {
        var stats = self.stats
        stats.count = android.count
        let operation = request.map { request in
            let kind = request.purpose == .enroll ? "FingerprintEnrollClient" : "FingerprintAuthenticationClient"
            return "{[9] com.android.server.biometrics.sensors.fingerprint.aidl.\(kind), proto=3, owner=\(request.package), cookie=0, requestId=1, userId=0}, State: 2"
        } ?? "null"
        return RecordedFingerprintOutput.dump(operation: operation, accept: stats.accept, reject: stats.reject, count: stats.count, lockout: stats.lockout) + "\n"
    }

    private func helperStatus() -> String {
        var lines = ["sensor 5", "active \(request == nil ? 0 : 1)", "lockout \(lockout)", "lock \(credentialType)", "strongauth \(strongAuth)"]
        lines += android.map { "finger \($0.id) \(Data($0.name.utf8).base64EncodedString())" }
        lines.append("end \(android.count)")
        return lines.joined(separator: "\n") + "\n"
    }
}

/// An engine without a fingerprint sensor (like crosvm).
final class PlainTestEngine: VMEngine, @unchecked Sendable {
    let name = "plain-test"
    let exits: AsyncStream<(any Error)?> = AsyncStream { _ in }

    func start(_ launch: EngineLaunch) async throws {}
    func stop() async {}
    func snapshot(to url: URL) async throws {}
    func connect(port: UInt32) async throws -> any ByteStream { throw AvoError.vmNotRunning }
}

final class FingerprintTestEngine: VMEngine, FingerprintEngine, @unchecked Sendable {
    let name = "fingerprint-test"
    let guest: SimulatedFingerprintAndroid
    let exits: AsyncStream<(any Error)?> = AsyncStream { _ in }

    init(_ guest: SimulatedFingerprintAndroid) { self.guest = guest }

    func start(_ launch: EngineLaunch) async throws {}
    func stop() async {}
    func snapshot(to url: URL) async throws {}
    func connect(port: UInt32) async throws -> any ByteStream { throw AvoError.vmNotRunning }
    func fingerprintGuest() async throws -> any FingerprintGuest { guest }
}

@Suite(.timeLimit(.minutes(1))) struct FingerprintCenterTests {
    let paths: AvoPaths
    let android = SimulatedFingerprintAndroid()

    init() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "avo-fingerprints-\(UUID().uuidString)", directoryHint: .isDirectory)
        paths = AvoPaths(home: home, temporaryDirectory: home.appending(path: "tmp"))
        try paths.createDirectories()
    }

    private func runningCenter() async -> FingerprintCenter {
        let center = FingerprintCenter(paths: paths, engine: FingerprintTestEngine(android))
        await center.androidChanged(.running)
        return center
    }

    /// Android's Settings adds a fingerprint, touched with finger `id`.
    private func enroll(_ center: FingerprintCenter, _ id: Int) async throws {
        await android.set(request: Self.settingsEnrollment)
        #expect(try await center.touch(id) == .enrolled)
    }

    static let settingsEnrollment = FingerprintRequest(purpose: .enroll, package: "com.android.settings")
    static let appAuthentication = FingerprintRequest(purpose: .authenticate, package: "com.avodroid.fptest")
    static let lockScreen = FingerprintRequest(purpose: .authenticate, package: "com.android.systemui")

    @Test func fingersLiveInAvoAndSettingsAddsTheOneThatTouches() async throws {
        let center = await runningCenter()
        let thumb = try await center.add(named: " Right thumb ")
        #expect(thumb == Fingerprint(id: 1, name: "Right thumb", enrolled: false))
        let index = try await center.add(named: "Left index finger")
        #expect(index.id == 2)
        // Avo's only: nothing in Android yet.
        #expect(await android.android.isEmpty)
        #expect(await android.sensor.isEmpty)
        #expect(FingerprintStore.load(paths).fingers == [thumb, index])
        await #expect(throws: AvoError.fingerprint(.duplicateName("Right thumb"))) { try await center.add(named: "right thumb") }

        // Settings adds the finger that touches it, under the finger's id and name.
        try await enroll(center, 1)
        #expect(await android.virtualEnabled)
        #expect(await android.sensor == [1])
        #expect(await android.android == [Fingerprint(id: 1, name: "Right thumb")])
        #expect(await center.current.fingers == [Fingerprint(id: 1, name: "Right thumb"), Fingerprint(id: 2, name: "Left index finger", enrolled: false)])
        // Once per finger, and only Avo's.
        await android.set(request: Self.settingsEnrollment)
        await #expect(throws: AvoError.fingerprint(.alreadyInAndroid("Right thumb"))) { try await center.touch(1) }
        await #expect(throws: AvoError.fingerprint(.unregisteredFinger)) { try await center.touch(nil) }
        await #expect(throws: AvoError.fingerprint(.unknownFinger)) { try await center.touch(9) }
        #expect(try await center.touch(2) == .enrolled)
        #expect(await android.android == [Fingerprint(id: 1, name: "Right thumb"), Fingerprint(id: 2, name: "Left index finger")])

        // An app asks: Android's fingers are recognized, the others are not.
        #expect(try await center.touch(1) == .nobodyAsked)
        let left = try await center.add(named: "Left thumb")
        await android.set(request: Self.appAuthentication)
        #expect(try await center.touch(nil) == .notRecognized)
        #expect(try await center.touch(left.id) == .notRecognized)
        #expect(try await center.touch(2) == .recognized)
        #expect(await center.current.request == nil)

        // Renamed and removed in Avo: Android follows.
        try await center.rename(2, to: "Left index")
        #expect(await android.android.last?.name == "Left index")
        try await center.remove(1)
        #expect(await android.android == [Fingerprint(id: 2, name: "Left index")])
        #expect(await android.sensor == [2])
        #expect(FingerprintStore.load(paths).fingers == [Fingerprint(id: 2, name: "Left index"), left])
    }

    @Test func wrongFingersLockFingerprintsOut() async throws {
        let center = await runningCenter()
        _ = try await center.add(named: "Right thumb")
        try await enroll(center, 1)
        await android.set(request: Self.lockScreen)
        for _ in 0..<4 { #expect(try await center.touch(nil) == .notRecognized) }
        #expect(try await center.touch(nil) == .lockedOut)
        #expect(await center.current.lockout == .timed)
        #expect(await !center.current.canTouch)
        // Nothing waits during the lockout: the touch says why.
        #expect(try await center.touch(1) == .lockedOut)
    }

    @Test func fingersNeedNoScreenLockAndroidDoes() async throws {
        await android.set(credentialType: -1)
        let center = await runningCenter()
        #expect(try await center.add(named: "Right thumb") == Fingerprint(id: 1, name: "Right thumb", enrolled: false))
        #expect(await center.current.availability == .noScreenLock)
        #expect(await center.current.canEdit)
        #expect(await !center.current.canTouch)
        // Without a lock, Avo changes nothing in Android.
        #expect(await android.sensor.isEmpty)
        #expect(await !android.virtualEnabled)
    }

    @Test func followsWhatAndroidDoesWithTheFingers() async throws {
        let center = await runningCenter()
        _ = try await center.add(named: "Right thumb")
        _ = try await center.add(named: "Left thumb")
        try await enroll(center, 1)
        try await enroll(center, 2)
        // In Android's Settings: one renamed, one removed (the finger stays in Avo).
        await android.set(android: [Fingerprint(id: 1, name: "Jempol kanan")], sensor: [1])
        let status = await center.status(refresh: true)
        #expect(status.fingers == [Fingerprint(id: 1, name: "Jempol kanan"), Fingerprint(id: 2, name: "Left thumb", enrolled: false)])
        #expect(FingerprintStore.load(paths).fingers == status.fingers)
        // Android's screen lock removed: none of them in Android any more.
        await android.set(android: [], sensor: [])
        #expect(await center.status(refresh: true).fingers.map(\.enrolled) == [false, false])
    }

    @Test func takesInFingerprintsAndroidHadBefore() async throws {
        // Added by an earlier Avo, which named only Android's list.
        await android.set(android: [Fingerprint(id: 7, name: "Finger 1"), Fingerprint(id: 8, name: "")], sensor: [7, 8])
        let center = await runningCenter()
        let fingers = await center.status(refresh: true).fingers
        #expect(fingers == [Fingerprint(id: 7, name: "Finger 1"), Fingerprint(id: 8, name: "Finger 2")])
        #expect(await android.android.last?.name == "Finger 2")
        // A new finger takes an id none of them has.
        #expect(try await center.add(named: "Right thumb").id == 9)
    }

    @Test func aFingerTakesAFreeIDWhenTheSensorStillHasItsOwn() async throws {
        // Added while Android was stopped; the sensor kept id 1 from before.
        try FingerprintStore(fingers: [Fingerprint(id: 1, name: "Right thumb", enrolled: false)]).save(paths)
        await android.set(android: [], sensor: [1])
        let center = await runningCenter()
        try await enroll(center, 1)
        #expect(await center.current.fingers == [Fingerprint(id: 2, name: "Right thumb")])
        #expect(await android.android == [Fingerprint(id: 2, name: "Right thumb")])
    }

    @Test func androidStoppedKeepsTheFingersAndResetTakesThemOutOfAndroid() async throws {
        let center = await runningCenter()
        _ = try await center.add(named: "Right thumb")
        try await enroll(center, 1)
        await center.androidChanged(.stopped)
        #expect(await center.current == FingerprintStatus(availability: .androidStopped, fingers: [Fingerprint(id: 1, name: "Right thumb")]))
        await #expect(throws: AvoError.vmNotRunning) { try await center.touch(1) }
        // Fingers come and go and get their names while Android is stopped too.
        let left = try await center.add(named: "Left thumb")
        #expect(left == Fingerprint(id: 2, name: "Left thumb", enrolled: false))
        try await center.rename(1, to: "Jempol kanan")
        // A new daemon still knows them, and Android gets the new name when it runs again.
        let later = FingerprintCenter(paths: paths, engine: FingerprintTestEngine(android))
        #expect(await later.current.fingers == [Fingerprint(id: 1, name: "Jempol kanan"), left])
        await later.androidChanged(.running)
        _ = await later.status(refresh: true)
        #expect(await android.android == [Fingerprint(id: 1, name: "Jempol kanan")])
        await later.forget()
        #expect(await later.current.fingers == [Fingerprint(id: 1, name: "Jempol kanan", enrolled: false), left])
        #expect(FingerprintStore.load(paths).fingers == [Fingerprint(id: 1, name: "Jempol kanan", enrolled: false), left])
    }

    @Test func aPausedAndroidIsNotWatched() async throws {
        let center = await runningCenter()
        _ = try await center.add(named: "Right thumb")
        try await enroll(center, 1)
        #expect(await center.isWatching)
        // Each look would wake Android: Pause When Idle would never hold.
        await center.androidPaused(true)
        #expect(await !center.isWatching)
        await center.androidPaused(false)
        #expect(await center.isWatching)
    }

    @Test func anEngineWithoutTheSensorIsUnsupported() async throws {
        let center = FingerprintCenter(paths: paths, engine: PlainTestEngine())
        await center.androidChanged(.running)
        #expect(await center.status(refresh: true).availability == .unsupported)
        await #expect(throws: AvoError.fingerprint(.unsupported)) { try await center.add(named: "Right thumb") }
    }

    @Test func androidLetsGoOfARemovedFingerOnceNothingAsks() async throws {
        let center = await runningCenter()
        _ = try await center.add(named: "Right thumb")
        try await enroll(center, 1)
        // Android's lock screen listens: a removal would wait behind it.
        await android.set(request: Self.lockScreen)
        // Adding and renaming wait for nothing.
        _ = try await center.add(named: "Left thumb")
        try await center.rename(1, to: "Jempol kanan")
        #expect(await android.android == [Fingerprint(id: 1, name: "Jempol kanan")])
        // Removed: gone from Avo now, from Android once nothing asks, and not taken back in meanwhile.
        try await center.remove(1)
        #expect(await center.current.fingers.map(\.name) == ["Left thumb"])
        #expect(await android.android.count == 1)
        #expect(await center.status(refresh: true).fingers.map(\.name) == ["Left thumb"])
        #expect(FingerprintStore.load(paths).removing == [1])
        await android.set(request: nil)
        _ = await center.status(refresh: true)
        #expect(await android.android.isEmpty)
        #expect(FingerprintStore.load(paths).removing.isEmpty)
    }

    @Test func cancelsAnAppsRequestOnly() async throws {
        let center = await runningCenter()
        _ = try await center.add(named: "Right thumb")
        await android.set(request: FingerprintRequest(purpose: .authenticate, package: "com.android.systemui"))
        try await center.cancelRequest()
        #expect(await !android.commands.contains(GuestFingerprints.cancelCommand))
        await android.set(request: FingerprintRequest(purpose: .authenticate, package: "com.avodroid.fptest"))
        try await center.cancelRequest()
        #expect(await android.commands.contains(GuestFingerprints.cancelCommand))
        #expect(await android.request == nil)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct FingerprintDaemonTests {
    @Test func onlyTheControlPanelChangesFingers() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        let (shim, _) = await harness.connect(.shim(package: "com.avodroid.hello"))
        let (engine, _) = await harness.connect(.engine)

        // Windows list and touch; only the Control Panel enrolls, renames and removes.
        #expect(try await harness.core.fingerprintStatus(refresh: false, client: shim).availability == .androidStopped)
        await #expect(throws: AvoError.unauthorizedCaller) { try await harness.core.addFingerprint(named: "Right thumb", client: shim) }
        await #expect(throws: AvoError.unauthorizedCaller) { try await harness.core.renameFingerprint(1, to: "x", client: shim) }
        await #expect(throws: AvoError.unauthorizedCaller) { try await harness.core.removeFingerprint(1, client: shim) }
        await #expect(throws: AvoError.unauthorizedCaller) { try await harness.core.fingerprintStatus(refresh: false, client: engine) }
        await #expect(throws: AvoError.vmNotRunning) { try await harness.core.touchFingerprint(1, client: shim) }
        // The fake engine has no fingerprint sensor: no fingers for it.
        await #expect(throws: AvoError.fingerprint(.unsupported)) { try await harness.core.addFingerprint(named: "Right thumb", client: panel) }

        try await harness.core.resetAndroid(client: panel)
        #expect(try await harness.core.fingerprintStatus(refresh: false, client: panel).fingers.isEmpty)
    }

    @Test func statusChangesReachControlPanelsAndWindows() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (_, panelEvents) = await harness.connect(.controlPanel)
        let (_, shimEvents) = await harness.connect(.shim(package: "com.avodroid.hello"))
        try await harness.core.startVM(client: harness.connect(.controlPanel).0)
        // The fake engine has no fingerprint sensor.
        for events in [panelEvents, shimEvents] {
            let event = await events.wait { if case .fingerprints = $0 { true } else { false } }
            #expect(event == .fingerprints(FingerprintStatus(availability: .unsupported)))
        }
    }
}
