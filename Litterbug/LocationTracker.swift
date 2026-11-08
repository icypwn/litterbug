import CoreLocation
import Observation

@MainActor
@Observable
final class LocationTracker: NSObject, CLLocationManagerDelegate {
    /// Shared so the last fix survives tab switches (HomeView is rebuilt each time).
    static let shared = LocationTracker()

    var location: CLLocation?

    /// Demo: everyone stands in the Spiedie Fest field at Otsiningo Park (where the demo litter is),
    /// whether or not they've shared their location. `defaults write icy.Litterbug realLocation -bool YES`
    /// switches back to real GPS.
    static let demoSpot = CLLocation(latitude: 42.1295, longitude: -75.9025)
    static var usesDemoSpot: Bool { !UserDefaults.standard.bool(forKey: "realLocation") }

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        if Self.usesDemoSpot { location = Self.demoSpot }
    }

    func start() {
        guard !Self.usesDemoSpot else { return }
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        Task { @MainActor in
            guard !Self.usesDemoSpot else { return }
            self.location = latest
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        manager.startUpdatingLocation()
    }
}
