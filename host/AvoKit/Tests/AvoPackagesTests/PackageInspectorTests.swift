import Foundation
import Testing
@testable import AvoPackages

private func fixture(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
}

private let pngSignature = Data([0x89, 0x50, 0x4E, 0x47])

@Suite struct PackageInspectorTests {
    @Test(arguments: ["plain.apk", "compact.apk"])
    func readsManifestAndResources(file: String) throws {
        let summary = try PackageArchive(url: fixture(file), languages: ["en-US"]).summary
        #expect(summary.format == .apk)
        #expect(summary.packageName == "com.avodroid.fixture")
        #expect(summary.label == "Avo Fixture")
        #expect(summary.versionName == "1.4.2")
        #expect(summary.versionCode == 42)
        #expect(summary.targetSdk == 36)
        // Duplicate <uses-permission> entries collapse.
        #expect(summary.permissions == ["android.permission.INTERNET", "android.permission.CAMERA"])
        #expect(summary.nativeABIs.isEmpty)
        #expect(summary.isInstallable)
        #expect(summary.parts.count == 1 && summary.parts[0].entryPath == nil)
    }

    @Test(arguments: ["plain.apk", "compact.apk"])
    func picksLabelForPreferredLanguage(file: String) throws {
        // compact.apk stores the Indonesian strings in a sparse table.
        let summary = try PackageArchive(url: fixture(file), languages: ["id-ID", "en"]).summary
        #expect(summary.label == "Contoh Avo")
        let fallback = try PackageArchive(url: fixture(file), languages: ["ja-JP"]).summary
        #expect(fallback.label == "Avo Fixture")
    }

    @Test func readsAdaptiveIconLayers() throws {
        let summary = try PackageArchive(url: fixture("plain.apk")).summary
        guard case .adaptive(let background, let foreground, let monochrome)? = summary.icon else {
            Issue.record("expected an adaptive icon, got \(String(describing: summary.icon))")
            return
        }
        #expect(background == .color(0xFFD8_E8A7))
        guard case .bitmap(let png)? = foreground else {
            Issue.record("expected a bitmap foreground")
            return
        }
        #expect(png.prefix(4) == pngSignature)
        guard case .vector(let xml)? = monochrome else {
            Issue.record("expected a vector monochrome layer")
            return
        }
        #expect(try BinaryXML.parse(xml).name == "vector")
    }

    @Test func compactEncodingYieldsSameIcon() throws {
        let plain = try PackageArchive(url: fixture("plain.apk")).summary.icon
        let compact = try PackageArchive(url: fixture("compact.apk")).summary.icon
        #expect(plain == compact)
    }

