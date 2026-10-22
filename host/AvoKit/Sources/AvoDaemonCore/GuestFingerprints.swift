import AvoADB
import AvoKit
import Foundation

/// Android's shell as the fingerprint steps use it (HostAgent's "Fingerprints").
protocol FingerprintGuest: Sendable {
    /// Runs `command` in Android's shell, as root (su) when `asRoot`.
    func fingerprintShell(_ command: String, asRoot: Bool) async throws -> ShellResult
    /// Writes `data` to `path` in Android (the helper jar).
    func fingerprintPush(_ data: Data, to path: String) async throws
}

/// An engine whose Android Avo can enroll and touch fingerprints in (VMMEngine, through HostAgent).
protocol FingerprintEngine: VMEngine {
    /// Android's shell once Android is ready; throws `AvoError.vmNotRunning` before.
    func fingerprintGuest() async throws -> any FingerprintGuest
}

/// AOSP's virtual fingerprint sensor (hardware/interfaces/biometrics/
/// fingerprint/aidl/default, in Cuttlefish's userdebug images as
/// `com.android.hardware.biometrics.fingerprint.virtual`), driven from
/// Android's shell: the commands and what they print.
///
/// - The sensor keeps its enrollments in `persist.vendor.fingerprint.virtual.enrollments`
///   ("1,2") and takes the finger on it from `vendor.fingerprint.virtual.enrollment_hit`.
///   It waits for a finger down, which `cmd fingerprint fingerdown` sends.
/// - Android's own list (with the names) is FingerprintService's; the helper
///   (guest/fingerprint) names, lists and removes them the way Settings does.
/// - Android's Settings app enrolls what the sensor's `next_enrollment` says
///   when a finger touches it: set right before the touch, that is the finger
///   the user chose, under its own id. Android names it "Finger N"; the
///   helper gives it the finger's name.
/// - `fingerdown` works only while the Secure setting
///   `biometric_fingerprint_virtual_enabled` is 1 (debuggable builds). From
///   the next boot on, Android then uses the sensor's `virtual` instance,
///   which reads the same properties.
enum GuestFingerprints {
    // MARK: The helper (guest/fingerprint, run as root with app_process)

    static var helperJar: Data? { Data(base64Encoded: FingerprintHelper.jar) }

    /// Named after its contents, so a jar from another Avo build never runs.
    static let helperPath = "/data/local/tmp/avo-fingerprint-\(checksum(FingerprintHelper.jar)).jar"

    static func helper(_ arguments: String) -> String {
        "CLASSPATH=\(helperPath) app_process / com.avodroid.fingerprint.Main " + arguments
    }

    /// The script's exit status when the jar still has to be copied in.
    static let helperMissingStatus: Int32 = 97
    static let helperMissingMarker = "avo-fingerprint-helper-missing"
    static var helperCheck: String {
        "[ -s \(helperPath) ] || { echo \(helperMissingMarker); exit \(helperMissingStatus); }"
    }

    /// FNV-1a: a short, stable name for the jar's contents.
    static func checksum(_ text: String) -> String {
        var hash: UInt32 = 0x811C_9DC5
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return String(format: "%08x", hash)
    }

    // MARK: Properties and settings

    static let enrollmentsProperty = "persist.vendor.fingerprint.virtual.enrollments"
    static let hitProperty = "vendor.fingerprint.virtual.enrollment_hit"
    static let nextEnrollmentProperty = "vendor.fingerprint.virtual.next_enrollment"
    static let virtualSetting = "biometric_fingerprint_virtual_enabled"
    /// Lockout as on a phone: five wrong fingers lock fingerprints out for
    /// 30 seconds; twenty in a row until the screen lock is entered (the
    /// sensor's own threshold).
    static let lockoutProperties = [
        ("persist.vendor.fingerprint.virtual.lockout_enable", "true"),
        ("persist.vendor.fingerprint.virtual.lockout_timed_threshold", "5"),
        ("persist.vendor.fingerprint.virtual.lockout_timed_duration", "30000"),
    ]
    /// The user (Avo works with Android's owner).
    static let user = 0

    // MARK: Status

