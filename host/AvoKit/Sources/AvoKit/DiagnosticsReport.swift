import Foundation

/// Help › Report a Problem (the Control Panel): a zip the user saves where
/// they choose and sends on themselves; Avo never uploads it. What goes in
/// is `contents` (and docs/architecture.md, "Report a Problem"). Android's
/// data (its disks and the apps' files), the ADB keys, fingerprints and
/// account details never do, and every log and file passes
/// `DiagnosticsRedactor` first.
public enum DiagnosticsReport {
    public struct Options: Sendable {
        /// What happened, in the user's words.
        public var note: String
        /// The end of Android's own log (logcat), which apps write to.
        public var includeAndroidLog: Bool
        /// The installed apps' names and versions.
        public var includeApps: Bool

        public init(note: String = "", includeAndroidLog: Bool = true, includeApps: Bool = true) {
            self.note = note
            self.includeAndroidLog = includeAndroidLog
            self.includeApps = includeApps
        }
    }

    /// `report.json`: what the Control Panel knows, as it knows it.
    public struct Facts: Codable, Sendable {
        public var created: Date
        /// "1.4 (37)".
        public var avo: String
        /// The Runtime Daemon's own version (nil when it did not answer).
        public var daemon: String?
        public var macOS: String
        /// "Mac16,7".
        public var mac: String
        public var host: HostInfo?
        public var status: VMStatus?
        public var settings: VMConfig?
        public var pendingRestart: Bool?
        public var adb: ADBStatus?
        public var dataDisk: DataDiskStatus?
        public var storageLocation: StorageLocationStatus?
        public var gpuCache: GPUCacheStatus?
        public var apps: [App]?
        /// What could not be collected, and why.
        public var problems: [String]

        public struct App: Codable, Sendable, Equatable {
            public var package: String
            public var version: String
            public var systemApp: Bool

            public init(_ record: AppRecord) {
                package = record.package
                version = "\(record.versionName) (\(record.versionCode))"
                systemApp = record.systemApp
            }
        }

        public init(created: Date = Date(), avo: String, daemon: String? = nil, macOS: String = ProcessInfo.processInfo.operatingSystemVersionString,
                    mac: String = DiagnosticsReport.macModel, host: HostInfo? = nil, status: VMStatus? = nil, settings: VMConfig? = nil,
                    pendingRestart: Bool? = nil, adb: ADBStatus? = nil, dataDisk: DataDiskStatus? = nil,
                    storageLocation: StorageLocationStatus? = nil, gpuCache: GPUCacheStatus? = nil, apps: [App]? = nil,
                    problems: [String] = []) {
            self.created = created
            self.avo = avo
            self.daemon = daemon
            self.macOS = macOS
            self.mac = mac
            self.host = host
            self.status = status
            self.settings = settings
            self.pendingRestart = pendingRestart
            self.adb = adb
            self.dataDisk = dataDisk
            self.storageLocation = storageLocation
            self.gpuCache = gpuCache
            self.apps = apps
            self.problems = problems
        }
    }

    /// How much of each log goes in: its end, where the problem usually is.
    static let limits: [String: Int] = [
        "daemon.log": 4 << 20, "avo-vmm.log": 2 << 20, "avo-vmm-gpu-failed.log": 1 << 20,
        "kernel.log": 512 << 10, "logcat.log": 2 << 20, "bluetooth.log": 512 << 10,
        // What came before avo-vmm's last rotation of a log it caps.
        "kernel.1.log": 512 << 10, "logcat.1.log": 2 << 20,
    ]
    /// Avo's own log, from the unified log, this far back.
    static let daemonLogSpan = "3h"

    /// What the report holds, for the form and the report's README.
    public static func contents(_ options: Options) -> [String] {
        var items = [
            String(localized: "Versions of Avo, macOS and Android, and this Mac’s model, memory and cores", bundle: .avoKit),
            String(localized: "Avo’s settings, and Android’s status, renderer and storage", bundle: .avoKit),
        ]
        if options.includeApps {
            items.append(String(localized: "The names and versions of the installed apps", bundle: .avoKit))
        }
        items.append(String(localized: "Avo’s log from the last 3 hours", bundle: .avoKit))
        items.append(String(localized: "The engine’s logs (the Bluetooth controller’s too) and the end of Android’s kernel log", bundle: .avoKit))
        if options.includeAndroidLog {
            items.append(String(localized: "The end of Android’s log (logcat), which apps write to as well", bundle: .avoKit))
        }
        return items
    }

