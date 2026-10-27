import AvoKit
import Foundation
import IOSurface
import os
import Security

/// Who may talk to the daemon (spec: "App Shim berkomunikasi dengan daemon
/// lewat XPC dengan validasi code signature pemanggil").
public enum CallerPolicy: Sendable {
    /// Release builds: Avo's own processes carry this Developer ID team; App
    /// Shims are ad hoc signed and pinned by code directory hash.
    case teamID(String)
    /// Development builds (signed to run locally): Avo's processes must live
    /// inside this app bundle; shims are still pinned by hash.
    case development(appBundle: URL)

    /// What the rest of a connection is held to once its hello passed: the
    /// shim's pinned code directory hash, else Avo's team. Nil for a
    /// development build.
    func requirement(shimHash: String?) -> String? {
        guard case .teamID(let team) = self else { return nil }
        if let shimHash { return "cdhash H\"\(shimHash)\"" }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// Checks the process behind `pid` for `role`. `shimHash` is the pinned
    /// hash for the shim's package.
    func validate(pid: pid_t, role: ClientHello.Role, shimHash: String?) -> Bool {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return false }
        guard SecCodeCheckValidity(code, [], nil) == errSecSuccess else {
            // A development build rebuilt while the caller ran: the running
            // code no longer matches its bundle. The bundle path is all a
            // development build is identified by, so the caller still counts
            // if what is on disk now is validly signed.
            guard case .development = self, role != .engine, Self.onDiskValid(code) else { return false }
            return validateDevelopmentPath(code, role: role)
        }
        switch role {
        case .shim:
            guard let shimHash, let hash = Self.cdhash(code) else { return false }
            return hash == shimHash
        case .controlPanel, .engine:
            switch self {
            case .teamID(let team):
                var requirement: SecRequirement?
                let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
                guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
                      let requirement else { return false }
                return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
            case .development:
                return validateDevelopmentPath(code, role: role)
            }
        }
    }

    /// Development builds: Avo's own processes live inside the app bundle;
    /// shims are checked by hash (their bundles live elsewhere).
    private func validateDevelopmentPath(_ code: SecCode, role: ClientHello.Role) -> Bool {
        guard case .development(let bundle) = self else { return false }
        if case .shim = role { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var url: CFURL?
        guard SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let path = (url as URL?)?.standardizedFileURL.path else {
            return false
        }
        return path.hasPrefix(bundle.standardizedFileURL.path + "/") || path == bundle.standardizedFileURL.path
    }

    private static func onDiskValid(_ code: SecCode) -> Bool {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        return SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess
    }

    static func cdhash(_ code: SecCode) -> String? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any], let unique = info[kSecCodeInfoUnique as String] as? Data else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }
}

/// The daemon's NSXPCListener delegate: one `ClientConnection` per peer.
public final class DaemonService: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    public let core: DaemonCore
    let policy: CallerPolicy
    private let listener: NSXPCListener
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "XPC")

    public init(core: DaemonCore, policy: CallerPolicy, listener: NSXPCListener) {
        self.core = core
        self.policy = policy
        self.listener = listener
        super.init()
        listener.delegate = self
    }

    /// The listener itself has no code requirement: libxpc lets a requirement
    /// be set once, and a shim made after the daemon started must still get
    /// in. Each connection is held to its own once its hello passed (`authorize`).
    public func resume() {
        listener.resume()
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let client = ClientConnection(connection: connection, service: self)
        connection.exportedInterface = AvoXPC.daemonInterface()
        connection.exportedObject = client
        connection.remoteObjectInterface = AvoXPC.clientInterface()
        connection.invalidationHandler = { client.invalidated() }
        connection.resume()
        return true
    }

    func authorize(_ connection: NSXPCConnection, role: ClientHello.Role) async -> Bool {
        let hash: String?
        if case .shim(let package) = role {
            hash = await core.shimHashes()[package]
        } else {
            hash = nil
        }
        let allowed = policy.validate(pid: connection.processIdentifier, role: role, shimHash: hash)
        // Bind the rest of this connection to the process that said hello
        // (not just its pid). Once per connection: a second requirement is an
        // XPC API misuse, and libxpc traps (the daemon dies, Android with it).
        if allowed, let requirement = policy.requirement(shimHash: hash) {
            connection.setCodeSigningRequirement(requirement)
        }
        if !allowed { logger.error("rejected \(String(describing: role), privacy: .public) from pid \(connection.processIdentifier)") }
        return allowed
    }
}

