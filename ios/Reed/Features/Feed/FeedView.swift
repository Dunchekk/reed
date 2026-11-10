import SwiftUI
import ReedDomain

struct FeedView: View {
    let context: LibraryContext
    let open: (UUID) -> Void
    @State private var sections: [FeedSection] = []
    @State private var enabled = Set(FeedKind.allCases)
    @State private var showsSettings = false
    @State private var loading = true
    @State private var errorMessage: String?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                Text("Ваши тексты, собранные по подборкам").reedFont(.body)
                if loading { ProgressView() }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red); Button("Повторить") { Task { await load() } } }
                if !loading && sections.isEmpty && errorMessage == nil {
                    ContentUnavailableView("Подборки появятся здесь", systemImage: "sparkles", description: Text("Добавляйте карточки с общими тегами, авторами или папками. Проверьте включённые группы."))
                }
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        Divider().overlay(ReedTheme.tertiary)
                        Text(section.explanation).reedFont(.caption).foregroundStyle(ReedTheme.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(section.cards) { card in
                                    CardPreview(card: card, compact: true, open: { open(card.id) }, favorite: { toggleFavorite(card.id) })
                                        .containerRelativeFrame(.horizontal, count: 6, span: 5, spacing: 12)
                                }
                            }.scrollTargetLayout()
                        }.scrollTargetBehavior(.viewAligned)
                    }
                }
            }.padding(ReedTheme.inset)
        }.background(ReedTheme.background)
        .task(id: context.revision) { await load() }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Настройки ленты", systemImage: "slider.horizontal.3") { showsSettings = true } } }
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                Form {
                    ForEach(FeedKind.allCases, id: \.self) { kind in
                        Toggle(kind.title, isOn: Binding(get: { enabled.contains(kind) }, set: { value in
                            if value { enabled.insert(kind) } else { enabled.remove(kind) }
                        }))
                    }
                    Text("Группа «Давно не открывали» доступна при включённой истории. Скрытые карточки и корзина в ленту не попадают.").reedFont(.caption)
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                }.navigationTitle("Подборки")
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        Task {
                            do { try await context.feed.setEnabledGroups(enabled); showsSettings = false; await load() }
                            catch { errorMessage = libraryErrorMessage(error) }
                        }
                    }
                } }
            }
        }
    }
    private func load() async {
        loading = true; defer { loading = false }
        do {
            let result = try await context.feed.feed(now: Date(), calendar: .current)
            let groups = try await context.feed.enabledGroups()
            guard !Task.isCancelled else { return }
            sections = result; enabled = groups; errorMessage = nil
        } catch { if !Task.isCancelled { errorMessage = libraryErrorMessage(error) } }
    }
    private func toggleFavorite(_ id: UUID) {
        Task {
            do {
                guard var card = try await context.repository.card(id: id) else { throw LibraryError.notFound }
                card.isFavorite.toggle(); try await context.repository.save(card); context.markChanged()
            } catch { errorMessage = libraryErrorMessage(error) }
        }
    }
}
