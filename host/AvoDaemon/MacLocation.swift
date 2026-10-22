import AvoDaemonCore
import CoreLocation
import os

/// This Mac's location for Android's GPS ("Share this Mac's location"):
/// CoreLocation (Wi-Fi positioning on most Macs) while Android runs, passed
/// to the engine as GNSS fixes. macOS asks the user the first time.
@MainActor
final class MacLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let deliver: (LocationFix?) -> Void
    private var running = false
    private var sharing = true
    private var active = false
    private let logger = Logger(subsystem: "com.avodroid", category: "Location")

    init(deliver: @escaping (LocationFix?) -> Void) {
        self.deliver = deliver
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
    }

    func update(running: Bool? = nil, sharing: Bool? = nil) {
        if let running { self.running = running }
        if let sharing { self.sharing = sharing }
        let wanted = self.running && self.sharing
        guard wanted != active else { return }
        active = wanted
        if wanted {
            manager.requestWhenInUseAuthorization()
            manager.startUpdatingLocation()
            if let last = manager.location { send(last) }
        } else {
            manager.stopUpdatingLocation()
            deliver(nil)
        }
    }

    private func send(_ location: CLLocation) {
        guard active, location.horizontalAccuracy >= 0 else { return }
        deliver(LocationFix(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                            altitude: location.verticalAccuracy >= 0 ? location.altitude : 0,
                            accuracy: location.horizontalAccuracy, speed: max(location.speed, 0), bearing: max(location.course, 0)))
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        MainActor.assumeIsolated { send(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated { logger.notice("location unavailable: \(message, privacy: .public)") }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            logger.notice("location authorization: \(status.rawValue)")
            if active, status == .authorizedAlways { self.manager.startUpdatingLocation() }
        }
    }
}
