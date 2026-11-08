import SwiftUI

/// Social = the feed and the ranks in one tab, switched by the Feed / Ranks tabs under the title.
/// Each keeps its own Local / Friends toggle.
struct SocialView: View {
    enum Section: String, CaseIterable { case feed = "Feed", ranks = "Ranks" }

    @State private var section: Section = .feed

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                PageTitle("Social")
                PillPicker(selection: $section, options: Section.allCases.map { ($0, $0.rawValue) })
                    .padding(.top, 10)
            }
            .padding(.horizontal, 30)

            // Both stay alive so switching back doesn't reload the feed's photos.
            ZStack {
                ImpactView(embedded: true)
                    .opacity(section == .feed ? 1 : 0)
                    .allowsHitTesting(section == .feed)
                LeaderboardView(embedded: true)
                    .opacity(section == .ranks ? 1 : 0)
                    .allowsHitTesting(section == .ranks)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.appBackground)
    }
}

