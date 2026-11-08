import UIKit
import CoreLocation
import Observation

/// Logs a pickup: Gemini checks the photo, then the litter doc is marked cleaned (or, for the + button's
/// unlogged litter, created). Shared by the review screen and the + flow, which saves in the background.
enum PickupSaver {
    enum Outcome {
        case saved(type: String)
        case rejected(String)
        case failed
    }

    static func save(pin: LitterPin, type expected: String, photo: UIImage?, detection: LitterDetection,
                     cutout: UIImage?, selfie: UIImage?, location: CLLocation?,
                     sighting: LitterLocator.Sighting? = nil, place knownPlace: String? = nil) async -> Outcome {
        let isNew = pin.id.hasPrefix(LitterPin.newPrefix)
        guard let jpeg = detection.crop.jpegData(compressionQuality: 0.7) else { return .failed }
        var type = expected

        // Gemini checks it's really the litter the drone saw here before any points are given. Normally that
        // already happened in the scan's one look (`sighting`); PickupVerifier is only the fallback.
        var description = ""
        var matches: Bool, seenType: String
        if let sighting {
            (matches, seenType, description) = (sighting.matches, sighting.seenType, sighting.description)
        } else {
            do {
                let verdict = try await PickupVerifier.verify(photo: photo ?? detection.crop, expectedType: type)
                (matches, seenType, description) = (verdict.matches, verdict.seenType, verdict.reason)
            } catch {
                return .rejected("Couldn't check the photo. Check your connection and try again.")
            }
        }
        // New items have no drone type to match: any litter counts, and Gemini names it.
        if isNew, matches { type = seenType }
        // Demo pieces are fake data (no drone photo to check against): every scan of one is approved.
        if pin.isDemo { matches = true }
        guard matches else {
            return .rejected(seenType != type && type != "litter"
                ? "That looks like a \(LitterType.displayName(seenType).lowercased()), not a \(LitterType.displayName(type).lowercased()). Retake it?"
                : "Couldn't see the litter in that photo. Retake it?")
        }

        let here = location ?? pin.location
        let place: String
        if let knownPlace { place = knownPlace } else { place = await placeName(for: here) }
        // A new item becomes its own doc (PATCH creates it) at where they're standing.
        var fields: [String: FirestoreValue] = [
            "status": .string("cleaned"),
            "type": .string(type),
            "place": .string(place),
            "photo": .bytes(jpeg),
            "bboxX": .double(detection.box.minX),
            "bboxY": .double(detection.box.minY),
            "bboxSize": .double(detection.box.width),
            "cleanedAt": .timestamp(.now),
            "cleanedBy": .string(AccountStore.shared.currentID),
            "pointsAwarded": .integer(isNew ? LitterType.points(type) : pin.points),
            "description": .string(description),
        ]
        if isNew {
            fields["lat"] = .double(here.coordinate.latitude)
            fields["lon"] = .double(here.coordinate.longitude)
            fields["createdAt"] = .timestamp(.now)
            fields["source"] = .string("user")
        }
        // Small: the whole doc must stay under Firestore's 1 MB.
        if let cutout, let png = cutout.downscaled(maxSide: 400).pngData() { fields["cutout"] = .bytes(png) }
        if let selfie, let selfieJPEG = selfie.downscaled(maxSide: 360).jpegData(compressionQuality: 0.6) {
            fields["selfie"] = .bytes(selfieJPEG)
        }
        do {
            try await FirestoreClient.shared.update("litter", id: docID(for: pin), fields: fields)
            return .saved(type: type)
        } catch {
            return .failed
        }
    }

    /// The Firestore doc id: the pin's, or for a + item, its id without the stand-in prefix.
    static func docID(for pin: LitterPin) -> String {
        pin.id.hasPrefix(LitterPin.newPrefix) ? String(pin.id.dropFirst(LitterPin.newPrefix.count)) : pin.id
    }

    private static func placeName(for location: CLLocation) async -> String {
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
        return placemark?.areasOfInterest?.first ?? placemark?.name ?? "Nearby"
    }

    /// The + flow: no review screen. Jump to Collection, stick the cutout on as the newest card,
    /// and save in the background; the card becomes the real entry once it's in (or peels off if not).
    @MainActor
    static func dropIntoCollection(pin: LitterPin, scan: PickupScan.Result, photo: UIImage?, location: CLLocation?) {
        let store = CollectionStore.shared
        store.beginDrop(id: docID(for: pin), sticker: scan.cutout ?? scan.detection.crop,
                        type: scan.sighting?.seenType ?? "litter",
                        description: scan.sighting?.description ?? "",
                        place: scan.place ?? "Nearby")
        AppRouter.shared.requestedTab = .leaderboard
        Task {
            let outcome = await save(pin: pin, type: pin.type, photo: photo, detection: scan.detection,
                                     cutout: scan.cutout, selfie: nil, location: location,
                                     sighting: scan.sighting, place: scan.place)
            await store.finishDrop(outcome)
        }
    }
}

/// Lets a screen ask for a tab switch (the + flow jumps to Collection).
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()
    var requestedTab: AppTab?
}