/// The object a single XPC peer talks to; every call is checked against the
/// role the peer declared in `hello`.
final class ClientConnection: NSObject, AvoDaemonXPC, @unchecked Sendable {
    let id = UUID()
    private weak var connection: NSXPCConnection?
    private let service: DaemonService
    private var core: DaemonCore { service.core }

    /// Input records go to the daemon one at a time, in the order the client
    /// sent them. A Task per record could overtake another: a paste waits
    /// for the Mac clipboard, and its key release must not reach Android
    /// first (the key would stay down and repeat).
    private let input = AsyncStream<Data>.makeStream()
    /// A connection says hello once: its code requirement is set then (`authorize`).
    private let helloLock = NSLock()
    private var saidHello = false
    /// Its hello passed: it is registered with the core, and held to its
    /// code requirement. Until then nothing else is answered: a call sent
    /// before the hello finished would escape that requirement (the hello
    /// checks the caller by its pid only), and no client of Avo's sends one.
    private var admitted = false
    /// The connection went (`invalidated`): a hello still being checked
    /// registers nothing for good.
    private var gone = false

    init(connection: NSXPCConnection, service: DaemonService) {
        self.connection = connection
        self.service = service
        super.init()
        let (records, core, id) = (input.stream, service.core, self.id)
        Task { for await record in records { await core.sendInput(record, client: id) } }
    }

    deinit {
        input.continuation.finish()
    }

    private var isAdmitted: Bool { helloLock.withLock { admitted } }

    private func run(_ reply: @escaping @Sendable (NSError?) -> Void, _ body: @escaping @Sendable () async throws -> Void) {
        guard isAdmitted else { return reply(AvoXPC.nsError(AvoError.unauthorizedCaller)) }
        Task {
            do {
                try await body()
                reply(nil)
            } catch {
                reply(AvoXPC.nsError(AvoError.reported(error)))
            }
        }
    }

    private func run(_ reply: @escaping @Sendable (Data?, NSError?) -> Void, _ body: @escaping @Sendable () async throws -> Data) {
        guard isAdmitted else { return reply(nil, AvoXPC.nsError(AvoError.unauthorizedCaller)) }
        answer(reply, body)
    }

    private func answer(_ reply: @escaping @Sendable (Data?, NSError?) -> Void, _ body: @escaping @Sendable () async throws -> Data) {
        Task {
            do {
                reply(try await body(), nil)
            } catch {
                reply(nil, AvoXPC.nsError(AvoError.reported(error)))
            }
        }
    }

    /// The answers without an error to give (status, configuration, apps):
    /// before the hello, nothing a client can read (it fails to decode).
    private func answerAdmitted(_ reply: @escaping @Sendable (Data) -> Void, _ body: @escaping @Sendable () async -> Data) {
        guard isAdmitted else { return reply(Data()) }
        Task { reply(await body()) }
    }

    // MARK: Session

    func hello(_ request: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        answer(reply) { [self] in
            let hello = try AvoXPC.decode(ClientHello.self, from: request)
            let first = helloLock.withLock {
                defer { saidHello = true }
                return !saidHello
            }
            guard first, let connection, await service.authorize(connection, role: hello.role) else { throw AvoError.unauthorizedCaller }
            guard let proxy = connection.remoteObjectProxy as? AvoClientXPC else { throw AvoError.internalError("no client proxy") }
            let answer = await core.register(id, role: hello.role, proxy: ClientProxy(proxy))
            // The client went while it was checked: its disconnect may have
            // come before it was registered, so it goes again now.
            let present = helloLock.withLock { () -> Bool in
                if !gone { admitted = true }
                return !gone
            }
            guard present else {
                await core.disconnect(id)
                throw AvoError.daemonUnreachable("the client went")
            }
            return AvoXPC.encode(answer)
        }
    }

    /// The connection was invalidated: the client quit or crashed.
    func invalidated() {
        helloLock.withLock {
            gone = true
            admitted = false
        }
        let (core, id) = (core, id)
        Task { await core.disconnect(id) }
    }

    // MARK: VM

    func status(reply: @escaping @Sendable (Data) -> Void) {
        answerAdmitted(reply) { [self] in AvoXPC.encode(await core.status()) }
    }

