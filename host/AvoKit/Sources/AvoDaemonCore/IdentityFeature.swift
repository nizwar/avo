import AvoKit
import Foundation

/// Declares `AvoIdentity.feature` in Android where Avo can add a file to
/// /product (HostAgent, every boot). Stock Cuttlefish images keep /product
/// read-only under verified boot; once Google apps are installed it is an
/// overlayfs whose changes persist on the data disk (GoogleAppsInstaller,
/// docs/engine.md). SystemConfig reads permission files when the framework
/// starts, so a file written now counts from the next boot.
///
/// The file is not on the install's file list (`GoogleAppsCommit.manifest`):
/// taking Google apps out keeps it, which is harmless since it only says what
/// is true, and Reset Android removes it together with the overlay.
enum IdentityFeature {
    static let path = AvoIdentity.permissionsPath
    /// Beside `path` under a name SystemConfig skips (it reads `*.xml`).
    static let temporary = (AvoIdentity.permissionsPath as NSString).deletingLastPathComponent
        + "/.\(AvoIdentifiers.prefix).feature.mac.xml.new"
    static let separator = "--avo-feature--"
    /// After it: whether the former file (`AvoIdentity.formerPermissionsPath`) is there.
    static let formerSeparator = "--avo-former-feature--"

    /// The install's file list (`GoogleAppsCommit.stateCommand`), then the
    /// file. `root` prefixes the paths (a scratch folder in tests).
    static func checkCommand(root: String = "") -> String {
        GoogleAppsCommit.stateCommand(layout: GoogleAppsCommit.Layout(root: root))
            + "; echo \(separator); cat \(quote(root + path)) 2>/dev/null"
            + "; echo \(formerSeparator); [ -e \(quote(root + AvoIdentity.formerPermissionsPath)) ] && echo former; true"
    }

    /// True when Google apps are installed in full, so /product keeps what is
    /// written, and the file is missing or not this schema's, or the former
    /// one is still there.
    static func needsWrite(checkOutput output: String) -> Bool {
        guard let mark = output.range(of: separator) else { return false }
        guard GoogleAppsCommit.state(fromOutput: String(output[..<mark.lowerBound])) == .complete else { return false }
        var current = output[mark.upperBound...]
        var former = false
        if let formerMark = current.range(of: formerSeparator) {
            former = current[formerMark.upperBound...].contains("former")
            current = current[..<formerMark.lowerBound]
        }
        if current.first == "\n" { current = current.dropFirst() }
        return former || current != AvoIdentity.permissionsFile
    }

    /// Makes /product writable (`remount`, as the Google apps install does),
    /// writes the file beside its place and renames it in (root:root, 0644,
    /// restorecon). /product stays writable until Android restarts, like
    /// after an install; remounting it read-only here could cut short an
    /// undo of that install running at the same time.
    static func writeScript(root: String = "") -> String {
        let file = quote(root + path)
        let staged = quote(root + Self.temporary)
        return [
            "remount /product >/dev/null 2>&1",
            "( set -e",
            "printf '%s' \(quote(AvoIdentity.permissionsFile)) > \(staged)",
            "chmod 0644 \(staged)",
            "chown root:root \(staged)",
            "mv -f \(staged) \(file)",
            "restorecon \(file)",
            "rm -f \(quote(root + AvoIdentity.formerPermissionsPath))",
            "sync )",
            "s=$?",
            "rm -f \(staged)",
            "exit $s",
        ].joined(separator: "\n") + "\n"
    }

    static func quote(_ text: String) -> String { GoogleAppsCommit.quote(text) }
}
