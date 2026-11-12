import SwiftUI
import UniformTypeIdentifiers

struct DataSettingsView: View {
    @State private var model: DataSettingsModel
    @State private var imports = false
    @State private var confirmsClear = false
    @State private var confirmsRestore = false
    @State private var importError: String?
    init(context: LibraryContext) { _model = State(initialValue: DataSettingsModel(context: context)) }
    var body: some View {
        Form {
            Section("На этом iPhone") {
                if let summary = model.summary {
                    LabeledContent("Карточки", value: "\(summary.cards)")
                    LabeledContent("Черновики", value: "\(summary.drafts)")
                    LabeledContent("Фотографии", value: "\(summary.photos)")
                }
                Text("Облачная синхронизация пока недоступна. Резервная копия позволяет перенести библиотеку или восстановить её после переустановки.").reedFont(.caption)
            }
            Section("Резервная копия") {
                Button("Создать резервную копию") { Task { await model.export() } }.accessibilityIdentifier("data.export")
                if let url = model.exportedURL { ShareLink("Сохранить или отправить файл", item: url) }
                Text("Файл содержит тексты, фото, черновики, историю и настройки. Он не зашифрован; храните его в подходящем месте. Данные входа в файл не включаются.").reedFont(.metadata)
            }
            Section("Восстановление") {
                Button("Выбрать резервную копию") { imports = true }
                if let prepared = model.prepared {
                    Text("Создана: \(ReedDatePresentation.dateTime(prepared.snapshot.createdAt))")
                    Text("Карточки: \(prepared.snapshot.cards.count) · Черновики: \(prepared.snapshot.drafts.count) · Фото: \(prepared.snapshot.attachmentIDs.count)").reedFont(.caption)
                    Button("Восстановить библиотеку") { confirmsRestore = true }
                    Button("Отменить выбор", role: .cancel) { Task { await model.discardPreview() } }
                }
                Text("Восстанавливаем в пустую библиотеку. Существующие данные автоматически не объединяются и не перезаписываются.").reedFont(.metadata)
            }
            Section("Удаление локальных данных") {
                Text("Будут удалены карточки, фото, черновики, история и настройки на этом iPhone. Аккаунт останется. Сначала сохраните резервную копию за пределами приложения.").reedFont(.caption)
                Button("Очистить библиотеку на iPhone", role: .destructive) { confirmsClear = true }.accessibilityIdentifier("data.clear")
            }
            if model.working { ProgressView("Выполняем операцию…") }
            if let message = model.message { Text(message).foregroundStyle(ReedTheme.secondary) }
            if let error = model.errorMessage ?? importError { Text(error).foregroundStyle(.red) }
        }.disabled(model.working)
        .navigationTitle("Данные").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.working)
        .task { await model.load() }
        .fileImporter(isPresented: $imports, allowedContentTypes: [.data]) { result in
            switch result {
            case let .success(url): Task { await model.inspect(url) }
            case .failure: importError = "Не удалось открыть выбранный файл."
            }
        }
        .confirmationDialog("Очистить все локальные данные? Отменить это действие можно только восстановлением из сохранённой копии.", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Очистить локальную библиотеку", role: .destructive) { Task { await model.clear() } }
        }
        .confirmationDialog("Восстановить тексты, фото и настройки из выбранной копии?", isPresented: $confirmsRestore, titleVisibility: .visible) {
            Button("Восстановить") { Task { await model.restore() } }
        }
        .onDisappear { if !model.working { Task { await model.discardPreview() } } }
    }
}
