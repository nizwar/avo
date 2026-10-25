// swift-tools-version: 6.0
//
// AvoKit: the host-side core of Avo, independent of AppKit UI so it can be
// unit tested with `swift test`. The Xcode project (host/project.yml) links
// these products into the Control Panel, the daemon, the Window Host and the
// App Shim. Two UI modules are the exception: the haze's window controls
// (AvoHazeUI) and the key mapping a window runs (AvoKeymapUI), here so Avo
// Hub's windows link the same ones as Avo's app windows.

import PackageDescription

let package = Package(
    name: "AvoKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        // The one product the Xcode targets link: a single dynamic framework,
        // so the app, the daemon and the Window Host never carry two copies
        // of the same classes (which breaks NSXPC class checks).
        .library(name: "AvoHostKit", type: .dynamic, targets: [
            "AvoKit", "AvoProtocol", "AvoPackages", "AvoIO", "AvoADB", "AvoKeymap", "AvoShimKit", "AvoDaemonCore",
            "AvoHazeUI", "AvoKeymapUI",
        ]),
        .library(name: "AvoKit", targets: ["AvoKit"]),
        .library(name: "AvoProtocol", targets: ["AvoProtocol"]),
        .library(name: "AvoPackages", targets: ["AvoPackages"]),
        .library(name: "AvoIO", targets: ["AvoIO"]),
        .library(name: "AvoADB", targets: ["AvoADB"]),
        .library(name: "AvoKeymap", targets: ["AvoKeymap"]),
        .library(name: "AvoHazeUI", targets: ["AvoHazeUI"]),
        .library(name: "AvoKeymapUI", targets: ["AvoKeymapUI"]),
        .library(name: "AvoShimKit", targets: ["AvoShimKit"]),
        .library(name: "AvoDaemonCore", targets: ["AvoDaemonCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.39.0"),
    ],
    targets: [
        // Shared models, configuration, paths, identifiers and XPC interfaces.
        // Resources/Localizable.xcstrings holds the user-facing text of every
        // module in this package (see Localization.swift).
        .target(name: "AvoKit", resources: [.process("Resources")]),

        // Control channel (protobuf) and Input channel (binary records).
        .target(
            name: "AvoProtocol",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
            exclude: ["Generated/README.md"]
        ),

        // .apk / .xapk / .apkm / .apks inspection: ZIP, binary XML, resources.arsc.
        .target(name: "AvoPackages", dependencies: ["AvoKit"]),

        // Byte streams over file descriptors, Unix sockets and the engine's vsock bridge.
        .target(name: "AvoIO"),

        // ADB wire protocol client (auth, shell v2, exec, sync) over any byte stream.
        .target(name: "AvoADB", dependencies: ["AvoIO"]),

        // Keymapping profiles and the engine that turns keys/mouse/gamepad into touches.
        .target(name: "AvoKeymap", dependencies: ["AvoKit", "AvoProtocol"]),

        // The haze in small (AppKit and SwiftUI): QuickHaze's colours and
        // type, the Quick* controls of an app window's panels, and HazeMenu,
        // the menu Avo pops up in place of macOS's.
        .target(name: "AvoHazeUI", dependencies: ["AvoKit"]),

        // The key mapping a window runs over its game view (AppKit and
        // SwiftUI): KeymapController, the editor and its panels, the hints
        // over the game and GamepadHub. Avo's Window Host and Avo Hub's
        // mirror windows give it their view and store (KeymapHost.swift).
        .target(name: "AvoKeymapUI", dependencies: ["AvoKit", "AvoProtocol", "AvoKeymap", "AvoHazeUI"]),

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

        .testTarget(name: "AvoKitTests", dependencies: ["AvoKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "AvoProtocolTests", dependencies: ["AvoProtocol"]),
        .testTarget(name: "AvoPackagesTests", dependencies: ["AvoPackages"], resources: [.copy("Fixtures")]),
        .testTarget(name: "AvoIOTests", dependencies: ["AvoIO"]),
        .testTarget(name: "AvoADBTests", dependencies: ["AvoADB", "AvoTestSupport"], resources: [.copy("Fixtures")]),
        .testTarget(name: "AvoKeymapTests", dependencies: ["AvoKeymap"]),
        .testTarget(name: "AvoKeymapUITests", dependencies: ["AvoKeymapUI", "AvoKeymap", "AvoProtocol"]),
        .testTarget(name: "AvoShimKitTests", dependencies: ["AvoShimKit", "AvoTestSupport"]),
        .testTarget(name: "AvoDaemonCoreTests", dependencies: ["AvoDaemonCore", "AvoTestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
