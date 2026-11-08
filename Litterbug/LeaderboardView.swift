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
    @State private var scope: ImpactView.Feed = .local

    /// Local: everyone (all accounts are Binghamton for now). Friends: you plus your friends list.
    private var people: [UserProfile] {
        switch scope {
        case .local: return account.users
        case .friends:
            let circle = Set((account.current?.friends ?? []) + [account.currentID])
            return account.users.filter { circle.contains($0.id) }
        }
    }

    private var entries: [(user: UserProfile, pieces: Int)] {
        people
            .map { ($0, ranks.pieces[$0.id] ?? 0) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                PageTitle("Ranks")
                FeedPicker(selection: $scope)
            }

            ScrollView {
                VStack(spacing: 12) {
                    // Top three get their own podium; the rows continue from 4th.
                    Podium(entries: Array(entries.prefix(3)), meID: account.currentID)
                        .padding(.top, 10)
                        .padding(.bottom, 12)

                    ForEach(Array(entries.dropFirst(3).enumerated()), id: \.element.user.id) { index, entry in
                        RankRow(
                            rank: index + 4,
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
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: scope)
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
            RankBadge(rank: rank)

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

/// 2nd · 1st · 3rd: big avatars ringed in silver, gold and bronze, 1st larger and raised.
struct Podium: View {
    let entries: [(user: UserProfile, pieces: Int)]
    let meID: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach([1, 0, 2], id: \.self) { index in
                if index < entries.count {
                    slot(rank: index + 1, entry: entries[index])
                        .modifier(PopIn(delay: [0.1, 0.0, 0.2][index]))
                } else {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                }
            }
        }
        .foregroundStyle(.white)
    }

    private func slot(rank: Int, entry: (user: UserProfile, pieces: Int)) -> some View {
        let first = rank == 1
        let size: CGFloat = first ? 92 : 70
        return VStack(spacing: 6) {
            AvatarView(name: entry.user.name, size: size)
                .overlay(WobblyCircle().stroke(RankBadge.medal(for: rank) ?? .white, lineWidth: first ? 5 : 4))
                .overlay(alignment: .bottom) {
                    RankBadge(rank: rank).offset(y: 14)
                }
                .padding(.bottom, 14)

            Text(entry.user.id == meID ? "\(entry.user.name) (you)" : entry.user.name)
                .font(.custom("MoreSugarRegular", size: first ? 19 : 16))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("\(entry.pieces * LeaderboardView.pointsPerPiece) pts")
                .font(.custom("CheeseMilky", size: first ? 24 : 20))
                .contentTransition(.numericText())
            Text("\(entry.pieces) \(entry.pieces == 1 ? "piece" : "pieces")")
                .font(.custom("MoreSugarRegular", size: 13))
                .opacity(0.6)
                .padding(.top, -6)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, first ? 18 : 0)
    }
}

/// Rank number; the top three sit in hand-drawn gold, silver and bronze circles.
struct RankBadge: View {
    let rank: Int

    private var medal: Color? { Self.medal(for: rank) }

    static func medal(for rank: Int) -> Color? {
        switch rank {
        case 1: Color(red: 0.96, green: 0.77, blue: 0.20)
        case 2: Color(red: 0.79, green: 0.81, blue: 0.84)
        case 3: Color(red: 0.80, green: 0.50, blue: 0.24)
        default: nil
        }
    }

    var body: some View {
        if let medal {
            Text("\(rank)")
                .font(.custom("CheeseMilky", size: 22))
                .foregroundStyle(Color.ink)
                .frame(width: 34, height: 34)
                .background(WobblyCircle().fill(medal))
                .overlay(WobblyCircle().stroke(Color.ink, lineWidth: 2))
        } else {
            Text("\(rank)")
                .font(.custom("CheeseMilky", size: 26))
                .frame(width: 34)
        }
    }
}

#Preview {
    LeaderboardView()
}
