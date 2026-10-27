import AvoADB
import AvoIO
import AvoKit
import AvoPackages
import Foundation

/// Installs a package file from the Mac (spec §3): inspect it, boot Android if
/// needed, stream the selected APKs through `pm install-create/-write/-commit`
/// and copy XAPK OBB files to /sdcard/Android/obb/.
public struct InstallPipeline: Sendable {
    public typealias Report = @Sendable (InstallProgress) -> Void

    public init() {}

    /// Returns the installed package name. The registry and shortcuts update
    /// when the Bridge Agent reports PACKAGE_ADDED.
    public func run(_ request: InstallRequest, file: OwnedDescriptor, guestSDK: Int = PackageArchive.guestSDK,
                    ensureRunning: @Sendable () async throws -> Void,
                    adb: @Sendable () async throws -> ADBConnection,
                    report: @escaping Report) async throws -> String {
        let id = request.id
        report(InstallProgress(id: id, phase: .inspecting))
        let archive: PackageArchive
        do {
            archive = try PackageArchive(fileDescriptor: file.value, url: URL(filePath: request.path), guestSDK: guestSDK)
        } catch let error as PackageError {
            throw AvoError.unsupportedPackage(error.localizedDescription)
        }
        let summary = archive.summary
        if let issue = summary.compatibility.first(where: \.isBlocking) {
            throw AvoError.unsupportedPackage(issue.message)
        }

        report(InstallProgress(id: id, phase: .startingVM, package: summary.packageName))
        try await ensureRunning()
        let connection = try await adb()

        let parts = summary.parts.map { part in
            ADBConnection.InstallPart(name: part.installName, size: part.size) {
                ChunkPipe { send in try archive.stream(part) { try send($0) } }.stream()
            }
        }
        report(InstallProgress(id: id, phase: .transferring, fraction: 0, package: summary.packageName))
        do {
            try await connection.install(parts) { done, total in
                let fraction = total == 0 ? 1 : Double(done) / Double(total)
                report(InstallProgress(id: id, phase: done < total ? .transferring : .installing,
                                       fraction: fraction, package: summary.packageName))
            }
        } catch let error as ADBError {
            throw AvoError.installFailed(Self.friendly(error.description))
        }

        if !summary.obbFiles.isEmpty {
            let total = summary.obbBytes
            var copied: UInt64 = 0
            for obb in summary.obbFiles {
                let base = copied
                report(InstallProgress(id: id, phase: .copyingOBB, fraction: total == 0 ? 0 : Double(base) / Double(total),
                                       package: summary.packageName))
                try await connection.push(ChunkPipe { send in try archive.stream(obb) { try send($0) } },
                                          to: "/sdcard/" + obb.destination, mode: 0o660) { sent in
                    report(InstallProgress(id: id, phase: .copyingOBB, fraction: Double(base + sent) / Double(max(total, 1)),
                                           package: summary.packageName))
                }
                copied += obb.size
            }
        }
        return summary.packageName
    }

    /// Android's storage keeps the size it was created with: only erasing
    /// Android's data changes it (Settings › Storage › Change Size).
    static var outOfStorage: String {
        String(localized: "Android is out of storage; uninstall apps or clear their data to make room, or use Change Size in Settings › Storage, which erases Android’s data",
               bundle: .avoKit)
    }

    /// Turns PackageManager failure codes into sentences.
    static func friendly(_ message: String) -> String {
        let known: [(String, String)] = [
            ("INSTALL_FAILED_NO_MATCHING_ABIS", String(localized: "the app has no 64-bit ARM code", bundle: .avoKit)),
            ("INSTALL_FAILED_INSUFFICIENT_STORAGE", outOfStorage),
            ("INSTALL_FAILED_UPDATE_INCOMPATIBLE",
             String(localized: "an installed version is signed with a different key; uninstall it first", bundle: .avoKit)),
            ("INSTALL_FAILED_VERSION_DOWNGRADE", String(localized: "a newer version is already installed", bundle: .avoKit)),
            ("INSTALL_FAILED_OLDER_SDK", String(localized: "the app needs a newer Android version", bundle: .avoKit)),
            ("INSTALL_PARSE_FAILED_NO_CERTIFICATES", String(localized: "the package is not signed", bundle: .avoKit)),
            ("INSTALL_FAILED_MISSING_SPLIT", String(localized: "a required split APK is missing from the bundle", bundle: .avoKit)),
        ]
        for (code, sentence) in known where message.contains(code) { return "\(sentence) (\(code))" }
        return message
    }
}
