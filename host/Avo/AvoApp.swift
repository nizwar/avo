import AppKit
import AvoHazeUI
import AvoKit
import AvoWindowHost
import SwiftUI

@main
struct AvoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The Library: Home, Games, Apps, Notifications and each app's page
        // (LibraryWindow.swift), with the status pill below it.
        Window("Avo", id: LibraryRouter.windowID) {
            LibraryView()
                .environment(appDelegate.model)
                .environment(appDelegate.images)
                .environment(appDelegate.setup)
                .environment(appDelegate.library)
                .environment(appDelegate.updater)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1200, height: 724)
        .commands {
            // Avo › Check for Updates… (AppUpdater.swift).
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updater: appDelegate.updater)
            }
            CommandGroup(after: .newItem) {
                Button("Install Android App…") { appDelegate.chooseAndInstall() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .appSettings) {
                SettingsCommand()
            }
            CommandGroup(after: .help) {
                Button("Setup Assistant…") { appDelegate.setup.show() }
                ReportProblemCommand()
            }
        }

        // Settings, laid out like System Settings, in the Library's haze (SettingsWindow.swift).
        Window("Avo Settings", id: SettingsWindow.id) {
            SettingsWindow()
                .environment(appDelegate.model)
                .environment(appDelegate.images)
                .environment(appDelegate.setup)
                .environment(appDelegate.library)
                .environment(appDelegate.updater)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 960, height: 680)

        // Help › Report a Problem… (ReportProblem.swift).
        Window("Report a Problem", id: ReportProblemView.windowID) {
            ReportProblemView()
                .environment(appDelegate.model)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        // The Setup Assistant (SetupAssistant.swift): first launch, no
        // Android image, or Help › Setup Assistant….
        Window("Set Up Avo", id: SetupWindow.id) {
            SetupWindow()
                .environment(appDelegate.model)
                .environment(appDelegate.images)
                .environment(appDelegate.setup)
                .environment(appDelegate.library)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: SetupAssistantView.size.width, height: SetupAssistantView.size.height)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        // Not in the Window menu: the assistant opens it (Help › Setup Assistant…).
        .commandsRemoved()
    }
}

/// Avo › Settings… (⌘,): the Settings window.
private struct SettingsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") { openWindow(id: SettingsWindow.id) }
            .keyboardShortcut(",")
    }
}

/// Avo › Check for Updates…: dimmed while a check runs, and in a build without an update feed.
private struct CheckForUpdatesCommand: View {
    let updater: AppUpdater

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}

/// Opens package files from Finder (double-click, Dock icon drop, Open With).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// First, before anything reads the preferences (and before the daemon
    /// of this build starts: ControlPanelModel.start).
    private let movedDefaults = ControlPanelDefaults.migrate()
    private let movedHelperDefaults = IdentifierMigration.migrate()
    let model = ControlPanelModel()
    /// Android images and the Setup Assistant (SetupAssistant.swift).
    let images = AndroidImageManager()
    let setup = SetupAssistant()
    /// Where the Library is, and the Settings pane links ask for.
    let library = LibraryRouter()
    /// Avo's own updates (Sparkle).
    let updater = AppUpdater()
    /// Light, dark, or as the Mac (Settings › General › Appearance).
    private var appearance: HazeAppearanceFollower?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before the first window shows.
        appearance = HazeAppearanceSetting.avo.followInApp()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        updater.model = model
        model.start()
        // Another Android version with its own data: the daemon moves Android to it.
        images.changeData = { [model] request in
            try await model.changeStorage(request)
        }
        setup.presentIfNeeded(images: images)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // The menu bar item's Check for Updates….
        if urls.contains(where: { ControlPanelLink.pane(in: $0) == ControlPanelLink.checkForUpdates }) {
            NSApp.activate()
            updater.checkForUpdates()
        }
        // An app window's Manage Fingerprints… (ControlPanelLink): that
        // Settings pane (the Library opens the Settings window for it).
        if let name = urls.lazy.compactMap(ControlPanelLink.pane(in:)).first, let pane = SettingsPane.named(name) {
            library.requestedSettingsPane = pane
            NSApp.activate()
        }
        // An app window's All Settings…: that app's page in the Library.
        if let package = urls.lazy.compactMap(ControlPanelLink.appPage(in:)).first {
            library.requestedAppPage = package
            NSApp.activate()
        }
        // One confirmation sheet at a time; extra files wait for the next drop.
        if let url = urls.first(where: { ControlPanelModel.packageExtensions.contains($0.pathExtension.lowercased()) }) {
            model.prepareInstall(url)
            NSApp.activate()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The VM keeps running in the background; the menu bar item stays.
        true
    }

    func chooseAndInstall() {
        model.chooseAndInstall()
    }
}

