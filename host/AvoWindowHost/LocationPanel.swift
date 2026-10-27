import AppKit
import AvoHazeUI
import AvoKit
import AvoPackages
import MapKit
import os
import SwiftUI
import UniformTypeIdentifiers

// The Location panel (Game Controls › Location…, ⌥⌘L, or Quick Settings ›
// Location; in the Control Panel, Settings › Devices › Location › Choose…,
// for every app): where Android's GPS says it is, on an Apple Maps map, and
// what it should say instead: a place (a click on the map, a search, or
// coordinates typed in), a route (stops clicked on the map, by road or in
// straight lines, or a GPX, KML or KMZ file) played at a walk, a run, by
// bike or by car, faster if wanted, once or over and over, or this Mac's own
// location again. It is Android's and the daemon's (LocationCenter): every
// app gets the same fix, and a route keeps playing with this panel and every
// window closed. The panel never asks macOS where the Mac is; the daemon
// says.

private func L(_ key: String.LocalizationValue) -> String { String(localized: key, bundle: .windowHost) }

extension GeoPoint {
    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

// MARK: - What the daemon says

/// The daemon's location as this App Shim knows it, for the panel and Quick
/// Settings. The daemon sends changes only while one of them shows it.
@MainActor
final class LocationModel: ObservableObject {
    static let shared = LocationModel()

    @Published private(set) var status: LocationStatus?
    /// The points of the route in `status` (fetched again for a new route).
    @Published private(set) var route: LocationRoute?
    @Published private(set) var problem: String?
    /// The Control Panel's: every app's location, with no app to choose for.
    private(set) var allAppsOnly = false
    private var client: DaemonClient?
    private var watchers = 0
    /// The Control Panel's switch for the daemon's location events, which its
    /// Settings pane uses too (nil in an App Shim: the client's own).
    private var watch: (@MainActor (Bool) -> Void)?
    private var problemTask: Task<Void, Never>?
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Location")

    /// After `hello`.
    func connect(_ client: DaemonClient) {
        self.client = client
        if watchers > 0 { refresh() }
    }

    /// After the Control Panel's `hello` (ControlPanelLocationWindow).
    func connectControlPanel(_ client: DaemonClient, watch: @escaping @MainActor (Bool) -> Void) {
        allAppsOnly = true
        self.watch = watch
        connect(client)
    }

    /// A panel or Quick Settings shows the location: the daemon sends every change meanwhile.
    func beginWatching() {
        watchers += 1
        if watchers == 1 { watch?(true) }
        refresh()
    }

    func endWatching() {
        watchers = max(watchers - 1, 0)
        guard watchers == 0, let client else { return }
        if let watch {
            watch(false)
            return
        }
        Task { _ = try? await client.location(watch: false) }
    }

    /// What the daemon says now, with the route's points.
    private func refresh() {
        guard let client else { return }
        Task {
            do {
                let status = try await client.location(watch: watchers > 0)
                apply(status, points: .some(status.route?.points))
            } catch {
                show(error)
            }
        }
    }

    /// `DaemonEvent.location` (without the route's points).
    func update(_ status: LocationStatus) {
        guard watchers > 0 else { return }
        apply(status)
    }

    /// `points`: the route's, when known (.none: keep, or fetch for a new route).
    private func apply(_ new: LocationStatus, points: LocationRoute?? = .none) {
        var status = new
        status.route?.points = nil
        if case .some(let points) = points {
            route = points
        } else if status.route?.id != self.status?.route?.id {
            route = nil
            if status.route != nil { refresh() }
        }
        // Android moves smoothly between the once-a-second updates.
        let moving = status.route?.playing == true && status.route?.id == self.status?.route?.id
        if moving {
            withAnimation(.linear(duration: 1)) { self.status = status }
        } else {
            self.status = status
        }
    }

    func send(_ request: LocationRequest) {
        guard let client else {
            show(AvoError.daemonUnreachable(L("not connected")))
            return
        }
        Task {
            do {
                let status = try await client.changeLocation(request)
                if case .route(let route, _) = request {
                    apply(status, points: .some(route))
                } else {
                    apply(status)
                }
            } catch {
                show(error)
            }
        }
    }

    func show(_ error: any Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        logger.error("location: \(message, privacy: .public)")
        show(message)
    }

    func show(_ message: String) {
        problem = message
        problemTask?.cancel()
        problemTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            problem = nil
        }
    }
}

// MARK: - The window

/// One Location window per App Shim, shared by its windows (or the Control Panel's).
@MainActor
final class LocationPanel: NSObject, NSWindowDelegate {
    static let shared = LocationPanel()
    static var title: String { L("Location") }

    private var window: NSWindow?
    private let editor = LocationEditor()
    /// Out of sight while the app runs in the background (`hideWithApp`).
    private var hiddenWithApp = false

