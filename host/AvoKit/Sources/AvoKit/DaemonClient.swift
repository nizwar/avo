import Foundation
import IOSurface
import os

/// Async client for the Runtime Daemon, used by the Control Panel and App Shims.
///
/// Events pushed by the daemon are delivered on `events`; frames go to the
/// optional `FrameReceiver` (App Shims only).
public final class DaemonClient: @unchecked Sendable {
    public protocol FrameReceiver: AnyObject, Sendable {
        func setSurfaces(_ displayID: UInt32, surfaces: [IOSurface])
        func present(_ displayID: UInt32, surfaceIndex: Int, sequence: UInt64)
    }

    public let events: AsyncStream<DaemonEvent>
    private let continuation: AsyncStream<DaemonEvent>.Continuation
    private let connection: NSXPCConnection
    private let receiver: Receiver
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "DaemonClient")

    public init(role: ClientHello.Role, version: String, frameReceiver: (any FrameReceiver)? = nil,
                machService: String = AvoIdentifiers.daemonMachService) {
        (events, continuation) = AsyncStream.makeStream(of: DaemonEvent.self, bufferingPolicy: .bufferingNewest(256))
        receiver = Receiver(events: continuation, frames: frameReceiver)
        let connection = NSXPCConnection(machServiceName: machService, options: [])
        self.connection = connection
        connection.remoteObjectInterface = AvoXPC.daemonInterface()
        connection.exportedInterface = AvoXPC.clientInterface()
        connection.exportedObject = receiver
        let continuation = self.continuation
        connection.invalidationHandler = { continuation.finish() }
        // The daemon exited. XPC would quietly reconnect to its next instance,
        // which has never heard this client's hello (every call would be
        // refused): end the session instead, so the owner starts a new one.
        connection.interruptionHandler = { [logger, weak connection] in
            logger.notice("daemon connection interrupted")
            connection?.invalidate()
        }
        connection.resume()
        self.role = role
        self.version = version
    }

    private let role: ClientHello.Role
    private let version: String

    deinit {
        connection.invalidate()
    }

    public func invalidate() {
        connection.invalidate()
    }

    // MARK: Calls

    public func hello() async throws -> DaemonHello {
        let request = AvoXPC.encode(ClientHello(role: role, version: version))
        let data: Data = try await call { proxy, done in
            proxy.hello(request) { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode(DaemonHello.self, from: data)
    }

    public func status() async throws -> VMStatus {
        let data: Data = try await call { proxy, done in proxy.status { done(.success($0)) } }
        return try AvoXPC.decode(VMStatus.self, from: data)
    }

    public func startVM() async throws { try await voidCall { $0.startVM(reply: $1) } }
    public func stopVM() async throws { try await voidCall { $0.stopVM(reply: $1) } }
    public func restartVM() async throws { try await voidCall { $0.restartVM(reply: $1) } }
    public func retryGPU() async throws { try await voidCall { $0.retryGPU(reply: $1) } }

    /// The engine's GPU shader cache: where and how big (Control Panel only).
    public func gpuCacheStatus() async throws -> GPUCacheStatus {
        let data: Data = try await call { proxy, done in
            proxy.gpuCacheStatus { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode(GPUCacheStatus.self, from: data)
    }

    /// Graphics › Clear GPU cache (Control Panel only).
    public func clearGPUCache() async throws -> GPUCacheStatus {
        let data: Data = try await call { proxy, done in
            proxy.clearGPUCache { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode(GPUCacheStatus.self, from: data)
    }
    public func takeSnapshot() async throws { try await voidCall { $0.takeSnapshot(reply: $1) } }
    public func resetAndroid() async throws { try await voidCall { $0.resetAndroid(reply: $1) } }

    // MARK: Where Android's data is (Settings › Storage › Location)

    public func storageLocation() async throws -> StorageLocationStatus {
        let data: Data = try await call { proxy, done in
            proxy.storageLocation { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode(StorageLocationStatus.self, from: data)
    }

    /// What the daemon finds at `path` (nil: Avo's own storage) and which
    /// choices it allows. The daemon reads the folder itself: on a removable
    /// volume macOS may ask first whether Avo may.
    public func inspectStorageLocation(_ path: String?) async throws -> StorageCandidate {
        let data: Data = try await call { proxy, done in
            proxy.inspectStorageLocation(path ?? "") { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode(StorageCandidate.self, from: data)
    }

    /// Returns once Android's data is in its new place (a move copies and
    /// checks every byte first); progress arrives as `.storageProgress`.
    public func changeStorageLocation(_ request: StorageChangeRequest) async throws {
        let payload = AvoXPC.encode(request)
        try await voidCall { $0.changeStorageLocation(payload, reply: $1) }
    }

    public func cancelStorageChange() async throws { try await voidCall { $0.cancelStorageChange(reply: $1) } }
    public func removeInternalStorageCopy() async throws { try await voidCall { $0.removeInternalStorageCopy(reply: $1) } }

    /// What the daemon finds at a folder to share with Android (Settings ›
    /// Storage › Shared Folder); macOS may ask first whether Avo may read it.
    public func inspectSharedFolder(_ path: String) async throws -> SharedFolderStatus {
        let data: Data = try await call { proxy, done in
            proxy.inspectSharedFolder(path) { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode(SharedFolderStatus.self, from: data)
    }

    public func configuration() async throws -> ConfigurationSnapshot {
        let data: Data = try await call { proxy, done in proxy.configuration { done(.success($0)) } }
        return try AvoXPC.decode(ConfigurationSnapshot.self, from: data)
    }

    public func updateConfiguration(_ config: VMConfig) async throws -> ConfigUpdateResult {
        let payload = AvoXPC.encode(config)
        let data: Data = try await call { proxy, done in
            proxy.updateConfiguration(payload) { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode(ConfigUpdateResult.self, from: data)
    }

    /// Sets one app's graphics override (nil or empty removes it). Only this
    /// override is validated: its issues come back in the result, and an
    /// error issue means nothing was saved.
    public func setAppGraphics(_ override: AppGraphicsOverride?, for package: String) async throws -> ConfigUpdateResult {
        let payload = override.map { AvoXPC.encode($0) }
        let data: Data = try await call { proxy, done in
            proxy.setAppGraphics(package: package, override: payload) { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode(ConfigUpdateResult.self, from: data)
    }

    /// Sets Android's frame rate cap, for every app (30, or 60 to 120:
    /// `VMConfig.isSupportedFPS`; another value comes back as an error issue
    /// and nothing is saved).
    public func setFrameRateLimit(_ fps: Int) async throws -> ConfigUpdateResult {
        let data: Data = try await call { proxy, done in
            proxy.setFrameRateLimit(fps) { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode(ConfigUpdateResult.self, from: data)
    }

    public func apps() async throws -> [AppRecord] {
        let data: Data = try await call { proxy, done in proxy.apps { done(.success($0)) } }
        return try AvoXPC.decode([AppRecord].self, from: data)
    }

    public func icon(for package: String) async throws -> Data? {
        try await call { proxy, done in proxy.icon(forPackage: package) { done(.success($0)) } }
    }

    /// Installs the package at `request.path`. This process opens the file and
    /// hands the descriptor to the daemon, so files the user chose in
    /// Downloads or Documents work without extra permissions.
    public func install(_ request: InstallRequest) async throws {
        let payload = AvoXPC.encode(request)
        let file = try FileHandle(forReadingFrom: URL(filePath: request.path))
        defer { try? file.close() }
        try await voidCall { $0.install(payload, file: file, reply: $1) }
    }

    public func uninstall(_ package: String) async throws { try await voidCall { $0.uninstall(package: package, reply: $1) } }
    public func forceStop(_ package: String) async throws { try await voidCall { $0.forceStop(package: package, reply: $1) } }
    public func deleteAppData(_ package: String) async throws { try await voidCall { $0.deleteAppData(package: package, reply: $1) } }
    public func openNotification(_ key: String) async throws { try await voidCall { $0.openNotification(key: key, reply: $1) } }
    public func clearNotifications() async throws { try await voidCall { $0.clearNotifications(reply: $1) } }
    public func dismissNotifications(_ keys: [String]) async throws {
        let payload = AvoXPC.encode(keys)
        try await voidCall { $0.dismissNotifications(payload, reply: $1) }
    }

    /// Whether macOS shows Avo's notifications, asked now.
    public func notificationPermission() async throws -> MacNotificationPermission {
        let data: Data = try await call { proxy, done in
            proxy.notificationPermission { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode(MacNotificationPermission.self, from: data)
    }

    /// Asks macOS to let Avo show notifications (its alert, while it has no
    /// answer yet). Returns at once with macOS's own answer, or `asking`
    /// while the alert waits; the user's answer arrives as an event.
    public func requestNotificationPermission() async throws -> MacNotificationPermission {
        let data: Data = try await call { proxy, done in
            proxy.requestNotificationPermission { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode(MacNotificationPermission.self, from: data)
    }

    /// Unlocks Android with its screen lock's credential (`VMStatus.screenLock`;
    /// a pattern as its dots, "1235"). Returns once Android is unlocked; throws
    /// `AvoError.screenLockRejected` for a wrong credential.
    public func unlockAndroid(credential: String) async throws {
        try await voidCall { $0.unlockAndroid(credential: credential, reply: $1) }
    }

    // MARK: Fingerprints (Settings › Fingerprints, a window's fingerprint menu)

    /// Avo's fingers and what Android does with them; `refresh` asks Android
    /// now instead of using what the daemon learned in the last few seconds.
    public func fingerprints(refresh: Bool = false) async throws -> FingerprintStatus {
        let data: Data = try await call { proxy, done in
            proxy.fingerprints(refresh: refresh) { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode(FingerprintStatus.self, from: data)
    }

    /// Registers a finger in Avo (Android's Settings adds it when touched
    /// with it); throws `AvoError.fingerprint` when the name does not do.
    public func addFingerprint(named name: String) async throws -> Fingerprint {
        let data: Data = try await call { proxy, done in
            proxy.addFingerprint(name: name) { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode(Fingerprint.self, from: data)
    }

    public func renameFingerprint(_ id: Int, to name: String) async throws {
        try await voidCall { $0.renameFingerprint(id, name: name, reply: $1) }
    }

    public func removeFingerprint(_ id: Int) async throws {
        try await voidCall { $0.removeFingerprint(id, reply: $1) }
    }

    /// Touches the sensor with finger `id`; nil touches with a finger Avo
    /// does not know, which Android does not recognize. While Android's
    /// Settings adds a fingerprint, the touch adds finger `id`.
    public func touchFingerprint(_ id: Int?) async throws -> FingerprintTouchResult {
        let data: Data = try await call { proxy, done in
            proxy.touchFingerprint(id ?? 0) { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode(FingerprintTouchResult.self, from: data)
    }

    public func cancelFingerprintRequest() async throws {
        try await voidCall { $0.cancelFingerprintRequest(reply: $1) }
    }

    // MARK: Widgets

    public func widgetProviders() async throws -> [WidgetProvider] {
        let data: Data = try await call { proxy, done in
            proxy.widgetProviders { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode([WidgetProvider].self, from: data)
    }

    public func placedWidgets() async throws -> [PlacedWidget] {
        let data: Data = try await call { proxy, done in
            proxy.placedWidgets { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode([PlacedWidget].self, from: data)
    }

    public func addWidget(_ provider: String) async throws -> PlacedWidget {
        let data: Data = try await call { proxy, done in
            proxy.addWidget(provider) { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode(PlacedWidget.self, from: data)
    }

    public func removeWidget(_ id: String) async throws {
        try await voidCall { $0.removeWidget(id, reply: $1) }
    }

    public func lockAndroidForFingerprints() async throws {
        try await voidCall { $0.lockAndroidForFingerprints(reply: $1) }
    }

    public func permissions(for package: String) async throws -> [AppPermission] {
        let data: Data = try await call { proxy, done in
            proxy.permissions(package: package) { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode([AppPermission].self, from: data)
    }

    public func setPermission(_ permission: String, granted: Bool, for package: String) async throws {
        try await voidCall { $0.setPermission(package: package, permission: permission, granted: granted, reply: $1) }
    }

    public func recreateShortcuts(for package: String? = nil) async throws {
        try await voidCall { $0.recreateShortcuts(package: package, reply: $1) }
    }

    /// How much each app was used (the Library's statistics).
    public func appUsage() async throws -> [AppUsage] {
        let data: Data = try await call { proxy, done in
            proxy.appUsage { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode([AppUsage].self, from: data)
    }

    // MARK: System Status

    /// What Android and its apps use now; `watch`: also send
    /// `.systemActivity` every 2 seconds until called with false.
    public func systemActivity(watch: Bool) async throws -> SystemActivity {
        let data: Data = try await call { proxy, done in
            proxy.systemActivity(watch: watch) { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode(SystemActivity.self, from: data)
    }

    // MARK: Google apps

    public func googleAppsStatus() async throws -> GoogleAppsStatus {
        let data: Data = try await call { proxy, done in
            proxy.googleAppsStatus { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode(GoogleAppsStatus.self, from: data)
    }

    /// Returns when Google apps are installed (or throws why not). A `.local`
    /// source must already be in `AvoPaths.googleAppsCache`: the daemon does
    /// not read the user's folders itself.
    public func installGoogleApps(_ request: GoogleAppsInstallRequest) async throws {
        let payload = AvoXPC.encode(request)
        try await voidCall { $0.installGoogleApps(payload, reply: $1) }
    }

    /// Stops the install `id` (whichever runs, when nil) while it can still stop.
    public func cancelGoogleApps(id: UUID? = nil) async throws {
        let id = id?.uuidString ?? ""
        try await voidCall { $0.cancelGoogleApps(id, reply: $1) }
    }

    /// Returns when Google apps are gone (or throws why not); progress
    /// arrives as `DaemonEvent.googleAppsProgress` for `id`.
    public func removeGoogleApps(id: UUID) async throws {
        let id = id.uuidString
        try await voidCall { $0.removeGoogleApps(id, reply: $1) }
    }

    // MARK: Location (an app window's Location panel)

    /// What Android's GPS reports, with the route's points; `watch`: also
    /// send `.location` events at every change until called with false.
    public func location(watch: Bool) async throws -> LocationStatus {
        let data: Data = try await call { proxy, done in
            proxy.location(watch: watch) { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode(LocationStatus.self, from: data)
    }

    @discardableResult
    public func changeLocation(_ request: LocationRequest) async throws -> LocationStatus {
        let payload = AvoXPC.encode(request)
        let data: Data = try await call { proxy, done in
            proxy.changeLocation(payload) { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode(LocationStatus.self, from: data)
    }

    public func openDisplay(_ request: OpenDisplayRequest) async throws -> UInt32 {
        let payload = AvoXPC.encode(request)
        let data: Data = try await call { proxy, done in
            proxy.openDisplay(payload) { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode(OpenDisplayReply.self, from: data).displayID
    }

    public func shareFiles(_ urls: [URL], with displayID: UInt32) async throws {
        let files = try urls.map { try FileHandle(forReadingFrom: $0) }
        defer { for file in files { try? file.close() } }
        let names = urls.map(\.lastPathComponent)
        try await voidCall { $0.shareFiles(displayID, files: files, names: names, reply: $1) }
    }

    /// Resizes a display and returns once Android has the newest size and
    /// the app is back on the display (a resize re-plugs it), so the window
    /// knows when frames of the new size are coming.
    public func resizeDisplayAndWait(_ displayID: UInt32, width: UInt32, height: UInt32, dpi: UInt32) async throws {
        try await voidCall { $0.resizeDisplay(displayID, width: width, height: height, dpi: dpi, reply: $1) }
    }

    // Fire-and-forget calls used on the input and window paths.

    public func closeDisplay(_ displayID: UInt32) {
        proxy()?.closeDisplay(displayID)
    }

    public func setDisplayVisible(_ displayID: UInt32, visible: Bool) {
        proxy()?.setDisplayVisible(displayID, visible: visible)
    }

    public func focusDisplay(_ displayID: UInt32) {
        proxy()?.focusDisplay(displayID)
    }

    /// Sends one Input channel record (already encoded with `InputWire`).
    public func sendInput(_ record: Data) {
        proxy()?.sendInput(record)
    }

    // MARK: Plumbing

    private func proxy() -> AvoDaemonXPC? {
        connection.remoteObjectProxyWithErrorHandler { [logger] error in
            logger.error("daemon call failed: \(error.localizedDescription, privacy: .public)")
        } as? AvoDaemonXPC
    }

    private static func result(_ data: Data?, _ error: NSError?) -> Result<Data, AvoError> {
        if let error { return .failure(AvoXPC.avoError(error)) }
        guard let data else { return .failure(.internalError("empty reply from daemon")) }
        return .success(data)
    }

    private func call<T: Sendable>(_ body: (AvoDaemonXPC, @escaping @Sendable (Result<T, AvoError>) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(with: .failure(AvoError.daemonUnreachable(error.localizedDescription)))
            }
            guard let daemon = proxy as? AvoDaemonXPC else {
                once.resume(with: .failure(AvoError.internalError("unexpected proxy type")))
                return
            }
            body(daemon) { result in once.resume(with: result.mapError { $0 as any Error }) }
        }
    }

    private func voidCall(_ body: (AvoDaemonXPC, @escaping @Sendable (NSError?) -> Void) -> Void) async throws {
        let _: Bool = try await call { proxy, done in
            body(proxy) { error in done(error.map { .failure(AvoXPC.avoError($0)) } ?? .success(true)) }
        }
    }

    /// Exported object receiving daemon callbacks.
    private final class Receiver: NSObject, AvoClientXPC, Sendable {
        let events: AsyncStream<DaemonEvent>.Continuation
        let frames: (any FrameReceiver)?

        init(events: AsyncStream<DaemonEvent>.Continuation, frames: (any FrameReceiver)?) {
            self.events = events
            self.frames = frames
        }

        func handleEvent(_ event: Data) {
            if let decoded = try? AvoXPC.decode(DaemonEvent.self, from: event) {
                events.yield(decoded)
            }
        }

        func setSurfaces(_ displayID: UInt32, surfaces: [IOSurface]) {
            frames?.setSurfaces(displayID, surfaces: surfaces)
        }

        func present(_ displayID: UInt32, surfaceIndex: Int, sequence: UInt64) {
            frames?.present(displayID, surfaceIndex: surfaceIndex, sequence: sequence)
        }
    }
}

/// Resumes a continuation at most once (XPC may call both the reply and the
/// error handler when a connection dies mid-call).
final class ResumeOnce<T: Sendable>: Sendable {
    private let state: OSAllocatedUnfairLock<CheckedContinuation<T, any Error>?>

    init(_ continuation: CheckedContinuation<T, any Error>) {
        state = OSAllocatedUnfairLock(initialState: continuation)
    }

    func resume(with result: Result<T, any Error>) {
        let continuation = state.withLock { value -> CheckedContinuation<T, any Error>? in
            defer { value = nil }
            return value
        }
        continuation?.resume(with: result)
    }
}