/// What the helpers and App Shims kept under the identifiers of the builds
/// before 0.3.0 Preview 2 (dev.avo) moves to Avo's domain: each new domain
/// takes the keys it does not have yet (AvoIdentifiers.formerPreferenceDomains),
/// once at launch, and the former ones go once no daemon of those builds runs.
enum IdentifierMigration {
    static let migratedKey = "AvoMovedFromDevAvo"

    /// At the first launch, before this build's daemon reads its preferences.
    @discardableResult
    static func migrate(_ defaults: UserDefaults = .standard) -> Int {
        guard Bundle.main.bundleIdentifier == AvoIdentifiers.app, !defaults.bool(forKey: migratedKey) else { return 0 }
        defaults.set(true, forKey: migratedKey)
        return copy(defaults)
    }

    /// When the former daemon's agent is gone (DaemonAgent): what it wrote
    /// since `migrate` comes along too, then the former domains go, with
    /// what macOS and that daemon kept under the former names (its HTTP
    /// storage and its runtime folder). Nothing of Avo's stays a dev.avo.
    static func finish(_ defaults: UserDefaults = .standard) {
        guard Bundle.main.bundleIdentifier == AvoIdentifiers.app else { return }
        copy(defaults)
        let files = FileManager.default
        for (from, _) in pairs() {
            defaults.removePersistentDomain(forName: from)
            try? files.removeItem(at: preferences.appending(path: "\(from).plist"))
        }
        try? files.removeItem(at: library.appending(path: "HTTPStorages/\(AvoIdentifiers.formerPrefix).daemon", directoryHint: .isDirectory))
        try? files.removeItem(at: URL(filePath: NSTemporaryDirectory()).appending(path: AvoIdentifiers.formerPrefix, directoryHint: .isDirectory))
    }

    private static var library: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library", directoryHint: .isDirectory)
    }
    private static var preferences: URL { library.appending(path: "Preferences", directoryHint: .isDirectory) }

    private static func pairs() -> [(from: String, to: String)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []
        return AvoIdentifiers.formerPreferenceDomains(preferenceFiles: names)
    }

    @discardableResult
    private static func copy(_ defaults: UserDefaults) -> Int {
        var moved = 0
        for (from, to) in pairs() {
            guard let former = defaults.persistentDomain(forName: from), !former.isEmpty else { continue }
            var current = defaults.persistentDomain(forName: to) ?? [:]
            for (key, value) in former where current[key] == nil { current[key] = value }
            defaults.setPersistentDomain(current, forName: to)
            moved += 1
        }
        return moved
    }
}

/// Avo.app's preferences under its former identifiers (AvoIdentifiers.formerApps)
/// come along once, so a Mac that used Avo before keeps its choices: Setup
/// Assistant done, remembered Android data, update checks. The newest of them wins.
enum ControlPanelDefaults {
    static let migratedKey = "AvoMovedFromFormerIdentifier"

    @discardableResult
    static func migrate(_ defaults: UserDefaults = .standard) -> Bool {
        guard Bundle.main.bundleIdentifier == AvoIdentifiers.app, !defaults.bool(forKey: migratedKey) else { return false }
        defaults.set(true, forKey: migratedKey)
        var moved = false
        for name in AvoIdentifiers.formerApps.reversed() {
            guard let former = defaults.persistentDomain(forName: name), !former.isEmpty else { continue }
            let current = defaults.persistentDomain(forName: AvoIdentifiers.app) ?? [:]
            for (key, value) in former where current[key] == nil { defaults.set(value, forKey: key) }
            moved = true
        }
        return moved
    }
}