    func show() {
        if let window {
            hiddenWithApp = false
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: LocationPanelView(model: .shared, editor: editor))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = Self.title
        window.titlebarAppearsTransparent = true
        window.contentMinSize = NSSize(width: 780, height: 540)
        // Over a game in full screen (⌥⌘L there), instead of a switch to the desktop's Space.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentViewController = host
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 1000, height: 660))
        if !window.setFrameUsingName("AvoLocationPanel") { window.center() }
        window.setFrameAutosaveName("AvoLocationPanel")
        self.window = window
        LocationModel.shared.beginWatching()
        editor.panelOpened()
        window.makeKeyAndOrderFront(nil)
    }

    /// Run in Background: the window goes with the app's, and stays open.
    func hideWithApp() {
        guard let window, window.isVisible else { return }
        hiddenWithApp = true
        window.orderOut(nil)
    }

    /// Back from the background with the app's windows, as it was.
    func returnWithApp() {
        guard hiddenWithApp, let window else { return }
        hiddenWithApp = false
        window.orderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        LocationModel.shared.endWatching()
        window = nil
        hiddenWithApp = false
    }
}

/// The Location window in the Control Panel (Settings › Devices › Location ›
/// Choose…): every app's location, set with no app window open.
@MainActor
public enum ControlPanelLocationWindow {
    /// After each `hello`: the window talks to the daemon through `client`,
    /// and `watch` turns the Control Panel's location events on or off.
    public static func connect(_ client: DaemonClient, watch: @escaping @MainActor (Bool) -> Void) {
        LocationModel.shared.connectControlPanel(client, watch: watch)
    }

    public static func show() {
        LocationPanel.shared.show()
    }

    /// A `DaemonEvent.location` the Control Panel got.
    public static func update(_ status: LocationStatus) {
        LocationModel.shared.update(status)
    }
}

// MARK: - What the panel edits

/// The panel's own state: the place or the route being made, the map, the
/// search. It stays while the App Shim runs; what Android gets is the daemon's.
@MainActor
final class LocationEditor: ObservableObject {
    enum Mode: Hashable { case place, route }

    struct Pin: Equatable {
        var point: GeoPoint
        var name: String?
    }

    /// A stop of a route being drawn, and the way to it from the one before
    /// (by road when found, else straight); the first has no way.
    struct Stop: Identifiable, Equatable {
        let id = UUID()
        var point: GeoPoint
        var name: String?
        /// The points after the previous stop, ending at this one.
        var leg: [GeoPoint]
        var routing = false
    }

    @Published var mode = Mode.place
    @Published var pin: Pin?
    /// An imported route; drawn stops go on from its end.
    @Published private(set) var base: LocationRoute?
    @Published private(set) var stops: [Stop] = []
    @Published var followRoads = true
    @Published var playback = LocationPlayback()
    @Published var camera = MapCameraPosition.automatic
    /// The map keeps Android in the middle.
    @Published var following = false
    @Published var satellite = false
    /// The map's heading, for Android's arrow.
    @Published var heading: Double = 0
    let search = PlaceSearch()
    private var lastCamera: MapCamera?
    /// The last click on the map, and the stop it added (see `mapClicked`).
    private var lastClick: (time: TimeInterval, location: CGPoint)?
    private var lastClickStop: UUID?
    private var opened = false

