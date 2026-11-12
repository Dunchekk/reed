import Foundation
import Observation
import ReedDomain
import ReedApplication

@MainActor @Observable
final class CardEditorModel {
    var draft: CardDraft
    private(set) var catalog = LibraryCatalog()
    private(set) var savesPhotos = true
    private(set) var isLoaded = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var saveStatus = ""
    private(set) var isChanged = false
    @ObservationIgnored private let context: LibraryContext
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var closed = false

    init(context: LibraryContext, card: Card? = nil, draft: CardDraft? = nil, initialText: String = "") {
        self.context = context
        self.draft = draft ?? CardDraft(card: card ?? Card(text: initialText))
    }
    var canSave: Bool { isLoaded && !isSaving && !draft.card.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func load() async {
        guard !isLoaded else { return }
        do {
            catalog = try await context.repository.catalog()
            savesPhotos = try await context.capturePreferences.capturePreferences().savesPhotos
            isLoaded = true
            if draft.card.version == 0 && !draft.isEmpty { changed() }
        } catch { errorMessage = libraryErrorMessage(error) }
    }
    func changed() {
        guard isLoaded, !closed else { return }
        isChanged = true
        enqueueSave(debounced: true)
    }
    private func enqueueSave(debounced: Bool) {
        pending?.cancel()
        let previous = pending, snapshot = draft, token = UUID(); generation = token
        saveStatus = "Сохраняем черновик…"
        pending = Task {
            await previous?.value
            do {
                if debounced { try await Task.sleep(for: .milliseconds(300)) }
                try Task.checkCancellation()
                try await context.editor.autosave(snapshot)
                if generation == token { saveStatus = "Черновик сохранён"; errorMessage = nil }
            } catch is CancellationError {} catch {
                if generation == token { saveStatus = ""; errorMessage = "Не удалось сохранить черновик. Повторите сохранение перед выходом." }
            }
        }
    }
    func flush() async {
        guard !closed, isChanged else { return }
        enqueueSave(debounced: false)
        await pending?.value
    }
    func finishEditing() async -> Bool {
        await flush()
        guard !isChanged || errorMessage == nil else { return false }
        closed = true; context.markDraftsChanged(); return true
    }
    func setSavesPhotos(_ value: Bool) async {
        guard !isSaving else { return }
        do {
            try await context.capturePreferences.setCapturePreferences(CapturePreferences(savesPhotos: value))
            savesPhotos = value
            if !value {
                draft.card.attachmentIDs.removeAll { draft.newAttachmentIDs.contains($0) }
                draft.newAttachmentIDs = []
                changed()
            }
        } catch { errorMessage = libraryErrorMessage(error) }
    }
    func removePhoto(_ id: UUID) {
        draft.card.attachmentIDs.removeAll { $0 == id }; draft.newAttachmentIDs.remove(id); changed()
    }
    func applyPhoto(_ photo: ProcessedPhoto, text: String, separate: Bool, attachPhoto: Bool = true) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true; defer { isSaving = false }
        await flush()
        do {
            var result = separate ? CardEditingService.fragment(from: draft, text: text) : draft
            if !separate && !text.isEmpty { result.card.text += (result.card.text.isEmpty ? "" : "\n\n") + text }
            if savesPhotos && attachPhoto { result = try await context.editor.attach(original: photo.original, thumbnail: photo.thumbnail, to: result) }
            try await context.editor.autosave(result)
            if !separate { draft = result; isChanged = true; saveStatus = "Черновик сохранён" }
            context.markDraftsChanged(); errorMessage = nil
            return true
        } catch { errorMessage = libraryErrorMessage(error); return false }
    }
    func save(continueEditing: Bool = false) async -> UUID? {
        guard canSave else { return nil }
        isSaving = true; defer { isSaving = false }
        await flush()
        do {
            let id = try await context.editor.publish(draft)
            context.markChanged(); context.markDraftsChanged()
            if continueEditing {
                let saved = try await context.repository.card(id: id)
                var next = CardDraft(); next.sourceID = saved?.source?.id; next.folderID = saved?.folder?.id
                next.tagNames = draft.tagNames
                draft = next; isChanged = false; saveStatus = "Карточка сохранена. Можно добавить следующий фрагмент."
                catalog = try await context.repository.catalog()
            } else { closed = true }
            return id
        } catch { errorMessage = libraryErrorMessage(error); return nil }
    }
    func discard() async -> Bool {
        pending?.cancel(); await pending?.value
        do {
            try await context.drafts.discardDraft(id: draft.id)
            closed = true; context.markDraftsChanged(); return true
        } catch { errorMessage = libraryErrorMessage(error); return false }
    }
}