    /// What it never holds.
    public static var leftOut: String {
        String(localized: "Never in it: Android’s data and your apps’ files, the keys Avo uses for ADB, your fingerprints and your accounts. Email addresses, account names, tokens and locations are taken out of the logs, and your home folder shows as ~.",
               bundle: .avoKit)
    }

    /// "Avo Report 2026-10-18 14.32.zip".
    public static func fileName(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Avo Report \(formatter.string(from: date)).zip"
    }

    /// Avo's log, under its subsystem and the one of the builds before com.avodroid.
    static let logPredicate = "subsystem == \"\(AvoIdentifiers.logSubsystem)\" OR subsystem == \"\(AvoIdentifiers.formerPrefix)\""

    /// Runs `log show` (a parameter for tests): Avo's subsystem, compact.
    public typealias LogReader = @Sendable (_ arguments: [String]) async throws -> Data

    /// Collects everything into a folder and zips it to `destination`
    /// (replacing a file there). Logs that are missing are noted in
    /// report.json's `problems`, never a failure.
    public static func write(to destination: URL, options: Options, facts: Facts, paths: AvoPaths,
                             redactor: DiagnosticsRedactor = DiagnosticsRedactor(),
                             readLog: LogReader = DiagnosticsReport.logShow) async throws {
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appending(path: "avo-report-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folder = work.appending(path: (fileName(at: facts.created) as NSString).deletingPathExtension, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }
        var facts = facts
        if !options.includeApps { facts.apps = nil }

        func put(_ name: String, _ text: String) throws {
            try Data(redactor.redact(text).utf8).write(to: folder.appending(path: name))
        }
        /// The end of a log file, cut at a line.
        func copyLog(_ source: URL, as name: String) {
            guard let data = try? Data(contentsOf: source) else {
                facts.problems.append("\(name): \(redactor.redact(source.path)) is missing")
                return
            }
            try? put(name, String(decoding: tail(data, bytes: limits[name] ?? (1 << 20)), as: UTF8.self))
        }

        do {
            // The former subsystem too: the hours after an update from a build
            // before com.avodroid (its daemon may still run).
            let log = try await readLog(["show", "--style", "compact", "--last", daemonLogSpan,
                                         "--predicate", Self.logPredicate])
            try put("daemon.log", String(decoding: tail(log, bytes: limits["daemon.log"]!), as: UTF8.self))
        } catch {
            facts.problems.append("daemon.log: \(error.localizedDescription)")
        }
        copyLog(paths.logs.appending(path: "avo-vmm.log"), as: "avo-vmm.log")
        let failed = paths.logs.appending(path: "avo-vmm-gpu-failed.log")
        if fileManager.fileExists(atPath: failed.path) { copyLog(failed, as: "avo-vmm-gpu-failed.log") }
        copyLog(paths.instance.appending(path: "kernel.log"), as: "kernel.log")
        // avo-vmm caps its logs: right after a rotation, the problem is in the
        // part before it.
        let kernelBefore = paths.instance.appending(path: "kernel.1.log")
        if fileManager.fileExists(atPath: kernelBefore.path) { copyLog(kernelBefore, as: "kernel.1.log") }
        // Android's Bluetooth controller (Root Canal), when it ran.
        let bluetooth = paths.instance.appending(path: "bluetooth.log")
        if fileManager.fileExists(atPath: bluetooth.path) { copyLog(bluetooth, as: "bluetooth.log") }
        if options.includeAndroidLog {
            copyLog(paths.instance.appending(path: "logcat.log"), as: "logcat.log")
            let before = paths.instance.appending(path: "logcat.1.log")
            if fileManager.fileExists(atPath: before.path) { copyLog(before, as: "logcat.1.log") }
        }
        // Small state files: no secrets, only builds, sizes and paths.
        for file in [paths.vm.appending(path: "gpu-fallback.json"), paths.data.appending(path: "data-disk.json"),
                     paths.data.appending(path: "android-data.json"), paths.instance.appending(path: "avo-image.json")] {
            guard let data = try? Data(contentsOf: file), data.count < 1 << 20 else { continue }
            try? fileManager.createDirectory(at: folder.appending(path: "state"), withIntermediateDirectories: true)
            try? put("state/\(file.lastPathComponent)", String(decoding: data, as: UTF8.self))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try put("report.json", String(decoding: try encoder.encode(facts), as: UTF8.self))
        try put("README.txt", readme(options: options, facts: facts))

        try? fileManager.removeItem(at: destination)
        try await zip(folder, to: destination)
    }

    static func readme(options: Options, facts: Facts) -> String {
        var lines = [String(localized: "Avo problem report", bundle: .avoKit),
                     ISO8601DateFormatter().string(from: facts.created), ""]
        let note = options.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            lines += [String(localized: "What happened:", bundle: .avoKit), note, ""]
        }
        lines.append(String(localized: "This report holds:", bundle: .avoKit))
        lines += contents(options).map { "- " + $0 }
        lines += ["", leftOut, "",
                  String(localized: "Avo does not send this report anywhere. Attach it to your message to Avo’s developers.", bundle: .avoKit)]
        return lines.joined(separator: "\n") + "\n"
    }

    /// The last `bytes` of `data`, from the start of a line.
    static func tail(_ data: Data, bytes: Int) -> Data {
        guard data.count > bytes else { return data }
        let cut = data.suffix(bytes)
        guard let newline = cut.firstIndex(of: 0x0A) else { return cut }
        return cut[cut.index(after: newline)...]
    }

    public static let logShow: LogReader = { arguments in
        try await run("/usr/bin/log", arguments, timeout: .seconds(90))
    }

    static func zip(_ folder: URL, to destination: URL) async throws {
        _ = try await run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, destination.path],
                          timeout: .seconds(120))
    }

    /// Runs a tool and returns what it printed; its error output on failure.
    static func run(_ tool: String, _ arguments: [String], timeout: Duration) async throws -> Data {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let timer = Task {
            try await Task.sleep(for: timeout)
            process.terminate()
        }
        // Read before waiting: a full pipe would block the tool.
        async let printed = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        async let complaint = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
        let (data, errorData) = await (printed, complaint)
        process.waitUntilExit()
        timer.cancel()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AvoError.internalError("\((tool as NSString).lastPathComponent) exited with \(process.terminationStatus)\(message.isEmpty ? "" : ": " + message)")
        }
        return data
    }

    /// The Mac's model identifier (`hw.model`).
    public static var macModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Takes what identifies the user out of a report's text: their home
