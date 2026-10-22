import AvoKit
import AvoTestSupport
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AvoShimKit

private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
    let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = context.data!.assumingMemoryBound(to: UInt8.self)
    // CGContext rows start at the bottom; flip so (0, 0) is the top-left pixel.
    let offset = ((image.height - 1 - y) * image.width + x) * 4
    return (data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
}

private func outlineImage(size: Int, argb: UInt32, lineWidth: CGFloat) -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setStrokeColor(MacIconRenderer.color(argb: argb))
    context.setLineWidth(lineWidth)
    context.stroke(CGRect(x: 20, y: 20, width: size - 40, height: size - 40))
    return context.makeImage()!
}

private func solidImage(size: Int, argb: UInt32, insetTransparent: Int = 0) -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(MacIconRenderer.color(argb: argb))
    context.fill(CGRect(x: insetTransparent, y: insetTransparent, width: size - 2 * insetTransparent, height: size - 2 * insetTransparent))
    return context.makeImage()!
}

@Suite struct MacIconRendererTests {
    @Test func adaptiveIconFillsTheSquircle() throws {
        let foreground = solidImage(size: 432, argb: 0xFF2F_4A1F, insetTransparent: 144) // centred dark square
        let image = try #require(MacIconRenderer.render(.adaptive(background: .color(MacIconRenderer.color(argb: 0xFFD8_E8A7)),
                                                                  foreground: .image(foreground)), pixels: 1024))
        #expect(image.width == 1024)
        #expect(pixel(image, 2, 2).a == 0)                       // outside the body
        #expect(pixel(image, 120, 512) == (0xD8, 0xE8, 0xA7, 255)) // background inside the body edge
        #expect(pixel(image, 512, 512) == (0x2F, 0x4A, 0x1F, 255)) // foreground centre
        #expect(pixel(image, 104, 104).a < 50)                    // rounded corner is clipped
        #expect(pixel(image, 512, 930).a > 0)                     // drop shadow below the body
        #expect(pixel(image, 512, 960).a == 0)
    }

    @Test func shapedLegacyIconsBecomeTheSquircle() throws {
        // An opaque shape with transparent margins (a rounded-square launcher
        // icon): no white plate, it fills the squircle.
        let shape = solidImage(size: 192, argb: 0xFF00_00FF, insetTransparent: 40)
        #expect(!MacIconRenderer.isFullBleed(shape))
        #expect(MacIconRenderer.footprint(shape)?.isShape == true)
        let image = try #require(MacIconRenderer.render(.legacy(shape), pixels: 512))
        #expect(pixel(image, 70, 256) == (0, 0, 255, 255))
        #expect(pixel(image, 256, 256) == (0, 0, 255, 255))
    }

    @Test func glyphLegacyIconsSitOnAWhitePlate() throws {
        // A thin outline on transparency is a glyph: it needs a plate.
        let glyph = outlineImage(size: 192, argb: 0xFF00_00FF, lineWidth: 8)
        #expect(MacIconRenderer.footprint(glyph)?.isShape == false)
        let image = try #require(MacIconRenderer.render(.legacy(glyph), pixels: 512))
        #expect(pixel(image, 256, 256) == (255, 255, 255, 255))
    }

    @Test func opaqueSquareLegacyIconsAreMasked() throws {
        let square = solidImage(size: 192, argb: 0xFFFF_0000)
        #expect(MacIconRenderer.isFullBleed(square))
        let image = try #require(MacIconRenderer.render(.legacy(square), pixels: 512))
        #expect(pixel(image, 60, 256) == (255, 0, 0, 255))
        #expect(pixel(image, 52, 52).a < 50)
    }

    @Test func icnsContainsEveryRepresentation() throws {
        let data = try #require(MacIconRenderer.icns(.legacy(solidImage(size: 192, argb: 0xFFFF_0000))))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let sizes = Set((0..<CGImageSourceGetCount(source)).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil)?.width })
        #expect(sizes.isSuperset(of: [16, 32, 64, 128, 256, 512, 1024]))
    }
}

