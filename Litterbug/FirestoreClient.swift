import Foundation

struct FirestoreClient {
    static let shared = FirestoreClient()

    private let projectID: String
    private let apiKey: String

    private init() {
        let config = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist").flatMap(NSDictionary.init(contentsOf:))
        projectID = config?["PROJECT_ID"] as? String ?? ""
        apiKey = config?["API_KEY"] as? String ?? ""
    }

    private var baseURL: String {
        "https://firestore.googleapis.com/v1/projects/\(projectID)/databases/(default)/documents"
    }

    func list(_ collection: String, fields: [String]) async throws -> [FirestoreDocument] {
        guard var components = URLComponents(string: "\(baseURL)/\(collection)") else { throw URLError(.badURL) }
        components.queryItems = [
            URLQueryItem(name: "pageSize", value: "300"),
            URLQueryItem(name: "key", value: apiKey),
        ] + fields.map { URLQueryItem(name: "mask.fieldPaths", value: $0) }
        guard let url = components.url else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        // Error bodies (e.g. 429 quota) decode as an empty list, so reject them instead of wiping the map.
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(FirestoreList.self, from: data).documents ?? []
    }

    /// Sets `fields`; any name in `deleting` is removed from the doc (it's in the update mask but not the body).
    func update(_ collection: String, id: String, fields: [String: FirestoreValue], deleting: [String] = []) async throws {
        guard var components = URLComponents(string: "\(baseURL)/\(collection)/\(id)") else { throw URLError(.badURL) }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
            + (fields.keys.sorted() + deleting).map { URLQueryItem(name: "updateMask.fieldPaths", value: $0) }
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["fields": fields])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    }
}

struct FirestoreList: Decodable {
    let documents: [FirestoreDocument]?
}

struct FirestoreDocument: Decodable {
    let name: String
    let fields: [String: FirestoreValue]?

    var id: String {
        String(name.split(separator: "/").last ?? "")
    }

    subscript(key: String) -> FirestoreValue? {
        fields?[key]
    }
}

struct FirestoreValue: Codable {
    var doubleValue: Double?
    var integerValue: String?
    var stringValue: String?
    var bytesValue: String?
    var timestampValue: String?

    var number: Double? {
        doubleValue ?? integerValue.flatMap(Double.init)
    }

    var data: Data? {
        bytesValue.flatMap { Data(base64Encoded: $0) }
    }

    var date: Date? {
        guard let timestampValue else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: timestampValue) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: timestampValue)
    }

    static func string(_ value: String) -> FirestoreValue { FirestoreValue(stringValue: value) }
    static func double(_ value: Double) -> FirestoreValue { FirestoreValue(doubleValue: value) }
    static func bytes(_ value: Data) -> FirestoreValue { FirestoreValue(bytesValue: value.base64EncodedString()) }
    static func timestamp(_ value: Date) -> FirestoreValue {
        FirestoreValue(timestampValue: ISO8601DateFormatter().string(from: value))
    }
}