/// folder and name, email addresses, account names, tokens and passwords,
/// device ids, locations and the query strings of links.
public struct DiagnosticsRedactor: Sendable {
    let home: String
    let user: String

    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path, user: String = NSUserName()) {
        self.home = home.hasSuffix("/") ? String(home.dropLast()) : home
        self.user = user
    }

    private static let rules: [(NSRegularExpression, String)] = [
        // Account {name=someone@example.com, type=com.google}
        (#"(Account ?\{name=)[^,}]+"#, "$1<account>"),
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
        (#"(?i)\b(bearer|oauth2?:?)\s+[A-Za-z0-9._~+/=-]{8,}"#, "$1 <redacted>"),
        (#"(?i)\b([a-z_]*(?:token|password|passwd|secret|cookie|authorization|api[_-]?key)[a-z_]*)(["']?\s*[:=]\s*["']?)(?!(?i:bearer|basic)\b)[^\s"',;&}]+"#, "$1$2<redacted>"),
        (#"(?i)\b(android[_ ]?id|gsf[_ ]?id|imei|meid|iccid|imsi|advertising[_ ]?id|adid)(["']?\s*[:=]\s*["']?)[^\s"',;&}]+"#, "$1$2<redacted>"),
        // GNSS fixes: avo-vmm's `location <lat> <lng> …` and Android's Location[gps 12.34,56.78 …].
        (#"\blocation -?\d+\.\d+ -?\d+\.\d+[^\n]*"#, "location <redacted>"),
        (#"(Location\[\w+) -?\d+\.\d+, ?-?\d+\.\d+"#, "$1 <redacted>"),
        (#"(?i)\b(lat(?:itude)?|lng|lon(?:gitude)?)(["']?\s*[:=]\s*)-?\d+\.\d+"#, "$1$2<redacted>"),
        // A link's query often carries a token.
        (#"(https?://[^\s?"'<>]+)\?[^\s"'<>]+"#, "$1?<redacted>"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    public func redact(_ text: String) -> String {
        var text = text
        if !home.isEmpty, home != "/" {
            text = text.replacingOccurrences(of: home, with: "~")
        }
        for (rule, template) in Self.rules {
            text = rule.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        // The user's short name elsewhere (a volume or a host name).
        if user.count >= 3 {
            text = text.replacingOccurrences(of: user, with: "<user>")
        }
        return text
    }
}
