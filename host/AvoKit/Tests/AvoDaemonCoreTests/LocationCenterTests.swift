import AvoKit
import Foundation
import Testing
@testable import AvoDaemonCore

/// Records what Android's GPS was told.
final class RecordingLocationEngine: LocationEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [LocationFix?] = []

    func setLocation(_ fix: LocationFix?) async {
        lock.withLock { sent.append(fix) }
    }

    var fixes: [LocationFix?] { lock.withLock { sent } }
    var last: LocationFix?? { lock.withLock { sent.last } }
}

/// Tells avo-vmm's control socket (the test VM's), as VMMEngine does.
final class ControlLocationEngine: LocationEngine, @unchecked Sendable {
    let control: EngineControl
    init(_ control: EngineControl) { self.control = control }

    func setLocation(_ fix: LocationFix?) async {
        try? await control.send(fix?.command ?? "location off")
    }
}

@Suite struct LocationCenterTests {
    static let mac = LocationFix(latitude: -0.0263, longitude: 109.3425, altitude: 3, accuracy: 35, speed: 0, bearing: 0)
    /// 1 km east along the equator, then 1 km north.
    static let route = LocationRoute(name: "Test", points: [
        GeoPoint(latitude: 0, longitude: 0), GeoPoint(latitude: 0, longitude: 1000 / 111_195.0),
        GeoPoint(latitude: 1000 / 111_195.0, longitude: 1000 / 111_195.0),
    ])

    @Test func theMacsLocationUnlessAPlaceIsChosen() async throws {
        let engine = RecordingLocationEngine()
        let center = LocationCenter(engine: engine)
        await center.macLocationChanged(Self.mac)
        #expect(engine.last == .some(Self.mac))
        var status = await center.status()
        #expect(status.source == .mac)
        #expect(status.mac?.latitude == Self.mac.latitude)
        #expect(status.fix?.point.longitude == Self.mac.longitude)

        status = try await center.change(.point(GeoPoint(latitude: 35.6812, longitude: 139.7671), name: "Tokyo Station"))
        #expect(status.source == .point)
        #expect(status.pointName == "Tokyo Station")
        let point = try #require(engine.last ?? nil)
        #expect(point.latitude == 35.6812 && point.speed == 0 && point.accuracy == LocationCenter.accuracy)
        // The Mac moving changes nothing now, but the panel still learns of it.
        let count = engine.fixes.count
        await center.macLocationChanged(LocationFix(latitude: 1, longitude: 1, altitude: 0, accuracy: 10, speed: 0, bearing: 0))
        #expect(engine.fixes.count == count)
        #expect(await center.status().mac?.latitude == 1)

        // Use My Mac's Location: the latest from CoreLocation, or no fix.
        _ = try await center.change(.mac)
        #expect(engine.last??.latitude == 1)
        await center.macLocationChanged(nil)
        #expect(engine.last == .some(nil))
        #expect(await center.status().fix == nil)

        await #expect(throws: AvoError.self) { try await center.change(.point(GeoPoint(latitude: 95, longitude: 0), name: nil)) }
    }

    static let jakarta = GeoPoint(latitude: -6.1754, longitude: 106.8272)
    static let pontianak = GeoPoint(latitude: -0.0263, longitude: 109.3425)

