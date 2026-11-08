import SwiftUI

/// Trade one of your stickers for one of a friend's: yours on the left, theirs on the right, a scuffed
/// swap arrow between, and a request that goes to them (Firestore `trades`, status "pending").
struct TradeView: View {
    @State private var store = CollectionStore.shared
    @State private var account = AccountStore.shared
    @State private var yours: CollectionStore.Item?
    @State private var theirs: CollectionStore.Item?
    @State private var picking: Side?
    @State private var isSending = false
    @State private var status: String?
    @State private var swapSpin = 0.0

    enum Side: Identifiable { case yours, theirs; var id: Self { self } }

    private var mine: [CollectionStore.Item] { store.items.filter { $0.cleanedBy == account.currentID } }
    private var friends: [CollectionStore.Item] {
        let ids = Set(account.current?.friends ?? [])
        return store.items.filter { ids.contains($0.cleanedBy) }
    }

    private func name(of userID: String) -> String {
        account.users.first { $0.id == userID }?.name ?? "Friend"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)   // with the one below, keeps the squares centred above the button

            // Top-aligned so the arrows sit at the middle of the squares, not of squares + labels.
            HStack(alignment: .top, spacing: 6) {
                TradeSlot(label: "Yours", item: yours) { picking = .yours }
                Image("swap")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(swapSpin))
                    .padding(.top, (TradeSlot.boxHeight - 40) / 2)
                TradeSlot(label: theirs.map { name(of: $0.cleanedBy) + "'s" } ?? "Theirs", item: theirs) { picking = .theirs }
            }

            Spacer(minLength: 20)

            // Always laid out (blank until there's something to say): appearing after "Send request"
            // would otherwise shrink the spacers and nudge the centred squares up.
            Text(status ?? " ")
                .font(.custom("MoreSugarRegular", size: 15))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .opacity(status == nil ? 0 : 1)
                .padding(.bottom, 12)

            Button {
                Task { await send() }
            } label: {
                Text(isSending ? "Sending…" : "Send request")
                    .font(.custom("MoreSugarRegular", size: 20))
                    .foregroundStyle(Color.appBackground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(yours == nil || theirs == nil || isSending)
            .opacity(yours == nil || theirs == nil ? 0.4 : 1)
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 24)
        .sheet(item: $picking) { side in
            StickerPickerSheet(
                title: side == .yours ? "Your stickers" : "Friends' stickers",
                items: side == .yours ? mine : friends,
                owner: side == .yours ? nil : { name(of: $0.cleanedBy) }
            ) { picked in
                if side == .yours { yours = picked } else { theirs = picked }
                status = nil
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { swapSpin += 180 }
            }
        }
    }

    private func send() async {
        guard let yours, let theirs else { return }
        isSending = true
        status = nil
        do {
            try await FirestoreClient.shared.update("trades", id: UUID().uuidString, fields: [
                "from": .string(account.currentID),
                "to": .string(theirs.cleanedBy),
                "give": .string(yours.id),
                "want": .string(theirs.id),
                "status": .string("pending"),
                "createdAt": .timestamp(.now),
            ])
            status = "Request sent to \(name(of: theirs.cleanedBy))"
            self.yours = nil
            self.theirs = nil
        } catch {
            status = "Couldn't send, try again"
        }
        isSending = false
    }
}

/// A dashed slot: the chosen sticker, or a hand-drawn + to pick one.
struct TradeSlot: View {
    static let boxHeight: CGFloat = 170

    let label: String
    let item: CollectionStore.Item?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(item == nil ? 0.6 : 0), style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                    if let item {
                        Image(uiImage: item.cutout)
                            .resizable()
                            .scaledToFit()
                            .padding(10)
                            .shadow(color: .black.opacity(0.3), radius: 5, y: 3)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    } else {
                        Image("add")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 30, height: 30)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(height: Self.boxHeight)
                .animation(.spring(response: 0.4, dampingFraction: 0.6), value: item?.id)

                Text(label)
                    .font(.custom("MoreSugarRegular", size: 16))
                    .foregroundStyle(.white)
                Text(item.map { LitterType.displayName($0.type) } ?? "Tap to pick")
                    .font(.custom("MoreSugarRegular", size: 13))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Grid of stickers to choose one for a trade.
struct StickerPickerSheet: View {
    let title: String
    let items: [CollectionStore.Item]
    /// Whose sticker it is, shown under each (friends' side only).
    let owner: ((CollectionStore.Item) -> String)?
    let onPick: (CollectionStore.Item) -> Void

    @Environment(\.dismiss) private var dismiss
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageTitle(title)
                .padding(.top, 24)
            if items.isEmpty {
                Text("No stickers here yet")
                    .font(.custom("MoreSugarRegular", size: 17))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(items) { item in
                        Button {
                            onPick(item)
                            dismiss()
                        } label: {
                            VStack(spacing: 2) {
                                CollectionSticker(item: item)
                                if let owner {
                                    Text(owner(item))
                                        .font(.custom("MoreSugarRegular", size: 11))
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 30)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.appBackground)
        .presentationDetents([.large])
    }
}