    @Test func inflatesLargeEntriesExactly() throws {
        // Deflated output arrives in several chunks per write, sharing one
        // buffer: each must be copied before the next (a 600 KB manifest broke).
        let directory = FileManager.default.temporaryDirectory.appending(path: "avo-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var state: UInt32 = 1
        let original = Data((0..<700_000).map { _ in
            state = state &* 1_103_515_245 &+ 12_345
            return UInt8(truncatingIfNeeded: state >> 16) & 0x3F
        })
        try original.write(to: directory.appending(path: "big.bin"))
        let zip = Process()
        zip.executableURL = URL(filePath: "/usr/bin/zip")
        zip.currentDirectoryURL = directory
        zip.arguments = ["-q", "-9", "big.zip", "big.bin"]
        try zip.run()
        zip.waitUntilExit()
        let archive = try ZipArchive(url: directory.appending(path: "big.zip"))
        let entry = try #require(archive.entry("big.bin"))
        #expect(entry.method == 8)
        #expect(try archive.data(of: entry) == original)
    }

    @Test func rejectsArm32OnlyApps() throws {
        let summary = try PackageArchive(url: fixture("arm32-only.apk")).summary
        #expect(summary.nativeABIs == ["armeabi-v7a"])
        #expect(summary.compatibility == [.noArm64Code(abis: ["armeabi-v7a"])])
        #expect(!summary.isInstallable)
    }

    @Test func flagsAppsNeedingNewerAndroid() throws {
        let summary = try PackageArchive(url: fixture("compact.apk"), guestSDK: 34).summary
        #expect(summary.compatibility == [.requiresNewerAndroid(minSdk: 35, available: 34)])
    }

    @Test func xapkSelectsSplitsAndOBB() throws {
        let archive = try PackageArchive(url: fixture("fixture.xapk"))
        let summary = archive.summary
        #expect(summary.format == .xapk)
        #expect(summary.packageName == "com.avodroid.fixture")
        #expect(summary.parts.map(\.splitName) == [nil, "config.arm64_v8a", "config.xxxhdpi"])
        #expect(summary.parts.map(\.installName) == ["base.apk", "split_config.arm64_v8a.apk", "split_config.xxxhdpi.apk"])
        #expect(summary.skippedSplits == ["config.x86_64"])
        #expect(summary.nativeABIs == ["arm64-v8a", "x86_64"])
        #expect(summary.isInstallable)
        #expect(summary.obbFiles.count == 1)
        #expect(summary.obbFiles[0].destination == "Android/obb/com.avodroid.fixture/main.42.com.avodroid.fixture.obb")
        #expect(summary.obbFiles[0].size == 70_000)

        // Streams reproduce the original bytes.
        var obbBytes = 0
        try archive.stream(summary.obbFiles[0]) { obbBytes += $0.count }
        #expect(obbBytes == 70_000)
        for part in summary.parts {
            var data = Data()
            try archive.stream(part) { data.append($0) }
            #expect(UInt64(data.count) == part.size)
            #expect(try ZipArchive(data: data).entry("AndroidManifest.xml") != nil)
        }
    }

    @Test func apkmWithOnlyArm32SplitIsRejected() throws {
        // The APKM fixture ships an armeabi-v7a split and no arm64 code.
        let summary = try PackageArchive(url: fixture("fixture.apkm")).summary
        #expect(summary.format == .apkm)
        #expect(summary.skippedSplits == ["config.armeabi_v7a"])
        #expect(summary.compatibility == [.noArm64Code(abis: ["armeabi-v7a"])])
    }

    @Test func iconFromDensitySplit() throws {
        // In split bundles the launcher bitmap lives in split_config.xxxhdpi.apk.
        let summary = try PackageArchive(url: fixture("fixture.apkm")).summary
        guard case .adaptive(_, .bitmap(let png)?, _)? = summary.icon else {
            Issue.record("expected the foreground bitmap from the density split")
            return
        }
        #expect(png.prefix(4) == pngSignature)
    }

    @Test func apksUsesSplitsDirectoryOnly() throws {
        let summary = try PackageArchive(url: fixture("fixture.apks")).summary
        #expect(summary.format == .apks)
        #expect(summary.parts.map(\.entryPath) == ["splits/base-master.apk", "splits/base-arm64_v8a.apk", "splits/base-xxxhdpi.apk"])
        #expect(summary.isInstallable)
    }

    @Test func rejectsNonPackages() throws {
        #expect(throws: PackageError.unknownFormat) { try PackageArchive(url: fixture("not-a-package.apk")) }
    }
}

@Suite struct ZipArchiveTests {
    @Test func readsStoredAndDeflatedEntries() throws {
        let zip = try ZipArchive(url: fixture("fixture.apkm"))
        let info = try zip.data(at: "info.json")
        #expect(String(decoding: info, as: UTF8.self).contains("\"pname\": \"com.avodroid.fixture\""))
        let base = try #require(zip.entry("base.apk"))
        #expect(base.method == 8)
        #expect(base.uncompressedSize > base.compressedSize)
    }

    @Test func detectsCorruption() throws {
        var bytes = try Data(contentsOf: fixture("fixture.apkm"))
        let zip = try ZipArchive(data: bytes)
        let entry = try #require(zip.entry("info.json"))
        // Flip a byte inside the deflated data of info.json.
        let localHeader = Int(entry.localHeaderOffset)
        let nameLength = Int(bytes[localHeader + 26]) | Int(bytes[localHeader + 27]) << 8
        let extraLength = Int(bytes[localHeader + 28]) | Int(bytes[localHeader + 29]) << 8
        bytes[localHeader + 30 + nameLength + extraLength + 3] ^= 0xFF
        let corrupted = try ZipArchive(data: bytes)
        #expect(throws: (any Error).self) { try corrupted.data(at: "info.json") }
    }

    @Test func crc32MatchesReference() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func refusesHugeEntriesInMemory() throws {
        let zip = try ZipArchive(url: fixture("fixture.xapk"))
        let obb = try #require(zip.entries.first { $0.path.hasSuffix(".obb") })
        #expect(throws: PackageError.entryTooLarge(obb.path, 70_000)) { try zip.data(of: obb, limit: 1000) }
    }
}