    /// An app's own location is what Android's GPS reports while its window
    /// is in front; every other app, and every app when it closes, gets
    /// every app's location.
    @Test func anAppsOwnLocationGoesWithItsWindow() async throws {
        let engine = RecordingLocationEngine()
        let center = LocationCenter(engine: engine)
        _ = try await center.change(.point(Self.jakarta, name: "Jakarta"))
        // "This App": it starts where every app is, and changes on its own.
        var mine = try await center.change(.ownLocation, for: "id.suruhkami")
        #expect(mine.ownLocation == true && mine.pointName == "Jakarta")
        mine = try await center.change(.point(Self.pontianak, name: "Pontianak"), for: "id.suruhkami")
        #expect(mine.pointName == "Pontianak")
        #expect(await center.status(for: "com.other").pointName == "Jakarta")
        #expect(await center.status(for: "com.other").ownLocation == false)
        #expect(engine.last??.latitude == Self.jakarta.latitude, "its window is not in front")

        await center.appFocused("id.suruhkami")
        #expect(engine.last??.latitude == Self.pontianak.latitude)
        #expect(await center.status().activeApp == "id.suruhkami")
        await center.appFocused("com.other")
        #expect(engine.last??.latitude == Self.jakarta.latitude)
        // Between apps without their own: nothing to tell Android.
        let count = engine.fixes.count
        await center.appFocused("com.third")
        #expect(engine.fixes.count == count)

        // The Control Panel lists it; closing it gives Android every app's place again.
        let apps = try #require(await center.status().apps)
        #expect(apps.map(\.package) == ["id.suruhkami"] && apps.first?.pointName == "Pontianak")
        await center.appFocused("id.suruhkami")
        await center.appClosed("id.suruhkami")
        #expect(engine.last??.latitude == Self.jakarta.latitude)

        // "All Apps" again, or removed in Settings: it follows every app's.
        _ = try await center.change(.followAllApps, for: "id.suruhkami")
        #expect(await center.status(for: "id.suruhkami").pointName == "Jakarta")
        _ = try await center.change(.ownLocation, for: "id.suruhkami")
        _ = try await center.change(.removeApp("id.suruhkami"))
        #expect(await center.status().apps?.isEmpty == true)
    }

    @Test func placesAreKeptForTheNextStart() async throws {
        let store = FileManager.default.temporaryDirectory.appending(path: "avo-location-\(UUID().uuidString.prefix(8)).json")
        defer { try? FileManager.default.removeItem(at: store) }
        do {
            let center = LocationCenter(engine: nil, store: store)
            _ = try await center.change(.point(Self.jakarta, name: "Jakarta"))
            _ = try await center.change(.ownLocation, for: "id.suruhkami")
            _ = try await center.change(.point(Self.pontianak, name: "Pontianak"), for: "id.suruhkami")
            // A route plays from where it is chosen: the place before it is kept.
            _ = try await center.change(.route(Self.route, LocationPlayback(pace: .walk)))
        }
        let engine = RecordingLocationEngine()
        let next = LocationCenter(engine: engine, store: store)
        #expect(await next.status().pointName == "Jakarta")
        #expect(await next.status(for: "id.suruhkami").pointName == "Pontianak")
        #expect(await next.status(for: "id.suruhkami").ownLocation == true)
        // The engine has every app's place before Android starts (it reported
        // its own built-in place until something changed).
        await next.restore()
        let sent = try #require(engine.last ?? nil)
        #expect(abs(sent.latitude - Self.jakarta.latitude) < 1e-9 && abs(sent.longitude - Self.jakarta.longitude) < 1e-9)
        // This Mac's location is not restored: CoreLocation sends it.
        let mac = RecordingLocationEngine()
        await LocationCenter(engine: mac).restore()
        #expect(mac.fixes.isEmpty)
    }