    func startVM(reply: @escaping @Sendable (NSError?) -> Void) { run(reply) { [self] in try await core.startVM(client: id) } }
    func stopVM(reply: @escaping @Sendable (NSError?) -> Void) { run(reply) { [self] in try await core.stopVM(client: id) } }
    func restartVM(reply: @escaping @Sendable (NSError?) -> Void) { run(reply) { [self] in try await core.restartVM(client: id) } }
    func retryGPU(reply: @escaping @Sendable (NSError?) -> Void) { run(reply) { [self] in try await core.retryGPU(client: id) } }
    func gpuCacheStatus(reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in AvoXPC.encode(try await core.gpuCacheStatus(client: id)) }
    }
    func clearGPUCache(reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in AvoXPC.encode(try await core.clearGPUCache(client: id)) }
    }
    func takeSnapshot(reply: @escaping @Sendable (NSError?) -> Void) { run(reply) { [self] in try await core.takeSnapshot(client: id) } }
    func resetAndroid(reply: @escaping @Sendable (NSError?) -> Void) { run(reply) { [self] in try await core.resetAndroid(client: id) } }

    // MARK: Checkpoints

    func checkpoints(reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in AvoXPC.encode(try await core.checkpoints(client: id)) }
    }

    func createCheckpoint(_ name: String, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in AvoXPC.encode(try await core.createCheckpoint(named: name, client: id)) }
    }

    func restoreCheckpoint(_ checkpoint: String, reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in try await core.restoreCheckpoint(try Self.checkpointID(checkpoint), client: id) }
    }

    func deleteCheckpoint(_ checkpoint: String, reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in try await core.deleteCheckpoint(try Self.checkpointID(checkpoint), client: id) }
    }

    private static func checkpointID(_ text: String) throws -> UUID {
        guard let id = UUID(uuidString: text) else { throw CheckpointStore.missing }
        return id
    }

    // MARK: Where Android's data is

    func storageLocation(reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in AvoXPC.encode(try await core.storageLocation(client: id)) }
    }

    func inspectStorageLocation(_ path: String, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in AvoXPC.encode(try await core.inspectStorageLocation(path.isEmpty ? nil : path, client: id)) }
    }

    func changeStorageLocation(_ request: Data, reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in
            try await core.changeStorageLocation(try AvoXPC.decode(StorageChangeRequest.self, from: request), client: id)
        }
    }

    func cancelStorageChange(reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in try await core.cancelStorageChange(client: id) }
    }

    func removeInternalStorageCopy(reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in try await core.removeInternalStorageCopy(client: id) }
    }

    func inspectSharedFolder(_ path: String, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in AvoXPC.encode(try await core.inspectSharedFolder(path, client: id)) }
    }

    // MARK: Configuration

    func configuration(reply: @escaping @Sendable (Data) -> Void) {
        answerAdmitted(reply) { [self] in AvoXPC.encode(await core.configurationSnapshot()) }
    }

    func updateConfiguration(_ config: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in
            let new = try AvoXPC.decode(VMConfig.self, from: config)
            return AvoXPC.encode(try await core.updateConfiguration(new, client: id))
        }
    }

    func setAppGraphics(package: String, override: Data?, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in
            let decoded = try override.map { try AvoXPC.decode(AppGraphicsOverride.self, from: $0) }
            return AvoXPC.encode(try await core.setAppGraphics(package, decoded, client: id))
        }
    }

    func setFrameRateLimit(_ fps: Int, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in AvoXPC.encode(try await core.setFrameRateLimit(fps, client: id)) }
    }

    // MARK: Apps

    func apps(reply: @escaping @Sendable (Data) -> Void) {
        answerAdmitted(reply) { [self] in AvoXPC.encode(await core.apps()) }
    }

    func icon(forPackage package: String, reply: @escaping @Sendable (Data?) -> Void) {
        guard isAdmitted else { return reply(nil) }
        Task { reply(await core.icon(for: package)) }
    }

    func install(_ request: Data, file: FileHandle, reply: @escaping @Sendable (NSError?) -> Void) {
        guard isAdmitted else { return reply(AvoXPC.nsError(AvoError.unauthorizedCaller)) }
        // Own a duplicate: the FileHandle closes its descriptor when released.
        let descriptor = OwnedDescriptor(dup(file.fileDescriptor))
        run(reply) { [self] in
            try await core.install(try AvoXPC.decode(InstallRequest.self, from: request), file: descriptor, client: id)
        }
    }

    func uninstall(package: String, reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in try await core.uninstall(package, client: id) }
    }

    func forceStop(package: String, reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in try await core.forceStop(package, client: id) }
    }

    func deleteAppData(package: String, reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in try await core.deleteAppData(package, client: id) }
    }

    func openNotification(key: String, reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in try await core.openNotification(key: key, client: id) }
    }

    func clearNotifications(reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in try await core.clearNotifications(client: id) }
    }

    func dismissNotifications(_ keys: Data, reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in try await core.dismissNotifications(try AvoXPC.decode([String].self, from: keys), client: id) }
    }

    func notificationPermission(reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in AvoXPC.encode(try await core.notificationPermission(client: id)) }
    }

    func requestNotificationPermission(reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in AvoXPC.encode(try await core.requestNotificationPermission(client: id)) }
    }

    func unlockAndroid(credential: String, reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in try await core.unlockAndroid(credential: credential, client: id) }
    }

    // MARK: Fingerprints

    func fingerprints(refresh: Bool, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in AvoXPC.encode(try await core.fingerprintStatus(refresh: refresh, client: id)) }
    }

    func addFingerprint(name: String, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in AvoXPC.encode(try await core.addFingerprint(named: name, client: id)) }
    }

    func renameFingerprint(_ fingerprint: Int, name: String, reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in try await core.renameFingerprint(fingerprint, to: name, client: id) }
    }

    func removeFingerprint(_ fingerprint: Int, reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in try await core.removeFingerprint(fingerprint, client: id) }
    }

    func touchFingerprint(_ fingerprint: Int, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in
            AvoXPC.encode(try await core.touchFingerprint(fingerprint > 0 ? fingerprint : nil, client: id))
        }
    }

    func cancelFingerprintRequest(reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in try await core.cancelFingerprintRequest(client: id) }
    }

    func lockAndroidForFingerprints(reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in try await core.lockAndroidForFingerprints(client: id) }
    }

    func shakeDevice(reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in try await core.shakeDevice(client: id) }
    }

    func androidVolume(reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in AvoXPC.encode(try await core.androidVolume(client: id)) }
    }

    func setAndroidVolume(level: Int, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in AvoXPC.encode(try await core.setAndroidVolume(level, client: id)) }
    }

    func widgetProviders(reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in AvoXPC.encode(try await core.widgetProviders(client: id)) }
    }

    func placedWidgets(reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in AvoXPC.encode(try await core.placedWidgets(client: id)) }
    }

    func addWidget(_ provider: String, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in AvoXPC.encode(try await core.addWidget(provider, client: id)) }
    }

    func removeWidget(_ widget: String, reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in try await core.removeWidget(widget, client: id) }
    }

    func permissions(package: String, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in AvoXPC.encode(try await core.permissions(for: package, client: id)) }
    }

    func setPermission(package: String, permission: String, granted: Bool, reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in try await core.setPermission(permission, granted: granted, for: package, client: id) }
    }

    func recreateShortcuts(package: String?, reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in
            try await core.recreateShortcuts(for: package, client: id)
        }
    }

    func appUsage(reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in AvoXPC.encode(try await core.appUsage(client: id)) }
    }

    func systemActivity(watch: Bool, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in AvoXPC.encode(try await core.systemActivity(watch: watch, client: id)) }
    }

    // MARK: Google apps

    func googleAppsStatus(reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in AvoXPC.encode(try await core.googleAppsStatus(client: id)) }
    }

    func installGoogleApps(_ request: Data, reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in
            try await core.installGoogleApps(try AvoXPC.decode(GoogleAppsInstallRequest.self, from: request), client: id)
        }
    }

    func cancelGoogleApps(_ request: String, reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in try await core.cancelGoogleApps(UUID(uuidString: request), client: id) }
    }

    func removeGoogleApps(_ request: String, reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in try await core.removeGoogleApps(UUID(uuidString: request) ?? UUID(), client: id) }
    }

    // MARK: Location

    func location(watch: Bool, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in AvoXPC.encode(try await core.locationStatus(watch: watch, client: id)) }
    }

    func changeLocation(_ request: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in
            AvoXPC.encode(try await core.changeLocation(try AvoXPC.decode(LocationRequest.self, from: request), client: id))
        }
    }

    // MARK: Translate Screen

    func wakeScreenText(reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in try await core.wakeScreenText(client: id) }
    }

    func readScreenText(_ request: Data, pixels: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in
            let frame = try AvoXPC.decode(ScreenTextRequest.self, from: request)
            return AvoXPC.encode(try await core.readScreenText(frame, pixels: pixels, client: id))
        }
    }

    func translateTexts(_ request: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in
            AvoXPC.encode(try await core.translateTexts(try AvoXPC.decode(TranslationRequest.self, from: request), client: id))
        }
    }

    func knownTranslations(_ request: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in
            AvoXPC.encode(try await core.knownTranslations(try AvoXPC.decode(TranslationRequest.self, from: request), client: id))
        }
    }

    // MARK: Displays

    func openDisplay(_ request: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in
            let open = try AvoXPC.decode(OpenDisplayRequest.self, from: request)
            return AvoXPC.encode(OpenDisplayReply(displayID: try await core.openDisplay(open, client: id)))
        }
    }

    func resizeDisplay(_ displayID: UInt32, width: UInt32, height: UInt32, dpi: UInt32, reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in try await core.resizeDisplay(displayID, width: width, height: height, dpi: dpi, client: id) }
    }

    // The calls without an answer are dropped before the hello.

    func closeDisplay(_ displayID: UInt32) {
        guard isAdmitted else { return }
        Task { [self] in await core.closeDisplay(displayID, client: id) }
    }

    func setDisplayVisible(_ displayID: UInt32, visible: Bool) {
        guard isAdmitted else { return }
        Task { [self] in await core.setDisplayVisible(displayID, visible: visible, client: id) }
    }

    func setDisplayInBackground(_ displayID: UInt32, inBackground: Bool) {
        guard isAdmitted else { return }
        Task { [self] in await core.setDisplayInBackground(displayID, inBackground: inBackground, client: id) }
    }

    func focusDisplay(_ displayID: UInt32) {
        guard isAdmitted else { return }
        Task { [self] in await core.focusDisplay(displayID, client: id) }
    }

    func sendInput(_ record: Data) {
        guard isAdmitted else { return }
        input.continuation.yield(record)
    }

    func shareFiles(_ displayID: UInt32, files: [FileHandle], names: [String], reply: @escaping @Sendable (NSError?) -> Void) {
        guard isAdmitted else { return reply(AvoXPC.nsError(AvoError.unauthorizedCaller)) }
        let descriptors = files.map { OwnedDescriptor(dup($0.fileDescriptor)) }
        run(reply) { [self] in
            guard descriptors.count == names.count else { throw AvoError.internalError("file and name counts differ") }
            try await core.shareFiles(Array(zip(descriptors, names)), displayID: displayID, client: id)
        }
    }

    // MARK: Engine

    func engineSetSurfaces(_ displayID: UInt32, surfaces: [IOSurface]) {
        guard isAdmitted else { return }
        let list = SurfaceList(surfaces)
        Task { [self] in
            guard await core.role(of: id) == .engine else { return }
            await core.engineSetSurfaces(displayID, surfaces: list)
        }
    }

    func enginePresent(_ displayID: UInt32, surfaceIndex: Int, sequence: UInt64) {
        guard isAdmitted else { return }
        Task { [self] in
            guard await core.role(of: id) == .engine else { return }
            await core.enginePresent(displayID, surfaceIndex: surfaceIndex, sequence: sequence)
        }
    }
}

// MARK: - What a client is told of a failure

extension AvoError {
    /// A failure as it crosses to a client: the daemon's own errors as they
    /// are, a start that a stop called off (its CancellationError) as
    /// `startCalledOff`, which clients tell apart, and anything else in its
    /// own words.
    static func reported(_ error: any Error) -> AvoError {
        if let error = error as? AvoError { return error }
        if error is CancellationError { return .startCalledOff }
        return .internalError(error.localizedDescription)
    }
}

/// A file descriptor received over XPC; closed when the last reference goes away.
public final class OwnedDescriptor: Sendable {
    public let value: Int32

    public init(_ value: Int32) {
        self.value = value
    }

    deinit {
        if value >= 0 { close(value) }
    }
}