@Suite(.serialized) struct ShimBuilderTests {
    let root: URL
    let template: URL
    let builder: ShimBuilder

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "avo-shims-\(UUID().uuidString)")
        template = root.appending(path: "Template/AvoShim.app")
        let macOS = template.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: macOS.appending(path: "AvoShim"))
        let info: [String: Any] = ["CFBundleExecutable": "AvoShim", "CFBundlePackageType": "APPL",
                                   "CFBundleIdentifier": "com.avodroid.shim.template", "LSMinimumSystemVersion": "15.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: template.appending(path: "Contents/Info.plist"))
        var builder = ShimBuilder(template: template, hostApplication: URL(filePath: "/Applications/Avo.app"),
                                  directory: root.appending(path: "Android Apps"))
        builder.registersWithLaunchServices = false
        self.builder = builder
    }

    private var icns: Data { MacIconRenderer.icns(.legacy(solidImage(size: 64, argb: 0xFF00_FF00)))! }

    private func cleanUp(aliases: Bool = false) {
        if aliases { LaunchServicesCleanup.unregisterApps(under: root) }
        try? FileManager.default.removeItem(at: root)
    }

    @Test func createsSignedShim() throws {
        defer { cleanUp() }
        let app = AppRecord(package: "org.fdroid.fdroid", label: "F-Droid", versionName: "1.20.1", versionCode: 1_020_001)
        let result = try builder.install(app, icns: icns)
        #expect(result.bundleURL.lastPathComponent == "F-Droid.app")
        #expect(result.cdhash.count == 40)
        #expect(ShimBuilder.cdhash(of: result.bundleURL) == result.cdhash)

        let info = try #require(NSDictionary(contentsOf: result.bundleURL.appending(path: "Contents/Info.plist")) as? [String: Any])
        #expect(info["CFBundleIdentifier"] as? String == "com.avodroid.shim.org.fdroid.fdroid")
        #expect(info["CFBundleName"] as? String == "F-Droid")
        #expect(info[AvoIdentifiers.shimPackageInfoKey] as? String == "org.fdroid.fdroid")
        #expect(info[AvoIdentifiers.shimHostAppInfoKey] as? String == "/Applications/Avo.app")
        #expect(FileManager.default.fileExists(atPath: result.bundleURL.appending(path: "Contents/Resources/AppIcon.icns").path))

        let verify = Process()
        verify.executableURL = URL(filePath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--strict", result.bundleURL.path]
        try verify.run()
        verify.waitUntilExit()
        #expect(verify.terminationStatus == 0)
        #expect(builder.existingShims() == ["org.fdroid.fdroid": result.bundleURL])
    }

    @Test func distinctLabelsCollideSafelyAndRenamesFollowUpdates() throws {
        defer { cleanUp() }
        let first = try builder.install(AppRecord(package: "com.a.notes", label: "Notes"), icns: icns)
        let second = try builder.install(AppRecord(package: "com.b.notes", label: "Notes"), icns: icns)
        #expect(first.bundleURL.lastPathComponent == "Notes.app")
        #expect(second.bundleURL.lastPathComponent == "Notes (com.b.notes).app")
        #expect(first.cdhash != second.cdhash)

        // Reinstalling keeps the name; a new label renames the bundle.
        let same = try builder.install(AppRecord(package: "com.a.notes", label: "Notes"), icns: icns, existing: first.bundleURL)
        #expect(same.bundleURL == first.bundleURL)
        let renamed = try builder.install(AppRecord(package: "com.a.notes", label: "Notes Pro"), icns: icns, existing: first.bundleURL)
        #expect(renamed.bundleURL.lastPathComponent == "Notes Pro.app")
        #expect(!FileManager.default.fileExists(atPath: first.bundleURL.path))

        try builder.remove(renamed.bundleURL)
        #expect(builder.existingShims() == ["com.b.notes": second.bundleURL])
    }

    @Test func sanitizesFileNames() {
        #expect(ShimBuilder.fileName(for: "AC/DC: Live") == "AC-DC- Live")
        #expect(ShimBuilder.fileName(for: "  ..  ") == "Android App")
    }

    @Test func refusesToRemoveOutsideItsDirectory() throws {
        defer { cleanUp() }
        try builder.remove(template)
        #expect(FileManager.default.fileExists(atPath: template.path))
    }

    @Test func desktopAliasPointsToShim() throws {
        defer { cleanUp(aliases: true) }
        let shim = try builder.install(AppRecord(package: "org.fdroid.fdroid", label: "F-Droid"), icns: icns)
        let desktop = root.appending(path: "Desktop")
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let alias = try Shortcuts.createAlias(to: shim.bundleURL, in: desktop)
        #expect(alias.lastPathComponent == "F-Droid")
        #expect(Shortcuts.isAlias(alias))
        #expect(try URL(resolvingAliasFileAt: alias).standardizedFileURL.path == shim.bundleURL.standardizedFileURL.path)
        // A real file with the same name is never overwritten.
        let file = desktop.appending(path: "Notes")
        try Data("mine".utf8).write(to: file)
        let notes = try builder.install(AppRecord(package: "com.a.notes", label: "Notes"), icns: icns)
        #expect(throws: (any Error).self) { try Shortcuts.createAlias(to: notes.bundleURL, in: desktop) }
        Shortcuts.removeAlias(file)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
