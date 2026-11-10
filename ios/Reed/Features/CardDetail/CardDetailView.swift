import SwiftUI
import ReedDomain

struct CardDetailView: View {
    let context: LibraryContext
    let cardID: UUID
    @State private var card: Card?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let card {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(card.displayTitle).reedFont(.screen)
                        Text(card.text).reedFont(.body).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        if let source = card.source { Text(source.displayName).reedFont(.caption).foregroundStyle(ReedTheme.secondary) }
                        if !card.page.isEmpty { Text("Страница / место: \(card.page)").reedFont(.caption) }
                        if !card.comment.isEmpty { Text(card.comment).reedFont(.body).textSelection(.enabled) }
                        FlowLayout { ForEach(card.tags) { TagChip(title: $0.name) } }
                    }.padding(ReedTheme.inset)
                }.background(ReedTheme.background)
            } else if isLoading { ProgressView() }
            else { ContentUnavailableView("Карточка недоступна", systemImage: "doc.questionmark", description: Text(errorMessage ?? "Возможно, она была удалена.")) }
        }
        .navigationTitle("Карточка").navigationBarTitleDisplayMode(.inline)
        .task(id: context.revision) {
            do { card = try await context.repository.card(id: cardID); errorMessage = nil }
            catch { errorMessage = libraryErrorMessage(error) }
            isLoading = false
        }
    }
}
