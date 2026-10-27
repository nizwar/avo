import Foundation

/// Desktop aliases and Dock tiles for App Shims (spec §4: "Buat alias di
/// Desktop" on by default, "Tambahkan ke Dock" optional).
public enum Shortcuts {
    /// Creates a Finder alias to `target` in `directory` (normally ~/Desktop)
    /// and returns its location.
    @discardableResult
    public static func createAlias(to target: URL, in directory: URL, name: String? = nil) throws -> URL {
        let aliasName = name ?? target.deletingPathExtension().lastPathComponent
        let alias = directory.appending(path: aliasName)
        let data = try target.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        if FileManager.default.fileExists(atPath: alias.path) {
            // Only replace something that is already an alias to an Avo shim.
            guard isAlias(alias) else { throw CocoaError(.fileWriteFileExists) }
            try FileManager.default.removeItem(at: alias)
        }
        try URL.writeBookmarkData(data, to: alias)
        return alias
    }

    /// Removes `alias` if it is a Finder alias (never a real file or folder).
    public static func removeAlias(_ alias: URL) {
        guard isAlias(alias) else { return }
        try? FileManager.default.removeItem(at: alias)
    }

    public static func isAlias(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true
    }

    // MARK: Dock

    private static var dockDomain: CFString { "com.apple.dock" as CFString }
    private static var persistentApps: CFString { "persistent-apps" as CFString }

    /// Adds a tile for `app` to the Dock's persistent apps if it is not there yet.
    /// macOS has no public API for this; Avo edits the Dock's preferences the
    /// same way `dockutil` does and restarts the Dock to apply them.
    public static func addToDock(_ app: URL, restartDock: Bool = true) -> Bool {
        var tiles = (CFPreferencesCopyAppValue(persistentApps, dockDomain) as? [[String: Any]]) ?? []
        let url = app.absoluteString
        if tiles.contains(where: { tileURL($0) == url }) { return false }
        tiles.append([
            "tile-type": "file-tile",
            "tile-data": ["file-data": ["_CFURLString": url, "_CFURLStringType": 15],
                          "file-label": app.deletingPathExtension().lastPathComponent],
        ])
        return save(tiles, restartDock: restartDock)
    }

    public static func removeFromDock(_ app: URL, restartDock: Bool = true) -> Bool {
        let tiles = (CFPreferencesCopyAppValue(persistentApps, dockDomain) as? [[String: Any]]) ?? []
        let url = app.absoluteString
        let kept = tiles.filter { tileURL($0) != url }
        guard kept.count != tiles.count else { return false }
        return save(kept, restartDock: restartDock)
    }

    public static func isInDock(_ app: URL) -> Bool {
        let tiles = (CFPreferencesCopyAppValue(persistentApps, dockDomain) as? [[String: Any]]) ?? []
        return tiles.contains { tileURL($0) == app.absoluteString }
    }

    private static func tileURL(_ tile: [String: Any]) -> String? {
        ((tile["tile-data"] as? [String: Any])?["file-data"] as? [String: Any])?["_CFURLString"] as? String
    }

    private static func save(_ tiles: [[String: Any]], restartDock: Bool) -> Bool {
        CFPreferencesSetAppValue(persistentApps, tiles as CFArray, dockDomain)
        guard CFPreferencesAppSynchronize(dockDomain) else { return false }
        if restartDock { Self.restartDock() }
        return true
    }

    /// The Dock reads its tiles again (after changes made with `restartDock: false`).
    public static func restartDock() {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try? process.run()
    }
}
