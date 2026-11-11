import SwiftUI
import ReedDomain

private struct ArchiveLoadKey: Equatable { let query: ArchiveQuery; let revision: Int }

struct ArchiveView: View {
    let context: LibraryContext
    let open: (UUID) -> Void
    @State private var model: ArchiveModel
    @State private var showsFilters = false
    @AppStorage("archive.compact") private var compact = false

    init(context: LibraryContext, visibility: ArchiveVisibility = .active, open: @escaping (UUID) -> Void) {
        self.context = context; self.open = open
        _model = State(initialValue: ArchiveModel(repository: context.repository, visibility: visibility))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(ReedTheme.secondary)
                    TextField("Поиск по слову…", text: $model.query.search).reedFont(.body)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("archive.search")
                    if !model.query.search.isEmpty {
                        Button { model.query.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .accessibilityLabel("Очистить поиск")
                    }
                }.reedField()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        Button { model.query.tagIDs = [] } label: { TagChip(title: "Все", selected: model.query.tagIDs.isEmpty) }
                        ForEach(model.catalog.tags) { tag in
                            Button { model.query.tagIDs = [tag.id] } label: { TagChip(title: tag.name, selected: model.query.tagIDs.contains(tag.id)) }
                        }
                    }.buttonStyle(.plain)
                }
                Button { showsFilters = true } label: {
                    HStack { Text("Фильтры и вид"); Spacer(); Image(systemName: "chevron.right") }
                        .reedFont(.caption).padding(12).frame(minHeight: 44)
                        .background(ReedTheme.surface, in: RoundedRectangle(cornerRadius: ReedTheme.radius))
                }.buttonStyle(.plain)
                Divider().overlay(ReedTheme.tertiary)
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                    Button("Повторить") { Task { await model.reload() } }
                }
                if model.cards.isEmpty && !model.isLoading && model.errorMessage == nil {
                    ContentUnavailableView("Карточек пока нет", systemImage: "folder", description: Text("Добавьте карточку или измените фильтры."))
                    Button("Сбросить фильтры") {
                        let visibility = model.query.visibility
                        model.query = ArchiveQuery(); model.query.visibility = visibility
                    }
                }
                ForEach(model.cards) { card in
                    CardPreview(card: card, compact: compact, open: { open(card.id) }, favorite: {
                        Task { await model.toggleFavorite(card.id, changed: context.markChanged) }
                    })
                }
                if model.isLoading { ProgressView().frame(maxWidth: .infinity) }
                if model.nextCursor != nil && !model.isLoading {
                    Button("Показать ещё") { Task { await model.loadMore() } }.frame(maxWidth: .infinity, minHeight: 44)
                }
            }.padding(ReedTheme.inset)
        }
        .background(ReedTheme.background)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink { CatalogView(context: context) } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Управление библиотекой").accessibilityIdentifier("archive.manage")
            }
        }
        .task(id: ArchiveLoadKey(query: model.query, revision: context.revision)) { await model.reload(debounce: true) }
        .refreshable { await model.reload() }
        .sheet(isPresented: $showsFilters) {
            ArchiveFiltersView(query: model.query, catalog: model.catalog, compact: $compact) { model.query = $0 }
        }
    }
}
