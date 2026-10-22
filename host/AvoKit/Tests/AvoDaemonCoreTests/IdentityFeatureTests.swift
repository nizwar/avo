import AvoKit
import Foundation
import Testing
@testable import AvoDaemonCore

/// Avo's identity at boot: the engine's properties file (VMMEngine) and the
/// system feature HostAgent declares where /product keeps changes
/// (IdentityFeature), run with this Mac's sh against a scratch folder
/// standing in for Android (remount, chown and restorecon are stubs).
@Suite(.serialized) struct IdentityFeatureTests {
    static func markers(_ renderer: AvoIdentity.Renderer) -> AvoIdentity.Markers {
        AvoIdentity.Markers(version: "0.1.0", hostOS: "macOS 27.0.1", hostChip: "Apple M4 Pro", renderer: renderer)
    }

    @Test func identityFileSaysWhichRendererThisLaunchUses() {
        let emulator = AndroidEmulator(directory: URL(filePath: "/Users/u/Library/Android/sdk/emulator"), version: "37.1.11", build: nil)
        let gpu = VMMEngine.identityProperties(profile: .avo, plan: .gpu(emulator), markers: Self.markers)
        let fallback = VMMEngine.identityProperties(profile: .avo, plan: .software(.failed, .crashed), markers: Self.markers)
        #expect(gpu.contains("ro.boot.avo.renderer=gpu\n"))
        #expect(fallback.contains("ro.boot.avo.renderer=software\n"))
        #expect(gpu.contains("ro.product.manufacturer=Avo\n") && gpu.contains("ro.boot.avo.schema=1\n"))
        // The rest is the same file.
        #expect(gpu.replacingOccurrences(of: "=gpu\n", with: "=software\n") == fallback)
    }

    @Test(arguments: [
        // No Google apps: /product would not keep the file.
        ("--avo-feature--\n", false),
        ("manifest\nproduct/app/A\n--avo-feature--\n", false),
        ("manifest\nproduct/app/A\n#complete\n#rollback\n--avo-feature--\n", false),
        // Installed: write it unless it is there already.
        ("manifest\nproduct/app/A\n#complete\n--avo-feature--\n", true),
        ("manifest\nproduct/app/A\n#complete\n--avo-feature--\n<permissions><feature name=\"com.avodroid.feature.MAC\" version=\"0\" /></permissions>\n", true),
        ("manifest\nproduct/app/A\n#complete\n--avo-feature--\n" + AvoIdentity.permissionsFile, false),
        ("garbage", false),
    ])
    func writesOnlyWhereProductKeepsIt(output: String, write: Bool) {
        #expect(IdentityFeature.needsWrite(checkOutput: output) == write)
    }

