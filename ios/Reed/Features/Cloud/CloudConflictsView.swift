import SwiftUI
import ReedDomain
import ReedApplication

struct CloudConflictsView: View {
    let context: LibraryContext
    @State private var model: CloudConflictsModel
    init(context: LibraryContext) {
        self.context = context
        _model = State(initialValue: CloudConflictsModel(repository: context.cloud.repository, library: context.repository, engine: context.cloud.engine))
    }
    var body: some View {
        List {
            Section {
                Text("Различающиеся версии сохранены. Выберите результат для каждой записи; выбор снова проверится перед сохранением.").reedFont(.caption)
            }
            if model.conflicts.isEmpty { Text("Конфликтующих версий нет").foregroundStyle(ReedTheme.secondary) }
            ForEach(model.conflicts) { conflict in
                NavigationLink {
                    CloudConflictDetail(conflict: conflict, catalog: model.catalog, store: context.attachments, model: model)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(conflict.remote.kind.title).reedFont(.metadata).foregroundStyle(ReedTheme.secondary)
                        Text(CloudVersionDescription(kind: conflict.remote.kind, value: conflict.local, catalog: model.catalog).title).reedFont(.body)
                        if conflict.remote.isDeleted { Text("В облаке запись удалена").reedFont(.caption).foregroundStyle(.orange) }
                    }.padding(.vertical,4)
                }
            }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red).reedFont(.caption) }
        }.navigationTitle("Конфликты").navigationBarTitleDisplayMode(.inline)
        .task(id: context.revision) { await model.load() }
        .refreshable { await model.load() }
    }
}

private struct CloudConflictDetail: View {
    @Environment(\.dismiss) private var dismiss
    let conflict: CloudConflict
    let catalog: LibraryCatalog
    let store: any AttachmentStore
    let model: CloudConflictsModel
    @State private var choice: CloudResolution?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                CloudVersionPanel(label: "На этом iPhone", value: CloudVersionDescription(kind: conflict.remote.kind, value: conflict.local, catalog: catalog, cardTitles: model.cardTitles), store: store)
                CloudVersionPanel(label: "В облаке", value: CloudVersionDescription(kind: conflict.remote.kind, value: conflict.remote.payload, catalog: catalog, cardTitles: model.cardTitles), store: store)
                VStack(spacing: 12) {
                    Button(conflict.remote.isDeleted ? "Принять удаление" : "Принять облачную версию", role: conflict.remote.isDeleted ? .destructive : nil) { choice = .remote }
                    if conflict.canKeepLocal { Button("Отправить мою версию") { choice = .local } }
                    if conflict.canKeepBoth { Button(conflict.remote.isDeleted ? "Сохранить мою карточку как новую" : "Сохранить обе карточки") { choice = .both } }
                }.buttonStyle(CloudOutlineButtonStyle()).disabled(model.working)
                if model.working { ProgressView("Сохраняем выбор…") }
                if let error = model.errorMessage { Text(error).reedFont(.caption).foregroundStyle(.red) }
            }.padding(16)
        }.background(ReedTheme.background)
        .navigationTitle(conflict.remote.kind.title).navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Применить выбранную версию?", isPresented: Binding(get: { choice != nil }, set: { if !$0 { choice = nil } }), titleVisibility: .visible) {
            if let choice {
                Button("Применить", role: choice == .remote ? .destructive : nil) {
                    Task { if await model.resolve(id: conflict.id, choice: choice) { dismiss() } }
                }
            }
        } message: {
            Text(choice == .both ? "Локальный текст и фото сохранятся в новой карточке. Облачная версия исходной записи останется." : choice == .local ? "Моя версия будет отправлена поверх показанной облачной. Если она снова изменилась, потребуется новый выбор." : "Локальная версия этой записи будет заменена показанной облачной версией.")
        }
    }
}
private struct CloudVersionPanel: View {
    let label: String
    let value: CloudVersionDescription
    let store: any AttachmentStore
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label).reedFont(.caption).foregroundStyle(ReedTheme.secondary)
            Text(value.title).reedFont(.cardTitle)
            if !value.text.isEmpty {
                Text(expanded ? value.text : String(value.text.prefix(1200))).reedFont(.body).textSelection(.enabled)
                if value.text.count > 1200 { Button(expanded ? "Свернуть текст" : "Показать весь текст") { expanded.toggle() }.reedFont(.caption) }
            }
            ForEach(value.fields.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 4) {
                    Text(value.fields[index].0).reedFont(.metadata).foregroundStyle(ReedTheme.secondary)
                    Text(value.fields[index].1).reedFont(.caption).textSelection(.enabled)
                }
            }
            if !value.photos.isEmpty {
                Text("Фотографии: \(value.photos.count)").reedFont(.caption)
                ForEach(value.photos, id: \.self) { id in AttachmentPreview(id: id, store: store) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(ReedTheme.raised, in: RoundedRectangle(cornerRadius: ReedTheme.radius))
    }
}
