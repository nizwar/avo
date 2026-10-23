import AppKit
import AvoKeymap
import AvoKit
import SwiftUI

// What the Library window shows, worked out from the Control Panel's model:
// which apps are games, what was used last, and the words for it.

extension ControlPanelModel {
    /// A game is an app with a key mapping or with game graphics chosen for
    /// it: the rule Settings › Graphics and app windows use.
    func isGame(_ app: AppRecord) -> Bool {
        graphics(for: app.package)?.profile == .games
    }

    /// Games, the most recently played first.
    var games: [AppRecord] { recentFirst(apps.filter(isGame)) }

    /// Everything that is not a game, the most recently used first.
    var nonGameApps: [AppRecord] { recentFirst(apps.filter { !isGame($0) }) }

    /// Most recently used first; apps never used after them, by name.
    func recentFirst(_ list: [AppRecord], now: Date = Date()) -> [AppRecord] {
        list.enumerated().sorted { a, b in
            let (x, y) = (lastUsed(a.element, now: now), lastUsed(b.element, now: now))
            switch (x, y) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    func lastUsed(_ app: AppRecord, now: Date = Date()) -> Date? {
        usage[app.package]?.lastUsed(now: now)
    }

    /// Apps with a window or a process, for the sidebar's Running list.
    var runningApps: [AppRecord] {
        recentFirst(apps.filter { activity[$0.package] != nil })
    }

    /// The game to continue: the last one played, else the first game.
    var continueGame: AppRecord? { games.first }

    /// Where an app came from, for a page's small capitals.
    func source(of app: AppRecord) -> LocalizedStringKey {
        if app.systemApp { return "System app" }
        switch app.installer {
        case "com.android.vending"?: return "Google Play"
        case "org.fdroid.fdroid"?, "org.fdroid.basic"?: return "F-Droid"
        case "com.aurora.store"?: return "Aurora Store"
        default: return "Installed from a file"
        }
    }

    /// A store app to get more games from, if one is installed.
    var storeApp: AppRecord? {
        ["com.android.vending", "com.aurora.store", "org.fdroid.fdroid", "org.fdroid.basic"].lazy
            .compactMap { package in self.apps.first { $0.package == package } }.first
    }
}

extension AppActivity {
    var label: LocalizedStringKey {
        switch self {
        case .open: "Running"
        case .minimized: "Minimized"
        case .background: "In background"
        }
    }
}

/// "5 hr 12 min", "35 min", "45 sec" in the user's language.
func formatPlayTime(_ seconds: Double) -> String {
    if seconds < 60 {
        return Duration.seconds(max(0, seconds.rounded())).formatted(.units(allowed: [.seconds], width: .condensedAbbreviated))
    }
    let minutes = (seconds / 60).rounded()
    return Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .condensedAbbreviated))
}

/// "2 hours ago", "yesterday".
func formatAgo(_ date: Date, now: Date = Date()) -> String {
    if now.timeIntervalSince(date) < 60 { return String(localized: "just now") }
    return date.formatted(.relative(presentation: .named, unitsStyle: .wide))
}

/// An app window's own settings, kept by its App Shim in the shim's defaults
/// (AvoWindowHost's KeymapController and KeymapHints): whether a new window
/// starts in Game Mode, and whether the key mapping shows over the game.
/// The Control Panel is not sandboxed, so it reads and writes that domain;
/// a running shim hears of a change (ShimRequest.preferencesChanged) and
/// shows it at once, and a new window starts with it.
struct ShimPreferences {
    private let defaults: UserDefaults?

    init(package: String) {
        self.package = package
        defaults = UserDefaults(suiteName: AvoIdentifiers.shimBundleIdentifier(for: package))
    }

    /// AvoWindowHost: KeymapController's `AvoGameMode`.
    var gameModeAtStart: Bool {
        get { defaults?.bool(forKey: "AvoGameMode") ?? false }
        nonmutating set {
            defaults?.set(newValue, forKey: "AvoGameMode")
            changed()
        }
    }

    /// AvoWindowHost: KeymapHints' `AvoKeymapHintsVisible` (shown unless turned off).
    var keyHintsVisible: Bool {
        get { defaults?.object(forKey: "AvoKeymapHintsVisible") as? Bool ?? true }
        nonmutating set {
            defaults?.set(newValue, forKey: "AvoKeymapHintsVisible")
            changed()
        }
    }

    private let package: String

    /// The app's running shim, if any, shows the change at once.
    private func changed() {
        defaults?.synchronize()
        DistributedNotificationCenter.default().postNotificationName(ShimRequest.preferencesChanged, object: package, userInfo: nil,
                                                                     deliverImmediately: true)
    }
}

/// The key mapping an app's windows use (the user's, else Avo's), read off
/// the main actor.
func loadKeyMapping(for package: String) async -> KeymapProfile? {
    let bundled = Bundle.main.resourceURL?.appending(path: "profiles/keymaps", directoryHint: .isDirectory)
    return await Task.detached(priority: .utility) {
        KeymapProfile.usable(for: package, bundledDirectory: bundled)?.profile
    }.value
}
