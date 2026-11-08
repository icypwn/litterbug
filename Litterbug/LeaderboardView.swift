import SwiftUI
import Observation

/// Pieces cleaned per user, from `cleanedBy` on cleaned litter docs.
@MainActor
@Observable
final class RankStore {
    var pieces: [String: Int] = [:]

    func refresh() async {
        guard let documents = try? await FirestoreClient.shared.list("litter", fields: ["status", "cleanedBy"]) else { return }
        var counts: [String: Int] = [:]
        for document in documents where document["status"]?.stringValue == "cleaned" {
            if let user = document["cleanedBy"]?.stringValue {
                counts[user, default: 0] += 1
            }
        }
        if counts != pieces {
            pieces = counts
        }
    }
}

struct LeaderboardView: View {
    static let pointsPerPiece = 10

    @State private var ranks = RankStore()
    @State private var account = AccountStore.shared

    private var entries: [(user: UserProfile, pieces: Int)] {
        account.users
            .map { ($0, ranks.pieces[$0.id] ?? 0) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageTitle("Ranks")

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(Array(entries.enumerated()), id: \.element.user.id) { index, entry in
                        RankRow(
                            rank: index + 1,
                            user: entry.user,
                            pieces: entry.pieces,
                            points: entry.pieces * Self.pointsPerPiece,
                            isMe: entry.user.id == account.currentID
                        )
                        .modifier(PopIn(delay: 0.05 + Double(index) * 0.07))
                    }
                }
                // Slack so rows springing in past full size aren't clipped by the scroll view.
                .padding(12)
                .padding(.bottom, 40)
            }
            .padding(-12)
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.appBackground)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: ranks.pieces)
        .task {
            async let users: Void = account.refresh()
            async let pieces: Void = ranks.refresh()
            _ = await (users, pieces)
        }
    }
}

struct RankRow: View {
    let rank: Int
    let user: UserProfile
    let pieces: Int
    let points: Int
    let isMe: Bool

    var body: some View {
        HStack(spacing: 14) {
            Text("\(rank)")
                .font(.custom("CheeseMilky", size: 26))
                .frame(width: 28)

            AvatarView(name: user.name, size: 40)
                .overlay(Circle().stroke(isMe ? Color.ink : .clear, lineWidth: 2))

            VStack(alignment: .leading, spacing: 2) {
                Text(isMe ? "\(user.name) (you)" : user.name)
                    .font(.custom("MoreSugarRegular", size: 20))
                Text("\(pieces) \(pieces == 1 ? "piece" : "pieces")")
                    .font(.custom("MoreSugarRegular", size: 14))
                    .opacity(0.7)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 0) {
                Text("\(points)")
                    .font(.custom("CheeseMilky", size: 26))
                    .contentTransition(.numericText())
                Text("pts")
                    .font(.custom("MoreSugarRegular", size: 12))
                    .opacity(0.7)
            }
        }
        .foregroundStyle(isMe ? Color.ink : .white)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(isMe ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).stroke(.white, lineWidth: 2))
    }
}

#Preview {
    LeaderboardView()
}
