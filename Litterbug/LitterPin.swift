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

    var symbol: String {
        switch type {
        case "bottle": "waterbottle.fill"
        case "can": "cylinder.fill"
        case "bag": "bag.fill"
        default: "trash.fill"
        }
    }
}
