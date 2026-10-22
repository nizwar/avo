import AvoKit
import AvoShimKit
import Foundation
import Testing
@testable import AvoDaemonCore

/// Shims are made again for an Avo.app updated in place: same path, new build.
@Suite struct ShimBuildTests {
    private func plist(_ info: [String: Any], at bundle: URL) throws {
        let contents = bundle.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
    }

    @Test func aShimFromAnotherBuildOfTheSameAvoIsMadeAgain() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "avo-shim-build-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let template = root.appending(path: "Avo.app/Contents/Library/Shim/AvoShim.app")
        let shim = root.appending(path: "Android Apps/F-Droid.app")
        let host = "/Applications/Avo.app"
        let builder = ShimBuilder(template: template, hostApplication: URL(filePath: host), directory: root.appending(path: "Android Apps"))
        let manager = ShortcutManager(builder: builder, paths: AvoPaths(home: root))
        let shortcuts = AppRecord.Shortcuts(shimPath: shim.path)

        try plist(["CFBundleVersion": "42"], at: template)
        try plist(["CFBundleVersion": "42", AvoIdentifiers.shimHostAppInfoKey: host], at: shim)
        #expect(!manager.madeForAnotherAvo(shortcuts))

        try plist(["CFBundleVersion": "41", AvoIdentifiers.shimHostAppInfoKey: host], at: shim)
        #expect(manager.madeForAnotherAvo(shortcuts), "made by the build before the update")

        try plist(["CFBundleVersion": "42", AvoIdentifiers.shimHostAppInfoKey: "/Users/me/Avo.app"], at: shim)
        #expect(manager.madeForAnotherAvo(shortcuts), "made by another copy of Avo")

        try plist(["CFBundleVersion": "42", AvoIdentifiers.shimHostAppInfoKey: host,
                   "CFBundleIdentifier": "dev.avo.shim.org.fdroid.fdroid"], at: shim)
        #expect(manager.madeForAnotherAvo(shortcuts), "made before com.avodroid")
        try plist(["CFBundleVersion": "42", AvoIdentifiers.shimHostAppInfoKey: host,
                   "CFBundleIdentifier": "com.avodroid.shim.org.fdroid.fdroid"], at: shim)
        #expect(!manager.madeForAnotherAvo(shortcuts))

        // A template without a build (tests, hand builds) changes nothing.
        try plist([:], at: template)
        try plist(["CFBundleVersion": "41", AvoIdentifiers.shimHostAppInfoKey: host], at: shim)
        #expect(!manager.madeForAnotherAvo(shortcuts))
    }
}
