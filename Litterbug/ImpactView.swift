import SwiftUI
import Observation
import CoreLocation

struct Cleanup: Identifiable, Equatable {
    let id: String
    let type: String
    let place: String
    let cleanedAt: Date
    let image: UIImage?
    /// Front-camera shot from the moment of pickup (BeReal-style), if one was taken.
    var selfie: UIImage? = nil
    var cleanedBy: String? = nil
    var location: CLLocation? = nil
    var points: Int = 0

    static func == (lhs: Cleanup, rhs: Cleanup) -> Bool {
        lhs.id == rhs.id && lhs.cleanedAt == rhs.cleanedAt && lhs.type == rhs.type
            && lhs.cleanedBy == rhs.cleanedBy && (lhs.selfie == nil) == (rhs.selfie == nil)
    }
}

@MainActor
@Observable
final class ImpactStore {
    var cleanups: [Cleanup] = []

    func poll(every interval: Duration = .seconds(5)) async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: interval)
        }
    }

    private func refresh() async {
        guard let documents = try? await FirestoreClient.shared.list("litter", fields: ["type", "place", "photo", "selfie", "status", "cleanedAt", "cleanedBy", "lat", "lon", "pointsAwarded"]) else { return }
        let latest = documents
            .filter { $0["status"]?.stringValue == "cleaned" }
            .map { document in
                Cleanup(
                    id: document.id,
                    type: document["type"]?.stringValue ?? "litter",
                    place: document["place"]?.stringValue ?? "Nearby",
                    cleanedAt: document["cleanedAt"]?.date ?? .distantPast,
                    image: document["photo"]?.data.flatMap(UIImage.init(data:)),
                    selfie: document["selfie"]?.data.flatMap(UIImage.init(data:)),
                    cleanedBy: document["cleanedBy"]?.stringValue,
                    location: document["lat"]?.number.flatMap { lat in
                        document["lon"]?.number.map { CLLocation(latitude: lat, longitude: $0) }
                    },
                    // Older cleanups have no pointsAwarded: score them by type like new ones.
                    points: document["pointsAwarded"]?.number.map(Int.init) ?? LitterType.points(document["type"]?.stringValue ?? "litter")
                )
            }
            .sorted { $0.cleanedAt > $1.cleanedAt }
        if latest != cleanups {
            cleanups = latest
        }
    }
}

/// The Social tab (was Impact): your profile up top, then everyone's pickups as a scrolling feed.
struct ImpactView: View {
    /// Inside Social, which shows its own title above the Feed / Ranks switch.
    var embedded = false
    @State private var store = ImpactStore()
    @State private var account = AccountStore.shared
    @State private var litter = LitterStore.shared
    @Environment(\.isTabActive) private var isTabActive
    @State private var feed: Feed = .local

    enum Feed: String, CaseIterable { case local = "Local", friends = "Friends" }

    /// Local: everyone within ~15 km of you (everyone, until we know where you are).
    /// Friends: posts by people on your friends list.
    private var posts: [Cleanup] {
        switch feed {
        case .local:
            guard let here = LocationTracker.shared.location else { return store.cleanups }
            return store.cleanups.filter { ($0.location?.distance(from: here) ?? 0) <= 15_000 }
        case .friends:
            let friends = Set(account.current?.friends ?? [])
            return store.cleanups.filter { $0.cleanedBy.map(friends.contains) ?? false }
        }
    }

    private var thisMonthCount: Int {
        store.cleanups.filter { Calendar.current.isDate($0.cleanedAt, equalTo: .now, toGranularity: .month) }.count
    }

    private var myPieces: Int {
        store.cleanups.filter { $0.cleanedBy == account.currentID }.count
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    if !embedded {
                        PageTitle("Social")
                        FeedPicker(selection: $feed)
                            .padding(.top, 10)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if posts.isEmpty {
                    Text(feed == .friends ? "No posts from friends yet" : "Nothing picked up nearby yet")
                        .font(.custom("MoreSugarRegular", size: 17))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.top, 40)
                }

                ForEach(posts) { cleanup in
                    PostCard(cleanup: cleanup, author: account.users.first { $0.id == cleanup.cleanedBy })
                        // Gentle: the next post stays clearly visible below the current one.
                        .scrollTransition(topLeading: .identity, bottomTrailing: .interactive) { content, phase in
                            content
                                .opacity(1 - abs(phase.value) * 0.2)
                                .scaleEffect(1 - abs(phase.value) * 0.03)
                        }
                }
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 44)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: store.cleanups)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: feed)
        }
        // Posts stop at the top of the safe area instead of sliding up under the clock / island.
        .clipped()
        .background(Color.appBackground)
        .task { await account.refresh() }
        .task(id: isTabActive) {
            guard isTabActive else { return }
            await store.poll()
        }
    }
}

