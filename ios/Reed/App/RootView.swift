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
    let authentication: AuthenticationModel
    let context: LibraryContext
    @State private var selectedTab = AppTab.today

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                LibraryTabView(tab: tab, authentication: authentication, context: context)
                .tabItem { Label(tab.title, systemImage: tab.symbol) }
                .tag(tab)
            }
        }
    }
}

private struct LibraryTabView: View {
    let tab: AppTab
    let authentication: AuthenticationModel
    let context: LibraryContext
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
                    Group {
                        if tab == .archive {
                            ArchiveView(context: context, open: { path.append($0) })
                        } else if tab == .settings {
                            Form {
                                Section("Аккаунт") {
                                    Text(authentication.account?.phone.value ?? "")
                                    Button("Выйти", role: .destructive) { Task { await authentication.signOut() } }
                                    if let error = authentication.errorMessage { Text(error).foregroundStyle(.red) }
                                }
                            }
                        } else {
                            ContentUnavailableView(tab.title, systemImage: tab.symbol)
                        }
                    }.navigationTitle(tab.title)
                    .navigationDestination(for: UUID.self) { CardDetailView(context: context, cardID: $0) }
        }
    }
}