    /// The first time: the map starts at Android.
    func panelOpened() {
        guard !opened else { return }
        opened = true
        Task {
            // The daemon's answer arrives right after the window opens.
            for _ in 0..<20 {
                if let fix = LocationModel.shared.status?.fix {
                    camera = .camera(MapCamera(centerCoordinate: fix.point.coordinate, distance: 3000))
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: The route being made

    var points: [GeoPoint] { (base?.points ?? []) + stops.flatMap(\.leg) }

    var draft: LocationRoute? {
        let points = self.points
        guard !points.isEmpty else { return nil }
        return LocationRoute(name: base?.name, points: points, times: stops.isEmpty ? base?.times : nil)
    }

    var canPlay: Bool { points.count >= 2 && !stops.contains(where: \.routing) }
    var isEmpty: Bool { base == nil && stops.isEmpty }

    /// A click on the map at `location` (in the map's points). The second
    /// click of a double-click zooms the map: it takes back the stop the
    /// first one added.
    func mapClicked(_ coordinate: CLLocationCoordinate2D, at location: CGPoint) {
        let point = GeoPoint(coordinate)
        guard point.isValid else { return }
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastClick = (now, location) }
        if let last = lastClick, now - last.time < NSEvent.doubleClickInterval,
           hypot(location.x - last.location.x, location.y - last.location.y) < 6 {
            if mode == .route, let stop = stops.last, stop.id == lastClickStop { stops.removeLast() }
            lastClickStop = nil
            return
        }
        switch mode {
        case .place: pin = Pin(point: point, name: nil)
        case .route:
            addStop(point, name: nil)
            lastClickStop = stops.last?.id
        }
    }

    func addStop(_ point: GeoPoint, name: String?) {
        guard let previous = points.last else {
            stops.append(Stop(point: point, name: name, leg: [point]))
            return
        }
        let stop = Stop(point: point, name: name, leg: [point], routing: followRoads)
        stops.append(stop)
        guard followRoads else { return }
        let id = stop.id
        let walking = [.walk, .run].contains(playback.pace)
        Task {
            let road = await Self.directions(from: previous, to: point, walking: walking)
            guard let index = stops.firstIndex(where: { $0.id == id }) else { return }
            var stop = stops[index]
            stop.routing = false
            if let road, road.count >= 2 {
                // The road ends near the stop: end exactly at it.
                stop.leg = Array(road.dropFirst()) + (Geo.distance(road[road.count - 1], point) > 1 ? [point] : [])
            } else {
                LocationModel.shared.show(L("Apple Maps found no road there, so this part is a straight line."))
            }
            stops[index] = stop
        }
    }

    func undo() {
        if !stops.isEmpty { stops.removeLast() } else { base = nil }
    }

    func clear() {
        base = nil
        stops = []
    }

    func reverse() {
        guard let draft else { return }
        base = draft.reversed()
        stops = []
    }

    /// The playing route, to change and play again.
    func edit(_ route: LocationRoute) {
        mode = .route
        base = route
        stops = []
        show(route)
    }

    /// A GPX, KML or KMZ file, chosen in an open panel.
    func importRoute() {
        let panel = NSOpenPanel()
        panel.title = L("Import a Route")
        panel.prompt = L("Import")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["gpx", "kml", "kmz"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let route = try Self.readRoute(url)
            mode = .route
            base = route
            stops = []
            if route.duration != nil { playback.pace = .recorded }
            show(route)
        } catch {
            LocationModel.shared.show(error)
        }
    }

    static func readRoute(_ url: URL) throws -> LocationRoute {
        if url.pathExtension.lowercased() == "kmz" {
            // A zipped KML: doc.kml, else its first .kml.
            let archive = try ZipArchive(url: url)
            guard let entry = archive.entry("doc.kml") ?? archive.entries.first(where: { $0.path.lowercased().hasSuffix(".kml") })
            else { throw RouteFileError.unreadable }
            return try LocationRoute.parse(try archive.data(of: entry), fileName: url.lastPathComponent)
        }
        return try LocationRoute.parse(try Data(contentsOf: url), fileName: url.lastPathComponent)
    }

    // MARK: The map

    /// Shows the whole route.
    func show(_ route: LocationRoute) {
        guard !route.points.isEmpty else { return }
        following = false
        let rect = route.points.reduce(MKMapRect.null) { rect, point in
            rect.union(MKMapRect(origin: MKMapPoint(point.coordinate), size: MKMapSize(width: 1, height: 1)))
        }
        let padded = rect.insetBy(dx: -max(rect.width * 0.15, 400), dy: -max(rect.height * 0.15, 400))
        camera = .rect(padded)
    }

    func show(_ point: GeoPoint) {
        following = false
        camera = .camera(MapCamera(centerCoordinate: point.coordinate, distance: min(lastCamera?.distance ?? 3000, 6000),
                                   heading: lastCamera?.heading ?? 0, pitch: 0))
    }

    func cameraChanged(_ camera: MapCamera, byUser: Bool) {
        lastCamera = camera
        heading = camera.heading
        if byUser, following { following = false }
        search.region = MKCoordinateRegion(center: camera.centerCoordinate,
                                           latitudinalMeters: camera.distance * 2, longitudinalMeters: camera.distance * 2)
    }

    /// Android moved: in the middle of the map while following.
    func androidMoved(_ fix: RouteFix?) {
        guard following, let fix else { return }
        camera = .camera(MapCamera(centerCoordinate: fix.point.coordinate, distance: lastCamera?.distance ?? 1500,
                                   heading: lastCamera?.heading ?? 0, pitch: lastCamera?.pitch ?? 0))
    }

    func choose(_ suggestion: PlaceSearch.Suggestion) {
        Task {
            guard let (point, name) = await search.resolve(suggestion) else {
                LocationModel.shared.show(L("Apple Maps couldn’t find that place."))
                return
            }
            show(point)
            switch mode {
            case .place: pin = Pin(point: point, name: name)
            case .route: addStop(point, name: name)
            }
        }
    }

    /// The road between two places from Apple Maps (nil: none found).
    private static func directions(from: GeoPoint, to: GeoPoint, walking: Bool) async -> [GeoPoint]? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to.coordinate))
        request.transportType = walking ? .walking : .automobile
        guard let polyline = try? await MKDirections(request: request).calculate().routes.first?.polyline,
              polyline.pointCount >= 2 else { return nil }
        var coordinates = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount)
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
        return coordinates.map(GeoPoint.init).filter(\.isValid)
    }
}

