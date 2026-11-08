import SwiftUI
import Observation

struct Cleanup: Identifiable, Equatable {
    let id: String
    let type: String
    let place: String
    let cleanedAt: Date
    let image: UIImage?

    static func == (lhs: Cleanup, rhs: Cleanup) -> Bool {
        lhs.id == rhs.id && lhs.cleanedAt == rhs.cleanedAt && lhs.type == rhs.type
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
        guard let documents = try? await FirestoreClient.shared.list("litter", fields: ["type", "place", "photo", "status", "cleanedAt"]) else { return }
        let latest = documents
            .filter { $0["status"]?.stringValue == "cleaned" }
            .map { document in
                Cleanup(
                    id: document.id,
                    type: document["type"]?.stringValue ?? "litter",
                    place: document["place"]?.stringValue ?? "Nearby",
                    cleanedAt: document["cleanedAt"]?.date ?? .distantPast,
                    image: document["photo"]?.data.flatMap(UIImage.init(data:))
                )
            }
            .sorted { $0.cleanedAt > $1.cleanedAt }
        if latest != cleanups {
            cleanups = latest
        }
    }
}

struct ImpactView: View {
    @State private var store = ImpactStore()
    @Environment(\.isTabActive) private var isTabActive
    @Namespace private var monthZoom

    private var thisYearCount: Int {
        store.cleanups.filter { Calendar.current.isDate($0.cleanedAt, equalTo: .now, toGranularity: .year) }.count
    }

    /// Cleanups grouped by calendar month, newest month first.
    private var months: [(month: Date, cleanups: [Cleanup])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: store.cleanups) {
            calendar.date(from: calendar.dateComponents([.year, .month], from: $0.cleanedAt)) ?? $0.cleanedAt
        }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted { $0.cleanedAt > $1.cleanedAt }) }
    }

    var body: some View {
        NavigationStack {
        ScrollView {
            VStack(spacing: 28) {
                PageTitle("Impact")
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 0) {
                    Text("\(thisYearCount)")
                        .font(.custom("CheeseMilky", size: 110))
                        .contentTransition(.numericText())
                    Text("\(thisYearCount == 1 ? "piece" : "pieces") of litter\ncleaned up in \(String(Calendar.current.component(.year, from: .now)))")
                        .font(.custom("MoreSugarRegular", size: 24))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)

                ForEach(months, id: \.month) { group in
                    NavigationLink(value: group.month) {
                        MonthCollage(month: group.month, cleanups: group.cleanups)
                            .matchedTransitionSource(id: group.month, in: monthZoom)
                    }
                    .buttonStyle(.plain)
                        // Each month fades and rises in as it scrolls up from the bottom.
                        .scrollTransition(topLeading: .identity, bottomTrailing: .interactive) { content, phase in
                            content
                                .opacity(1 - abs(phase.value) * 0.9)
                                .scaleEffect(1 - abs(phase.value) * 0.08)
                                .offset(y: phase.value * 60)
                        }
                }
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 44)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: store.cleanups)
        }
        .background(Color.appBackground)
        .toolbar(.hidden, for: .navigationBar)
        // The zoom transition shrinks the screen behind; show green there, not black.
        .containerBackground(Color.appBackground, for: .navigation)
        .navigationDestination(for: Date.self) { month in
            // Zooms out of the tapped collage (like Tallo's product page) instead of sliding in.
            MonthDetailView(month: month, cleanups: months.first { $0.month == month }?.cleanups ?? [])
                .navigationTransition(.zoom(sourceID: month, in: monthZoom))
        }
        }
        .task(id: isTabActive) {
            guard isTabActive else { return }
            await store.poll()
        }
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
