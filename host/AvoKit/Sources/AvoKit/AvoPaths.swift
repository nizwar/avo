import Foundation

/// File system layout of an Avo installation for one user.
///
/// ```
/// ~/Library/Application Support/Avo/
///   config.json            VMConfig
///   apps.json              app registry (source of truth: the guest)
///   icons/<package>.png    launcher icons reported by the Bridge Agent
///   keymaps/<package>.json keymapping profiles
///   adbkey                 RSA key the daemon uses for the ADB channel
///   images/<version>/      Android image (kernel, system/vendor, overlays)
///   vm/userdata.img        user data disk (size fixed once Android created its storage)
///   vm/snapshots/          quick-boot snapshots
///   data-location.json     Android's data is in another folder (StorageLocation.swift)
/// ~/Applications/Android Apps/<Label>.app   App Shims
/// ~/Library/Logs/Avo/                          logs
/// $TMPDIR/com.avodroid/                        runtime sockets (mode 0700)
/// ```
public struct AvoPaths: Sendable, Equatable {
    public let home: URL
    public let applicationSupport: URL
    public let shims: URL
    public let logs: URL
    public let runtime: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.home = home
        self.applicationSupport = home.appending(path: "Library/Application Support/Avo", directoryHint: .isDirectory)
        self.shims = home.appending(path: "Applications/Android Apps", directoryHint: .isDirectory)
        self.logs = home.appending(path: "Library/Logs/Avo", directoryHint: .isDirectory)
        self.runtime = temporaryDirectory.appending(path: AvoIdentifiers.prefix, directoryHint: .isDirectory)
    }

    public var config: URL { applicationSupport.appending(path: "config.json") }
    public var registry: URL { applicationSupport.appending(path: "apps.json") }
    public var icons: URL { applicationSupport.appending(path: "icons", directoryHint: .isDirectory) }
    public var keymaps: URL { applicationSupport.appending(path: "keymaps", directoryHint: .isDirectory) }
    public var adbKey: URL { applicationSupport.appending(path: "adbkey") }
    public var images: URL { applicationSupport.appending(path: "images", directoryHint: .isDirectory) }
    public var vm: URL { applicationSupport.appending(path: "vm", directoryHint: .isDirectory) }
    /// Android's data disk, in `data` (Avo's own storage, `vm`, unless the
    /// user chose another folder in Settings › Storage).
    public var dataDisk: URL { data.appending(path: "userdata.img") }
    public var snapshots: URL { vm.appending(path: "snapshots", directoryHint: .isDirectory) }
    /// Android widgets on the Mac (Library › Widgets).
    public var widgets: URL { applicationSupport.appending(path: "widgets.json") }
    public var desktop: URL { home.appending(path: "Desktop", directoryHint: .isDirectory) }

    /// Unix socket the engine exposes for guest vsock ports.
    public var vsockSocket: URL { runtime.appending(path: "vsock.sock") }
    /// crosvm control socket (stop, suspend, snapshot, balloon).
    public var engineControlSocket: URL { runtime.appending(path: "crosvm.sock") }

    public func icon(for package: String) -> URL { icons.appending(path: "\(package).png") }
    public func keymap(for package: String) -> URL { keymaps.appending(path: "\(package).json") }

    /// Unix domain socket paths are limited to 104 bytes on Darwin.
    public static let maxSocketPathLength = 103

    /// Creates the directories Avo writes to. The runtime directory is
    /// private to the user because it exposes the guest's vsock ports.
    public func createDirectories(fileManager: FileManager = .default) throws {
        for url in [applicationSupport, icons, keymaps, images, vm, snapshots, logs] {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try fileManager.createDirectory(at: runtime, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
    }

    public func validateSocketPaths() throws {
        for url in [vsockSocket, engineControlSocket] where url.path.utf8.count > Self.maxSocketPathLength {
            throw AvoError.socketPathTooLong(url.path)
        }
    }
}
