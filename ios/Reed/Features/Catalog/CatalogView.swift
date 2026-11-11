import SwiftUI
import ReedDomain

struct CatalogView: View {
    let context: LibraryContext
    @State private var model: CatalogModel
    @State private var selected: CatalogEntry?
    init(context: LibraryContext) {
        self.context = context
        _model = State(initialValue: CatalogModel(repository: context.catalogManagement))
    }
    var body: some View {
        List {
            Picker("Раздел", selection: $model.kind) { ForEach(CatalogKind.allCases) { Text($0.title).tag($0) } }
            Toggle("Только без карточек", isOn: $model.onlyUnused)
            Text("Переименование и объединение обновляют связи во всех карточках, включая скрытые и корзину. Карточки при удалении элемента остаются.").reedFont(.metadata).foregroundStyle(ReedTheme.secondary)
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red)
                Button("Обновить список") { Task { await model.load() } }
            }
            ForEach(model.visibleEntries) { entry in
                Button { selected = entry } label: {
                    HStack {
                        Text(entry.name).reedFont(.body)
                        Spacer()
                        Text("\(entry.cardCount)").reedFont(.metadata).foregroundStyle(ReedTheme.secondary)
                        Image(systemName: "chevron.right")
                    }
                }
            }
            if model.visibleEntries.isEmpty { Text("Элементов пока нет").foregroundStyle(ReedTheme.secondary) }
        }.navigationTitle("Управление библиотекой").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.search, prompt: "Название")
        .task(id: model.kind) { await model.load() }
        .sheet(item: $selected) { entry in
            CatalogEntryView(entry: entry, model: model) { context.markChanged(); context.markDraftsChanged() }
        }
    }
}

private struct CatalogEntryView: View {
    @Environment(\.dismiss) private var dismiss
    let entry: CatalogEntry
    @Bindable var model: CatalogModel
    let changed: () -> Void
    @State private var name = ""
    @State private var target: UUID?
    @State private var confirmation = false
    @State private var mutation: CatalogMutation?
    var body: some View {
        NavigationStack {
            Form {
                Section("Название") {
                    TextField("Название", text: $name)
                    Button("Переименовать") { run(.rename(id: entry.id, name: name)) }
                }
                Section("Объединить") {
                    Picker("Оставить элемент", selection: $target) {
                        Text("Выберите…").tag(UUID?.none)
                        ForEach(model.snapshot.entries.filter { $0.id != entry.id }) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Text("Все ссылки перейдут к выбранному элементу. Его название и данные сохранятся. Старый элемент исчезнет; дубликатов связей не будет.").reedFont(.metadata)
                    Button("Объединить") { if let target { mutation = .merge(id: entry.id, into: target); confirmation = true } }.disabled(target == nil)
                }
                Section {
                    Text("Связанных карточек: \(entry.cardCount). При удалении исчезает только связь. Если элемент используется в правилах возвращений, они будут очищены от этой связи, а возвращения приостановятся до вашей проверки настроек.").reedFont(.metadata)
                    Button("Удалить элемент", role: .destructive) { mutation = .remove(id: entry.id); confirmation = true }
                }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
                if model.working { ProgressView() }
            }.disabled(model.working)
            .navigationTitle(entry.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() }.disabled(model.working) } }
            .task { name = entry.name }
            .confirmationDialog("Применить изменение ко всем связанным карточкам и черновикам?", isPresented: $confirmation, titleVisibility: .visible) {
                Button("Применить", role: .destructive) { if let mutation { run(mutation) } }
            }
        }
    }
    private func run(_ mutation: CatalogMutation) {
        Task { if await model.update(mutation) { changed(); dismiss() } }
    }
}
