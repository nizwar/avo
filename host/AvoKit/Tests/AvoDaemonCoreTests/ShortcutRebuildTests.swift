import AvoKit
import AvoShimKit
import AvoTestSupport
import Foundation
import Testing
@testable import AvoDaemonCore

/// Settings › General's shortcut options and Recreate Shortcuts make every
/// app's shortcuts again, off the core (frames and input pass through it).
/// The Dock is left alone here: these tests never add to it.
@Suite(.serialized, .timeLimit(.minutes(1))) struct ShortcutRebuildTests {
    @Test func desktopAliasesFollowTheSettingAndEachShimKeepsItsHash() async throws {
        let harness = try Harness(apps: [FakeBridgeAgent.app("org.fdroid.fdroid", label: "F-Droid"),
                                         FakeBridgeAgent.app("com.example.notes", label: "Notes")], desktopAliases: true)
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        #expect(await harness.waitForShims(2))
        let aliases = await harness.core.apps().compactMap(\.shortcuts.desktopAliasPath)
        #expect(aliases.count == 2)

        var config = await harness.core.configurationSnapshot().config
        config.createDesktopAlias = false
        _ = try await harness.core.updateConfiguration(config, client: panel)
        for app in await harness.core.apps() {
            #expect(app.shortcuts.desktopAliasPath == nil)
            let shim = try #require(app.shortcuts.shimPath)
            #expect(ShimBuilder.cdhash(of: URL(filePath: shim)) == app.shortcuts.shimCDHash, "the hash the daemon lets the shim in by")
        }
        #expect(aliases.allSatisfy { !FileManager.default.fileExists(atPath: $0) })

        config.createDesktopAlias = true
        _ = try await harness.core.updateConfiguration(config, client: panel)
        #expect(await harness.core.apps().allSatisfy { $0.shortcuts.desktopAliasPath.map(FileManager.default.fileExists) == true })

        // One app's, from its page; the other's stays as it was.
        let before = await harness.core.apps()
        try await harness.core.recreateShortcuts(for: "com.example.notes", client: panel)
        let after = await harness.core.apps()
        let notes = try #require(after.first { $0.package == "com.example.notes" })
        #expect(ShimBuilder.cdhash(of: URL(filePath: try #require(notes.shortcuts.shimPath))) == notes.shortcuts.shimCDHash)
        #expect(after.first { $0.package == "org.fdroid.fdroid" }?.shortcuts == before.first { $0.package == "org.fdroid.fdroid" }?.shortcuts)
    }
}
