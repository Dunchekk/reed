import SwiftUI
import ReedApplication

private enum AppTab: String, CaseIterable {
    case archive, today, feed, settings
    var title: String { switch self { case .archive: "Архив"; case .today: "Главная"; case .feed: "Лента"; case .settings: "Настройки" } }
    var symbol: String { switch self { case .archive: "folder"; case .today: "house"; case .feed: "star"; case .settings: "gearshape" } }
}
private struct CardDestination: Hashable { let id: UUID; var fromNotification = false }
private struct EditorDraft: Identifiable { let id = UUID(); let input: CardInput; let text: String }

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    let authentication: AuthenticationModel
    let context: LibraryContext
    @State private var selectedTab = AppTab.today
    @State private var paths: [AppTab: [CardDestination]] = [:]
    @State private var editor: EditorDraft?
    @State private var router = NotificationRouter.shared
    @State private var routeError = false

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                NavigationStack(path: Binding(get: { paths[tab] ?? [] }, set: { paths[tab] = $0 })) {
                    content(tab)
                        .navigationTitle(tab == .today ? "" : tab.title)
                        .navigationDestination(for: CardDestination.self) { destination in
                            CardDetailView(context: context, cardID: destination.id, origin: destination.fromNotification ? .notification : .manual)
                        }
                        .toolbar {
                            if tab == .archive || tab == .today {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Добавить", systemImage: "plus") { editor = EditorDraft(input: .text, text: "") }
                                        .accessibilityIdentifier("library.add")
                                }
                            }
                        }
                }.tabItem { Label(tab.title, systemImage: tab.symbol) }.tag(tab)
            }
        }
        .sheet(item: $editor) { draft in CardEditorView(context: context, initialText: draft.text, initialInput: draft.input) }
        .task { await context.refreshAfterActivation() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await context.refreshAfterActivation() } } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in context.returnCoordinator.refresh() }
        .onChange(of: router.route, initial: true) { _, route in
            guard let route else { return }
            guard route.accountID == context.account.id else { routeError = true; return }
            selectedTab = .today
            paths[.today] = [CardDestination(id: route.cardID, fromNotification: true)]
            router.route = nil
        }
        .alert("Другой аккаунт", isPresented: $routeError) {
            Button("Понятно", role: .cancel) {}
        } message: { Text("Это уведомление связано с другой библиотекой. Войдите в соответствующий аккаунт.") }
    }
    @ViewBuilder private func content(_ tab: AppTab) -> some View {
        let open: (UUID) -> Void = { paths[tab, default: []].append(CardDestination(id: $0)) }
        switch tab {
        case .archive: ArchiveView(context: context, open: open)
        case .today: TodayView(context: context, open: open, add: { editor = EditorDraft(input: $0, text: $1) })
        case .feed: FeedView(context: context, open: open)
        case .settings: SettingsView(context: context, authentication: authentication, open: open)
        }
    }
}