    /// One root round trip: what the sensor is, Android's fingerprint
    /// service as `dumpsys` shows it, then the helper's status.
    static var statusScript: String {
        [
            "echo debuggable=$(getprop ro.debuggable)",
            "echo halstart=$(getprop ro.vendor.fingerprint_virtual_hal_start)",
            "[ -d /apex/com.android.hardware.biometrics.fingerprint.virtual ] && echo virtualapex=1",
            "[ -x /vendor/bin/hw/android.hardware.biometrics.fingerprint-service.example ] && echo virtualvendor=1",
            "echo virtual=$(settings get secure \(virtualSetting))",
            "echo enrolled=$(getprop \(enrollmentsProperty))",
            "echo \(dumpMarker)",
            "dumpsys fingerprint",
            "echo \(helperMarker)",
            helperCheck,
            helper("status \(user)"),
        ].joined(separator: "; ")
    }

    static let dumpMarker = "--- dumpsys fingerprint"
    static let helperMarker = "--- helper"

    /// What the sensor is (from the status script's first lines).
    struct Facts: Equatable {
        var debuggable = false
        /// AOSP's virtual sensor is in this Android.
        var virtualSensor = false
        /// `biometric_fingerprint_virtual_enabled` is 1.
        var virtualEnabled = false
        /// The sensor's own enrollments.
        var sensorEnrollments: [Int] = []
    }

    /// The helper's `status`.
    struct HelperStatus: Equatable {
        /// The first fingerprint sensor's id; nil when Android lists none.
        var sensor: Int?
        var active = false
        var lockout: FingerprintStatus.Lockout = .none
        /// LockPatternUtils' credential type: -1 none, 1 pattern, 2 PIN or
        /// password, 3 PIN, 4 password; nil when unknown.
        var credentialType: Int?
        var strongAuth = 0
        var fingers: [Fingerprint] = []
        /// The list ended where the helper said it would.
        var complete = false
        var error: String?
    }

    struct Report: Equatable {
        var facts = Facts()
        var dump = SensorDump()
        var helper = HelperStatus()
        var helperMissing = false
    }

