import AvoKit
import Foundation
import Testing
@testable import AvoDaemonCore

/// `GoogleAppsCommit`'s scripts, read and run with this Mac's sh against a
/// folder standing in for /product and /system_ext (restorecon and chown
/// are stubs; `FAIL_ON` makes restorecon fail for a path, as a crash would,
/// and `RM_FAIL_ON` does the same for rm).
@Suite(.serialized) struct GoogleAppsCommitTests {
    static let package = [
        "product/etc/permissions/privapp-permissions-google-product.xml",
        "product/etc/default-permissions/default-permissions-google.xml",
        "product/etc/sysconfig/google.xml",
        "product/framework/com.google.android.dialer.support.jar",
        "product/lib64/libjni_latinimegoogle.so",
        "product/overlay/GmsOverlay.apk",
        "product/priv-app/Phonesky/Phonesky.apk",
        "product/app/GoogleCalendarSyncAdapter/GoogleCalendarSyncAdapter.apk",
        "product/app/Camera/lib/arm64/libcamera.so",
        "product/media/audio/ringtones/Google.ogg",
        "system_ext/etc/permissions/privapp-permissions-google-system_ext.xml",
        "system_ext/priv-app/GoogleServicesFramework/GoogleServicesFramework.apk",
    ]
    /// What Android had before (an AOSP image).
    static let stock = [
        "product/etc/permissions/com.android.stock.xml",
        "product/priv-app/Stock/Stock.apk",
        "product/media/audio/ringtones/Stock.ogg",
        "system_ext/etc/permissions/stock_ext.xml",
    ]

    /// A scratch Android: partitions, staging folder and the stubs.
    struct Android {
        let root: URL
        let partitions: URL
        let staging: URL
        let stubs: URL

