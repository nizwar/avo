import AppKit
import AvoHazeUI
import AvoKit

extension HazeAppearanceSetting {
    /// Avo's look (Settings › General › Appearance: System, Light or Dark)
    /// for every window it draws: the Control Panel's, the App Shims' (an
    /// app's window, its Quick Settings, the key mapping editor, the
    /// Location panel) and the daemon's (the menu bar item's panel, the
    /// widgets). Kept in the Window Host's defaults, which every App Shim
    /// and the daemon read; a change reaches the running ones at once.
    /// What draws over a game (the HUD, notices, translations) stays dark.
    public static let avo = HazeAppearanceSetting(store: UserDefaults(suiteName: AvoIdentifiers.windowHost) ?? .standard,
                                                  key: "AvoAppearance",
                                                  changed: Notification.Name("\(AvoIdentifiers.prefix).appearanceChanged"))
}
