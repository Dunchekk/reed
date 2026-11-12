import SwiftUI
import ReedDomain

struct CardEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let context: LibraryContext
    let initialInput: CardInput
    @State private var model: CardEditorModel
    @State private var confirmsDiscard = false
    @State private var review: PhotoReviewInput?
    @State private var photoError: String?

    init(context: LibraryContext, card: Card? = nil, draft: CardDraft? = nil, initialText: String = "", initialInput: CardInput = .text) {
        self.context = context; self.initialInput = initialInput
        _model = State(initialValue: CardEditorModel(context: context, card: card, draft: draft, initialText: initialText))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Фото и распознавание") {
                    Toggle("Сохранять фото", isOn: Binding(get: { model.savesPhotos }, set: { value in Task { await model.setSavesPhotos(value) } }))
                        .accessibilityIdentifier("editor.savePhotos")
                    Text("Выбор запоминается для следующих фото. Уже прикреплённые фотографии можно удалить отдельно.").reedFont(.metadata).foregroundStyle(ReedTheme.secondary)
                    PhotoInputView(initialInput: initialInput, savesPhotos: model.savesPhotos, apply: { photo, text, separate in
                        await model.applyPhoto(photo, text: text, separate: separate)
                    })
                    ForEach(model.draft.card.attachmentIDs, id: \.self) { id in
                        EditorPhotoRow(id: id, context: context, remove: { model.removePhoto(id) }, recognize: {
                            Task {
                                do { review = PhotoReviewInput(data: try await context.attachments.original(id: id)) }
                                catch { photoError = "Оригинал фотографии недоступен. Можно удалить вложение или выбрать фото заново." }
                            }
                        })
                    }
                    if let photoError { Text(photoError).foregroundStyle(.red) }
                }.disabled(!model.isLoaded)
                Section("Текст") {
                    TextEditor(text: $model.draft.card.text).reedFont(.body).frame(minHeight: 240)
                        .accessibilityLabel("Текст карточки").accessibilityIdentifier("editor.text")
                    PasteButton(payloadType: String.self) { values in
                        guard let value = values.first else { return }
                        model.draft.card.text += (model.draft.card.text.isEmpty ? "" : "\n\n") + value
                    }
                }
                Section("Контекст — по желанию") {
                    TextField("Заголовок", text: $model.draft.card.title).accessibilityIdentifier("editor.title")
                    TextField("Комментарий", text: $model.draft.card.comment, axis: .vertical).lineLimit(3...8)
                    TextField("Страница или место", text: $model.draft.card.page)
                }
                Section("Источник") {
                    Picker("Сохранённый источник", selection: $model.draft.sourceID) {
                        Text("Без источника / новый").tag(UUID?.none)
                        ForEach(model.catalog.sources) { Text($0.displayName).tag(Optional($0.id)) }
                    }
                    if model.draft.sourceID == nil {
                        TextField("Название нового источника", text: $model.draft.sourceTitle)
                        TextField("Авторы через точку с запятой", text: $model.draft.authorNames)
                    }
                }
                Section("Организация") {
                    TextField("Теги через запятую", text: $model.draft.tagNames).accessibilityIdentifier("editor.tags")
                    Picker("Папка", selection: $model.draft.folderID) {
                        Text("Без папки / новая").tag(UUID?.none)
                        ForEach(model.catalog.folders) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if model.draft.folderID == nil { TextField("Название новой папки", text: $model.draft.folderName) }
                }
                Section {
                    if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
                    if !model.isLoaded { Button("Повторить загрузку") { Task { await model.load() } } }
                    if !model.saveStatus.isEmpty { Text(model.saveStatus).reedFont(.metadata).foregroundStyle(ReedTheme.secondary) }
                    Button("Сохранить и добавить следующий фрагмент") { Task { _ = await model.save(continueEditing: true) } }.disabled(!model.canSave)
                    if model.isSaving { ProgressView("Сохраняем…") }
                }
            }
            .disabled(model.isSaving)
            .navigationTitle(model.draft.card.version == 0 ? "Добавить карточку" : "Изменить карточку")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { Task { if await model.finishEditing() { dismiss() } } }.disabled(model.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { Task { if await model.save() != nil { dismiss() } } }
                        .disabled(!model.canSave).accessibilityIdentifier("editor.save")
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Удалить черновик", role: .destructive) { confirmsDiscard = true }.disabled(model.isSaving)
                }
            }
            .confirmationDialog("Удалить черновик? Сохранённая карточка не изменится.", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("Удалить черновик", role: .destructive) { Task { if await model.discard() { dismiss() } } }
            }
            .interactiveDismissDisabled(model.isSaving || model.isChanged)
            .onChange(of: model.draft) { _, _ in model.changed() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { Task { await model.flush() } } }
            .onDisappear { Task { await model.flush(); context.markDraftsChanged() } }
            .task { await model.load() }
            .sheet(item: $review) { input in
                PhotoReviewView(data: input.data, savesPhotos: false) { photo, text, separate in
                    // Existing photos are already attached; repeating OCR must not duplicate them.
                    await model.applyPhoto(photo, text: text, separate: separate, attachPhoto: false)
                }
            }
        }
    }
}

private struct EditorPhotoRow: View {
    let id: UUID
    let context: LibraryContext
    let remove: () -> Void
    let recognize: () -> Void
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        HStack {
            if let image { Image(uiImage: image).resizable().scaledToFit().frame(width: 64, height: 80) }
            else { Image(systemName: failed ? "photo.badge.exclamationmark" : "photo").frame(width: 64, height: 80) }
            Button("Распознать снова", action: recognize).buttonStyle(.borderless)
            Spacer()
            Button("Удалить фото", systemImage: "trash", role: .destructive, action: remove).labelStyle(.iconOnly).buttonStyle(.borderless)
        }.task(id: id) {
            do { image = UIImage(data: try await context.attachments.thumbnail(id: id)); failed = image == nil }
            catch { failed = true }
        }
    }
}