    @Test func aRouteMovesOnlyWhileAndroidRuns() async throws {
        let engine = RecordingLocationEngine()
        let center = LocationCenter(engine: engine)
        let fast = LocationPlayback(pace: .drive, multiplier: 20) // 278 m/s
        var status = try await center.change(.route(Self.route, fast))
        #expect(status.source == .route)
        #expect(status.route?.waiting == true)
        #expect(status.route?.travelled == 0)
        #expect(await center.isPlaying)
        // Stopped Android: the route waits at its start.
        try await Task.sleep(for: .milliseconds(400))
        #expect(await center.status().route?.travelled == 0)

        await center.androidChanged(running: true)
        try await Task.sleep(for: .milliseconds(900))
        status = await center.status()
        let travelled = try #require(status.route?.travelled)
        #expect(travelled > 100 && travelled < 400)
        #expect(status.route?.playing == true)
        let moving = try #require(engine.last ?? nil)
        #expect(abs(moving.speed - 278) < 0.01)
        #expect(abs(moving.bearing - 90) < 0.5)
        #expect(moving.longitude > 0)

        // Paused: it stands still and says so; Pause When Idle may go ahead.
        status = try await center.change(.pause)
        #expect(status.route?.paused == true)
        #expect(engine.last??.speed == 0)
        #expect(!(await center.isPlaying))
        let held = await center.status().route?.travelled
        try await Task.sleep(for: .milliseconds(400))
        #expect(await center.status().route?.travelled == held)

        // To the end: it holds the last point.
        _ = try await center.change(.seek(0.99))
        _ = try await center.change(.resume)
        try await Task.sleep(for: .milliseconds(600))
        status = await center.status()
        #expect(status.route?.finished == true)
        #expect(!(await center.isPlaying))
        let end = try #require(engine.last ?? nil)
        #expect(abs(end.latitude - Self.route.points[2].latitude) < 1e-9 && end.speed == 0)
        // Resume plays a finished route again from its start.
        status = try await center.change(.resume)
        #expect(status.route?.finished == false)
        #expect(status.route?.travelled == 0)
        await center.androidChanged(running: false)
        #expect(await center.status().route?.waiting == true)
    }

    @Test func thePanelsHearOfChanges() async throws {
        let center = LocationCenter(engine: nil)
        var updates = center.updates.makeAsyncIterator()
        _ = try await center.change(.route(Self.route, LocationPlayback(pace: .walk, loop: true)))
        let first = await updates.next()
        #expect(first?.source == .route)
        #expect(first?.route?.points == nil)
        #expect(first?.route?.playback.loop == true)
        // The reply to `location(watch:)` carries the points.
        #expect(await center.status(withPoints: true).route?.points == Self.route)
        _ = try await center.change(.playback(LocationPlayback(pace: .run)))
        #expect(await updates.next()?.route?.playback.pace == .run)
    }

    /// Plays a route on the test VM's avo-vmm (`AVO_LOCATION_VM` = its
    /// directory, with `runtime/control.sock`; `AVO_LOCATION_SECONDS`), for
    /// checking from Android meanwhile.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AVO_LOCATION_VM"] != nil))
    func playsARouteOnTheTestVM() async throws {
        let environment = ProcessInfo.processInfo.environment
        // The socket's absolute path is too long for sun_path.
        #expect(FileManager.default.changeCurrentDirectoryPath(try #require(environment["AVO_LOCATION_VM"])))
        let control = EngineControl(socketPath: "runtime/control.sock")
        let center = LocationCenter(engine: ControlLocationEngine(control))
        await center.androidChanged(running: true)
        // Around Pontianak's Tugu Khatulistiwa: 200 m north, then 200 m east.
        let metre = 1 / 111_195.0
        let start = GeoPoint(latitude: 0.0007, longitude: 109.3222)
        let route = LocationRoute(name: "VM check", points: [
            start, GeoPoint(latitude: start.latitude + 200 * metre, longitude: start.longitude),
            GeoPoint(latitude: start.latitude + 200 * metre, longitude: start.longitude + 200 * metre),
        ])
        let pace = LocationPace(rawValue: environment["AVO_LOCATION_PACE"] ?? "") ?? .drive
        _ = try await center.change(.route(route, LocationPlayback(pace: pace)))
        try await Task.sleep(for: .seconds(Double(environment["AVO_LOCATION_SECONDS"] ?? "") ?? 20))
        let status = await center.status()
        print("location check: travelled \(status.route?.travelled ?? -1) m, fix \(String(describing: status.fix))")
        await control.close()
    }
}
