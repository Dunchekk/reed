import Foundation
import Testing
import ReedDomain
import ReedApplication
import ReedPersistence

@Test func draftPhotosSurviveRestartAndPublicationIsAtomic() async throws {
    let library = try TestLibrary(); defer { library.cleanup() }
    let database = try LibraryDatabase(root: library.root, accountID: library.accountID)
    let drafts = LocalDraftRepository(database: database)
    let files = FileAttachmentStore(directory: database.directory)
    let editor = CardEditingService(library: library.repository, drafts: drafts, attachments: files)
    var draft = CardDraft(card: Card(text: "Текст страницы"))
    draft = try await editor.attach(original: Data([1]), thumbnail: Data([2]), to: draft)
    draft = try await editor.attach(original: Data([3]), thumbnail: Data([4]), to: draft)
    let reopened = LocalDraftRepository(database: try LibraryDatabase(root: library.root, accountID: library.accountID))
    #expect(try await reopened.draft(id: draft.id)?.card.attachmentIDs == draft.card.attachmentIDs)
    try await files.collectOrphans(retaining: library.repository.attachmentIDs())
    #expect(try await files.thumbnail(id: draft.card.attachmentIDs[0]) == Data([2]))
    let id = try await editor.publish(draft)
    #expect(try await drafts.drafts().isEmpty)
    #expect(try await library.repository.card(id: id)?.attachmentIDs == draft.card.attachmentIDs)
    await #expect(throws: LibraryError.notFound) { try await editor.autosave(draft) }
    #expect(try await drafts.drafts().isEmpty)
}

@Test func failedPublicationKeepsDraftAndDiscardCannotBeUndoneByLateAutosave() async throws {
    let library = try TestLibrary(); defer { library.cleanup() }
    let drafts = LocalDraftRepository(database: try LibraryDatabase(root: library.root, accountID: library.accountID))
    let original = Card(text: "Исходный текст")
    try await library.repository.save(original)
    var card = try #require(await library.repository.card(id: original.id))
    var draft = CardDraft(card: card); draft.card.text = "Из черновика"
    try await drafts.saveDraft(draft)
    card.text = "Из другого редактора"; try await library.repository.save(card)
    await #expect(throws: LibraryError.conflict) { try await drafts.publishDraft(id: draft.id, card: draft.card) }
    #expect(try await drafts.draft(id: draft.id)?.card.text == "Из черновика")
    #expect(try await library.repository.card(id: original.id)?.text == "Из другого редактора")
    try await drafts.discardDraft(id: draft.id)
    await #expect(throws: LibraryError.notFound) { try await drafts.saveDraft(draft) }
}

@Test func editorResolvesCurrentCatalogAndKeepsEmptyEdits() async throws {
    let library = try TestLibrary(); defer { library.cleanup() }
    let database = try LibraryDatabase(root: library.root, accountID: library.accountID)
    let drafts = LocalDraftRepository(database: database)
    let editor = CardEditingService(library: library.repository, drafts: drafts, attachments: FileAttachmentStore(directory: database.directory))
    var draft = CardDraft(card: Card(text: "Начало"))
    try await editor.autosave(draft)
    draft.card.text = ""
    try await editor.autosave(draft)
    #expect(try await drafts.draft(id: draft.id)?.card.text == "")
    await #expect(throws: LibraryError.emptyText) { _ = try await editor.publish(draft) }
    #expect(try await drafts.draft(id: draft.id) != nil)
    draft.card.text = "Продолжение"; draft.sourceTitle = "Книга"; draft.authorNames = "Автор; Автор"
    draft.tagNames = "Тема, тема, Еж, Ёж"
    let id = try await editor.publish(draft)
    let card = try #require(await library.repository.card(id: id))
    #expect(card.tags.count == 2); #expect(card.source?.authors.count == 1)
}
