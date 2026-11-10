import SwiftUI
import ReedApplication

enum AppTab: String, CaseIterable {
    case archive, today, feed, settings

    var title: String {
        switch self {
        case .archive: "Архив"
        case .today: "Главная"
        case .feed: "Лента"
        case .settings: "Настройки"
        }
    }

    var symbol: String {
        switch self {
        case .archive: "folder"
        case .today: "house"
        case .feed: "star"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @State private var selectedTab = AppTab.today

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                NavigationStack {
                    ContentUnavailableView(tab.title, systemImage: tab.symbol)
                        .navigationTitle(tab.title)
                }
                .tabItem { Label(tab.title, systemImage: tab.symbol) }
                .tag(tab)
            }
        }
    }
}
