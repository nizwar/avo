import AvoKit
import Foundation
import os

// What Android's GPS reports (an app window's Location panel): this Mac's
// own location, a place chosen on the map, or a route played at a pace.
// There is a location for every app, and an app may have one of its own
// (the panel's "This App"); Android has one GPS, so an app's own location is
// what every app hears while that app's window is in front (`appFocused`).
// Places are kept across starts (location.json); a route plays from where it
// is chosen. The daemon owns it all, so a route keeps playing with every
// window closed. Routes move on four times a second while Android runs, each
// on its own clock, and stand still while it is stopped or paused; Android's
// GNSS HAL reads the newest fix about once a second (gnss.rs in the engine),
// with its speed and bearing.

/// An engine that can tell Android's GPS where it is.
public protocol LocationEngine: AnyObject, Sendable {
    /// nil: no fix.
    func setLocation(_ fix: LocationFix?) async
}

extension VMMEngine: LocationEngine {}

/// The places kept across starts: every app's, and the apps' own.
struct LocationStore: Codable, Equatable {
    enum Saved: Codable, Equatable {
        case mac
        case point(GeoPoint, name: String?)
    }

    var global = Saved.mac
    var apps: [String: Saved] = [:]

    static func load(_ url: URL) -> LocationStore {
        (try? JSONDecoder().decode(LocationStore.self, from: Data(contentsOf: url))) ?? LocationStore()
    }

    func save(_ url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: url, options: .atomic)
    }
}

