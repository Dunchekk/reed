import SwiftUI
import ReedDomain

struct DraftsView: View {
    let context: LibraryContext
    @State private var drafts: [DraftSummary] = []
    @State private var selected: CardDraft?
    @State private var errorMessage: String?
    var body: some View {
        List {
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            if drafts.isEmpty { ContentUnavailableView("Нет черновиков", systemImage: "doc.text", description: Text("Незаконченные фрагменты сохраняются автоматически.")) }
            ForEach(drafts) { draft in
                Button {
                    Task {
                        do { selected = try await context.drafts.draft(id: draft.id) }
                        catch { errorMessage = libraryErrorMessage(error) }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(draft.title).reedFont(.body).lineLimit(2)
                        Text("\(ReedDatePresentation.dateTime(draft.updatedAt)) · Фото: \(draft.photoCount)").reedFont(.metadata).foregroundStyle(ReedTheme.secondary)
                        if draft.editsExistingCard { Text("Изменения сохранённой карточки").reedFont(.metadata).foregroundStyle(ReedTheme.secondary) }
                    }
                }.swipeActions {
                    Button("Удалить", role: .destructive) {
                        Task {
                            do { try await context.drafts.discardDraft(id: draft.id); context.markDraftsChanged(); await load() }
                            catch { errorMessage = libraryErrorMessage(error) }
                        }
                    }
                }
            }
        }.navigationTitle("Черновики")
        .sheet(item: $selected, onDismiss: { Task { await load() } }) { CardEditorView(context: context, draft: $0) }
        .task(id: context.draftRevision) { await load() }
    }
    private func load() async {
        do { drafts = try await context.drafts.drafts(); errorMessage = nil }
        catch { errorMessage = libraryErrorMessage(error) }
    }
}
