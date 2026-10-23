import AppKit
import AvoKit
import os
import Security
import Sparkle

/// Avo's own updates: it reads its GitHub releases directly (GitHubUpdateFeed)
/// and hands Sparkle 2 an appcast built from them, so the download, the code
/// check and the swap stay Sparkle's — no appcast is hosted anywhere. The
/// GitHub DMG is notarized and Developer ID signed, which Sparkle checks
/// against the running app (the same team) in place of an EdDSA signature, so
/// updates run only in a Developer ID build (`signedForUpdates`), not a local
/// one. Releases name their DMG `Avo-<version>-b<build>.dmg`; the build number
/// is the version Sparkle compares.
///
/// Sparkle swaps Avo.app when the Control Panel quits or relaunches. Android
/// is never stopped for that without the player's say: before Install and
/// Relaunch, a running Android is offered a stop first. The daemon notices the
/// new build by itself and restarts on it once Android holds nothing
/// (AvoDaemon/AppUpdateWatcher.swift); the Control Panel does the same for a
/// daemon left from before (ControlPanelModel.checkDaemonBuild). Shims made
/// from the old build's template are made again (ShortcutManager.madeForAnotherAvo).
@MainActor @Observable
final class AppUpdater: NSObject {
    /// Whether this build can update itself: a Developer ID signature Sparkle
    /// can check a download against (the GitHub source is always there).
    let readiness: AppUpdate.Readiness
    private(set) var canCheckForUpdates = false
    /// Settings › About's switch (Sparkle keeps it in Avo's defaults).
    private(set) var automaticallyChecks = false
    private(set) var lastCheck: Date?
    /// Asked whether Android runs, and to stop it, before an install.
    @ObservationIgnored weak var model: ControlPanelModel?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var automaticTimer: Timer?
    @ObservationIgnored private let session = URLSession(configuration: .ephemeral)
    @ObservationIgnored private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Updates")
    /// This build's number (CFBundleVersion); 0 keeps every release newer.
    @ObservationIgnored private let currentBuild: Int
    /// The appcast Avo writes from GitHub for Sparkle to read (a file URL).
    @ObservationIgnored private let appcastFile = URL(filePath: NSTemporaryDirectory())
        .appending(path: "avo-update-appcast.xml")

    override init() {
        currentBuild = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).flatMap(Int.init) ?? 0
        readiness = Self.signedForUpdates() ? .ready(feed: GitHubUpdateFeed.releasesURL()) : .noFeed
        super.init()
        // feedURLString must always name a real file, so Sparkle has a feed
        // before the first fetch: an empty one reads as "up to date".
        try? GitHubUpdateFeed.emptyAppcast().write(to: appcastFile, atomically: true, encoding: .utf8)
        guard case .ready = readiness else {
            logger.notice("updates are off: this build is not Developer ID signed")
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        do {
            try controller.updater.start()
            logger.notice("updates check \(GitHubUpdateFeed.repository, privacy: .public) on GitHub")
        } catch {
            logger.error("the updater did not start: \(error.localizedDescription, privacy: .public)")
        }
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh(); self?.scheduleAutomatic() }
            },
        ]
        refresh()
        scheduleAutomatic()
    }

    /// Avo › Check for Updates…, Settings › About and the menu bar item's:
    /// reads GitHub, then lets Sparkle show and install whatever is newer.
    func checkForUpdates() {
        Task {
            await refreshFeed()
            controller?.checkForUpdates(nil)
        }
    }

    func setAutomaticallyChecks(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
        refresh()
        scheduleAutomatic()
    }

    func refresh() {
        guard let updater = controller?.updater else { return }
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecks = updater.automaticallyChecksForUpdates
        if let last = updater.lastUpdateCheckDate { lastCheck = last }
    }

    /// Writes the appcast from GitHub's latest Avo release (any build), so
    /// Sparkle, reading it next, compares that build with this one. An empty
    /// feed stays when GitHub has no Avo DMG or could not be reached, so a
    /// check then says "up to date" rather than failing.
    private func refreshFeed() async {
        guard let releases = await fetchReleases() else { return }
        let latest = releases.compactMap(GitHubUpdateFeed.candidate(for:)).max { $0.build < $1.build }
        let xml = latest.map { GitHubUpdateFeed.appcast(for: $0) } ?? GitHubUpdateFeed.emptyAppcast()
        try? xml.write(to: appcastFile, atomically: true, encoding: .utf8)
        lastCheck = Date()
    }

    private func fetchReleases() async -> [GitHubUpdateFeed.Release]? {
        var request = URLRequest(url: GitHubUpdateFeed.releasesURL())
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Avo/\(currentBuild)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                logger.error("GitHub releases: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([GitHubUpdateFeed.Release].self, from: data)
        } catch {
            logger.error("GitHub releases: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Automatic checks (Sparkle's own scheduler reads a static feed; the
    // feed here is built on each check, so Avo times the checks itself).

    private func scheduleAutomatic() {
        automaticTimer?.invalidate()
        automaticTimer = nil
        guard case .ready = readiness, automaticallyChecks else { return }
        automaticTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.automaticCheck() }
        }
        // Once a little after launch, so it is not in the way of starting up.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            await self?.automaticCheck()
        }
    }

    private func automaticCheck() async {
        await refreshFeed()
        guard let releases = await fetchReleases(),
              GitHubUpdateFeed.update(in: releases, currentBuild: currentBuild) != nil else { return }
        // Sparkle shows its window only when the feed it reads has a newer build.
        controller?.updater.checkForUpdatesInBackground()
    }

    /// A Developer ID signature: Sparkle checks a download against the running
    /// app's, so without one (a local, ad hoc build) it could not trust an
    /// update. The leaf certificate of a Developer ID app is named
    /// "Developer ID Application: …".
    private static func signedForUpdates() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first else {
            return false
        }
        var common: CFString?
        guard SecCertificateCopyCommonName(leaf, &common) == errSecSuccess, let name = common as String? else { return false }
        return name.hasPrefix("Developer ID Application:")
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    /// The appcast Avo built from GitHub (`refreshFeed`), as a file URL.
    func feedURLString(for updater: SPUUpdater) -> String? {
        guard case .ready = readiness else { return nil }
        return appcastFile.absoluteString
    }

    /// Before Install and Relaunch: a running Android is stopped first if the
    /// player says so (the update swaps the code under it otherwise; it goes on
    /// running the old build until it stops, then the daemon restarts on the
    /// new one).
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard let model, model.status.state.holdsAndroid else { return false }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Stop Android before installing Avo \(item.displayVersionString)?")
        alert.informativeText = String(localized: "Android and its app windows run on the version of Avo you have now. Stop Android first to install cleanly (save your progress in open games), or install now and restart Android later: until then it keeps running as it is.")
        alert.addButton(withTitle: String(localized: "Stop Android and Install"))
        alert.addButton(withTitle: String(localized: "Install Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                if await model.stopAndroidForUpdate() {
                    installHandler()
                } else {
                    self.logger.error("Android did not stop for the update; it installs when Avo quits")
                }
            }
        case .alertSecondButtonReturn:
            installHandler()
        default:
            logger.notice("update \(item.displayVersionString, privacy: .public) waits for Avo to quit")
        }
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        refresh()
    }
}