actor LocationCenter {
    /// How often a playing route moves on.
    static let tick: Duration = .milliseconds(250)
    /// How often the panels hear about it while it moves (ticks).
    static let ticksPerUpdate = 4
    /// What Android is told of a simulated fix's accuracy, in metres.
    static let accuracy = 5.0

    enum Source {
        case mac
        case point(GeoPoint, name: String?)
        case route(Playing)
    }

    struct Playing {
        let id = UUID()
        var tracker: RouteTracker
        var playback: LocationPlayback
        var paused = false
    }

    /// Something changed (every app's status; the daemon makes each panel its own).
    nonisolated let updates: AsyncStream<LocationStatus>
    private let continuation: AsyncStream<LocationStatus>.Continuation
    private let engine: (any LocationEngine)?
    /// Lets a paused Android go on (VMManager.wake).
    private let wake: @Sendable () async -> Void
    private let storeURL: URL?
    private var stored: LocationStore
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Location")

    /// Every app's location.
    private(set) var source = Source.mac
    /// The apps with a location of their own.
    private var own: [String: Source] = [:]
    /// The app whose window is in front.
    private var active: String?
    /// The Mac's own location as CoreLocation last gave it (MacLocation).
    private var macFix: LocationFix?
    private var macSharing = true
    /// Android runs and is not paused: routes move only then.
    private var androidRunning = false
    private var ticker: Task<Void, Never>?
    private var lastTick: SuspendingClock.Instant?
    private var ticksSinceUpdate = 0

    /// `store`: where places are kept across starts (nil: not kept).
    init(engine: (any LocationEngine)?, wake: @escaping @Sendable () async -> Void = {}, store: URL? = nil) {
        self.engine = engine
        self.wake = wake
        storeURL = store
        stored = store.map(LocationStore.load) ?? LocationStore()
        source = Self.source(stored.global)
        own = stored.apps.mapValues(Self.source)
        (updates, continuation) = AsyncStream.makeStream(of: LocationStatus.self, bufferingPolicy: .bufferingNewest(4))
    }

    private static func source(_ saved: LocationStore.Saved) -> Source {
        switch saved {
        case .mac: .mac
        case let .point(point, name): .point(point, name: name)
        }
    }

    /// The app in front, when it has its own location (nil: every app's).
    private var activeOwner: String? { active.flatMap { own[$0] == nil ? nil : $0 } }

    /// What Android's GPS reports now.
    private var current: Source { activeOwner.flatMap { own[$0] } ?? source }

    // MARK: What it hears

    /// The daemon started: a place kept from before goes to the engine, which
    /// keeps it for Android's start (this Mac's location comes when
    /// CoreLocation has one; routes are not kept).
    func restore() async {
        guard case .point = current else { return }
        await sendFix()
    }

    /// From CoreLocation (nil: unknown, not shared, or Android stopped).
    func macLocationChanged(_ fix: LocationFix?) async {
        macFix = fix
        if case .mac = current { await engine?.setLocation(fix) }
        publish()
    }

    /// Settings › Devices › Share this Mac’s location with Android.
    func sharingChanged(_ sharing: Bool) {
        guard sharing != macSharing else { return }
        macSharing = sharing
        publish()
    }

    /// Android runs (and is not paused), or not: routes go on or wait.
    func androidChanged(running: Bool) {
        guard running != androidRunning else { return }
        androidRunning = running
        updateTicker()
        publish()
    }

    /// The Mac's key window is an app's (`focusDisplay`): its own location,
    /// if it has one, is what Android reports while it is in front.
    func appFocused(_ package: String?) async {
        guard package != active else { return }
        let before = activeOwner
        active = package
        guard activeOwner != before else { return }
        await sendFix()
        publish()
    }

    /// An app's last window closed: Android reports every app's location again.
    func appClosed(_ package: String) async {
        guard active == package else { return }
        await appFocused(nil)
    }

    /// A route plays somewhere (Pause When Idle waits for it).
    var isPlaying: Bool {
        ([source] + Array(own.values)).contains { Self.playing($0) }
    }

    private static func playing(_ source: Source) -> Bool {
        guard case .route(let playing) = source else { return false }
        return !playing.paused && !playing.tracker.finished
    }

    // MARK: What the panels ask

    /// `package`'s location (its own, or every app's), or every app's with
    /// the apps that have their own (nil: the Control Panel).
    func status(for package: String? = nil, withPoints: Bool = false) -> LocationStatus {
        let owner = package.flatMap { own[$0] == nil ? nil : $0 }
        var status = describe(owner.flatMap { own[$0] } ?? source, withPoints: withPoints)
        if let package {
            status.ownLocation = owner == package
        } else {
            status.apps = own.keys.sorted().map { app in
                let point = describe(own[app]!, withPoints: false)
                return AppLocation(package: app, source: point.source, point: point.fix?.point, pointName: point.pointName)
            }
        }
        status.activeApp = activeOwner
        return status
    }

    private func describe(_ source: Source, withPoints: Bool) -> LocationStatus {
        let mac = macFix.map { GeoPoint(latitude: $0.latitude, longitude: $0.longitude, altitude: $0.altitude) }
        var status = LocationStatus(source: .mac, mac: mac, macSharing: macSharing)
        switch source {
        case .mac:
            status.fix = macFix.map { RouteFix(point: GeoPoint(latitude: $0.latitude, longitude: $0.longitude, altitude: $0.altitude),
                                               speed: $0.speed, bearing: $0.bearing) }
        case let .point(point, name):
            status.source = .point
            status.fix = RouteFix(point: point)
            status.pointName = name
        case .route(let playing):
            status.source = .route
            status.fix = playing.tracker.fix(playback: playing.playback, paused: playing.paused || !androidRunning)
            let route = playing.tracker.route
            status.route = RouteStatus(id: playing.id, name: route.name, distance: playing.tracker.distance,
                                       duration: route.duration, playback: playing.playback,
                                       travelled: playing.tracker.travelled, finished: playing.tracker.finished,
                                       paused: playing.paused, waiting: !androidRunning,
                                       remaining: playing.tracker.remainingSeconds(playback: playing.playback),
                                       points: withPoints ? route : nil)
        }
        return status
    }

    /// A panel's change: to its app's own location when it has one (or
    /// gets one), else to every app's (nil: the Control Panel).
    func change(_ request: LocationRequest, for package: String? = nil) async throws -> LocationStatus {
        switch request {
        case .ownLocation:
            if let package, own[package] == nil { own[package] = start(from: source) }
        case .followAllApps:
            if let package { own[package] = nil }
        case .removeApp(let app):
            own[app] = nil
        default:
            if let package, var mine = own[package] {
                try apply(request, to: &mine)
                own[package] = mine
            } else {
                try apply(request, to: &source)
            }
        }
        keep()
        updateTicker()
        await sendFix()
        if case .route = request { await wakeForRoute() }
        if case .resume = request { await wakeForRoute() }
        publish()
        return status(for: package)
    }

    /// An app's own location to begin with: where every app's is (a route:
    /// the place it has reached).
    private func start(from source: Source) -> Source {
        guard case .route = source else { return source }
        let status = describe(source, withPoints: false)
        return status.fix.map { .point($0.point, name: status.route?.name) } ?? .mac
    }

    private func apply(_ request: LocationRequest, to source: inout Source) throws {
        switch request {
        case .mac:
            source = .mac
        case let .point(point, name):
            guard point.isValid else { throw AvoError.internalError(String(localized: "That place is not on Earth.", bundle: .avoKit)) }
            source = .point(point, name: name)
        case let .route(route, playback):
            guard route.isValid else { throw AvoError.internalError(String(localized: "That route cannot be played.", bundle: .avoKit)) }
            source = .route(Playing(tracker: RouteTracker(route: route), playback: playback))
            logger.notice("route: \(route.points.count) points, \(Int(route.distance)) m, \(playback.pace.rawValue, privacy: .public) ×\(playback.multiplier)")
        case .playback(let playback):
            guard case .route(var playing) = source else { return }
            playing.playback = playback
            source = .route(playing)
        case .pause:
            guard case .route(var playing) = source else { return }
            playing.paused = true
            source = .route(playing)
        case .resume:
            guard case .route(var playing) = source else { return }
            if playing.tracker.finished { playing.tracker.restart() }
            playing.paused = false
            source = .route(playing)
        case .seek(let progress):
            guard case .route(var playing) = source else { return }
            playing.tracker.seek(to: progress)
            source = .route(playing)
        case .ownLocation, .followAllApps, .removeApp:
            return
        }
    }

    /// The places for the next start (a route keeps the place before it).
    private func keep() {
        guard let storeURL else { return }
        var kept = stored
        if let saved = Self.saved(source) { kept.global = saved }
        kept.apps = kept.apps.filter { own[$0.key] != nil }
        for (app, source) in own {
            if let saved = Self.saved(source) { kept.apps[app] = saved }
        }
        guard kept != stored else { return }
        stored = kept
        kept.save(storeURL)
    }

    private static func saved(_ source: Source) -> LocationStore.Saved? {
        switch source {
        case .mac: .mac
        case let .point(point, name): .point(point, name: name)
        case .route: nil
        }
    }

    // MARK: Playing routes

    private func wakeForRoute() async {
        guard isPlaying else { return }
        await wake()
    }

    /// Ticks while a route plays and Android runs; none otherwise.
    private func updateTicker() {
        let wanted = isPlaying && androidRunning
        if wanted, ticker == nil {
            lastTick = SuspendingClock.now
            ticksSinceUpdate = 0
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.tick, clock: .suspending)
                    guard !Task.isCancelled else { return }
                    await self?.tick()
                }
            }
        } else if !wanted, let ticker {
            ticker.cancel()
            self.ticker = nil
            lastTick = nil
        }
    }

    private func tick() async {
        guard ticker != nil else { return }
        let now = SuspendingClock.now
        // The Mac's sleep does not count (a suspending clock), nor does a
        // stall beyond two seconds.
        let elapsed = min(lastTick.map { now - $0 } ?? .zero, .seconds(2))
        lastTick = now
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        var finished = false
        let advance = { (source: inout Source) in
            guard case .route(var playing) = source, !playing.paused, !playing.tracker.finished else { return }
            playing.tracker.advance(by: seconds, playback: playing.playback)
            finished = finished || playing.tracker.finished
            source = .route(playing)
        }
        advance(&source)
        for app in own.keys {
            var mine = own[app]!
            advance(&mine)
            own[app] = mine
        }
        ticksSinceUpdate += 1
        if finished || ticksSinceUpdate >= Self.ticksPerUpdate {
            ticksSinceUpdate = 0
            publish()
        }
        if finished { updateTicker() }
        if case .route = current { await sendFix() }
    }

    /// What Android's GPS reports now, to the engine, which keeps it.
    private func sendFix() async {
        if case .mac = current {
            await engine?.setLocation(macFix)
            return
        }
        guard let fix = describe(current, withPoints: false).fix else { return }
        await engine?.setLocation(LocationFix(latitude: fix.point.latitude, longitude: fix.point.longitude,
                                              altitude: fix.point.altitude ?? 0, accuracy: Self.accuracy,
                                              speed: fix.speed, bearing: fix.bearing))
    }

    private func publish() {
        continuation.yield(status())
    }
}

