import Foundation
import Testing
@testable import AvoKit

/// `AvoIdentity`: what docs/for-game-developers.md promises publishers.
@Suite struct AvoIdentityTests {
    static let markers = AvoIdentity.Markers(version: "0.1.0", hostOS: "macOS 27.0.1", hostChip: "Apple M4 Pro",
                                             renderer: .gpu)

    @Test func markersAreTheDocumentedProperties() {
        #expect(Self.markers.properties == [
            "ro.boot.avo.schema": "1",
            "ro.boot.avo.version": "0.1.0",
            "ro.boot.avo.host.os": "macOS 27.0.1",
            "ro.boot.avo.host.chip": "Apple M4 Pro",
            "ro.boot.avo.renderer": "gpu",
            "ro.boot.avo.input": "keyboard,mouse,touch,gamepad",
        ])
        var software = Self.markers
        software.renderer = .software
        #expect(software.properties["ro.boot.avo.renderer"] == "software")
        #expect(AvoIdentity.schema == 1)
        #expect(AvoIdentity.feature == "com.avodroid.feature.MAC")
        // Every name is in the one namespace.
        #expect(Self.markers.properties.keys.allSatisfy { $0.hasPrefix(AvoIdentity.propertyPrefix) })
    }

    @Test func propertyFileHasTheProfileThenTheMarkers() {
        let file = AvoIdentity.propertyFile(profile: .avo, markers: Self.markers)
        #expect(file == """
            ro.boot.avo.host.chip=Apple M4 Pro
            ro.boot.avo.host.os=macOS 27.0.1
            ro.boot.avo.input=keyboard,mouse,touch,gamepad
            ro.boot.avo.renderer=gpu
            ro.boot.avo.schema=1
            ro.boot.avo.version=0.1.0
            ro.product.brand=Avo
            ro.product.device=avo_droid
            ro.product.manufacturer=Avo
            ro.product.model=AVO-Droid
            ro.product.name=avo_droid

            """)
        // A phone profile changes Build.*, never the markers.
        let phone = DeviceProfile(id: "phone", name: "Phone", properties: ["ro.product.model": "SM-S928B"])
        let impersonating = AvoIdentity.propertyFile(profile: phone, markers: Self.markers)
        #expect(impersonating.contains("ro.product.model=SM-S928B\n"))
        #expect(impersonating.contains("ro.boot.avo.version=0.1.0\n"))
        // No profile at all (the catalog failed): the markers alone.
        #expect(AvoIdentity.propertyFile(profile: nil, markers: Self.markers).split(separator: "\n").count == 6)
    }

    @Test(arguments: [
        ("Apple M4 Pro", "Apple M4 Pro"),
        ("  Apple   M4\tMax \n", "Apple M4 Max"),
        ("Apple M5™", "Apple M5?"),
        ("line\nbreak", "line break"),
        ("", "unknown"),
        (" \n ", "unknown"),
    ])
    func valuesAreOneLineOfASCII(raw: String, value: String) {
        #expect(AvoIdentity.value(raw) == value)
    }

    @Test func longValuesFitSystemPropertyGet() {
        let value = AvoIdentity.value(String(repeating: "x", count: 200))
        #expect(value.utf8.count == AvoIdentity.maxValueBytes)
    }

    @Test func hostFacts() {
        #expect(AvoIdentity.hostOS(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 1)) == "macOS 27.0.1")
        let chip = AvoIdentity.hostChip()
        #expect(!chip.isEmpty && chip == AvoIdentity.value(chip))
        let current = AvoIdentity.Markers.current(version: "0.1.0", renderer: .software)
        #expect(current.hostOS.hasPrefix("macOS "))
        #expect(current.input == AvoIdentity.Input.allCases)
    }

    @Test func permissionsFileDeclaresTheFeature() throws {
        let xml = AvoIdentity.permissionsFile
        #expect(xml.contains(#"<feature name="com.avodroid.feature.MAC" version="1" />"#))
        // Well formed, and nothing but the one feature.
        final class Collector: NSObject, XMLParserDelegate {
            var elements: [(String, [String: String])] = []
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                        attributes: [String: String] = [:]) {
                elements.append((name, attributes))
            }
        }
        let collector = Collector()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = collector
        #expect(parser.parse())
        #expect(collector.elements.map(\.0) == ["permissions", "feature"])
        #expect(collector.elements.last?.1 == ["name": "com.avodroid.feature.MAC", "version": "1"])
        // No apostrophes: the guest writes it through two layers of sh quoting.
        #expect(!xml.contains("'"))
    }

    @Test func avoImageShipsTheSameFile() throws {
        let file = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../guest/device/avo/avo_arm64/com.avodroid.feature.mac.xml").standardizedFileURL
        #expect(try String(contentsOf: file, encoding: .utf8) == AvoIdentity.permissionsFile)
    }
}
