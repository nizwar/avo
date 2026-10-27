import AppKit
import AvoKit
import os
import Security
import Sparkle

/// Avo's own updates, with Sparkle 2. The feed (`SUFeedURL`) is the
/// `appcast.xml` of Avo's latest GitHub release,
/// https://github.com/nizwar/avo/releases/latest/download/appcast.xml: each
/// release carries one next to its DMG, made by Sparkle's generate_appcast,
/// which signs the DMG with Avo's update key (`SUPublicEDKey`;
/// scripts/build-dmg.sh). GitHub's "latest" is the newest release that is not
/// a pre-release, so a beta reaches only those who download it. Sparkle checks
/// the feed by itself once a day, and installs a DMG whose signature is valid
/// for the key or whose app has the running app's Developer ID
/// (docs/releasing.md). Updates run only in a Developer ID build
/// (`signedForUpdates`), not a local one.
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
    /// Whether this build can update itself: an https feed and an EdDSA key
    /// in Info.plist, and a Developer ID signature.
    let readiness: AppUpdate.Readiness
    private(set) var canCheckForUpdates = false
    /// Settings › About's switch (Sparkle keeps it in Avo's defaults).
    private(set) var automaticallyChecks = false
    private(set) var lastCheck: Date?
    /// Asked whether Android runs, and to stop it, before an install.
    @ObservationIgnored weak var model: ControlPanelModel?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Updates")

    override init() {
        let info = Bundle.main.infoDictionary
        let feed = AppUpdate.readiness(feedURL: info?["SUFeedURL"] as? String, publicKey: info?["SUPublicEDKey"] as? String)
        let signed = Self.signedForUpdates()
        readiness = signed ? feed : .noFeed
        super.init()
        guard case .ready(let url) = readiness else {
            logger.notice("updates are off: \(signed ? "Info.plist has no usable feed or key" : "this build is not Developer ID signed", privacy: .public)")
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        do {
            try controller.updater.start()
            logger.notice("updates check \(url.absoluteString, privacy: .public)")
        } catch {
            logger.error("the updater did not start: \(error.localizedDescription, privacy: .public)")
        }
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
        ]
        refresh()
    }

    /// Avo › Check for Updates…, Settings › About and the menu bar item's:
    /// Sparkle reads the feed and shows whatever is newer.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecks(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
        refresh()
    }

    func refresh() {
        guard let updater = controller?.updater else { return }
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecks = updater.automaticallyChecksForUpdates
        if let last = updater.lastUpdateCheckDate { lastCheck = last }
    }

    /// A Developer ID signature: a local, ad hoc build does not update itself
    /// (it would be replaced by a release). The leaf certificate of a
    /// Developer ID app is named "Developer ID Application: …".
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
        let version = item.displayVersionString
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                guard let problem = await model.stopAndroidForUpdate() else {
                    installHandler()
                    return
                }
                self.logger.error("Android did not stop for the update: \(problem, privacy: .public)")
                // Said, not only logged: the player waits for the install.
                let failed = NSAlert()
                failed.alertStyle = .warning
                failed.messageText = String(localized: "Android did not stop")
                failed.informativeText = String(localized: "\(problem) Avo \(version) installs when you quit Avo, or now with Install Now: Android goes on running the version of Avo you have until it restarts.")
                failed.addButton(withTitle: String(localized: "Install Now"))
                failed.addButton(withTitle: String(localized: "Later"))
                NSApp.activate()
                if failed.runModal() == .alertFirstButtonReturn { installHandler() }
            }
        case .alertSecondButtonReturn:
            installHandler()
        default:
            logger.notice("update \(version, privacy: .public) waits for Avo to quit")
        }
        return true
    }

    /// A check that failed says why in the log (Report a Problem's diagnostics):
    /// "no update" is not a failure.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        refresh()
        if let error = error as NSError?, !(error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue)) {
            logger.error("update check: \(error.localizedDescription, privacy: .public) (\(error.domain, privacy: .public) \(error.code))")
        }
    }
}
