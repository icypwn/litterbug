import Foundation
import CoreLocation

struct LitterPin: Identifiable, Equatable {
    let id: String
    let lat: Double
    let lon: Double
    let type: String

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
