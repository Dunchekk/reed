import SwiftUI
import ReedDomain

struct CardEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let context: LibraryContext
    @State private var model: CardEditorModel
    @State private var confirmsDiscard = false

    init(context: LibraryContext, card: Card? = nil, initialText: String = "") {
        self.context = context
        _model = State(initialValue: CardEditorModel(repository: context.repository, attachments: context.attachments, card: card, initialText: initialText))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Фото и распознавание") {
                    PhotoInputView(apply: { draft in
                        model.photo = draft
                        if !draft.recognizedText.isEmpty { model.text += (model.text.isEmpty ? "" : "\n\n") + draft.recognizedText }
                    }, isProcessing: $model.isProcessingPhoto)
                    if model.photo != nil { Text("Фотография прикреплена. Проверьте распознанный текст перед сохранением.").foregroundStyle(ReedTheme.secondary) }
                }
                Section("Текст") {
                    TextEditor(text: $model.text).reedFont(.body).frame(minHeight: 240)
                        .accessibilityLabel("Текст карточки").accessibilityIdentifier("editor.text")
                    PasteButton(payloadType: String.self) { values in
                        guard let value = values.first else { return }
                        model.text += (model.text.isEmpty ? "" : "\n\n") + value
                    }.disabled(model.isSaving)
                }
                Section("Контекст — по желанию") {
                    TextField("Заголовок", text: $model.title).accessibilityIdentifier("editor.title")
                    TextField("Комментарий", text: $model.comment, axis: .vertical).lineLimit(3...8)
                    TextField("Страница или место", text: $model.page)
                }
                Section("Источник") {
                    Picker("Сохранённый источник", selection: $model.selectedSourceID) {
                        Text("Без источника / новый").tag(UUID?.none)
                        ForEach(model.catalog.sources) { Text($0.displayName).tag(Optional($0.id)) }
                    }
                    if model.selectedSourceID == nil {
                        TextField("Название нового источника", text: $model.sourceTitle)
                        TextField("Авторы через точку с запятой", text: $model.authorNames)
                    }
                }
                Section("Организация") {
                    TextField("Теги через запятую", text: $model.tagNames).accessibilityIdentifier("editor.tags")
                    Picker("Папка", selection: $model.selectedFolderID) {
                        Text("Без папки / новая").tag(UUID?.none)
                        ForEach(model.catalog.folders) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if model.selectedFolderID == nil { TextField("Название новой папки", text: $model.newFolderName) }
                }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
                if !model.isCatalogLoaded { Button("Загрузить источники и теги") { Task { await model.loadCatalog() } } }
                if model.isSaving { ProgressView("Сохраняем…") }
            }
            .disabled(model.isSaving)
            .navigationTitle(model.original == nil ? "Добавить карточку" : "Изменить карточку")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { if model.isChanged { confirmsDiscard = true } else { dismiss() } }.disabled(model.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        Task { if await model.save() != nil { context.markChanged(); dismiss() } }
                    }.disabled(!model.canSave).accessibilityIdentifier("editor.save")
                }
            }
            .confirmationDialog("Отменить изменения?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("Отменить изменения", role: .destructive) { dismiss() }
            }
            .interactiveDismissDisabled(model.isChanged || model.isSaving || model.isProcessingPhoto)
            .task { await model.loadCatalog() }
        }
    }
}
