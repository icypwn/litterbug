import SwiftUI
import Observation

/// Collection: the cutout stickers of litter picked up (Gemini box → SAM, with the white sticker border),
/// yours and your friends', with what it is and where it came from.
@MainActor
@Observable
final class CollectionStore {
    static let shared = CollectionStore()

    struct Item: Identifiable, Equatable {
        let id: String
        let type: String
        let place: String
        let description: String
        let cleanedAt: Date
        let cleanedBy: String
        let cutout: UIImage

        static func == (a: Item, b: Item) -> Bool {
            a.id == b.id && a.cleanedAt == b.cleanedAt && a.description == b.description && a.type == b.type
        }
    }

    /// A + pickup still being checked and saved: shown as the newest sticker in Mine until it lands
    /// (then the real entry replaces it) or is rejected (then it peels off with the reason).
    struct Drop: Equatable {
        let id: String
        let sticker: UIImage
        /// Known from the scan, so the label shows the moment the sticker lands.
        let type: String
        let description: String
        let place: String
        var rejection: String?
    }

    var items: [Item] = []
    var drop: Drop?
    var loaded = false
    /// The sticker that was slammed in: its saved entry takes its place without popping in again.
    var landedID: String?

    func refresh() async {
        guard let all = await fetch() else { return }
        if all != items { items = all }
        if let drop, items.contains(where: { $0.id == drop.id }) { self.drop = nil }
        loaded = true
    }

    private func fetch() async -> [Item]? {
        guard let documents = try? await FirestoreClient.shared.list(
            "litter", fields: ["status", "cleanedBy", "type", "place", "description", "cleanedAt", "cutout", "hiddenFromCollection"]
        ) else { return nil }
        return documents.compactMap { d -> Item? in
            // Hidden from Collection only (still in Social / Ranks): `hiddenFromCollection: "yes"`.
            guard d["status"]?.stringValue == "cleaned", d["hiddenFromCollection"] == nil,
                  let by = d["cleanedBy"]?.stringValue,
                  let cutout = d["cutout"]?.data.flatMap(UIImage.init(data:)) else { return nil }
            return Item(
                id: d.id,
                type: d["type"]?.stringValue ?? "litter",
                place: d["place"]?.stringValue ?? "Nearby",
                description: d["description"]?.stringValue ?? "",
                cleanedAt: d["cleanedAt"]?.date ?? .distantPast,
                cleanedBy: by,
                cutout: cutout
            )
        }
        .sorted { $0.cleanedAt > $1.cleanedAt }
    }

    func beginDrop(id: String, sticker: UIImage, type: String, description: String, place: String) {
        landedID = id
        drop = Drop(id: id, sticker: sticker, type: type, description: description, place: place)
    }

    func finishDrop(_ outcome: PickupSaver.Outcome) async {
        switch outcome {
        case .saved:
            // Swap the landed sticker for its saved entry in one un-animated step: same spot, same tilt,
            // same labels, so nothing visibly moves.
            let latest = await fetch()
            var swap = Transaction()
            swap.disablesAnimations = true
            withTransaction(swap) {
                if let latest { items = latest }
                drop = nil
            }
        case .rejected(let reason):
            drop?.rejection = reason
            try? await Task.sleep(for: .seconds(3))
            drop = nil
        case .failed:
            drop?.rejection = "Couldn't save, try again"
            try? await Task.sleep(for: .seconds(3))
            drop = nil
        }
    }
}

struct CollectionView: View {
    enum Scope: Hashable { case mine, trade }

