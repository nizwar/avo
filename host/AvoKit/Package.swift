// swift-tools-version: 6.0
//
// AvoKit: the host-side core of Avo, independent of AppKit UI so it can be
// unit tested with `swift test`. The Xcode project (host/project.yml) links
// these products into the Control Panel, the daemon, the Window Host and the
// App Shim. What Avo shares with Avo Hub (the key mapping and its UI, the
// haze's window controls, the Input channel's records, screen sampling) is
// avo_kit, a submodule at vendor/avo_kit; AvoShared brings it into AvoHostKit.

import Foundation
import PackageDescription

// avo_kit: Avo's own submodule (vendor/avo_kit), or, while Avo is itself a
// project's submodule (Avo Hub's vendor/avo), that project's vendor/avo_kit
// beside it. Both then build the one copy the project pins: SwiftPM does not
// take two packages of the same identity from two places.
let avoRoot = URL(fileURLWithPath: Context.packageDirectory).deletingLastPathComponent().deletingLastPathComponent()
let avoKitBesideAvo = avoRoot.deletingLastPathComponent().appendingPathComponent("avo_kit")
let avoKitPath = avoRoot.deletingLastPathComponent().lastPathComponent == "vendor"
    && FileManager.default.fileExists(atPath: avoKitBesideAvo.appendingPathComponent("Package.swift").path)
    ? "../../../avo_kit" : "../../vendor/avo_kit"

let package = Package(
    name: "AvoKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        // The one product the Xcode targets link: a single dynamic framework,
        // so the app, the daemon and the Window Host never carry two copies
        // of the same classes (which breaks NSXPC class checks).
        .library(name: "AvoHostKit", type: .dynamic, targets: [
            "AvoKit", "AvoProtocol", "AvoPackages", "AvoIO", "AvoADB", "AvoShared", "AvoShimKit", "AvoDaemonCore",
        ]),
        .library(name: "AvoKit", targets: ["AvoKit"]),
        .library(name: "AvoProtocol", targets: ["AvoProtocol"]),
        .library(name: "AvoPackages", targets: ["AvoPackages"]),
        .library(name: "AvoIO", targets: ["AvoIO"]),
        .library(name: "AvoADB", targets: ["AvoADB"]),
        .library(name: "AvoShimKit", targets: ["AvoShimKit"]),
        .library(name: "AvoDaemonCore", targets: ["AvoDaemonCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.39.0"),
        .package(path: avoKitPath),
    ],
    targets: [
        // Shared models, configuration, paths, identifiers and XPC interfaces.
        // Resources/Localizable.xcstrings holds the user-facing text of every
        // module in this package (see Localization.swift).
        .target(name: "AvoKit", dependencies: [.product(name: "AvoScreen", package: "avo_kit")], resources: [.process("Resources")]),

        // Control channel (protobuf) and Input channel (binary records).
        .target(
            name: "AvoProtocol",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf"), .product(name: "AvoInput", package: "avo_kit")],
            exclude: ["Generated/README.md"]
        ),

        // .apk / .xapk / .apkm / .apks inspection: ZIP, binary XML, resources.arsc.
        .target(name: "AvoPackages", dependencies: ["AvoKit"]),

        // Byte streams over file descriptors, Unix sockets and the engine's vsock bridge.
        .target(name: "AvoIO"),

        // ADB wire protocol client (auth, shell v2, exec, sync) over any byte stream.
        .target(name: "AvoADB", dependencies: ["AvoIO"]),

        // avo_kit's key mapping and haze UI, brought into AvoHostKit.
        .target(name: "AvoShared", dependencies: [
            .product(name: "AvoKeymap", package: "avo_kit"),
            .product(name: "AvoKeymapUI", package: "avo_kit"),
            .product(name: "AvoHazeUI", package: "avo_kit"),
        ]),

        // App Shim bundles, macOS-style icons and Desktop/Dock shortcuts.
        .target(name: "AvoShimKit", dependencies: ["AvoKit"]),

        // Runtime Daemon logic: VM lifecycle, app registry, install pipeline.
        .target(
            name: "AvoDaemonCore",
            dependencies: ["AvoKit", "AvoIO", "AvoProtocol", "AvoPackages", "AvoADB", "AvoShimKit"]
        ),

        // Fakes shared by the test targets: adbd, Bridge Agent, engine.
        .target(
            name: "AvoTestSupport",
            dependencies: ["AvoADB", "AvoIO", "AvoProtocol", "AvoDaemonCore"],
            path: "Tests/AvoTestSupport"
        ),

        .testTarget(name: "AvoKitTests", dependencies: ["AvoKit", .product(name: "AvoKeymap", package: "avo_kit")],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "AvoProtocolTests", dependencies: ["AvoProtocol"]),
        .testTarget(name: "AvoPackagesTests", dependencies: ["AvoPackages"], resources: [.copy("Fixtures")]),
        .testTarget(name: "AvoIOTests", dependencies: ["AvoIO"]),
        .testTarget(name: "AvoADBTests", dependencies: ["AvoADB", "AvoTestSupport"], resources: [.copy("Fixtures")]),
        .testTarget(name: "AvoShimKitTests", dependencies: ["AvoShimKit", "AvoTestSupport"]),
        .testTarget(name: "AvoDaemonCoreTests", dependencies: ["AvoDaemonCore", "AvoTestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
