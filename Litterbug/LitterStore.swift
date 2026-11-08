import Foundation
import CoreLocation
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
    /// Returns how many picked-up pieces were restored and what the piece next to you is now.
    /// Judges' demo: each reset turns the piece next to you into the next of these, so every judge
    /// picks up something different.
    private static let demoCycle = ["bottle", "cup", "wrapper"]

    func resetDemoPieces() async throws -> (restored: Int, next: String?) {
        let documents = try await FirestoreClient.shared.list("litter", fields: ["demoType", "status", "lat", "lon"])
        let demo = documents.filter { $0["demoType"] != nil }

        // The demo piece right by you (within 15 m), picked up or not, moves on to the next object.
        let here = LocationTracker.shared.location ?? LocationTracker.demoSpot
        let close = demo
            .compactMap { d -> (FirestoreDocument, CLLocationDistance)? in
                guard let lat = d["lat"]?.number, let lon = d["lon"]?.number else { return nil }
                return (d, CLLocation(latitude: lat, longitude: lon).distance(from: here))
            }
            .filter { $0.1 <= 15 }
            .min { $0.1 < $1.1 }?.0
        var next: String?
        if let close {
            let current = close["demoType"]?.stringValue ?? ""
            let index = Self.demoCycle.firstIndex(of: current) ?? -1
            next = Self.demoCycle[(index + 1) % Self.demoCycle.count]
        }

        let picked = demo.filter { $0["status"]?.stringValue == "cleaned" || $0.id == close?.id }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for document in picked {
                let isClose = document.id == close?.id
                let type = isClose ? next! : document["demoType"]?.stringValue ?? "litter"
                group.addTask {
                    try await FirestoreClient.shared.update(
                        "litter", id: document.id,
                        fields: ["status": .string("open"), "type": .string(type)]
                            .merging(isClose ? ["demoType": .string(type)] : [:]) { a, _ in a },
                        deleting: ["photo", "place", "cleanedAt", "cleanedBy", "bboxX", "bboxY", "bboxSize"]
                    )
                }
            }
            try await group.waitForAll()
        }
        await reload()
        return (picked.filter { $0["status"]?.stringValue == "cleaned" }.count, next)
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
        guard let documents = try? await FirestoreClient.shared.list("litter", fields: ["lat", "lon", "type", "status", "cleanedAt", "cleanedBy", "demoType"]) else { return nil }
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
        self.init(id: document.id, lat: lat, lon: lon, type: document["type"]?.stringValue ?? "litter",
                  isDemo: document["demoType"] != nil)
    }
}