    @State private var store = CollectionStore.shared
    @State private var account = AccountStore.shared
    @State private var scope: Scope = .mine

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3)

    private var mine: [CollectionStore.Item] {
        store.items.filter { $0.cleanedBy == account.currentID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                PageTitle("Collection")
                PillPicker(selection: $scope, options: [(.mine, "Mine (\(mine.count))"), (.trade, "Trade")])
                    .padding(.top, 10)
            }
            .padding(.horizontal, 24)

            switch scope {
            case .mine: grid
            case .trade: TradeView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.appBackground)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: scope)
        .task {
            async let users: Void = account.refresh()
            async let litter: Void = store.refresh()
            _ = await (users, litter)
        }
    }

    private var grid: some View {
        ScrollView {
            if store.loaded && mine.isEmpty && store.drop == nil {
                Text("Pick up some litter and it'll show up here")
                    .font(.custom("MoreSugarRegular", size: 17))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
            }
            LazyVGrid(columns: columns, spacing: 18) {
                if let drop = store.drop, !mine.contains(where: { $0.id == drop.id }) {
                    DroppingSticker(drop: drop)
                }
                ForEach(Array(mine.enumerated()), id: \.element.id) { index, item in
                    CollectionSticker(item: item)
                        .modifier(PopIn(delay: 0.03 * Double(min(index, 9)), enabled: item.id != store.landedID))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 44)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: store.items)
        }
        // Normally clipped to the grid area; while a sticker is being slammed in, nothing is clipped so it
        // swoops in over the title and the Mine / Trade switch (the grid draws after them, so it's on top).
        .scrollClipDisabled(store.drop != nil)
        .clipShape(Rectangle().inset(by: store.drop == nil ? 0 : -600))
        .zIndex(1)
    }
}

/// One sticker: the cutout (it carries its own white border), centered labels underneath.
struct CollectionSticker: View {
    let item: CollectionStore.Item

    private var tilt: Double { Self.tilt(for: item.id) }

    /// Each sticker's resting tilt, from its id — the landing sticker uses it too so it lands where it stays.
    static func tilt(for id: String) -> Double {
        Double(id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 11 - 5)
    }

    var body: some View {
        VStack(spacing: 3) {
            Image(uiImage: item.cutout)
                .resizable()
                .scaledToFit()
                .frame(height: 92)
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                .rotationEffect(.degrees(tilt))
                .padding(.bottom, 4)

            Text(LitterType.displayName(item.type))
                .font(.custom("CheeseMilky", size: 16))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if !item.description.isEmpty {
                Text(item.description)
                    .font(.custom("MoreSugarRegular", size: 11))
                    .opacity(0.75)
                    .lineLimit(2)
            }
            Text(item.place)
                .font(.custom("MoreSugarRegular", size: 10))
                .opacity(0.55)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
    }
}

/// The + pickup landing: slapped on from above like a sticker, then either replaced by the real entry
/// once it's saved or peeled away with the reason it wasn't.
struct DroppingSticker: View {
    let drop: CollectionStore.Drop
    @State private var stuck = false

    var body: some View {
        // Same spacing as CollectionSticker, so it lands exactly where it stays.
        VStack(spacing: 3) {
            Image(uiImage: drop.sticker)
                .resizable()
                .scaledToFit()
                .frame(height: 92)
                .shadow(color: .black.opacity(stuck ? 0.3 : 0.5), radius: stuck ? 4 : 16, y: stuck ? 2 : 12)
                .scaleEffect(stuck ? 1 : 2.2)
                .rotationEffect(.degrees(stuck ? CollectionSticker.tilt(for: drop.id) : -18))
                .offset(y: stuck ? 0 : -170)   // starts up over the title and the Mine / Trade switch
                .opacity(drop.rejection == nil ? 1 : 0.35)
                .padding(.bottom, 4)
            if let rejection = drop.rejection {
                Text(rejection)
                    .font(.custom("MoreSugarRegular", size: 11))
                    .lineLimit(3)
            } else {
                // Same labels as a saved sticker, straight from the scan.
                Text(LitterType.displayName(drop.type))
                    .font(.custom("CheeseMilky", size: 16))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !drop.description.isEmpty {
                    Text(drop.description)
                        .font(.custom("MoreSugarRegular", size: 11))
                        .opacity(0.75)
                        .lineLimit(2)
                }
                Text(drop.place)
                    .font(.custom("MoreSugarRegular", size: 10))
                    .opacity(0.55)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.55).delay(0.15)) { stuck = true }
        }
    }
}
