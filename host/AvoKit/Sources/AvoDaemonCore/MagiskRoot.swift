import AvoKit
import CryptoKit
import Foundation

/// Root for Android's apps (Settings › System › Developer, `rooted`) with
/// Magisk. The image's userdebug `su` serves only Android's shell; Magisk
/// gives apps root and asks the user for each one.
///
/// Magisk lives in init_boot's ramdisk (GKI: the generic ramdisk). Avo
/// downloads one known Magisk release from its GitHub page (checked against
/// its SHA-256; Magisk is GPL and never ships with Avo), patches the image's
/// init_boot.img with Magisk's own `boot_patch.sh` inside the running
/// Android (as root, through the shell's `su`), and keeps the result in
/// `vm/magisk`, with the hash of the init_boot it came from. While root is
/// on, avo-vmm boots that copy (`--init-boot`); off, the image's own. The
/// image itself never changes, and neither does Android's data. A new
/// Android version (another init_boot) is patched again at its first start.
enum MagiskRoot {
    struct Release: Equatable, Sendable {
        let version: String
        let url: URL
        let sha256: String
        let size: Int
    }

    /// Magisk v30.7 (2026-02-23), the newest stable release.
    static let release = Release(
        version: "30.7",
        url: URL(string: "https://github.com/topjohnwu/Magisk/releases/download/v30.7/Magisk-v30.7.apk")!,
        sha256: "e0d32d2123532860f97123d927b1bb86c4e08e6fd8a48bfc6b5bee0afae9ebd5",
        size: 11_613_864)

    /// What a patched init_boot was made from.
    struct Record: Codable, Equatable {
        /// SHA-256 of the image's init_boot.img.
        var stock: String
        var magisk: String
    }

    static func directory(_ paths: AvoPaths) -> URL { paths.vm.appending(path: "magisk", directoryHint: .isDirectory) }
    static func patchedImage(_ paths: AvoPaths) -> URL { directory(paths).appending(path: "init_boot.img") }
    static func recordFile(_ paths: AvoPaths) -> URL { directory(paths).appending(path: "init_boot.json") }
    /// The kernel's log of the last start with Magisk that did not get
    /// Android ready (DaemonCore.prepareRoot): why it rebooted.
    static func failedBootLog(_ paths: AvoPaths) -> URL { directory(paths).appending(path: "failed-boot-kernel.log") }
    static func cachedAPK(_ paths: AvoPaths) -> URL {
        paths.home.appending(path: "Library/Caches/Avo/magisk/Magisk-v\(release.version).apk")
    }

    static func stockImage(of image: AndroidImage) -> URL { image.directory.appending(path: "init_boot.img") }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The patched init_boot for `image`, when there is one made from its init_boot.
    static func patchedImage(for image: AndroidImage, paths: AvoPaths) -> URL? {
        let patched = patchedImage(paths)
        guard FileManager.default.fileExists(atPath: patched.path),
              let data = try? Data(contentsOf: recordFile(paths)),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              let stock = try? sha256(of: stockImage(of: image)), record.stock == stock else { return nil }
        return patched
    }

    /// Keeps `patched` as the init_boot for the image whose init_boot hashes to `stock`.
    static func store(_ patched: Data, stock: String, paths: AvoPaths) throws {
        try FileManager.default.createDirectory(at: directory(paths), withIntermediateDirectories: true)
        try patched.write(to: patchedImage(paths), options: .atomic)
        try JSONEncoder().encode(Record(stock: stock, magisk: release.version)).write(to: recordFile(paths), options: .atomic)
    }

    /// Magisk's APK, from the cache or downloaded, checked against its hash.
    static func apk(paths: AvoPaths, session: URLSession = .shared) async throws -> URL {
        let cached = cachedAPK(paths)
        if (try? sha256(of: cached)) == release.sha256 { return cached }
        let (download, response) = try await session.download(from: release.url)
        defer { try? FileManager.default.removeItem(at: download) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AvoError.installFailed(String(localized: "Magisk could not be downloaded from GitHub", bundle: .avoKit))
        }
        guard try sha256(of: download) == release.sha256 else {
            throw AvoError.installFailed(String(localized: "The Magisk download is not the expected file", bundle: .avoKit))
        }
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: cached)
        try FileManager.default.moveItem(at: download, to: cached)
        return cached
    }

    /// Where the patch runs in Android.
    static let staging = "/data/local/tmp/avo-magisk"

    /// Run as root in `staging`, with magisk.apk and init_boot.img there:
    /// Magisk's own patch script, as its app runs it (BOOTMODE: Android is
    /// up), leaves new-boot.img readable for the shell user.
    static var patchScript: String {
        [
            "set -e",
            "cd \(staging)",
            "unzip -o -q magisk.apk 'assets/*' 'lib/arm64-v8a/*'",
            "cp lib/arm64-v8a/libmagiskboot.so magiskboot",
            "cp lib/arm64-v8a/libmagiskinit.so magiskinit",
            "cp lib/arm64-v8a/libmagisk.so magisk",
            "cp lib/arm64-v8a/libinit-ld.so init-ld",
            "cp assets/boot_patch.sh assets/util_functions.sh assets/stub.apk .",
            "chmod 755 magiskboot magiskinit magisk init-ld",
            "rm -f new-boot.img",
            "sh ./boot_patch.sh init_boot.img",
            "chmod 644 new-boot.img",
        ].joined(separator: "\n")
    }

    /// A patched init_boot: a boot image (header magic) with Magisk's init in it.
    static func looksPatched(_ data: Data) -> Bool {
        data.count > 4096 && data.prefix(8) == Data("ANDROID!".utf8)
    }
}

/// An engine that applies Settings › Devices (network speed, Wi-Fi, the Mac's
/// Bluetooth devices) to the running Android at once (VMMEngine).
public protocol DeviceSettingsEngine: VMEngine {
    func applyDeviceSettings(_ config: VMConfig) async
}

/// An engine that can root Android with Magisk (VMMEngine).
public protocol RootEngine: VMEngine {
    /// The running Android booted with Magisk's init_boot.
    func bootedRooted() async -> Bool
    /// There is a patched init_boot for the running Android's image.
    func hasPatchedImage() async -> Bool
    /// Downloads Magisk, patches the running image's init_boot in Android and
    /// keeps it for the next start; installs Magisk's app.
    func prepareRoot() async throws
}