/// Places as the search field is typed in: Apple Maps' suggestions near the
/// map, and coordinates ("-0.0263, 109.3425") as they are.
@MainActor
final class PlaceSearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    struct Suggestion: Identifiable {
        let id: Int
        let title: String
        let subtitle: String
        var completion: MKLocalSearchCompletion?
        var point: GeoPoint?
    }

    @Published var query = "" {
        didSet { queryChanged() }
    }
    @Published private(set) var suggestions: [Suggestion] = []
    private let completer = MKLocalSearchCompleter()

    var region: MKCoordinateRegion {
        get { completer.region }
        set { completer.region = newValue }
    }

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    private func queryChanged() {
        let text = query.trimmingCharacters(in: .whitespaces)
        if let point = Self.coordinates(text) {
            completer.cancel()
            suggestions = [Suggestion(id: 0, title: String(format: "%.5f, %.5f", point.latitude, point.longitude),
                                      subtitle: L("Coordinates"), point: point)]
        } else if text.isEmpty {
            completer.cancel()
            suggestions = []
        } else {
            completer.queryFragment = text
        }
    }

    func clear() {
        query = ""
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            guard Self.coordinates(query) == nil, !query.isEmpty else { return }
            // Our own completer (the delegate is called on the main thread).
            suggestions = self.completer.results.prefix(6).enumerated().map { index, result in
                Suggestion(id: index + 1, title: result.title, subtitle: result.subtitle, completion: result)
            }
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        MainActor.assumeIsolated { suggestions = [] }
    }

    /// Where a suggestion is, and its name.
    func resolve(_ suggestion: Suggestion) async -> (GeoPoint, String?)? {
        defer { clear() }
        if let point = suggestion.point { return (point, nil) }
        guard let completion = suggestion.completion else { return nil }
        let search = MKLocalSearch(request: MKLocalSearch.Request(completion: completion))
        guard let item = try? await search.start().mapItems.first else { return nil }
        let point = GeoPoint(item.placemark.coordinate)
        return point.isValid ? (point, item.name ?? suggestion.title) : nil
    }

    /// "lat, lng" or "lat lng" in degrees.
    static func coordinates(_ text: String) -> GeoPoint? {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).filter { !$0.isEmpty }
        guard parts.count == 2, let latitude = Double(parts[0]), let longitude = Double(parts[1]) else { return nil }
        let point = GeoPoint(latitude: latitude, longitude: longitude)
        return point.isValid ? point : nil
    }
}

// MARK: - Showing numbers

enum LocationText {
    static func coordinates(_ point: GeoPoint) -> String {
        String(format: "%.5f, %.5f", point.latitude, point.longitude)
    }

    static func distance(_ metres: Double) -> String {
        Measurement(value: metres, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }

    static func speed(_ metresPerSecond: Double) -> String {
        let unit: UnitSpeed = Locale.current.measurementSystem == .us ? .milesPerHour : .kilometersPerHour
        let value = Measurement(value: metresPerSecond, unit: UnitSpeed.metersPerSecond).converted(to: unit)
        return value.formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }

    static func duration(_ seconds: Double) -> String {
        Duration.seconds(max(seconds, 0).rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated,
                                                                     maximumUnitCount: 2))
    }

    static func pace(_ pace: LocationPace) -> String {
        switch pace {
        case .walk: L("Walk")
        case .run: L("Run")
        case .cycle: L("Cycle")
        case .drive: L("Drive")
        case .recorded: L("As Recorded")
        }
    }

    static func paceSymbol(_ pace: LocationPace) -> String {
        switch pace {
        case .walk: "figure.walk"
        case .run: "figure.run"
        case .cycle: "bicycle"
        case .drive: "car.fill"
        case .recorded: "clock.arrow.circlepath"
        }
    }

    static func multiplier(_ value: Double) -> String {
        "×" + value.formatted(.number.precision(.fractionLength(0...1)))
    }
}

// MARK: - The panel

struct LocationPanelView: View {
    @ObservedObject var model: LocationModel
    @ObservedObject var editor: LocationEditor

    var body: some View {
        HStack(spacing: 0) {
            LocationMap(model: model, editor: editor)
            ScrollView(.vertical) {
                LocationSidebar(model: model, editor: editor)
                    .padding(.horizontal, 14)
                    .padding(.top, 38)
                    .padding(.bottom, 14)
            }
            .scrollIndicators(.automatic)
            .frame(width: 330)
            .background { QuickHaze.background.ignoresSafeArea() }
        }
        .onChange(of: model.status?.fix) { _, fix in editor.androidMoved(fix) }
    }
}

private struct LocationMap: View {
    @ObservedObject var model: LocationModel
    @ObservedObject var editor: LocationEditor

