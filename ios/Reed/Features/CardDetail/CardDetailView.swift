import SwiftUI
import ReedDomain

struct CardDetailView: View {
    let context: LibraryContext
    let cardID: UUID
    @State private var card: Card?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showsEditor = false
    @State private var confirmsTrash = false

    var body: some View {
        Group {
            if let card {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if card.deletedAt != nil { Text("В корзине. Удаляется окончательно через 7 дней.").foregroundStyle(ReedTheme.secondary) }
                        else if card.isHidden { Text("Скрытая карточка").foregroundStyle(ReedTheme.secondary) }
                        Text(card.displayTitle).reedFont(.screen)
                        Text(card.text).reedFont(.body).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        if let source = card.source { Text(source.displayName).reedFont(.caption).foregroundStyle(ReedTheme.secondary) }
                        if !card.page.isEmpty { Text("Страница / место: \(card.page)").reedFont(.caption) }
                        if !card.comment.isEmpty { Text(card.comment).reedFont(.body).textSelection(.enabled) }
                        FlowLayout { ForEach(card.tags) { TagChip(title: $0.name) } }
                        if let folder = card.folder { Label(folder.name, systemImage: "folder").reedFont(.caption) }
                        if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                    }.padding(ReedTheme.inset)
                }.background(ReedTheme.background)
            } else if isLoading { ProgressView() }
            else { ContentUnavailableView("Карточка недоступна", systemImage: "doc.questionmark", description: Text(errorMessage ?? "Возможно, она была удалена.")) }
        }
        .navigationTitle("Карточка").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let card {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if card.deletedAt == nil {
                            Button("Изменить", systemImage: "pencil") { showsEditor = true }
                            Button(card.isFavorite ? "Убрать из избранного" : "В избранное", systemImage: "star") { update { $0.isFavorite.toggle() } }
                            Button(card.isHidden ? "Показать в архиве" : "Скрыть", systemImage: "eye.slash") { update { $0.isHidden.toggle() } }
                            ShareLink(item: [card.text, card.source?.displayName ?? "", card.page, card.comment].filter { !$0.isEmpty }.joined(separator: "\n\n")) { Label("Поделиться текстом", systemImage: "square.and.arrow.up") }
                            Button("В корзину", systemImage: "trash", role: .destructive) { confirmsTrash = true }
                        } else {
                            Button("Восстановить", systemImage: "arrow.uturn.backward") { update { $0.deletedAt = nil } }
                        }
                    } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("Действия с карточкой").disabled(isSaving)
                }
            }
        }
        .confirmationDialog("Переместить карточку в корзину?", isPresented: $confirmsTrash, titleVisibility: .visible) {
            Button("В корзину на 7 дней", role: .destructive) { update { $0.deletedAt = Date() } }
        }
        .sheet(isPresented: $showsEditor) { if let card { CardEditorView(context: context, card: card) } }
        .task(id: context.revision) { await load() }
    }

    private func load() async {
        do { card = try await context.repository.card(id: cardID); errorMessage = nil }
        catch { errorMessage = libraryErrorMessage(error) }
        isLoading = false
    }

    private func update(_ mutation: @escaping (inout Card) -> Void) {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                guard var latest = try await context.repository.card(id: cardID) else { throw LibraryError.notFound }
                mutation(&latest); latest.updatedAt = Date()
                try await context.repository.save(latest)
                context.markChanged()
            } catch { errorMessage = libraryErrorMessage(error) }
        }
    }
}
