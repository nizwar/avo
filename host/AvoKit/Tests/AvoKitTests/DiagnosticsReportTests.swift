import Foundation
import Testing
@testable import AvoKit

@Suite struct DiagnosticsRedactorTests {
    let redactor = DiagnosticsRedactor(home: "/Users/someone", user: "someone")

    @Test func homeAndUserNameGo() {
        #expect(redactor.redact("/Users/someone/Library/Logs/Avo/avo-vmm.log") == "~/Library/Logs/Avo/avo-vmm.log")
        #expect(redactor.redact("volume someone's SSD") == "volume <user>'s SSD")
    }

    @Test func accountsEmailsAndTokensGo() {
        #expect(redactor.redact("Account {name=jane.doe@gmail.com, type=com.google}") == "Account {name=<account>, type=com.google}")
        #expect(redactor.redact("signed in as jane.doe@example.co.id now") == "signed in as <email> now")
        #expect(redactor.redact("Authorization: Bearer ya29.a0AfB_byC1234567890") == "Authorization: Bearer <redacted>")
        #expect(redactor.redact("auth_token=abc123&x=1") == "auth_token=<redacted>&x=1")
        #expect(redactor.redact(#"{"refreshToken": "1//0gAbC"}"#) == #"{"refreshToken": "<redacted>"}"#)
        #expect(redactor.redact("password: hunter2") == "password: <redacted>")
        #expect(redactor.redact("android_id=3f2a9c1b7d6e5f40") == "android_id=<redacted>")
        #expect(redactor.redact("GET https://api.example.com/v1/feed?key=SECRET&uid=7 200") == "GET https://api.example.com/v1/feed?<redacted> 200")
    }

    @Test func locationsGo() {
        #expect(redactor.redact("control: location -6.2087634 106.8455990 12.0 5.0 0.00 0.0") == "control: location <redacted>")
        #expect(redactor.redact("Location[gps -6.208763,106.845599 hAcc=5]") == "Location[gps <redacted> hAcc=5]")
        #expect(redactor.redact(#""latitude": -6.2087"#) == #""latitude": <redacted>"#)
    }

    @Test func whatHelpsStays() {
        let line = "10-18 14:51:06.123  1234  1250 E AndroidRuntime: FATAL EXCEPTION in com.example.game (pid 1234)"
        #expect(redactor.redact(line) == line)
        let engine = "[gpu] ctx=13 res=74 blobs=39 mapped=41MiB fences=0 oldest=0ms"
        #expect(redactor.redact(engine) == engine)
    }
}

@Suite struct DiagnosticsReportTests {
    @Test func tailsStartAtALine() {
        let data = Data("one\ntwo\nthree\nfour\n".utf8)
        #expect(String(decoding: DiagnosticsReport.tail(data, bytes: 9), as: UTF8.self) == "four\n")
        #expect(DiagnosticsReport.tail(data, bytes: 100) == data)
    }

    @Test func fileNameSortsByDate() {
        var components = DateComponents(year: 2026, month: 10, day: 18, hour: 14, minute: 32)
        components.timeZone = .current
        let date = Calendar(identifier: .gregorian).date(from: components)!
        #expect(DiagnosticsReport.fileName(at: date) == "Avo Report 2026-10-18 14.32.zip")
    }

    @Test func theContentsFollowTheOptions() {
        let all = DiagnosticsReport.contents(.init())
        let fewer = DiagnosticsReport.contents(.init(includeAndroidLog: false, includeApps: false))
        #expect(all.count == fewer.count + 2)
    }

    /// A whole report from a made-up home: the logs, redacted, and nothing
    /// of Android's data or Avo's keys.
    @Test func aReportHoldsTheLogsAndNeverTheData() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "avo-report-test-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home")
        let paths = AvoPaths(home: home, temporaryDirectory: root.appending(path: "tmp"))
        let fm = FileManager.default
        for directory in [paths.logs, paths.instance, paths.vm, paths.data] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("[vmm] 4 vCPUs\n[vmm] paused\n".utf8).write(to: paths.logs.appending(path: "avo-vmm.log"))
        try Data("Booting Linux\n".utf8).write(to: paths.instance.appending(path: "kernel.log"))
        try Data("I AccountManager: Account {name=jane@gmail.com, type=com.google}\n".utf8).write(to: paths.instance.appending(path: "logcat.log"))
        try Data("PRIVATE KEY".utf8).write(to: paths.adbKey)
        try Data(repeating: 1, count: 4096).write(to: paths.dataDisk)
        try Data(#"{"failure":"noFrames"}"#.utf8).write(to: paths.vm.appending(path: "gpu-fallback.json"))

        let zip = root.appending(path: "out/report.zip")
        try fm.createDirectory(at: zip.deletingLastPathComponent(), withIntermediateDirectories: true)
        let facts = DiagnosticsReport.Facts(avo: "1.0 (1)", status: VMStatus(state: .suspended, pause: VMPause(since: Date(), automatic: true)),
                                            settings: VMConfig(imageLocation: home.appending(path: "Images").path),
                                            apps: [.init(AppRecord(package: "org.fdroid.fdroid", label: "F-Droid"))])
        let redactor = DiagnosticsRedactor(home: home.path, user: "nobody-here")
        try await DiagnosticsReport.write(to: zip, options: .init(note: "It froze"), facts: facts, paths: paths, redactor: redactor) { arguments in
            #expect(arguments.contains("subsystem == \"com.avodroid\" OR subsystem == \"dev.avo\""))
            return Data("daemon: Android paused (idle) at \(home.path)/x\n".utf8)
        }

        let listing = String(decoding: try await DiagnosticsReport.run("/usr/bin/zipinfo", ["-1", zip.path], timeout: .seconds(20)), as: UTF8.self)
        let files = Set(listing.split(separator: "\n").map { $0.split(separator: "/", maxSplits: 1).last.map(String.init) ?? "" })
        #expect(files.isSuperset(of: ["README.txt", "report.json", "daemon.log", "avo-vmm.log", "kernel.log", "logcat.log",
                                      "state/gpu-fallback.json"]), "\(files)")
        #expect(!listing.contains("adbkey") && !listing.contains("userdata"))

        let unpacked = root.appending(path: "unpacked")
        _ = try await DiagnosticsReport.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path], timeout: .seconds(20))
        let folder = try #require(try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil).first)
        let text = { (name: String) in (try? String(contentsOf: folder.appending(path: name), encoding: .utf8)) ?? "" }
        #expect(text("logcat.log").contains("Account {name=<account>"))
        #expect(!text("logcat.log").contains("jane@gmail.com"))
        #expect(text("daemon.log") == "daemon: Android paused (idle) at ~/x\n")
        #expect(text("README.txt").contains("It froze"))
        let report = text("report.json")
        #expect(report.contains("\"imageLocation\" : \"~/Images\""))
        #expect(report.contains("org.fdroid.fdroid"))
        #expect(report.contains("\"automatic\" : true"))
        #expect(!report.contains(home.path))
    }
}