    var body: some View {
        MapReader { proxy in
            Map(position: $editor.camera) {
                if let route = model.route, model.status?.source == .route, route.points.count >= 2 {
                    MapPolyline(coordinates: route.points.map(\.coordinate))
                        .stroke(QuickHaze.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    Annotation(L("Start"), coordinate: route.points[0].coordinate) { RouteEnd(symbol: "flag.fill") }
                    Annotation(L("End"), coordinate: route.points[route.points.count - 1].coordinate) {
                        RouteEnd(symbol: "flag.checkered")
                    }
                }
                if editor.mode == .route, editor.points.count >= 2 {
                    MapPolyline(coordinates: editor.points.map(\.coordinate))
                        .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [7, 5]))
                }
                if editor.mode == .route {
                    if let base = editor.base, let first = base.points.first {
                        Annotation(base.name ?? L("Start"), coordinate: first.coordinate) { StopDot(label: "1") }
                    }
                    ForEach(Array(editor.stops.enumerated()), id: \.element.id) { index, stop in
                        Annotation(stop.name ?? "", coordinate: stop.point.coordinate) {
                            StopDot(label: "\(index + (editor.base == nil ? 1 : 2))", busy: stop.routing)
                        }
                    }
                }
                if editor.mode == .place, let pin = editor.pin {
                    Marker(pin.name ?? L("Selected place"), systemImage: "mappin", coordinate: pin.point.coordinate)
                        .tint(QuickHaze.rgb(0x8BB35E))
                }
                if let mac = model.status?.mac, model.status?.source != .mac {
                    Annotation(L("This Mac"), coordinate: mac.coordinate) { MacDot() }
                }
                if let fix = model.status?.fix {
                    Annotation(L("Android"), coordinate: fix.point.coordinate, anchor: .center) {
                        AndroidPuck(bearing: fix.bearing - editor.heading, moving: fix.speed > 0)
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(editor.satellite ? .hybrid(elevation: .realistic) : .standard(elevation: .realistic))
            .mapControls {
                MapCompass()
                MapScaleView()
                MapZoomStepper()
                MapPitchToggle()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                editor.cameraChanged(context.camera, byUser: editor.camera.positionedByUser)
            }
            .onTapGesture { position in
                if let coordinate = proxy.convert(position, from: .local) { editor.mapClicked(coordinate, at: position) }
            }
            .overlay(alignment: .topLeading) {
                SearchField(editor: editor, search: editor.search)
                    .padding(.top, 40)
                    .padding(.leading, 14)
            }
            .overlay(alignment: .bottomLeading) {
                MapButtons(model: model, editor: editor)
                    .padding(14)
            }
        }
        .ignoresSafeArea()
    }
}

/// Android on the map: a green puck with an arrow while it moves.
private struct AndroidPuck: View {
    let bearing: Double
    let moving: Bool

    var body: some View {
        ZStack {
            Circle().fill(QuickHaze.accent.opacity(0.22)).frame(width: 44, height: 44)
            Circle().fill(QuickHaze.accent).frame(width: 22, height: 22)
                .overlay { Circle().strokeBorder(Color.white, lineWidth: 3) }
                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
            if moving {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(QuickHaze.onAccent)
                    .rotationEffect(.degrees(bearing))
            }
        }
        .accessibilityLabel(Text(verbatim: L("Android")))
    }
}

private struct MacDot: View {
    var body: some View {
        Image(systemName: "laptopcomputer")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Circle().fill(Color(red: 0.2, green: 0.45, blue: 0.95)))
            .overlay { Circle().strokeBorder(Color.white, lineWidth: 2) }
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }
}

private struct StopDot: View {
    let label: String
    var busy = false

    var body: some View {
        ZStack {
            Circle().fill(Color.white).frame(width: 22, height: 22)
            if busy {
                ProgressView().controlSize(.mini)
            } else {
                Text(verbatim: label).font(QuickHaze.mona(11, 700)).foregroundStyle(QuickHaze.onAccent)
            }
        }
        .overlay { Circle().strokeBorder(QuickHaze.onAccent.opacity(0.5), lineWidth: 1.5) }
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }
}

private struct RouteEnd: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(QuickHaze.onAccent)
            .frame(width: 24, height: 24)
            .background(Circle().fill(QuickHaze.accent))
            .overlay { Circle().strokeBorder(Color.white, lineWidth: 2) }
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }
}

/// The search field over the map, with Apple Maps' suggestions under it.
private struct SearchField: View {
    @ObservedObject var editor: LocationEditor
    @ObservedObject var search: PlaceSearch
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(QuickHaze.textTertiary)
                TextField(text: $search.query, prompt: Text(verbatim: L("Search for a place or coordinates"))) {
                    Text(verbatim: L("Search"))
                }
                .textFieldStyle(.plain)
                .font(QuickHaze.mona(13.5))
                .foregroundStyle(QuickHaze.text)
                .focused($focused)
                .onSubmit { if let first = search.suggestions.first { editor.choose(first) } }
                .onExitCommand { search.clear() }
                if !search.query.isEmpty {
                    Button { search.clear() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(QuickHaze.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: L("Clear")))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(QuickHaze.text.opacity(0.12)) }
            if !search.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(search.suggestions) { suggestion in
                        Button {
                            focused = false
                            editor.choose(suggestion)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: suggestion.point == nil ? "mappin.circle.fill" : "scope")
                                    .font(.system(size: 16))
                                    .foregroundStyle(QuickHaze.accent)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: suggestion.title).font(QuickHaze.mona(13, 600)).foregroundStyle(QuickHaze.text)
                                    if !suggestion.subtitle.isEmpty {
                                        Text(verbatim: suggestion.subtitle).font(QuickHaze.mona(11.5)).foregroundStyle(QuickHaze.textTertiary)
                                    }
                                }
                                .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(QuickHaze.text.opacity(0.12)) }
            }
        }
        .frame(width: 320)
    }
}

/// Follow Android, and the map's look.
private struct MapButtons: View {
    @ObservedObject var model: LocationModel
    @ObservedObject var editor: LocationEditor

    var body: some View {
        HStack(spacing: 8) {
            MapPillButton(symbol: editor.following ? "location.fill" : "location", label: L("Follow Android"),
                          on: editor.following) {
                editor.following.toggle()
                if editor.following { editor.androidMoved(model.status?.fix) }
            }
            .disabled(model.status?.fix == nil)
            if let route = model.route, model.status?.source == .route {
                MapPillButton(symbol: "point.topleft.down.to.point.bottomright.curvepath", label: L("Show Route"), on: false) {
                    editor.show(route)
                }
            }
            MapPillButton(symbol: editor.satellite ? "globe.americas.fill" : "map", label: editor.satellite ? L("Map") : L("Satellite"),
                          on: false) {
                editor.satellite.toggle()
            }
        }
    }
}

