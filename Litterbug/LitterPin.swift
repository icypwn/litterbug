import Foundation
import CoreLocation

struct LitterPin: Identifiable, Decodable {
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

extension LitterPin {
    static let samples: [LitterPin] = [
        LitterPin(id: "1", lat: 37.3362, lon: -122.0105, type: "bottle"),
        LitterPin(id: "2", lat: 37.3338, lon: -122.0071, type: "can"),
        LitterPin(id: "3", lat: 37.3331, lon: -122.0112, type: "bag"),
        LitterPin(id: "4", lat: 37.3371, lon: -122.0068, type: "wrapper"),
    ]
}
