import AvoKit
import AvoProtocol
import AvoShimKit
import CoreGraphics
import Foundation
import os

/// Keeps App Shims, Desktop aliases and Dock tiles in line with the registry
/// and the shortcut options (spec §4).
public struct ShortcutManager: Sendable {
    public let builder: ShimBuilder?
    public let paths: AvoPaths
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Shortcuts")

    /// `builder` is nil when the shim template is missing (unit tests, broken install).
    public init(builder: ShimBuilder?, paths: AvoPaths) {
        self.builder = builder
        self.paths = paths
    }

    /// Creates or refreshes shortcuts for a launchable app and returns the new
    /// state. `restartDock` false: a change of its Dock tile waits for the
    /// caller's `Shortcuts.restartDock()` (one for many apps).
    public func apply(_ app: AppRecord, info: Avo_V1_AppInfo?, config: VMConfig, restartDock: Bool = true) -> AppRecord.Shortcuts {
        var shortcuts = app.shortcuts
        // The Bridge Agent decides which system apps are user-facing (launchable).
        guard app.launchable, let builder else { return shortcuts }

        let existing = shortcuts.shimPath.map { URL(filePath: $0) }
        let source = info.map(Self.iconSource) ?? iconSourceFromCache(app.package)
        guard let icns = MacIconRenderer.icns(source) else { return shortcuts }
        do {
            let result = try builder.install(app, icns: icns, existing: existing)
            if let old = shortcuts.desktopAliasPath, existing != result.bundleURL {
                Shortcuts.removeAlias(URL(filePath: old))
                shortcuts.desktopAliasPath = nil
            }
            shortcuts.shimPath = result.bundleURL.path
            shortcuts.shimCDHash = result.cdhash
        } catch {
            logger.error("shim for \(app.package, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return shortcuts
        }

        let shim = URL(filePath: shortcuts.shimPath!)
        if config.createDesktopAlias, shortcuts.desktopAliasPath == nil {
            shortcuts.desktopAliasPath = (try? Shortcuts.createAlias(to: shim, in: paths.desktop))?.path
        } else if !config.createDesktopAlias, let alias = shortcuts.desktopAliasPath {
            Shortcuts.removeAlias(URL(filePath: alias))
            shortcuts.desktopAliasPath = nil
        }
        if config.addToDock && !shortcuts.inDock {
            shortcuts.inDock = Shortcuts.addToDock(shim, restartDock: restartDock) || Shortcuts.isInDock(shim)
        } else if !config.addToDock && shortcuts.inDock {
            _ = Shortcuts.removeFromDock(shim, restartDock: restartDock)
            shortcuts.inDock = false
        }
        return shortcuts
    }

    /// A shim made by another Avo.app (a development build, a copy since
    /// replaced or moved): its windows would load that Avo's frameworks, old
    /// code or none, so it is made again for this one. So is one made from
    /// another build's template (Avo updated in place: the same path, a new
    /// CFBundleVersion), which may differ from this build's, and one with the
    /// identifier of the builds before com.avodroid (`dev.avo.shim.…`).
    public func madeForAnotherAvo(_ shortcuts: AppRecord.Shortcuts) -> Bool {
        guard let builder, let path = shortcuts.shimPath else { return false }
        let plist = URL(filePath: path).appending(path: "Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) else { return false }
        if (info["CFBundleIdentifier"] as? String)?.hasPrefix(AvoIdentifiers.formerShimPrefix) == true { return true }
        guard let host = info[AvoIdentifiers.shimHostAppInfoKey] as? String else { return true }
        if URL(filePath: host).standardizedFileURL.resolvingSymlinksInPath().path
            != builder.hostApplication.standardizedFileURL.resolvingSymlinksInPath().path {
            return true
        }
        let template = NSDictionary(contentsOf: builder.template.appending(path: "Contents/Info.plist"))
        let build = { (info: NSDictionary?) in info?["CFBundleVersion"] as? String }
        guard let templateBuild = build(template) else { return false }
        return build(info) != templateBuild
    }

    /// Uninstall removes the shim and its alias (spec §4).
    public func remove(_ shortcuts: AppRecord.Shortcuts) {
        if let alias = shortcuts.desktopAliasPath { Shortcuts.removeAlias(URL(filePath: alias)) }
        if let shim = shortcuts.shimPath {
            let url = URL(filePath: shim)
            if shortcuts.inDock { _ = Shortcuts.removeFromDock(url) }
            try? builder?.remove(url)
        }
    }

    // MARK: Icons

    static func iconSource(_ info: Avo_V1_AppInfo) -> MacIconRenderer.Source {
        if info.hasAdaptiveIcon {
            let icon = info.adaptiveIcon
            let background = MacIconRenderer.image(from: icon.backgroundPng).map(MacIconRenderer.Layer.image)
            let foreground = MacIconRenderer.image(from: icon.foregroundPng).map(MacIconRenderer.Layer.image)
            if background != nil || foreground != nil {
                return .adaptive(background: background, foreground: foreground)
            }
        }
        if let image = MacIconRenderer.image(from: info.iconPng) { return .legacy(image) }
        return placeholder
    }

    private func iconSourceFromCache(_ package: String) -> MacIconRenderer.Source {
        guard let data = try? Data(contentsOf: paths.icon(for: package)), let image = MacIconRenderer.image(from: data) else {
            return Self.placeholder
        }
        return .legacy(image)
    }

    /// Avo's flesh green with nothing on it, for apps without a readable icon.
    static let placeholder = MacIconRenderer.Source.adaptive(
        background: .color(CGColor(srgbRed: 0.847, green: 0.910, blue: 0.655, alpha: 1)), foreground: nil)
}
