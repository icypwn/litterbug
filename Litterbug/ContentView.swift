import SwiftUI

enum AppTab: CaseIterable {
    case home, impact, leaderboard, settings

    var icon: String {
        switch self {
        case .home: "tab-home"
        case .impact: "tab-impact"
        case .leaderboard: "tab-leaderboard"
        case .settings: "tab-settings"
        }
    }

    var title: String {
        switch self {
        case .home: "Home"
        case .impact: "Impact"
        case .leaderboard: "Ranks"
        case .settings: "Settings"
        }
    }

    var iconSize: CGSize {
        guard let size = UIImage(named: icon)?.size, size.width > 0, size.height > 0 else {
            return CGSize(width: 40, height: 40)
        }
        let scale = (1500 / (size.width * size.height)).squareRoot()
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

struct ContentView: View {
    @State private var selection: AppTab = {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "tab") {
        case "impact": return .impact
        case "ranks": return .leaderboard
        case "settings": return .settings
        default: return .home
        }
        #else
        return .home
        #endif
    }()

    @State private var visited: Set<AppTab> = []

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Home and Impact stay alive once opened, so switching back doesn't rebuild the map or reload photos.
                ForEach([AppTab.home, .impact], id: \.self) { tab in
                    if visited.contains(tab) || selection == tab {
                        Group {
                            if tab == .home { HomeView() } else { ImpactView() }
                        }
                        .environment(\.isTabActive, selection == tab)
                        .opacity(selection == tab ? 1 : 0)
                        .allowsHitTesting(selection == tab)
                        .accessibilityHidden(selection != tab)
                    }
                }
                switch selection {
                case .leaderboard: LeaderboardView()
                case .settings: SettingsView()
                default: EmptyView()
                }
            }
            .frame(maxHeight: .infinity)
            .onChange(of: selection, initial: true) { _, tab in visited.insert(tab) }

            HStack(spacing: 0) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    Button {
                        selection = tab
                    } label: {
                        VStack(spacing: 4) {
                            Image(tab.icon)
                                .resizable()
                                .frame(width: tab.iconSize.width, height: tab.iconSize.height)
                                .frame(height: 42)
                            Text(tab.title)
                                .font(.custom("MoreSugarRegular", size: 13))
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .foregroundStyle(.white.opacity(selection == tab ? 1 : 0.4))
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 4)
        }
        .background(Color.appBackground)
        .preferredColorScheme(.dark)
    }
}

extension EnvironmentValues {
    /// False while a kept-alive tab is hidden, so it can pause polling.
    @Entry var isTabActive = true
}

extension Color {
    static let appBackground = Color(red: 28 / 255, green: 72 / 255, blue: 57 / 255)
}

#Preview {
    ContentView()
}