    @Test func checkAndWriteAgainstAScratchAndroid() throws {
        let android = try Scratch()
        defer { android.cleanUp() }
        // Stock Android: nothing to do.
        #expect(!IdentityFeature.needsWrite(checkOutput: try android.run(IdentityFeature.checkCommand(root: android.root.path))))

        // Google apps installed: the file goes in once.
        try "product/app/A\n#complete\n".write(to: android.file("product/etc/avo-gapps.files"), atomically: true, encoding: .utf8)
        #expect(IdentityFeature.needsWrite(checkOutput: try android.run(IdentityFeature.checkCommand(root: android.root.path))))
        _ = try android.run(IdentityFeature.writeScript(root: android.root.path))
        let written = android.file(String(AvoIdentity.permissionsPath.dropFirst()))
        #expect(try String(contentsOf: written, encoding: .utf8) == AvoIdentity.permissionsFile)
        let mode = try FileManager.default.attributesOfItem(atPath: written.path)[.posixPermissions] as? Int
        #expect(mode == 0o644)
        #expect(try android.calls() == ["remount /product", "chown root:root \(android.root.path)/product/etc/permissions/.com.avodroid.feature.mac.xml.new",
                                       "restorecon \(written.path)"])
        // Nothing left beside it that SystemConfig could read.
        let names = try FileManager.default.contentsOfDirectory(atPath: android.file("product/etc/permissions").path)
        #expect(names.sorted() == ["com.android.stock.xml", "com.avodroid.feature.mac.xml"])
        #expect(!IdentityFeature.needsWrite(checkOutput: try android.run(IdentityFeature.checkCommand(root: android.root.path))))
    }

    @Test func theFormerFeatureFileGoesWhereTheNewOneIs() throws {
        let android = try Scratch()
        defer { android.cleanUp() }
        // A data disk from before com.avodroid: Google apps, this file already
        // right, and dev.avo.feature.mac.xml beside it.
        try "product/app/A\n#complete\n".write(to: android.file("product/etc/avo-gapps.files"), atomically: true, encoding: .utf8)
        try AvoIdentity.permissionsFile.write(to: android.file(String(AvoIdentity.permissionsPath.dropFirst())),
                                              atomically: true, encoding: .utf8)
        let former = android.file(String(AvoIdentity.formerPermissionsPath.dropFirst()))
        try "<permissions><feature name=\"dev.avo.feature.MAC\" version=\"1\" /></permissions>".write(to: former, atomically: true, encoding: .utf8)
        #expect(IdentityFeature.needsWrite(checkOutput: try android.run(IdentityFeature.checkCommand(root: android.root.path))))
        _ = try android.run(IdentityFeature.writeScript(root: android.root.path))
        #expect(!FileManager.default.fileExists(atPath: former.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: android.file("product/etc/permissions").path)
        #expect(names.sorted() == ["com.android.stock.xml", "com.avodroid.feature.mac.xml"])
        #expect(!IdentityFeature.needsWrite(checkOutput: try android.run(IdentityFeature.checkCommand(root: android.root.path))))
    }

    @Test func aFailedWriteLeavesNoHalfFile() throws {
        let android = try Scratch()
        defer { android.cleanUp() }
        // /product stayed read-only: the copy fails and nothing is left.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: android.file("product/etc/permissions").path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: android.file("product/etc/permissions").path) }
        #expect(throws: (any Error).self) { try android.run(IdentityFeature.writeScript(root: android.root.path)) }
        let names = try FileManager.default.contentsOfDirectory(atPath: android.file("product/etc/permissions").path)
        #expect(names == ["com.android.stock.xml"])
    }

    @Test func writeScriptLeavesProductWritable() {
        // A read-only remount here could cut short an undo of Google apps.
        let script = IdentityFeature.writeScript()
        #expect(script.hasPrefix("remount /product "))
        #expect(!script.contains("remount,ro"))
        #expect(script.contains("'/product/etc/permissions/com.avodroid.feature.mac.xml'"))
    }

    /// /product/etc/permissions with one stock file, and stubs on PATH that log their calls.
    struct Scratch {
        let root: URL
        let stubs: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "avo-identity-\(UUID().uuidString)")
            stubs = root.appending(path: "bin")
            let permissions = root.appending(path: "product/etc/permissions")
            try FileManager.default.createDirectory(at: permissions, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: stubs, withIntermediateDirectories: true)
            try "<permissions />\n".write(to: permissions.appending(path: "com.android.stock.xml"), atomically: true, encoding: .utf8)
            for name in ["remount", "chown", "restorecon"] {
                let stub = stubs.appending(path: name)
                try "#!/bin/sh\necho \"\(name) $*\" >> \"$AVO_CALLS\"\nexit 0\n".write(to: stub, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
            }
        }

        func file(_ path: String) -> URL { root.appending(path: path) }

        func calls() throws -> [String] {
            try String(contentsOf: root.appending(path: "calls"), encoding: .utf8).split(separator: "\n").map(String.init)
        }

        /// Runs `script` with sh; throws when it exits non-zero.
        func run(_ script: String) throws -> String {
            let process = Process()
            process.executableURL = URL(filePath: "/bin/sh")
            process.arguments = ["-c", script]
            process.environment = ["PATH": stubs.path + ":/usr/bin:/bin", "AVO_CALLS": root.appending(path: "calls").path]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
            return String(decoding: data, as: UTF8.self)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }
}
