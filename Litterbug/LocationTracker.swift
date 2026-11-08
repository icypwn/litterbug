import CoreLocation
import Observation

@MainActor
@Observable
final class LocationTracker: NSObject, CLLocationManagerDelegate {
    /// Shared so the last fix survives tab switches (HomeView is rebuilt each time).
    static let shared = LocationTracker()

    var location: CLLocation?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        Task { @MainActor in self.location = latest }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        manager.startUpdatingLocation()
    }
}