        init(package: [String] = GoogleAppsCommitTests.package, stock: [String] = GoogleAppsCommitTests.stock) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "avo-commit-\(UUID().uuidString)")
            partitions = root.appending(path: "android")
            staging = root.appending(path: "avo-gapps")
            stubs = root.appending(path: "bin")
            for partition in GoogleAppsCommit.partitions {
                try FileManager.default.createDirectory(at: partitions.appending(path: partition), withIntermediateDirectories: true)
            }
            for path in stock { try Self.write(Data("stock \(path)".utf8), to: partitions.appending(path: path)) }
            for path in package { try Self.write(Data("gapps \(path)".utf8), to: staging.appending(path: path)) }
            try FileManager.default.createDirectory(at: stubs, withIntermediateDirectories: true)
            try Self.stub("restorecon", #"for a in "$@"; do case "$a" in *"$FAIL_ON"*) [ -n "$FAIL_ON" ] && exit 1;; esac; done; exit 0"#, in: stubs)
            try Self.stub("chown", "exit 0", in: stubs)
            try Self.stub("rm", #"for a in "$@"; do case "$a" in *"$RM_FAIL_ON"*) [ -n "$RM_FAIL_ON" ] && exit 1;; esac; done; exec /bin/rm "$@""#, in: stubs)
        }

        var layout: GoogleAppsCommit.Layout {
            GoogleAppsCommit.Layout(root: partitions.path, staging: staging.path, android: false)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }

        /// Runs a script with sh; returns its exit status.
        @discardableResult
        func run(_ script: String, failOn: String = "", rmFailOn: String = "") throws -> Int32 {
            try runSaying(script, failOn: failOn, rmFailOn: rmFailOn).status
        }

        /// Runs a script with sh; its exit status and what it said on stderr.
        func runSaying(_ script: String, failOn: String = "", rmFailOn: String = "") throws -> (status: Int32, said: String) {
            let file = root.appending(path: "script-\(UUID().uuidString).sh")
            try script.write(to: file, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(filePath: "/bin/sh")
            process.arguments = [file.path]
            process.environment = ["PATH": stubs.path + ":/usr/bin:/bin:/usr/sbin:/sbin", "FAIL_ON": failOn, "RM_FAIL_ON": rmFailOn]
            process.standardOutput = FileHandle.nullDevice
            let said = Pipe()
            process.standardError = said
            try process.run()
            let text = String(decoding: said.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (process.terminationStatus, text)
        }

        /// Every file and folder under the partitions, with file contents.
        func tree() -> [String: String] {
            var result: [String: String] = [:]
            let base = partitions.standardizedFileURL.resolvingSymlinksInPath().path
            guard let walker = FileManager.default.enumerator(at: partitions, includingPropertiesForKeys: [.isDirectoryKey]) else { return [:] }
            for case let url as URL in walker {
                let full = url.standardizedFileURL.resolvingSymlinksInPath().path
                let path = String(full.dropFirst(base.count + 1))
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                result[path] = isDirectory ? "<dir>" : (try? String(contentsOf: url, encoding: .utf8)) ?? "?"
            }
            return result
        }

        var manifest: [String] {
            ((try? String(contentsOf: partitions.appending(path: GoogleAppsCommit.manifest), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }

        static func write(_ data: Data, to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        static func stub(_ name: String, _ body: String, in folder: URL) throws {
            let url = folder.appending(path: name)
            try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    @Test func unitsGoInSafestFirst() {
        let units = GoogleAppsCommit.units(Self.package)
        func rank(_ unit: GoogleAppsCommit.Unit) -> Int {
            let top = unit.path.split(separator: "/")[1]
            return top == "etc" ? 0 : ["app", "priv-app"].contains(top) ? 2 : 1
        }
        #expect(units.map(rank) == units.map(rank).sorted())
        // Allowlists of both partitions before any app.
        #expect(units.prefix(4).allSatisfy { $0.path.contains("/etc/") })
        #expect(units.contains(.folder("product/priv-app/Phonesky")))
        #expect(units.contains(.folder("product/app/Camera")))
        #expect(units.contains(.file("product/lib64/libjni_latinimegoogle.so")))
        // A folder Android has already (media/audio) is still one piece.
        #expect(units.contains(.folder("product/media/audio")))
        #expect(units.filter { $0 == .folder("product/app/Camera") }.count == 1)
    }

    @Test func theScriptListsEverythingBeforeChangingAnything() {
        let lines = GoogleAppsCommit.script(Self.package).split(separator: "\n").map(String.init)
        let firstChange = lines.firstIndex { $0.hasPrefix("d ") || $0.hasPrefix("f ") || $0.hasPrefix("if [ -e") }
        let lastListing = lines.lastIndex { $0.hasPrefix("n ") }
        let firstSync = lines.firstIndex(of: "sync")
        #expect(firstChange != nil && lastListing != nil && firstSync != nil)
        if let firstChange, let lastListing, let firstSync {
            #expect(lastListing < firstSync)
            #expect(firstSync < firstChange)
        }
        let allowlist = lines.firstIndex { $0.contains("privapp-permissions-google-product.xml") && $0.hasPrefix("f ") }
        let playStore = lines.firstIndex { $0.contains("else t 'product/priv-app/Phonesky'") }
        #expect(allowlist != nil && playStore != nil && allowlist! < playStore!)
        #expect(lines.suffix(5).contains("echo '#complete' >> \"$M\""))
        // Pieces are renamed into place from the partition's own scratch folder.
        #expect(lines.contains { $0.hasPrefix("t() {") && $0.contains(".avo-new") && $0.contains("mv ") })
    }

    @Test func aCommitGoesInAndComesOutAgain() throws {
        let android = try Android()
        defer { android.cleanUp() }
        let before = android.tree()

        #expect(try android.run(GoogleAppsCommit.script(Self.package, layout: android.layout)) == 0)
        let after = android.tree()
        for path in Self.package { #expect(after[path] == "gapps \(path)", "\(path)") }
        for path in Self.stock { #expect(after[path] == "stock \(path)", "\(path)") }
        #expect(after["product/.avo-new"] == nil && after["system_ext/.avo-new"] == nil)
        #expect(!FileManager.default.fileExists(atPath: android.staging.path))
        let manifest = android.manifest
        #expect(manifest.last == GoogleAppsCommit.completeMarker)
        #expect(manifest.contains("product/priv-app/Phonesky"))
        #expect(manifest.contains("product/etc/default-permissions"))
        #expect(manifest.contains("product/media/audio/ringtones/Google.ogg"))
        // What Android had is never listed, so a rollback leaves it alone.
        #expect(!manifest.contains("product/media/audio"))
        #expect(!manifest.contains("product/etc/permissions"))

        #expect(try android.run(GoogleAppsCommit.rollbackScript(layout: android.layout)) == 0)
        #expect(android.tree() == before)
    }

    @Test func aCommitThatStopsHalfwayComesOutCompletely() throws {
        let android = try Android()
        defer { android.cleanUp() }
        let before = android.tree()

        // Fails right after the Play Store's folder is renamed in.
        #expect(try android.run(GoogleAppsCommit.script(Self.package, layout: android.layout), failOn: "Phonesky") != 0)
        let half = android.tree()
        #expect(half["product/etc/permissions/privapp-permissions-google-product.xml"] != nil)
        #expect(half["system_ext/etc/permissions/privapp-permissions-google-system_ext.xml"] != nil)
        #expect(!android.manifest.contains(GoogleAppsCommit.completeMarker))

        #expect(try android.run(GoogleAppsCommit.rollbackScript(layout: android.layout)) == 0)
        #expect(android.tree() == before)
    }

    /// Installing over a finished install: its files stay when the new
    /// commit is taken out; an unfinished one's list is kept and added to.
    @Test func aSecondCommitOnlyListsWhatItAdds() throws {
        let android = try Android()
        defer { android.cleanUp() }
        #expect(try android.run(GoogleAppsCommit.script(Self.package, layout: android.layout)) == 0)
        let installed = android.tree()

        for path in Self.package + ["product/priv-app/Wellbeing/Wellbeing.apk"] {
            try Android.write(Data("new \(path)".utf8), to: android.staging.appending(path: path))
        }
        let update = Self.package + ["product/priv-app/Wellbeing/Wellbeing.apk"]
        #expect(try android.run(GoogleAppsCommit.script(update, layout: android.layout), failOn: "Wellbeing") != 0)
        // Only the new folder (and, for a folder that turns out to be there, its files).
        #expect(android.manifest == ["product/priv-app/Wellbeing", "product/priv-app/Wellbeing/Wellbeing.apk"])
        #expect(try android.run(GoogleAppsCommit.rollbackScript(layout: android.layout)) == 0)
        let afterRollback = android.tree()
        #expect(afterRollback["product/priv-app/Wellbeing"] == nil)
        // The earlier install's files are still there (updated, not removed).
        #expect(Set(afterRollback.keys) == Set(installed.keys).subtracting([GoogleAppsCommit.manifest]))
        #expect(afterRollback["product/priv-app/Phonesky/Phonesky.apk"] == "new product/priv-app/Phonesky/Phonesky.apk")
    }

    /// A rollback cut short (here: the allowlist cannot be removed) went
    /// from the apps back to the allowlists, and its list no longer reads
    /// as complete; the next commit keeps those paths and finishes cleanly.
    @Test func aRollbackCutShortLeavesNoAppWithoutItsAllowlist() throws {
        let android = try Android()
        defer { android.cleanUp() }
        let before = android.tree()
        #expect(try android.run(GoogleAppsCommit.script(Self.package, layout: android.layout)) == 0)

        let allowlist = "privapp-permissions-google-product.xml"
        #expect(try android.run(GoogleAppsCommit.rollbackScript(layout: android.layout), rmFailOn: allowlist) != 0)
        let half = android.tree()
        #expect(half["product/etc/permissions/" + allowlist] != nil)
        #expect(half["product/priv-app/Phonesky"] == nil)
        #expect(half["system_ext/priv-app/GoogleServicesFramework"] == nil)
        let output = "manifest\n" + android.manifest.joined(separator: "\n")
        #expect(GoogleAppsCommit.state(fromOutput: output) == .partial)

        // Installing again: the list keeps what is still there, without the markers.
        for path in Self.package { try Android.write(Data("gapps \(path)".utf8), to: android.staging.appending(path: path)) }
        #expect(try android.run(GoogleAppsCommit.script(Self.package, layout: android.layout)) == 0)
        #expect(android.manifest.filter { $0.hasPrefix("#") } == [GoogleAppsCommit.completeMarker])
        #expect(GoogleAppsCommit.state(fromOutput: "manifest\n" + android.manifest.joined(separator: "\n")) == .complete)
        #expect(try android.run(GoogleAppsCommit.rollbackScript(layout: android.layout)) == 0)
        #expect(android.tree() == before)
    }

    @Test func aRollbackWithoutAManifestChangesNothing() throws {
        let android = try Android()
        defer { android.cleanUp() }
        let before = android.tree()
        #expect(try android.run(GoogleAppsCommit.rollbackScript(layout: android.layout)) == 0)
        #expect(android.tree() == before)
        #expect(!FileManager.default.fileExists(atPath: android.staging.path))
    }

    @Test func readsHowFarTheCommitGot() {
        #expect(GoogleAppsCommit.state(fromOutput: "") == .none)
        #expect(GoogleAppsCommit.state(fromOutput: "manifest\nproduct/priv-app/Phonesky\n") == .partial)
        #expect(GoogleAppsCommit.state(fromOutput: "manifest\n") == .partial)
        #expect(GoogleAppsCommit.state(fromOutput: "manifest\nproduct/priv-app/Phonesky\n#complete\n") == .complete)
        #expect(GoogleAppsCommit.state(fromOutput: "manifest\nproduct/priv-app/Phonesky\n#complete\n#rollback\n") == .partial)
    }

    @Test func onlyPlainFileNamesReachTheScripts() {
        #expect(GoogleAppsCommit.isSafe("product/priv-app/Phonesky/Phonesky.apk"))
        #expect(GoogleAppsCommit.isSafe("product/lib64/libjni_latinimegoogle.so"))
        #expect(!GoogleAppsCommit.isSafe("product/app/$(reboot)/x.apk"))
        #expect(!GoogleAppsCommit.isSafe("product/app/x\nproduct/etc/y.apk"))
        #expect(!GoogleAppsCommit.isSafe("product/app/it's.apk"))
    }

    /// Android's overlays as Remove meets them: /product and /system_ext
    /// read-only, the package in the overlays' upper folders (`upper`),
    /// listed in `mounts`, and a `remount` that behaves as `remounts`.
    private func overlaid(remounting remounts: String) throws -> (Android, upper: URL, layout: GoogleAppsCommit.Layout) {
        let android = try Android()
        #expect(try android.run(GoogleAppsCommit.script(Self.package, layout: android.layout)) == 0)
        let upper = android.root.appending(path: "upper")
        try FileManager.default.copyItem(at: android.partitions, to: upper)
        let mounts = android.root.appending(path: "mounts")
        try GoogleAppsCommit.partitions.map { "overlay /\($0) overlay ro,lowerdir=/\($0),upperdir=\(upper.path)/\($0),workdir=/w 0 0" }
            .joined(separator: "\n").appending("\n").write(to: mounts, atomically: true, encoding: .utf8)
        try Android.stub("remount", remounts.replacingOccurrences(of: "$MOUNTS", with: mounts.path), in: android.stubs)
        for partition in GoogleAppsCommit.partitions {
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: android.partitions.appending(path: partition).path)
        }
        var layout = android.layout
        layout.android = true
        layout.mounts = mounts.path
        return (android, upper, layout)
    }

    private func writable(_ android: Android) {
        for partition in GoogleAppsCommit.partitions {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: android.partitions.appending(path: partition).path)
        }
    }

    /// b79: verified boot was back on, and `remount` turned it off and left
    /// the overlays out of /proc/mounts. The upper folders read before it
    /// still take the files out.
    @Test func aRemoveFindsTheOverlaysThatRemountHides() throws {
        let (android, upper, layout) = try overlaid(remounting: #"printf 'Successfully disabled verity\nNow reboot your device for settings to take effect\n'; : > "$MOUNTS"; exit 0"#)
        defer {
            writable(android)
            android.cleanUp()
        }
        let result = try android.runSaying(GoogleAppsCommit.rollbackScript(layout: layout))
        #expect(result.status == 0, "\(result.said)")
        for path in Self.package { #expect(!FileManager.default.fileExists(atPath: upper.appending(path: path).path), "\(path)") }
        #expect(!FileManager.default.fileExists(atPath: upper.appending(path: GoogleAppsCommit.manifest).path))
        for path in Self.stock { #expect(FileManager.default.fileExists(atPath: upper.appending(path: path).path), "\(path)") }
    }

    /// Nowhere to take the files out of: the Remove fails, saying where it
    /// looked and what `remount` answered, instead of failing silently.
    @Test func aRemoveWithNowhereToRemoveFromSaysWhy() throws {
        let (android, _, layout) = try overlaid(remounting: #"echo 'remount failed: overlayfs is not supported'; : > "$MOUNTS"; exit 1"#)
        defer {
            writable(android)
            android.cleanUp()
        }
        // No overlay to begin with either.
        try "".write(toFile: layout.mounts, atomically: true, encoding: .utf8)
        let result = try android.runSaying(GoogleAppsCommit.rollbackScript(layout: layout))
        #expect(result.status != 0)
        #expect(result.said.contains("product (not writable)"), "\(result.said)")
        #expect(result.said.contains("remount (1): remount failed: overlayfs is not supported"), "\(result.said)")
    }

    @Test func theRollbackDoesNotStopItself() {
        #expect(GoogleAppsCommit.killPattern("/data/local/tmp/avo-gapps") == "/data/local/tmp/avo-gapp[s]")
        let script = GoogleAppsCommit.rollbackScript()
        #expect(script.contains("pkill -9 -f '/data/local/tmp/avo-gapps-commi[t]'"))
        #expect(script.contains("pkill -9 -f '/data/local/tmp/avo-gapp[s]/'"))
        // Its own command line must not match what it kills.
        #expect(!script.contains("avo-gapps/"))
        #expect(script.contains("remount"))
        #expect(script.contains("upperdir="))
        #expect(GoogleAppsCommit.rootCommand("echo 'x'") == #"su 0 sh -c 'echo '\''x'\'''"#)
    }
}