private struct MapPillButton: View {
    let symbol: String
    let label: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                Text(verbatim: label).font(QuickHaze.mona(12, 600))
            }
            .foregroundStyle(on ? QuickHaze.onAccent : QuickHaze.text)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background {
                if on {
                    Capsule().fill(QuickHaze.accent)
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
            .overlay { Capsule().strokeBorder(QuickHaze.text.opacity(on ? 0 : 0.12)) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(label)
    }
}

// MARK: - The sidebar

private struct LocationSidebar: View {
    @ObservedObject var model: LocationModel
    @ObservedObject var editor: LocationEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: LocationPanel.title)
                    .font(QuickHaze.hubot(18, 700))
                    .foregroundStyle(QuickHaze.text)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: model.allAppsOnly
                    ? L("Where Android’s GPS says it is for every app. An app can have its own in its window’s Location panel.")
                    : L("Where Android’s GPS says it is: every app’s location, or this app’s own while its window is in front."))
                    .font(QuickHaze.mona(11.5))
                    .foregroundStyle(QuickHaze.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
            // Android has one GPS: an app's own location is what every app
            // hears while its window is in front (LocationCenter in the daemon).
            if !model.allAppsOnly {
                QuickSegmented(label: L("Location for"), options: [(false, L("All Apps")), (true, L("This App"))],
                               selection: model.status.map { $0.ownLocation == true }, fill: true,
                               help: { own in own ? L("This app gets its own location, starting where every app is. Android reports it while this window is in front.")
                                                  : L("This app follows every app’s location.") }) { own in
                    model.send(own ? .ownLocation : .followAllApps)
                }
            }
            AndroidLocationCard(model: model, editor: editor)
            if let route = model.status?.route, model.status?.source == .route {
                NowPlayingCard(model: model, editor: editor, route: route)
            }
            QuickSegmented(label: L("Choose"), options: [(LocationEditor.Mode.place, L("Place")), (.route, L("Route"))],
                           selection: editor.mode, fill: true) { editor.mode = $0 }
            switch editor.mode {
            case .place: PlaceCard(model: model, editor: editor)
            case .route: RouteCard(model: model, editor: editor)
            }
            if let problem = model.problem {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(QuickHaze.rgb(0xF2C14E, light: 0x9A6410))
                    Text(verbatim: problem)
                        .font(QuickHaze.mona(12))
                        .foregroundStyle(QuickHaze.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(QuickHaze.rgb(0xF2C14E, 0.1, light: 0xD09A2C, 0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.problem)
    }
}

/// Where Android is now, why, and the way back to the Mac's own location.
private struct AndroidLocationCard: View {
    @ObservedObject var model: LocationModel
    @ObservedObject var editor: LocationEditor

    var body: some View {
        let status = model.status
        QuickCard(title: L("Android Is At"), scope: status?.ownLocation == true ? L("This app") : L("Every app"), separated: false) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol(status))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(QuickHaze.onAccent)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(QuickHaze.accent))
                VStack(alignment: .leading, spacing: 2) {
                    QuickText(LocationSummary.title(status))
                    if let fix = status?.fix {
                        Text(verbatim: LocationText.coordinates(fix.point))
                            .font(QuickHaze.mona(12).monospacedDigit())
                            .foregroundStyle(QuickHaze.textSecondary)
                            .textSelection(.enabled)
                        if fix.speed > 0 {
                            QuickCaption(L("\(LocationText.speed(fix.speed)) heading \(Int(fix.bearing.rounded()) % 360)°"))
                        }
                    } else if status != nil {
                        QuickCaption(LocationSummary.noFix(status))
                    }
                }
                Spacer(minLength: 0)
                if status?.fix != nil {
                    Button {
                        if let fix = model.status?.fix { editor.show(fix.point) }
                    } label: {
                        Image(systemName: "scope").font(.system(size: 13, weight: .semibold)).foregroundStyle(QuickHaze.accent)
                    }
                    .buttonStyle(.plain)
                    .help(L("Show on Map"))
                    .accessibilityLabel(Text(verbatim: L("Show on Map")))
                }
            }
            if status?.source != .mac {
                LocationButton(title: L("Use My Mac’s Location"), symbol: "laptopcomputer", style: .secondary) {
                    model.send(.mac)
                }
                if status?.macSharing == false {
                    QuickCaption(L("Sharing this Mac’s location is off in Avo’s Settings › Devices › Location, so Android will have no location."))
                }
            }
        }
    }

    private func symbol(_ status: LocationStatus?) -> String {
        switch status?.source {
        case .point: "mappin"
        case .route:
            status?.route.map { LocationText.paceSymbol($0.playback.pace == .recorded && $0.duration == nil ? .walk : $0.playback.pace) }
                ?? "point.topleft.down.to.point.bottomright.curvepath"
        default: "laptopcomputer"
        }
    }
}

