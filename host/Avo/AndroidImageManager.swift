import AppKit
import AvoKit
import AvoPackages
import Observation
import os

/// The Android images on this Mac and which one Android starts with, the
/// versions Avo can download, and the download or import running now; for
/// the Setup Assistant and Settings › System › Android version.
///
/// The Control Panel downloads and installs images itself (the daemon never
/// reads files the user picks, and a download needs no running Android); the
/// daemon finds the chosen image at its next start (`CuttlefishImage.prepareStart`).
@MainActor
@Observable
final class AndroidImageManager {
    enum Catalog: Equatable {
        case idle
        case loading
        case loaded([AndroidImageOffer])
        case failed(String)
    }

    /// What to do once an image is installed.
    enum AfterInstall: Equatable {
        case nothing
        /// Android starts with it from its next start.
        case use
        /// Use it with Android data from another place (each Android version
        /// keeps its own data: AndroidDataSheet).
        case useWithData(StorageChangeRequest)
    }

    private(set) var catalog: Catalog = .idle
    /// Android versions older than `minimumSDK` (Older Versions), listed
    /// only when asked for.
    private(set) var olderCatalog: Catalog = .idle
    private(set) var installed: [AndroidImageSummary] = []
    /// What Android starts with next.
    private(set) var current: AndroidImageSummary?
    /// The image chosen before it, kept to go back to.
    private(set) var previous: AndroidImageSummary?
    /// What the last start used (nil before the first start with this Avo).
    private(set) var booted: AndroidImageBootRecord?
    /// The newest Android that used the data disk; nil without data.
    private(set) var dataRelease: AndroidRelease?
    /// The developer setting `AvoCuttlefishImages` (the daemon's defaults) names the image.
    private(set) var overridden = false
    private(set) var job: AndroidImageJob?
    private(set) var after: AfterInstall = .nothing
    /// The last thing that went wrong outside a job (choosing, removing).
    var problem: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    /// Run once the job's image is chosen (Google services follow a switch).
    @ObservationIgnored private var whenUsed: (@MainActor () -> Void)?
    /// Runs when a downloaded or imported image is set to be used, with the
    /// job that brought it (nil: it was on this Mac already). AppDelegate:
    /// the Setup Assistant's start after the download.
    @ObservationIgnored var imageUsed: (@MainActor (_ job: UUID?) -> Void)?
    @ObservationIgnored private let source = AndroidBuildSource.current()
    @ObservationIgnored private let paths = AvoPaths()
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "AndroidImages")
    /// Moves Android to the data at another place (the daemon's storage
    /// change), for a version that uses its own data.
    @ObservationIgnored var changeData: (@MainActor (StorageChangeRequest) async throws -> Void)?

    var store: AndroidImageStore { AndroidImageStore(paths: paths) }
    var minimumSDK: Int { source.minimumSDK }

    /// Previews and screenshots: no disk, no network.
    @ObservationIgnored private let preview: Bool

    init(preview: Bool = false) {
        self.preview = preview
        guard !preview else { return }
        store.removeStaging()
        refresh()
    }

    // MARK: State

    /// Reads the images on disk again (cheap: manifests and a few headers).
    func refresh() {
        guard !preview else { return }
        let override = Self.daemonOverride
        let store = self.store
        overridden = override != nil
        installed = store.installed(override: override)
        current = store.imageForBoot(override: override)
        previous = store.previousImage().flatMap { $0.path == current?.path ? nil : $0 }
        booted = store.bootRecord()
        dataRelease = store.dataRecord()?.release
    }

    /// The daemon's `AvoCuttlefishImages` (a developer setting).
    static var daemonOverride: String? {
        UserDefaults(suiteName: AvoIdentifiers.daemonBundleID)?.string(forKey: "AvoCuttlefishImages").flatMap { $0.isEmpty ? nil : $0 }
    }

    /// No image Android could start with.
    var needsImage: Bool { current == nil }

    /// Android runs with another image than the one chosen: a restart switches.
    func needsRestart(running: Bool) -> Bool {
        guard running, let booted, let current else { return false }
        return booted.path != current.path
    }

    var offers: [AndroidImageOffer] {
        if case .loaded(let offers) = catalog { return offers }
        return []
    }

    var olderOffers: [AndroidImageOffer] {
        if case .loaded(let offers) = olderCatalog { return offers }
        return []
    }

    /// The oldest Android an image may be (Older Versions included).
    var oldestSDK: Int { min(minimumSDK, AndroidImageCatalog.oldestSDK) }

    /// The installed image of an offer's build, if any.
    func installedImage(for offer: AndroidImageOffer) -> AndroidImageSummary? {
        installed.first { $0.build == offer.build && $0.release?.version == offer.release.version }
    }

    func change(to release: AndroidRelease?, path: String?) -> AndroidImageChange {
        store.change(to: release, path: path, current: current)
    }

    /// Google apps were installed on the Android that ran last, and would not match `release`.
    func googleAppsMismatch(_ release: AndroidRelease?, googleAppsInstalled: Bool) -> Bool {
        guard googleAppsInstalled, let release, let now = booted?.release ?? current?.release ?? dataRelease else { return false }
        return now.version != release.version
    }

    // MARK: Catalog

    func loadCatalog(force: Bool = false) async {
        guard !preview else { return }
        if case .loading = catalog { return }
        if !force, case .loaded = catalog { return }
        catalog = .loading
        do {
            let offers = try await AndroidImageCatalog(source: source).offers()
            catalog = .loaded(offers)
            restorePausedDownload(offers)
        } catch is CancellationError {
            catalog = .idle
        } catch {
            logger.error("catalog: \(error.localizedDescription, privacy: .public)")
            catalog = .failed(error.localizedDescription)
        }
    }

    func loadOlderCatalog(force: Bool = false) async {
        guard !preview else { return }
        if case .loading = olderCatalog { return }
        if !force, case .loaded = olderCatalog { return }
        olderCatalog = .loading
        do {
            olderCatalog = .loaded(try await AndroidImageCatalog(source: source).olderOffers())
        } catch is CancellationError {
            olderCatalog = .idle
        } catch {
            logger.error("older catalog: \(error.localizedDescription, privacy: .public)")
            olderCatalog = .failed(error.localizedDescription)
        }
    }

    /// A download Avo quit in the middle of comes back paused, to resume.
    private func restorePausedDownload(_ offers: [AndroidImageOffer]) {
        guard job == nil else { return }
        let installer = self.installer
        for offer in offers where installedImage(for: offer) == nil {
            let received = installer.downloadedBytes(offer)
            guard received > 0, received <= offer.downloadSize else { continue }
            job = AndroidImageJob(kind: .download(offer), phase: .paused(DownloadProgress(received: received, total: offer.downloadSize)))
            return
        }
    }

    // MARK: Jobs

    var installer: AndroidImageInstaller {
        AndroidImageInstaller(store: store, client: AndroidBuildClient(source: source))
    }

    /// Downloads `offer` (or continues an earlier download of it), then
    /// `after`; `whenUsed` runs once Android is set to start with it.
    func download(_ offer: AndroidImageOffer, then after: AfterInstall, whenUsed: (@MainActor () -> Void)? = nil) {
        guard job?.isRunning != true else { return }
        self.whenUsed = whenUsed
        if let image = installedImage(for: offer) {
            Task { await self.finish(image, after: after, job: nil) }
            return
        }
        self.after = after
        job = AndroidImageJob(kind: .download(offer))
        start()
    }

    /// Checks a file or folder the user chose; nil (and `problem`) if it will not do.
    func inspect(_ url: URL) -> AndroidImageCandidate? {
        do {
            return try installer.inspect(url, minimumSDK: oldestSDK)
        } catch {
            problem = error.localizedDescription
            return nil
        }
    }

    /// Installs a checked file or folder, then `after`.
    func importImage(_ candidate: AndroidImageCandidate, then after: AfterInstall) {
        guard job?.isRunning != true else { return }
        self.after = after
        whenUsed = nil
        job = AndroidImageJob(kind: .importing(candidate.name))
        let installer = self.installer
        let id = job!.id
        task = Task {
            do {
                let image = try await installer.importImage(candidate) { event in Task { @MainActor in self.handle(event, job: id) } }
                await self.installed(image, job: id)
            } catch is CancellationError {
            } catch {
                self.handle(.failed(message: error.localizedDescription, resumable: false), job: id)
            }
        }
    }

    /// The download or import running now is used once installed.
    func useWhenInstalled() {
        guard job?.isRunning == true || job?.canResume == true, after == .nothing else { return }
        after = .use
    }

    func pause() {
        guard var job, job.apply(.pause) else { return }
        self.job = job
        task?.cancel()
    }

    func resume() {
        guard var job, job.apply(.resume) else { return }
        self.job = job
        start()
    }

    func cancel() {
        guard var job, job.apply(.cancel) else { return }
        self.job = job
        after = .nothing
        whenUsed = nil
        task?.cancel()
        if let offer = job.offer {
            let installer = self.installer
            Task.detached { installer.discardDownload(offer) }
        }
    }

    /// Forgets a finished, failed or cancelled job.
    func dismissJob() {
        guard let job, !job.isRunning, !job.canResume || job.isDone else { return }
        self.job = nil
    }

    private func start() {
        guard let job, let offer = job.offer else { return }
        let installer = self.installer
        let id = job.id
        task = Task {
            do {
                let image = try await installer.download(offer) { event in Task { @MainActor in self.handle(event, job: id) } }
                await self.installed(image, job: id)
            } catch is CancellationError {
                // Pause or Cancel: the phase says which.
            } catch {
                // Offline, a server error, a full disk while unpacking: Resume tries again
                // (from what arrived). A damaged download starts over.
                self.handle(.failed(message: error.localizedDescription, resumable: !Self.isPermanent(error)), job: id)
            }
        }
    }

    private static func isPermanent(_ error: any Error) -> Bool {
        switch error as? AndroidImageError {
        case .checksumMismatch?, .notAnImage?: true
        default: false
        }
    }

    private func handle(_ event: AndroidImageJob.Event, job id: UUID) {
        guard var job, job.id == id, job.apply(event) else { return }
        self.job = job
    }

    private func installed(_ image: AndroidImageSummary, job id: UUID) async {
        guard job?.id == id else { return }
        handle(.finished(path: image.path), job: id)
        refresh()
        await finish(image, after: after, job: id)
    }

    private func finish(_ image: AndroidImageSummary, after: AfterInstall, job: UUID?) async {
        let whenUsed = self.whenUsed
        self.whenUsed = nil
        self.after = .nothing
        switch after {
        case .nothing:
            return
        case .use:
            guard use(image) else { return }
            whenUsed?()
            imageUsed?(job)
        case .useWithData(let request):
            guard await use(image, data: request) else { return }
            whenUsed?()
            imageUsed?(job)
        }
    }

    // MARK: Choosing

    /// Android starts with `image` from its next start.
    @discardableResult
    func use(_ image: AndroidImageSummary) -> Bool {
        defer { refresh() }
        do {
            try store.select(image)
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }

    /// Android starts with `image` and the data `request` points at. The
    /// image is chosen first, so no start can ever pair the other Android
    /// with that data (an older Android's data would be upgraded); when the
    /// data cannot change, the image chosen before comes back.
    func use(_ image: AndroidImageSummary, data request: StorageChangeRequest?) async -> Bool {
        let before = current
        guard use(image) else { return false }
        guard let request else { return true }
        do {
            guard let changeData else { throw AvoError.daemonUnreachable(String(localized: "not connected")) }
            try await changeData(request)
            refresh()
            return true
        } catch {
            if let before { use(before) }
            problem = error.localizedDescription
            return false
        }
    }

    func remove(_ image: AndroidImageSummary) {
        do {
            try store.remove(image)
        } catch {
            problem = error.localizedDescription
        }
        refresh()
    }
}

// MARK: - Formatting

extension AndroidImageSummary {
    /// `Android 17 · build 16373615`.
    var title: String {
        guard let build else { return name }
        return String(localized: "\(name) · build \(build)")
    }
}

extension AndroidRelease {
    /// `June 2026`, from the security patch.
    var patchMonth: String? {
        guard let securityPatch, let date = try? Date(securityPatch + "T00:00:00Z", strategy: .iso8601) else { return nil }
        return date.formatted(.dateTime.month(.wide).year().locale(Locale.current))
    }
}
