import Foundation

// What an app window's Location panel asks of the daemon and what it hears
// back (XPC `location(watch:)`, `changeLocation`, `DaemonEvent.location`).
// The daemon owns it all: a route keeps playing with every window closed.
//
// There is a location for every app, and an app may have one of its own.
// Android has one GPS, so an app's own location is what every app hears
// while that app's window is in front (the Mac's key window).

/// Where Android's GPS says it is, and why.
public struct LocationStatus: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// This Mac's own location (CoreLocation), while Settings shares it.
        case mac
        /// A place chosen on the map or found by a search.
        case point
        /// A route playing (or paused, or played to its end).
        case route
    }

    public var source: Source
    /// What Android's GPS reports now; nil when it has no fix (the Mac's
    /// location is unknown or not shared).
    public var fix: RouteFix?
    /// The Mac's own position as CoreLocation last gave it (nil: unknown,
    /// not shared, or Android not running).
    public var mac: GeoPoint?
    /// Settings › Privacy & Security › Share this Mac’s location with Android.
    public var macSharing: Bool
    /// The chosen place's name (a search result).
    public var pointName: String?
    public var route: RouteStatus?
    /// For an App Shim: its app has a location of its own, which this is;
    /// otherwise this is every app's.
    public var ownLocation: Bool?
    /// For the Control Panel: the apps with a location of their own.
    public var apps: [AppLocation]?
    /// The app in front, when Android's GPS reports its own location now
    /// (nil: every app's).
    public var activeApp: String?

    public init(source: Source = .mac, fix: RouteFix? = nil, mac: GeoPoint? = nil, macSharing: Bool = true,
                pointName: String? = nil, route: RouteStatus? = nil, ownLocation: Bool? = nil, apps: [AppLocation]? = nil,
                activeApp: String? = nil) {
        self.source = source
        self.fix = fix
        self.mac = mac
        self.macSharing = macSharing
        self.pointName = pointName
        self.route = route
        self.ownLocation = ownLocation
        self.apps = apps
        self.activeApp = activeApp
    }
}

/// An app with a location of its own (Settings › Devices › Location).
public struct AppLocation: Codable, Equatable, Sendable {
    public var package: String
    public var source: LocationStatus.Source
    /// Where it is (nil: the Mac's location, while it has none yet).
    public var point: GeoPoint?
    public var pointName: String?

    public init(package: String, source: LocationStatus.Source, point: GeoPoint? = nil, pointName: String? = nil) {
        self.package = package
        self.source = source
        self.point = point
        self.pointName = pointName
    }
}

/// The route Android's GPS follows.
public struct RouteStatus: Codable, Equatable, Sendable {
    /// New for every route played: the panel asks for its points again.
    public var id: UUID
    public var name: String?
    /// Metres from start to end.
    public var distance: Double
    /// Seconds the recording took (nil: drawn, or not recorded with times).
    public var duration: Double?
    public var playback: LocationPlayback
    /// Metres played of this lap.
    public var travelled: Double
    /// Played to its end (it stays at its last point until it plays again).
    public var finished: Bool
    /// Paused in the panel.
    public var paused: Bool
    /// Android is not running (or paused): the route goes on when it does.
    public var waiting: Bool
    /// Seconds to the end of this lap.
    public var remaining: Double
    /// The route itself: in replies to `location(watch:)`, never in events.
    public var points: LocationRoute?

    public init(id: UUID, name: String?, distance: Double, duration: Double?, playback: LocationPlayback, travelled: Double,
                finished: Bool, paused: Bool, waiting: Bool, remaining: Double, points: LocationRoute? = nil) {
        self.id = id
        self.name = name
        self.distance = distance
        self.duration = duration
        self.playback = playback
        self.travelled = travelled
        self.finished = finished
        self.paused = paused
        self.waiting = waiting
        self.remaining = remaining
        self.points = points
    }

    /// Moving now.
    public var playing: Bool { !finished && !paused && !waiting }
    public var progress: Double { distance > 0 ? min(max(travelled / distance, 0), 1) : (finished ? 1 : 0) }
}

/// A change to what Android's GPS reports.
public enum LocationRequest: Codable, Equatable, Sendable {
    /// Use My Mac's Location.
    case mac
    /// Stay at one place (its name, when it came from a search).
    case point(GeoPoint, name: String?)
    /// Play a route from its first point.
    case route(LocationRoute, LocationPlayback)
    /// Play the current route at another pace, or loop it or not.
    case playback(LocationPlayback)
    case pause
    /// Go on; a route played to its end starts over.
    case resume
    /// Jump to this much (0...1) of the current route.
    case seek(Double)
    /// The asking app gets a location of its own, every app's to begin with;
    /// the requests above then change it, not every app's.
    case ownLocation
    /// The asking app uses every app's location again.
    case followAllApps
    /// The Control Panel: this app uses every app's location again.
    case removeApp(String)
}
