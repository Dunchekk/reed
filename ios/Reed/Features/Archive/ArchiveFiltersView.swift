import SwiftUI
import ReedDomain

struct ArchiveFiltersView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query: ArchiveQuery
    let catalog: LibraryCatalog
    @Binding var compact: Bool
    let apply: (ArchiveQuery) -> Void
    @State private var limitsDates: Bool
    @State private var start: Date
    @State private var end: Date

    init(query: ArchiveQuery, catalog: LibraryCatalog, compact: Binding<Bool>, apply: @escaping (ArchiveQuery) -> Void) {
        _query = State(initialValue: query); self.catalog = catalog; _compact = compact; self.apply = apply
        _limitsDates = State(initialValue: query.createdAfter != nil || query.createdBefore != nil)
        _start = State(initialValue: query.createdAfter ?? Calendar.current.date(byAdding: .day, value: -30, to: Date())!)
        _end = State(initialValue: query.createdBefore.map { $0.addingTimeInterval(-1) } ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Сортировка и вид") {
                    Picker("Порядок", selection: $query.sort) {
                        Text("Новые").tag(ArchiveSort.newest)
                        Text("Старые").tag(ArchiveSort.oldest)
                        Text("По алфавиту").tag(ArchiveSort.alphabetical)
                        Text("Случайные").tag(ArchiveSort.random)
                    }
                    Toggle("Компактные карточки", isOn: $compact)
                    Toggle("Только избранное", isOn: $query.favoritesOnly)
                }
                Section("Теги: любой из выбранных") {
                    ForEach(catalog.tags) { tag in
                        Toggle(tag.name, isOn: Binding(get: { query.tagIDs.contains(tag.id) }, set: { enabled in
                            query.tagIDs.removeAll { $0 == tag.id }; if enabled { query.tagIDs.append(tag.id) }
                        }))
                    }
                }
                Section("Источник и папка") {
                    Picker("Автор", selection: $query.authorID) {
                        Text("Любой").tag(UUID?.none)
                        ForEach(catalog.authors) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Picker("Источник", selection: $query.sourceID) {
                        Text("Любой").tag(UUID?.none)
                        ForEach(catalog.sources) { Text($0.title).tag(Optional($0.id)) }
                    }
                    Picker("Папка", selection: $query.folderID) {
                        Text("Любая").tag(UUID?.none)
                        ForEach(catalog.folders) { Text($0.name).tag(Optional($0.id)) }
                    }
                    TextField("Ключевые слова", text: $query.keywords)
                }
                Section("Период сохранения") {
                    Toggle("Ограничить период", isOn: $limitsDates)
                    if limitsDates {
                        DatePicker("С", selection: $start, displayedComponents: .date)
                        DatePicker("По", selection: $end, displayedComponents: .date)
                        if start > end { Text("Конец периода должен быть не раньше начала.").foregroundStyle(.red) }
                    }
                }
                Button("Сбросить фильтры") {
                    let visibility = query.visibility
                    query = ArchiveQuery(); query.visibility = visibility; limitsDates = false
                }
            }
            .navigationTitle("Фильтры и вид").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Применить") {
                        query.createdAfter = limitsDates ? Calendar.current.startOfDay(for: start) : nil
                        query.createdBefore = limitsDates ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end)) : nil
                        apply(query); dismiss()
                    }.disabled(limitsDates && start > end)
                }
            }
        }
    }
}
