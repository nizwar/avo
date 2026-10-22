import AvoProtocol
import AvoShimKit
import CoreGraphics
import Foundation
import Testing
@testable import AvoDaemonCore

/// The helper's `appinfo` output (guest/clipboard AppInfo.java) and what
/// HostAgent makes of it.
@Suite struct HostAgentAppInfoTests {
    /// A `size`-square PNG of one colour.
    static func png(size: Int, argb: UInt32) throws -> Data {
        let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(MacIconRenderer.color(argb: argb))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = try #require(context.makeImage())
        return try #require(MacIconRenderer.png(image))
    }

    /// Base64 the way org.json writes it into a string (`/` escaped).
    static func json(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "/", with: "\\/")
    }

    static func installed(_ package: String, system: Bool = false) -> HostAgent.InstalledPackage {
        HostAgent.InstalledPackage(package: package, path: "/data/app/~~x==/\(package)-y==/base.apk", versionCode: 7, system: system)
    }

    /// The colour of one pixel (premultiplied RGBA, origin top left).
    static func pixel(_ png: Data, x: Int, y: Int) throws -> [UInt8] {
        let image = try #require(MacIconRenderer.image(from: png))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let index = (y * image.width + x) * 4
        return Array(pixels[index..<index + 4])
    }

    static func near(_ pixel: [UInt8], _ wanted: [UInt8]) -> Bool {
        zip(pixel, wanted).allSatisfy { abs(Int($0) - Int($1)) <= 3 }
    }

    @Test func readsOneReportPerLineAndSkipsTheRest() throws {
        let layer = try Self.png(size: 432, argb: 0xFF00_00FF)
        let output = """
            WARNING: linker: app_process has text relocations
            {"package":"com.google.android.googlequicksearchbox","label":"Google","versionName":"17.66.12.ve.arm64",\
            "versionCode":301820578,"sizeBytes":329463546,"firstInstallTime":1792214041101,"lastUpdateTime":1792215883814,\
            "system":true,"backgroundColor":4294967295,"foregroundPng":"\(Self.json(layer))"}
            {"package":"com.garena.game.df","label":"Garena Delta Force","sizeBytes":751877049,\
            "backgroundPng":"\(Self.json(layer))","foregroundPng":"\(Self.json(layer))"}
            {"package":"no.such.app","error":"android.content.pm.PackageManager$NameNotFoundException: no.such.app"}
            {"package":"cut.off","label":"Cut
            not json at all

            """
        let reports = HostAgent.parseAppInfo(output)
        #expect(Set(reports.keys) == ["com.google.android.googlequicksearchbox", "com.garena.game.df", "no.such.app"])
        let google = try #require(reports["com.google.android.googlequicksearchbox"])
        #expect(google.label == "Google")
        #expect(google.versionName == "17.66.12.ve.arm64")
        #expect(google.sizeBytes == 329_463_546)
        #expect(google.backgroundColor == 0xFFFF_FFFF)
        #expect(google.foregroundPng == layer)
        #expect(google.backgroundPng == nil && google.iconPng == nil && google.error == nil)
        #expect(reports["com.garena.game.df"]?.backgroundPng == layer)
        #expect(reports["no.such.app"]?.error?.contains("NameNotFoundException") == true)
    }

    @Test func anAdaptiveIconIsDrawnFromItsLayers() throws {
        // A blue square in the middle of a transparent foreground, on a red background.
        let context = try #require(CGContext(data: nil, width: 432, height: 432, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(MacIconRenderer.color(argb: 0xFF00_00FF))
        context.fill(CGRect(x: 176, y: 176, width: 80, height: 80))
        let image = try #require(context.makeImage())
        let foreground = try #require(MacIconRenderer.png(image))
        let reports = HostAgent.parseAppInfo("""
            {"package":"com.example.game","label":"  Example Game ","versionName":"2.1","sizeBytes":751877049,\
            "firstInstallTime":1792214161792,"lastUpdateTime":1792214161793,\
            "backgroundColor":\(UInt32(0xFFFF_0000)),"foregroundPng":"\(Self.json(foreground))"}
            """)
        let report = try #require(reports["com.example.game"])
        var info = HostAgent.packageOnlyInfo(Self.installed("com.example.game"), launchable: true)
        #expect(!HostAgent.isComplete(info))
        HostAgent.fill(&info, from: report)
        #expect(info.label == "Example Game")
        #expect(info.versionName == "2.1")
        #expect(info.versionCode == 7)
        #expect(info.sizeBytes == 751_877_049)
        #expect(info.firstInstallTimeMs == 1_792_214_161_792)
        #expect(info.lastUpdateTimeMs == 1_792_214_161_793)
        #expect(info.launchable)
        #expect(HostAgent.isComplete(info))
        let icon = try #require(MacIconRenderer.image(from: info.iconPng))
        #expect(icon.width == 256 && icon.height == 256)
        // The middle is the foreground, the body's edge the background, the corner the Mac's margin.
        #expect(Self.near(try Self.pixel(info.iconPng, x: 128, y: 128), [0, 0, 255, 255]))
        #expect(Self.near(try Self.pixel(info.iconPng, x: 128, y: 40), [255, 0, 0, 255]))
        #expect(try Self.pixel(info.iconPng, x: 2, y: 2)[3] < 40)
    }

    @Test func aBitmapBackgroundLayerIsUsedToo() throws {
        let background = try Self.png(size: 432, argb: 0xFF00_FF00)
        let reports = HostAgent.parseAppInfo("""
            {"package":"com.android.vending","label":"Play Store","backgroundPng":"\(Self.json(background))"}
            """)
        var info = HostAgent.packageOnlyInfo(Self.installed("com.android.vending", system: true), launchable: true)
        HostAgent.fill(&info, from: try #require(reports["com.android.vending"]))
        #expect(info.systemApp)
        #expect(Self.near(try Self.pixel(info.iconPng, x: 128, y: 128), [0, 255, 0, 255]))
    }

    @Test func aLegacyIconIsKeptAsAndroidDrewIt() throws {
        let bitmap = try Self.png(size: 256, argb: 0xFFD8_E8A7)
        let reports = HostAgent.parseAppInfo("""
            {"package":"com.avodroid.hello","label":"Avo Hello","versionName":"1.5","sizeBytes":33272,"iconPng":"\(Self.json(bitmap))"}
            """)
        var info = HostAgent.packageOnlyInfo(Self.installed("com.avodroid.hello"), launchable: true)
        HostAgent.fill(&info, from: try #require(reports["com.avodroid.hello"]))
        #expect(info.iconPng == bitmap)
        #expect(info.sizeBytes == 33272)
        #expect(HostAgent.isComplete(info))
    }

    @Test func aReportWithoutLabelOrIconLeavesThePackageName() throws {
        let reports = HostAgent.parseAppInfo(#"{"package":"com.example.bare","label":" ","iconPng":"bm90IGEgcG5n"}"#)
        var info = HostAgent.packageOnlyInfo(Self.installed("com.example.bare"), launchable: true)
        HostAgent.fill(&info, from: try #require(reports["com.example.bare"]))
        #expect(info.label == "com.example.bare")
        #expect(info.iconPng.isEmpty) // "not a png"
        #expect(!HostAgent.isComplete(info))
    }

    @Test func androidsAnswerComesFirstThenOnlySmallAPKsAreRead() {
        let answer = HostAgent.HelperAppInfo(package: "com.google.android.googlequicksearchbox", label: "Google")
        var failed = answer
        failed.error = "NameNotFoundException"
        let limit = HostAgent.largestAPKReadOnHost
        #expect(HostAgent.appInfoSource(answer, baseAPKBytes: 243_683_703) == .android)
        #expect(HostAgent.appInfoSource(answer, baseAPKBytes: nil) == .android)
        // No helper (not pushed yet, Android not answering): small base APKs are read on the Mac.
        #expect(HostAgent.appInfoSource(nil, baseAPKBytes: 33272) == .apk)
        #expect(HostAgent.appInfoSource(nil, baseAPKBytes: limit) == .apk)
        #expect(HostAgent.appInfoSource(failed, baseAPKBytes: 33272) == .apk)
        // The Google app's 243 MB APK, an unreadable one.
        #expect(HostAgent.appInfoSource(nil, baseAPKBytes: 243_683_703) == .packageOnly)
        #expect(HostAgent.appInfoSource(nil, baseAPKBytes: limit + 1) == .packageOnly)
        #expect(HostAgent.appInfoSource(nil, baseAPKBytes: nil) == .packageOnly)
        #expect(HostAgent.appInfoSource(nil, baseAPKBytes: 0) == .packageOnly)
    }

    @Test func theCommandRunsTheHelperForEveryPackageQuoted() {
        let command = HostAgent.appInfoCommand(["com.garena.game.df", "com.avodroid.hello"])
        #expect(command == "CLASSPATH=/data/local/tmp/avo-clipboard.jar timeout 20 app_process / com.avodroid.clipboard.Main appinfo "
            + "'com.garena.game.df' 'com.avodroid.hello'")
        #expect(HostAgent.appInfoCommand(["it's"], seconds: 7).hasSuffix("timeout 7 app_process / com.avodroid.clipboard.Main appinfo 'it'\\''s'"))
        // A hung run and the rest of ListApps fit in the Mac's 60 seconds.
        #expect(HostAgent.appInfoRunSeconds <= HostAgent.appInfoSeconds && HostAgent.appInfoSeconds <= 30)
    }

    @Test func aLabelWithUnicodeLineBreaksStaysOneReport() throws {
        // Android's org.json leaves U+0085 and U+2028 as they are; Swift counts both as newlines.
        let output = "{\"package\":\"com.example.nel\",\"label\":\"One\u{85}Two\u{2028}Three\",\"versionName\":\"1\u{2029}0\"}\n"
            + "{\"package\":\"com.avodroid.hello\",\"label\":\"Avo Hello\"}\r\n"
        let reports = HostAgent.parseAppInfo(output)
        #expect(reports["com.example.nel"]?.label == "One\u{85}Two\u{2028}Three")
        #expect(reports["com.example.nel"]?.versionName == "1\u{2029}0")
        #expect(reports["com.avodroid.hello"]?.label == "Avo Hello")
    }

    @Test func adaptiveLayersAreKeptForTheAppShim() throws {
        let foreground = try Self.png(size: 432, argb: 0x8000_00FF)
        let background = try Self.png(size: 432, argb: 0xFF00_FF00)
        let reports = HostAgent.parseAppInfo("""
            {"package":"com.google.android.googlequicksearchbox","label":"Google","backgroundColor":\(UInt32(0xFFFF_0000)),\
            "foregroundPng":"\(Self.json(foreground))"}
            {"package":"com.garena.game.df","label":"Garena Delta Force","backgroundPng":"\(Self.json(background))",\
            "foregroundPng":"bm90IGEgcG5n"}
            {"package":"com.avodroid.hello","label":"Avo Hello","iconPng":"\(Self.json(background))"}
            """)
        var google = HostAgent.packageOnlyInfo(Self.installed("com.google.android.googlequicksearchbox", system: true), launchable: true)
        HostAgent.fill(&google, from: try #require(reports["com.google.android.googlequicksearchbox"]))
        #expect(google.hasAdaptiveIcon)
        #expect(google.adaptiveIcon.foregroundPng == foreground)
        // The colour comes as a full 432 px layer, the same bytes every time (the icon digest).
        let layer = try #require(MacIconRenderer.image(from: google.adaptiveIcon.backgroundPng))
        #expect(layer.width == 432 && layer.height == 432)
        #expect(Self.near(try Self.pixel(google.adaptiveIcon.backgroundPng, x: 10, y: 400), [255, 0, 0, 255]))
        #expect(HostAgent.layerPNG(argb: 0xFFFF_0000) == google.adaptiveIcon.backgroundPng)
        #expect(!google.iconPng.isEmpty)
        if case .adaptive(let back?, let front?) = ShortcutManager.iconSource(google), case .image = back, case .image = front {
        } else {
            Issue.record("the App Shim's icon is not drawn from the layers")
        }

        var game = HostAgent.packageOnlyInfo(Self.installed("com.garena.game.df"), launchable: true)
        HostAgent.fill(&game, from: try #require(reports["com.garena.game.df"]))
        #expect(game.adaptiveIcon.backgroundPng == background)
        #expect(game.adaptiveIcon.foregroundPng.isEmpty) // "not a png"

        var hello = HostAgent.packageOnlyInfo(Self.installed("com.avodroid.hello"), launchable: true)
        HostAgent.fill(&hello, from: try #require(reports["com.avodroid.hello"]))
        #expect(!hello.hasAdaptiveIcon)
    }

    @Test func aRunThatStopsGoesOnAfterThePackageItStoppedAt() {
        let batch = ["a", "b", "c", "d"]
        let answered = { (packages: [String]) in
            Dictionary(uniqueKeysWithValues: packages.map { ($0, HostAgent.HelperAppInfo(package: $0, label: $0)) })
        }
        #expect(HostAgent.appInfoRun(batch, reports: answered(batch), exitCode: 0) == .done)
        #expect(HostAgent.appInfoRun(batch, reports: answered(["a"]), exitCode: 0) == .done)
        #expect(HostAgent.appInfoRun(batch, reports: answered(batch), exitCode: 1) == .done)
        // Hung on c (`timeout`), crashed on b (a signal).
        #expect(HostAgent.appInfoRun(batch, reports: answered(["a", "b"]), exitCode: 124) == .stopped(at: "c", rest: ["d"]))
        #expect(HostAgent.appInfoRun(batch, reports: answered(["a"]), exitCode: 139) == .stopped(at: "b", rest: ["c", "d"]))
        #expect(HostAgent.appInfoRun(batch, reports: answered(["a", "b", "c"]), exitCode: 124) == .stopped(at: "d", rest: []))
        #expect(HostAgent.appInfoRun(batch, reports: [:], exitCode: 124) == .stopped(at: "a", rest: ["b", "c", "d"]))
        // The previous helper (usage, 2) and none pushed (app_process aborts, 134).
        #expect(HostAgent.appInfoRun(batch, reports: [:], exitCode: 2) == .notStarted)
        #expect(HostAgent.appInfoRun(batch, reports: [:], exitCode: 134) == .notStarted)
    }

    @Test func packagesLeftWhenTimeRanOutAreNotReadFromTheirAPKs() {
        let left = HostAgent.HelperAppInfo(package: "com.avodroid.hello", error: HostAgent.appInfoOutOfTime)
        #expect(HostAgent.appInfoSource(left, baseAPKBytes: 33272) == .packageOnly)
    }

    @Test func anAppListIsKeptToOneFrame() {
        func app(_ package: String, icon: Int, layers: Int) -> Avo_V1_AppInfo {
            var info = HostAgent.packageOnlyInfo(Self.installed(package), launchable: true)
            info.label = package
            info.iconPng = Data(count: icon)
            if layers > 0 {
                info.adaptiveIcon.backgroundPng = Data(count: layers)
                info.adaptiveIcon.foregroundPng = Data(count: layers)
            }
            return info
        }
        let apps = [app("small", icon: 1000, layers: 1000), app("game", icon: 50000, layers: 200_000), app("plain", icon: 20000, layers: 0)]
        let total = apps.reduce(0) { $0 + (try! $1.serializedData()).count }

        var fits = apps
        #expect(HostAgent.fitAppList(&fits, bytes: total + 100).isEmpty)
        #expect(fits == apps)

        // The game's layers alone are enough.
        var layersOut = apps
        #expect(HostAgent.fitAppList(&layersOut, bytes: total - 300_000) == ["game"])
        #expect(!layersOut[1].hasAdaptiveIcon && layersOut[1].iconPng.count == 50000)
        #expect(layersOut[0] == apps[0] && layersOut[2] == apps[2])

        // Then every layer, then the largest flattened icons.
        var iconsOut = apps
        #expect(HostAgent.fitAppList(&iconsOut, bytes: total - 420_000) == ["game", "small"])
        #expect(iconsOut.allSatisfy { !$0.hasAdaptiveIcon })
        #expect(iconsOut[1].iconPng.isEmpty && iconsOut[2].iconPng.count == 20000 && iconsOut[0].iconPng.count == 1000)
        #expect(iconsOut.allSatisfy { $0.label == $0.package })
    }

    @Test func infoIsCompleteWithANameAndAnIcon() {
        var info = HostAgent.packageOnlyInfo(Self.installed("com.garena.game.df"), launchable: true)
        #expect(HostAgent.completeness(info) == 0)
        info.label = "Garena Delta Force"
        #expect(!HostAgent.isComplete(info)) // the placeholder icon in the screenshot
        #expect(HostAgent.completeness(info) == 1)
        info.iconPng = Data([1])
        #expect(HostAgent.isComplete(info))
        #expect(HostAgent.completeness(info) == 2)
        info.label = "com.garena.game.df"
        #expect(!HostAgent.isComplete(info)) // the package name as its name
        #expect(HostAgent.completeness(info) == 1)
    }
}