/// One line on what Android's GPS reports (the panel and Quick Settings).
enum LocationSummary {
    static func title(_ status: LocationStatus?) -> String {
        guard let status else { return L("Asking Avo…") }
        switch status.source {
        case .mac: return L("This Mac’s location")
        case .point: return status.pointName ?? L("A chosen place")
        case .route: return status.route?.name.map { L("Route: \($0)") } ?? L("A route")
        }
    }

    static func noFix(_ status: LocationStatus?) -> String {
        guard status?.macSharing != false else {
            return L("Sharing this Mac’s location is off in Avo’s Settings › Devices › Location.")
        }
        return L("No location yet. Android gets this Mac’s location while it runs, once macOS knows it.")
    }

    /// "1.2 of 3.4 km · 5 min left", or how the route waits.
    static func progress(_ route: RouteStatus) -> String {
        let done = L("\(LocationText.distance(route.travelled)) of \(LocationText.distance(route.distance))")
        if route.finished { return L("\(done) · Arrived") }
        if route.paused { return L("\(done) · Paused") }
        if route.waiting { return L("\(done) · Waits for Android") }
        return L("\(done) · \(LocationText.duration(route.remaining)) left")
    }
}

/// The route Android follows: how far along, pause, start over, and how it plays.
private struct NowPlayingCard: View {
    @ObservedObject var model: LocationModel
    @ObservedObject var editor: LocationEditor
    let route: RouteStatus
    @State private var seeking: Double?

    var body: some View {
        QuickCard(title: L("Route"), scope: route.playback.loop ? L("Loops") : L("Plays once"), separated: false) {
            VStack(alignment: .leading, spacing: 6) {
                QuickSlider(label: L("Progress"), value: Binding(get: { seeking ?? route.progress }, set: { value in
                    if seeking == nil {
                        model.send(.seek(value))
                    } else {
                        seeking = value
                    }
                }), range: 0...1, step: 0.01, valueText: Text(route.progress, format: .percent.precision(.fractionLength(0)))) { editing in
                    if editing {
                        seeking = route.progress
                    } else if let value = seeking {
                        seeking = nil
                        model.send(.seek(value))
                    }
                }
                QuickCaption(LocationSummary.progress(route))
            }
            if route.waiting {
                QuickCaption(L("Android isn’t running. The route goes on when it does."))
            }
            HStack(spacing: 8) {
                if route.playing || (route.waiting && !route.paused && !route.finished) {
                    LocationButton(title: L("Pause"), symbol: "pause.fill", style: .primary) { model.send(.pause) }
                } else {
                    LocationButton(title: route.finished ? L("Play Again") : L("Resume"), symbol: "play.fill", style: .primary) {
                        model.send(.resume)
                    }
                }
                LocationIconButton(symbol: "backward.end.fill", label: L("Back to the Start")) { model.send(.seek(0)) }
                LocationIconButton(symbol: "pencil", label: L("Edit This Route")) {
                    if let points = model.route { editor.edit(points) }
                }
                .disabled(model.route == nil)
            }
            PlaybackControls(playback: Binding(get: { route.playback }, set: { model.send(.playback($0)) }),
                             recorded: route.duration != nil)
        }
    }
}

/// A place: clicked on the map or found, then set.
private struct PlaceCard: View {
    @ObservedObject var model: LocationModel
    @ObservedObject var editor: LocationEditor

    var body: some View {
        QuickCard(title: L("Place"), scope: L("Stays put"), separated: false) {
            if let pin = editor.pin {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "mappin.circle.fill").font(.system(size: 22)).foregroundStyle(QuickHaze.rgb(0x8BB35E, light: 0x5A8A30))
                    VStack(alignment: .leading, spacing: 2) {
                        QuickText(pin.name ?? L("Selected place"))
                        Text(verbatim: LocationText.coordinates(pin.point))
                            .font(QuickHaze.mona(12).monospacedDigit())
                            .foregroundStyle(QuickHaze.textSecondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                LocationButton(title: L("Move Android Here"), symbol: "location.fill", style: .primary) {
                    model.send(.point(pin.point, name: pin.name))
                }
            } else {
                QuickCaption(L("Click the map or search for a place, then move Android there."))
            }
        }
    }
}

/// A route: stops clicked on the map (by road, or straight), or a file.
private struct RouteCard: View {
    @ObservedObject var model: LocationModel
    @ObservedObject var editor: LocationEditor

