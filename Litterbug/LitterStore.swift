import Foundation
import Observation

@MainActor
@Observable
final class LitterStore {
    /// Shared so pins survive tab switches (HomeView is rebuilt each time).
    static let shared = LitterStore()

    var pins: [LitterPin] = []
    /// Consecutive days (ending today, or yesterday if nothing yet today) with at least one cleanup.
    var streak = 0

    func poll(every interval: Duration = .seconds(2)) async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: interval)
        }
    }

    func refresh() async {
        guard let latest = await fetch(), latest != pins else { return }
        pins = latest
    }

    /// Manual refresh: fetch, then clear and repopulate so pins and rows visibly pop back in.
    func reload() async {
        guard let latest = await fetch() else { return }
        pins = []
        try? await Task.sleep(for: .milliseconds(200))
        pins = latest
    }

    /// Demo reset: every placed piece (tagged with `demoType`) that has been picked up goes back on
    /// the map as it was — open, original type, no photo or cleanup info. Seeded history is untouched.
    /// Returns how many pieces were restored.
    func resetDemoPieces() async throws -> Int {
        let documents = try await FirestoreClient.shared.list("litter", fields: ["demoType", "status"])
        let picked = documents.filter { $0["demoType"] != nil && $0["status"]?.stringValue == "cleaned" }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for document in picked {
                let type = document["demoType"]?.stringValue ?? "litter"
                group.addTask {
                    try await FirestoreClient.shared.update(
                        "litter", id: document.id,
                        fields: ["status": .string("open"), "type": .string(type)],
                        deleting: ["photo", "place", "cleanedAt", "cleanedBy", "bboxX", "bboxY", "bboxSize"]
                    )
                }
            }
            try await group.waitForAll()
        }
        await reload()
        return picked.count
    }

    private func fetch() async -> [LitterPin]? {
        #if DEBUG
        // Launch with LITTER_DEMO=1 to show sample pins without reading Firestore.
        if ProcessInfo.processInfo.environment["LITTER_DEMO"] != nil {
            let center = (lat: 42.1302, lon: -75.9030)
            let offsets: [(String, Double, Double)] = [
                ("cup", 0.0001, 0.0001), ("bottle", 0.0004, -0.0003), ("can", -0.0003, 0.0003),
                ("bag", 0.0001, -0.0006), ("wrapper", -0.0005, -0.0002), ("litter", 0.0006, 0.0004),
            ]
            return offsets.map { LitterPin(id: "demo-\($0.0)", lat: center.lat + $0.1, lon: center.lon + $0.2, type: $0.0) }
        }
        #endif
        guard let documents = try? await FirestoreClient.shared.list("litter", fields: ["lat", "lon", "type", "status", "cleanedAt", "cleanedBy"]) else { return nil }
        // Streak is the signed-in account's own cleanups.
        let me = AccountStore.shared.currentID
        let mine = documents.filter { $0["status"]?.stringValue == "cleaned" && $0["cleanedBy"]?.stringValue == me }
        let days = Self.streak(from: mine.compactMap { $0["cleanedAt"]?.date })
        if days != streak { streak = days }
        return documents
            .filter { $0["status"]?.stringValue != "cleaned" }
            .compactMap(LitterPin.init(document:))
    }
}

extension LitterStore {
    static func streak(from dates: [Date], calendar: Calendar = .current, now: Date = .now) -> Int {
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
        var day = calendar.startOfDay(for: now)
        if !days.contains(day) { day = calendar.date(byAdding: .day, value: -1, to: day)! }
        var count = 0
        while days.contains(day) {
            count += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return count
    }
}

private extension LitterPin {
    init?(document: FirestoreDocument) {
        guard let lat = document["lat"]?.number, let lon = document["lon"]?.number else { return nil }
        self.init(id: document.id, lat: lat, lon: lon, type: document["type"]?.stringValue ?? "litter")
    }
}
