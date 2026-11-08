import Foundation
import CoreLocation

struct LitterPin: Identifiable, Equatable {
    let id: String
    let lat: Double
    let lon: Double
    let type: String
    /// Reward for picking it up, set by the drone from Gemini's 1-10 score (score x 10).
    var points: Int = LitterType.defaultPoints

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var location: CLLocation {
        CLLocation(latitude: lat, longitude: lon)
    }

    var symbol: String {
        LitterType.all.contains(type) ? "litter-\(type)" : "litter-litter"
    }
}

enum LitterType {
    static let all = ["bottle", "can", "bag", "wrapper", "cup", "litter"]
    /// Points for litter the drone didn't score (older pins, manual ones).
    static let defaultPoints = 10

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