struct ProfileHeader: View {
    let user: UserProfile
    let pieces: Int
    let points: Int
    let streak: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                AvatarView(name: user.name, size: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.name)
                        .font(.custom("CheeseMilky", size: 28))
                    Text("@\(user.username)\(user.school.isEmpty ? "" : " · \(user.school)")")
                        .font(.custom("MoreSugarRegular", size: 14))
                        .opacity(0.7)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 0) {
                stat("\(pieces)", pieces == 1 ? "piece" : "pieces")
                divider
                stat("\(points)", "points")
                divider
                stat("\(streak)", streak == 1 ? "day streak" : "day streak")
            }
            .padding(.vertical, 12)
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white, lineWidth: 2))
        }
        .foregroundStyle(.white)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.3)).frame(width: 1.5, height: 34)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.custom("CheeseMilky", size: 28))
                .contentTransition(.numericText())
            Text(label)
                .font(.custom("MoreSugarRegular", size: 13))
                .opacity(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Local | Friends switch: two capsules in the row style, the selected one filled white.
struct FeedPicker: View {
    @Binding var selection: ImpactView.Feed

    var body: some View {
        PillPicker(selection: $selection, options: ImpactView.Feed.allCases.map { ($0, $0.rawValue) })
    }
}

/// Two (or more) options in a white-outlined capsule; the selected one is filled white and slides over.
/// Social's Feed / Ranks, Collection's Mine / Friends.
struct PillPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { feed, title in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { selection = feed }
                } label: {
                    Text(title)
                        .font(.custom("MoreSugarRegular", size: 17))
                        .foregroundStyle(selection == feed ? Color.appBackground : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background {
                            if selection == feed {
                                Capsule().fill(.white).matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .overlay(Capsule().stroke(.white, lineWidth: 2))
    }
}

/// Community total for the month, in the white-outline style of the rows, with a little pile of
/// the colored litter icons.
struct CommunityStat: View {
    let count: Int

    var body: some View {
        HStack(spacing: 14) {
            Text("\(count)")
                .font(.custom("CheeseMilky", size: 40))
                .contentTransition(.numericText())
                .monospacedDigit()

            VStack(alignment: .leading, spacing: 0) {
                Text(count == 1 ? "piece of litter" : "pieces of litter")
                    .font(.custom("MoreSugarRegular", size: 17))
                Text("picked up in Binghamton this month")
                    .font(.custom("MoreSugarRegular", size: 13))
                    .opacity(0.7)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 0)

            ZStack {
                ForEach(Array(["litter-bottle-color", "litter-can-color", "litter-cup-color"].enumerated()), id: \.offset) { index, name in
                    Image(name)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 26, height: 26)
                        .rotationEffect(.degrees([-14, 6, 18][index]))
                        .offset(x: CGFloat(index - 1) * 11, y: index == 1 ? -5 : 3)
                }
            }
            .frame(width: 52)
        }
        .foregroundStyle(.white)
        .animation(.spring, value: count)
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.white, lineWidth: 2))
    }
}

/// One pickup in the feed: who/where/when, the photo with the selfie inset top-left, and what it was.
struct PostCard: View {
    let cleanup: Cleanup
    let author: UserProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AvatarView(name: author?.name ?? "?", size: 36, inverted: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(author?.name ?? "Someone")
                        .font(.custom("MoreSugarRegular", size: 17))
                    HStack(spacing: 3) {
                        Image(systemName: "mappin")
                            .font(.system(size: 9, weight: .bold))
                        Text("\(cleanup.place) · \(cleanup.cleanedAt.formatted(.relative(presentation: .named)))")
                            .font(.custom("MoreSugarRegular", size: 13))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .opacity(0.6)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.ink)

            Color(white: 0.85)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image = cleanup.image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if let selfie = cleanup.selfie {
                        Image(uiImage: selfie)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 84, height: 112)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white, lineWidth: 3))
                            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                            .padding(10)
                    }
                }

            HStack(alignment: .lastTextBaseline) {
                Text("Picked up a \(LitterType.displayName(cleanup.type).lowercased())")
                    .font(.custom("MoreSugarRegular", size: 17))
                Spacer()
                Text("+\(cleanup.points) pts")
                    .font(.custom("MoreSugarRegular", size: 14))
                    .opacity(0.6)
            }
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 2)
        }
        .padding(12)
        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
    }
}

