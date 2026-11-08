import Foundation
import Observation

@MainActor
@Observable
final class LitterStore {
    var pins: [LitterPin] = []

    private let collectionURL: URL? = {
        guard let url = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist"),
              let config = NSDictionary(contentsOf: url),
              let projectID = config["PROJECT_ID"] as? String,
              let apiKey = config["API_KEY"] as? String else { return nil }
        return URL(string: "https://firestore.googleapis.com/v1/projects/\(projectID)/databases/(default)/documents/litter?pageSize=300&key=\(apiKey)")
    }()

    func poll(every interval: Duration = .seconds(2)) async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: interval)
        }
    }

    private func refresh() async {
        guard let collectionURL,
              let (data, _) = try? await URLSession.shared.data(from: collectionURL),
              let response = try? JSONDecoder().decode(FirestoreList.self, from: data) else { return }
        let latest = (response.documents ?? []).compactMap(LitterPin.init(document:))
        if latest != pins {
            pins = latest
        }
    }
}

private struct FirestoreList: Decodable {
    let documents: [FirestoreDocument]?
}

private struct FirestoreDocument: Decodable {
    let name: String
    let fields: [String: FirestoreValue]
}

private struct FirestoreValue: Decodable {
    let doubleValue: Double?
    let integerValue: String?
    let stringValue: String?

    var number: Double? {
        doubleValue ?? integerValue.flatMap(Double.init)
    }
}

private extension LitterPin {
    init?(document: FirestoreDocument) {
        guard let lat = document.fields["lat"]?.number,
              let lon = document.fields["lon"]?.number,
              let id = document.name.split(separator: "/").last else { return nil }
        self.init(id: String(id), lat: lat, lon: lon, type: document.fields["type"]?.stringValue ?? "litter")
    }
}