    var body: some View {
        QuickCard(title: L("New Route"), scope: editor.isEmpty ? "" : LocationText.distance(editor.draft?.distance ?? 0), separated: false) {
            if editor.isEmpty {
                QuickCaption(L("Click the map to add stops, or import a GPX, KML or KMZ file."))
            } else {
                QuickCaption(stopsSummary)
            }
            QuickToggle(label: L("Follow roads"), caption: L("Apple Maps’ directions between stops"), isOn: editor.followRoads) {
                editor.followRoads = $0
            }
            HStack(spacing: 8) {
                LocationButton(title: L("Import…"), symbol: "square.and.arrow.down", style: .secondary) { editor.importRoute() }
                Spacer(minLength: 0)
                LocationIconButton(symbol: "arrow.uturn.backward", label: L("Undo Last Stop")) { editor.undo() }
                    .disabled(editor.isEmpty)
                LocationIconButton(symbol: "arrow.left.arrow.right", label: L("Reverse")) { editor.reverse() }
                    .disabled(editor.points.count < 2)
                LocationIconButton(symbol: "trash", label: L("Clear")) { editor.clear() }
                    .disabled(editor.isEmpty)
            }
            if model.status?.source != .route {
                PlaybackControls(playback: $editor.playback, recorded: editor.draft?.duration != nil)
            }
            LocationButton(title: L("Play Route"), symbol: "play.fill", style: .primary) {
                guard let draft = editor.draft else { return }
                var playback = model.status?.source == .route ? (model.status?.route?.playback ?? editor.playback) : editor.playback
                if draft.duration == nil, playback.pace == .recorded { playback.pace = .walk }
                editor.playback = playback
                model.send(.route(draft, playback))
            }
            .disabled(!editor.canPlay)
        }
    }

    private var stopsSummary: String {
        let count = editor.points.count
        if let base = editor.base, editor.stops.isEmpty {
            if let duration = base.duration {
                return L("\(count) points, recorded over \(LocationText.duration(duration))")
            }
            return count == 1 ? L("1 point") : L("\(count) points")
        }
        let stops = editor.stops.count + (editor.base == nil ? 0 : 1)
        return stops == 1 ? L("1 stop. Click the map to add the next.") : L("\(stops) stops")
    }
}

/// Pace, how much faster, and whether to loop.
private struct PlaybackControls: View {
    @Binding var playback: LocationPlayback
    let recorded: Bool

    var body: some View {
        let paces = LocationPace.allCases.filter { $0 != .recorded || recorded }
        VStack(alignment: .leading, spacing: 8) {
            QuickSegmented(label: L("Pace"), options: paces.map { ($0, LocationText.pace($0)) },
                           selection: recorded ? playback.pace : (playback.pace == .recorded ? .walk : playback.pace), fill: true,
                           help: { pace in pace.metresPerSecond.map { LocationText.speed($0) } ?? L("At the times it was recorded") }) {
                playback.pace = $0
            }
            QuickRow(label: L("Speed")) {
                QuickSegmented(label: L("Speed"), options: LocationPlayback.multipliers.map { ($0, LocationText.multiplier($0)) },
                               selection: playback.multiplier, segmentPadding: 7) {
                    playback.multiplier = $0
                }
                .fixedSize()
            }
            QuickToggle(label: L("Loop"), caption: L("Start over at the end"), isOn: playback.loop) { playback.loop = $0 }
        }
    }
}

/// Also Quick Settings' All Settings.
struct LocationButton: View {
    enum Style { case primary, secondary }
    let title: String
    let symbol: String
    let style: Style
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12, weight: .bold))
                Text(verbatim: title).font(QuickHaze.mona(13, 650))
            }
            .foregroundStyle(style == .primary ? QuickHaze.onAccent : QuickHaze.accentText)
            .padding(.horizontal, 14)
            .frame(maxWidth: style == .primary ? .infinity : nil)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(style == .primary ? QuickHaze.accent : QuickHaze.inset)
            }
            .overlay {
                if style == .secondary {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(QuickHaze.accent.opacity(0.35))
                }
            }
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct LocationIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(QuickHaze.accentText)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(QuickHaze.inset))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(Text(verbatim: label))
    }
}

// MARK: - In Quick Settings

/// Quick Settings › Location: what Android's GPS reports, and the panel.
struct QuickLocationCard: View {
    @ObservedObject var model = LocationModel.shared

    var body: some View {
        let status = model.status
        QuickCard(title: L("Location"), scope: L("Every app"), separated: false) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: status?.source == .route ? "point.topleft.down.to.point.bottomright.curvepath"
                      : status?.source == .point ? "mappin" : "location.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(QuickHaze.onAccent)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(QuickHaze.accent))
                VStack(alignment: .leading, spacing: 1) {
                    QuickText(LocationSummary.title(status))
                    if let route = status?.route, status?.source == .route {
                        QuickCaption(LocationSummary.progress(route))
                    } else if let fix = status?.fix {
                        QuickCaption(LocationText.coordinates(fix.point))
                    } else if status != nil {
                        QuickCaption(LocationSummary.noFix(status))
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                LocationButton(title: L("Open Location…"), symbol: "map", style: .secondary) {
                    LocationPanel.shared.show()
                }
                Spacer(minLength: 0)
                if let route = status?.route, status?.source == .route {
                    let pausable = route.playing || (route.waiting && !route.paused && !route.finished)
                    LocationIconButton(symbol: pausable ? "pause.fill" : "play.fill", label: pausable ? L("Pause") : L("Resume")) {
                        model.send(pausable ? .pause : .resume)
                    }
                }
                if let source = status?.source, source != .mac {
                    LocationIconButton(symbol: "laptopcomputer", label: L("Use My Mac’s Location")) { model.send(.mac) }
                }
            }
        }
        .onAppear { model.beginWatching() }
        .onDisappear { model.endWatching() }
    }
}