/// A month opened from Impact: pinned header (back + "November 2026"), then every cleanup as a big photo card.
struct MonthDetailView: View {
    let month: Date
    let cleanups: [Cleanup]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")

                PageTitle(month.formatted(.dateTime.month(.wide).year()))
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(cleanups) { cleanup in
                        CleanupCard(cleanup: cleanup)
                    }
                }
                .padding(.horizontal, 30)
                .padding(.top, 8)
                .padding(.bottom, 44)
            }
        }
        .background(Color.appBackground)
        .toolbar(.hidden, for: .navigationBar)
        // The zoom transition shrinks the screen behind; show green there, not black.
        .containerBackground(Color.appBackground, for: .navigation)
    }
}

/// Compact row (thumbnail, type, place, date) so a month's worth fits on screen.
struct CleanupCard: View {
    let cleanup: Cleanup

    var body: some View {
        HStack(spacing: 18) {
            Color(white: 0.55)
                .overlay {
                    if let image = cleanup.image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(LitterType.displayName(cleanup.type))
                    .font(.custom("MoreSugarRegular", size: 22))
                Text(cleanup.place)
                    .font(.custom("MoreSugarRegular", size: 15))
                    .opacity(0.7)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(cleanup.cleanedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.custom("MoreSugarRegular", size: 13))
                    .opacity(0.5)
            }
            .foregroundStyle(Color.ink)

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(red: 0.96, green: 0.94, blue: 0.88), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// One month as a white photo-book page: a mosaic of that month's photos with a handwritten caption.
struct MonthCollage: View {
    let month: Date
    let cleanups: [Cleanup]

    private var rows: [[Cleanup]] {
        stride(from: 0, to: cleanups.count, by: 3).map { Array(cleanups[$0..<min($0 + 3, cleanups.count)]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                CollageRow(items: row, flipped: index.isMultiple(of: 2) == false)
            }

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(month.formatted(.dateTime.month(.wide)))
                    .font(.custom("CheeseMilky", size: 34))
                Text(month.formatted(.dateTime.year()))
                    .font(.custom("MoreSugarRegular", size: 18))
                    .opacity(0.6)
                Spacer()
                Text("\(cleanups.count) \(cleanups.count == 1 ? "PIECE" : "PIECES")")
                    .font(.custom("MoreSugarRegular", size: 12))
                    .tracking(3)
                    .opacity(0.6)
            }
            .foregroundStyle(Color.ink)
            .padding(.top, 10)
            .padding(.horizontal, 4)
        }
        .padding(12)
        .background(.white)
        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
    }
}

/// Up to three photos: one large tile beside two stacked ones (mirrored on alternate rows).
struct CollageRow: View {
    let items: [Cleanup]
    let flipped: Bool

    private let gap: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            switch items.count {
            case 1:
                CollageTile(cleanup: items[0]).frame(width: w, height: h)
            case 2:
                HStack(spacing: gap) {
                    CollageTile(cleanup: items[0]).frame(width: (w - gap) * 0.56, height: h)
                    CollageTile(cleanup: items[1]).frame(width: (w - gap) * 0.44, height: h)
                }
            default:
                let big = (w - gap) * 0.62
                let small = w - gap - big
                let half = (h - gap) / 2
                HStack(spacing: gap) {
                    if !flipped { CollageTile(cleanup: items[0]).frame(width: big, height: h) }
                    VStack(spacing: gap) {
                        CollageTile(cleanup: items[1]).frame(width: small, height: half)
                        CollageTile(cleanup: items[2]).frame(width: small, height: half)
                    }
                    if flipped { CollageTile(cleanup: items[0]).frame(width: big, height: h) }
                }
            }
        }
        .frame(height: items.count == 1 ? 190 : 240)
    }
}

/// A photo with its location pinned along the bottom edge.
struct CollageTile: View {
    let cleanup: Cleanup

    var body: some View {
        Color(white: 0.85)
            .overlay {
                if let image = cleanup.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 3) {
                    Image("mappin")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 14)
                    Text(cleanup.place)
                        .font(.custom("MoreSugarRegular", size: 12))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.top, 14)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            }
            .clipped()
    }
}

#Preview {
    ImpactView()
}
