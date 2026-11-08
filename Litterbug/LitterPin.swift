import Foundation
import CoreLocation

struct LitterPin: Identifiable, Equatable {
    let id: String
    let lat: Double
    let lon: Double
    let type: String
    /// Placed by hand for demos (no drone photo behind it): any scan of it is approved.
    var isDemo = false

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var location: CLLocation {
        CLLocation(latitude: lat, longitude: lon)
    }

    /// Id prefix for a stand-in pin made by the + button (litter that isn't on the map yet).
    static let newPrefix = "new-"

    /// A stand-in for unlogged litter at your feet; CaptureFlow saves it as a new doc.
    static func unlogged(at location: CLLocation) -> LitterPin {
        LitterPin(id: newPrefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20),
                  lat: location.coordinate.latitude, lon: location.coordinate.longitude, type: "litter")
    }

    /// Reward for picking it up: fixed per category.
    var points: Int { LitterType.points(type) }

    var symbol: String {
        LitterType.all.contains(type) ? "litter-\(type)" : "litter-litter"
    }
}

enum LitterType {
    static let all = ["bottle", "can", "bag", "wrapper", "cup", "litter"]
    /// Fixed points per category, by how much good removing it does.
    /// Keep in sync with POINTS in the drone's classify.py.
    static func points(_ type: String) -> Int {
        switch type {
        case "bag", "bottle": 80
        case "can", "cup": 60
        case "wrapper": 50
        default: 30
        }
    }

    static func displayName(_ type: String) -> String {
        switch type {
        case "bottle": "Bottle"
        case "can": "Tin can"
        case "bag": "Plastic bag"
        case "wrapper": "Wrapper"
        case "cup": "Cup"
        default: "Litter"
        }
    }
}