    static func report(_ output: String) -> Report {
        var report = Report()
        var section = 0
        var dumpLines: [Substring] = []
        var helperLines: [Substring] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text == dumpMarker { section = 1; continue }
            if text == helperMarker { section = 2; continue }
            if text == helperMissingMarker { report.helperMissing = true; continue }
            switch section {
            case 0: report.facts.read(text)
            case 1: dumpLines.append(line)
            default: helperLines.append(line)
            }
        }
        report.dump = sensorDump(dumpLines.joined(separator: "\n"))
        report.helper = helperStatus(helperLines.joined(separator: "\n"))
        return report
    }

    static func helperStatus(_ output: String) -> HelperStatus {
        var status = HelperStatus()
        var expected: Int?
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard let key = parts.first else { continue }
            let value = parts.count > 1 ? String(parts[1]) : ""
            switch key {
            case "sensor": status.sensor = Int(value).flatMap { $0 >= 0 ? $0 : nil }
            case "active": status.active = value == "1"
            case "lockout":
                status.lockout = switch Int(value) {
                case 1: .timed
                case 2: .permanent
                default: .none
                }
            case "lock": status.credentialType = Int(value)
            case "strongauth": status.strongAuth = Int(value) ?? 0
            case "finger":
                guard let id = Int(value) else { continue }
                let encoded = parts.count > 2 ? String(parts[2]) : ""
                let name = Data(base64Encoded: encoded).map { String(decoding: $0, as: UTF8.self) } ?? ""
                status.fingers.append(Fingerprint(id: id, name: name))
            case "end": expected = Int(value)
            case "error": status.error = parts.dropFirst().joined(separator: " ")
            default: break
            }
        }
        status.complete = expected == status.fingers.count
        return status
    }

    // MARK: What asks for a finger (`dumpsys fingerprint`)

    static let dumpCommand = "dumpsys fingerprint"

    /// Android's counts for the user: `{"service":…,"prints":[{"id":0,"count":2,"accept":1,"reject":1,…}]}`.
    struct Stats: Equatable {
        var count = 0
        var accept = 0
        var reject = 0
        var lockout = 0
        var permanentLockout = 0
    }

    struct SensorDump: Equatable {
        var request: FingerprintRequest?
        var stats: Stats?
    }

    /// `Current operation: {[14] com.android.server.biometrics.sensors.fingerprint.aidl.FingerprintAuthenticationClient,
    /// proto=3, owner=dev.example, cookie=…, requestId=1, userId=0}, State: 2` (2: started) and the counts.
    static func sensorDump(_ output: String, user: Int = user) -> SensorDump {
        var dump = SensorDump()
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("Current operation:") {
                dump.request = request(inOperation: text)
            } else if text.hasPrefix("{\"service\""), let stats = stats(text, user: user) {
                dump.stats = stats
            }
        }
        return dump
    }

    static func request(inOperation line: String) -> FingerprintRequest? {
        guard !line.contains("Current operation: null"), line.hasSuffix("State: 2"),
              let owner = value(of: "owner", in: line) else { return nil }
        if line.contains("AuthenticationClient,") { return FingerprintRequest(purpose: .authenticate, package: owner) }
        if line.contains("EnrollClient,") { return FingerprintRequest(purpose: .enroll, package: owner) }
        return nil
    }

    private static func value(of key: String, in line: String) -> String? {
        guard let range = line.range(of: " \(key)=") else { return nil }
        let value = line[range.upperBound...].prefix { $0 != "," && $0 != "}" && $0 != " " }
        return value.isEmpty ? nil : String(value)
    }

    private static func stats(_ json: String, user: Int) -> Stats? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let prints = object["prints"] as? [[String: Any]],
              let entry = prints.first(where: { ($0["id"] as? Int) == user }) else { return nil }
        func number(_ key: String) -> Int { entry[key] as? Int ?? 0 }
        return Stats(count: number("count"), accept: number("accept"), reject: number("reject"),
                     lockout: number("lockout"), permanentLockout: number("permanentLockout"))
    }

    // MARK: Status for the Mac

    /// StrongAuthTracker flags that keep fingerprints out until the screen
    /// lock is entered (after a boot, a lockdown, a fingerprint lockout, a
    /// timeout); the "some auth" ones still let fingerprints in.
    static let credentialRequiredFlags = 0x1 | 0x2 | 0x8 | 0x10 | 0x20 | 0x40 | 0x80

    static func availability(_ report: Report) -> FingerprintStatus.Availability {
        guard report.facts.debuggable, report.facts.virtualSensor, report.helper.sensor != nil else { return .unsupported }
        // Unknown counts as set: Android itself refuses then.
        if let type = report.helper.credentialType, type <= 0 { return .noScreenLock }
        return .ready
    }

    static func credentialRequired(_ report: Report) -> Bool {
        report.helper.strongAuth & credentialRequiredFlags != 0
    }

    // MARK: Avo's fingers against Android's

    /// Avo's fingers against Android's fingerprints (`android`, its list now):
    /// - A finger Android has is `enrolled`; one it lacks is not (never added,
    ///   or removed in Android's Settings, with its screen lock or by Reset Android).
    /// - A fingerprint no finger has (added before Avo kept fingers of its
    ///   own) becomes one, with Android's name or else "Finger N"; not the
    ///   ones Avo is taking out of Android (`removing`).
    /// - A name Android changed since the last look (`androidNames`: Android's
    ///   names then) comes over. Any other difference is Avo's (Android cannot
    ///   change while it is stopped, nor name a finger before it has it) and
    ///   goes to Android: `renames`.
    /// The names come back as Android has them now, before the renames.
    static func merge(android: [Fingerprint], fingers: [Fingerprint], androidNames: [Int: String], removing: [Int],
                      defaultName: (Int) -> String) -> (fingers: [Fingerprint], renames: [Fingerprint], androidNames: [Int: String]) {
        var merged: [Fingerprint] = []
        var renames: [Fingerprint] = []
        var names: [Int: String] = [:]
        var prints: [Int: Fingerprint] = [:]
        for print in android where prints[print.id] == nil { prints[print.id] = print }

        for finger in fingers {
            guard let print = prints[finger.id] else {
                merged.append(Fingerprint(id: finger.id, name: finger.name, enrolled: false))
                continue
            }
            names[finger.id] = print.name
            var name = finger.name
            let given = print.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !given.isEmpty, given != finger.name, let last = androidNames[finger.id], last != print.name,
               case .success(let valid) = FingerprintName.validated(given, among: fingers, renaming: finger.id) {
                name = valid  // renamed in Android's Settings
            }
            merged.append(Fingerprint(id: finger.id, name: name, enrolled: true))
            if print.name != name { renames.append(Fingerprint(id: finger.id, name: name)) }
        }
        for print in android where names[print.id] == nil && !removing.contains(print.id) {
            names[print.id] = print.name
            var name = print.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || FingerprintName.finger(named: name, among: merged) != nil {
                var number = merged.count + 1
                while FingerprintName.finger(named: defaultName(number), among: merged + android) != nil { number += 1 }
                name = defaultName(number)
            }
            merged.append(Fingerprint(id: print.id, name: name, enrolled: true))
            if print.name != name { renames.append(Fingerprint(id: print.id, name: name)) }
        }
        return (merged, renames, names)
    }

    /// An id above every one in `ids` (Avo's, Android's and the sensor's).
    static func newID(avoiding ids: [Int]) -> Int {
        max(0, ids.max() ?? 0) + 1
    }

    // MARK: Commands (as root unless said otherwise)

    /// Turns on what `fingerdown` needs and phone-like lockout (without
    /// overriding a value set by hand).
    static var prepareScript: String {
        var steps = ["[ \"$(settings get secure \(virtualSetting))\" = 1 ] || settings put secure \(virtualSetting) 1"]
        steps += lockoutProperties.map { property, value in "[ -n \"$(getprop \(property))\" ] || setprop \(property) \(value)" }
        return steps.joined(separator: "; ")
    }

    static func renameScript(id: Int, name: String) -> String {
        helperCheck + "; " + helper("rename \(id) \(encoded(name)) \(user)")
    }

    /// Removes it as Settings does: Android takes it out of the sensor too.
    static func removeScript(id: Int) -> String {
        helperCheck + "; " + helper("remove \(id) \(user)")
    }

    /// Puts finger `id` on the sensor (0: one the sensor does not know).
    static func touchScript(id: Int) -> String {
        "setprop \(hitProperty) \(max(0, id)) && cmd fingerprint fingerdown"
    }

    /// Puts finger `id` on the sensor while Android's Settings adds a
    /// fingerprint: the sensor enrolls it under `id` (three captures of
    /// 100 ms, then success).
    static func enrollScript(id: Int) -> String {
        "setprop \(nextEnrollmentProperty) \(id):100,100,100:true && " + touchScript(id: id)
    }

    /// As the shell user: Back on Android's own screen, where an app's
    /// BiometricPrompt shows, cancels it (the app hears "canceled").
    static let cancelCommand = "input -d 0 keyevent 4"

    /// As the shell user: sleep and wake, as the power button does; Android
    /// locks and asks for its screen lock, which resets a fingerprint lockout.
    static let lockCommand = "input keyevent 223 && input keyevent 224"

    static func encoded(_ name: String) -> String {
        Data(name.utf8).base64EncodedString()
    }

    // MARK: A touch's outcome

    /// What the counts say a touch did, nil while they have not moved.
    static func touchOutcome(_ purpose: FingerprintRequest.Purpose, before: Stats, after: Stats) -> FingerprintTouchResult? {
        switch purpose {
        case .enroll:
            return after.count > before.count ? .enrolled : nil
        case .authenticate:
            if after.lockout > before.lockout || after.permanentLockout > before.permanentLockout { return .lockedOut }
            if after.accept > before.accept { return .recognized }
            if after.reject > before.reject { return .notRecognized }
            return nil
        }
    }
}

extension GuestFingerprints.Facts {
    mutating func read(_ line: String) {
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return }
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        switch parts[0] {
        case "debuggable": debuggable = value == "1"
        case "halstart": virtualSensor = virtualSensor || value == "true"
        case "virtualapex", "virtualvendor": virtualSensor = virtualSensor || value == "1"
        case "virtual": virtualEnabled = value == "1"
        case "enrolled": sensorEnrollments = value.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        default: break
        }
    }
}