// MARK: - The daemon's side (XPC `location(watch:)`, `changeLocation`)

extension DaemonCore {
    /// Starts following Android's status and the setting, and passes every
    /// change on to the panels that watch.
    func startLocation() {
        let location = self.location
        // The place kept from before is where Android is from its start on.
        Task { await location.restore() }
        Task { [weak self] in
            for await _ in location.updates { await self?.sendLocation() }
        }
        Task { [weak self] in
            guard let statuses = await self?.statusChanges() else { return }
            for await status in statuses { await location.androidChanged(running: status.state == .running && !status.isPaused) }
        }
        Task { [weak self] in
            guard let configs = await self?.configChanges() else { return }
            for await config in configs { await location.sharingChanged(config.shareLocation) }
        }
    }

    /// Each watcher hears its own app's location (the Control Panel every app's).
    private func sendLocation() async {
        for id in locationWatchers {
            send(.location(await location.status(for: locationApp(of: id))), toClient: id)
        }
    }

    /// The app a client speaks for (nil: the Control Panel, every app's).
    private func locationApp(of client: ClientID) -> String? {
        if case .shim(let package)? = role(of: client) { return package }
        return nil
    }

    /// The caller's app's location (an App Shim), or every app's with the
    /// apps that have their own (a Control Panel), with the route's points;
    /// `watch`: the caller hears every change (`DaemonEvent.location`) until
    /// it says false or goes.
    public func locationStatus(watch: Bool, client: ClientID) async throws -> LocationStatus {
        guard let role = role(of: client), role != .engine else { throw AvoError.unauthorizedCaller }
        if watch { locationWatchers.insert(client) } else { locationWatchers.remove(client) }
        return await location.status(for: locationApp(of: client), withPoints: true)
    }

    /// The Location panel's changes (this Mac's location, a place, a route
    /// and how it plays; its app's own location or every app's), and the
    /// Control Panel's to every app's.
    public func changeLocation(_ request: LocationRequest, client: ClientID) async throws -> LocationStatus {
        guard let role = role(of: client), role != .engine else { throw AvoError.unauthorizedCaller }
        return try await location.change(request, for: locationApp(of: client))
    }

    /// The Mac's own location from CoreLocation (the daemon's MacLocation).
    public func macLocationChanged(_ fix: LocationFix?) async {
        await location.macLocationChanged(fix)
    }
}
