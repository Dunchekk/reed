import Foundation
import Testing
import ReedDomain
import ReedApplication
import ReedPersistence

@Test(arguments: CatalogKind.allCases)
func mergingCatalogEntriesPreservesCardsAndRemapsLinks(kind: CatalogKind) async throws {
    let library = try TestLibrary(); defer { library.cleanup() }
    let database = try LibraryDatabase(root: library.root, accountID: library.accountID)
    let manager = LocalCatalogManagementRepository(database: database)
    let first = Card(text: "Первый", source: Source(title: "Источник 1", authors: [Author(name: "Автор 1")]), tags: [Tag(name: "Тег 1")], folder: Folder(name: "Папка 1"))
    let second = Card(text: "Второй", source: Source(title: "Источник 2", authors: [Author(name: "Автор 2")]), tags: [Tag(name: "Тег 2")], folder: Folder(name: "Папка 2"))
    try await library.repository.save(first); try await library.repository.save(second)
    let snapshot = try await manager.entries(kind: kind)
    let from = snapshot.entries[0], to = snapshot.entries[1]
    #expect(from.cardCount == 1)
    try await manager.update(kind: kind, mutation: .merge(id: from.id, into: to.id), expectedRevision: snapshot.revision)
    let next = try await manager.entries(kind: kind)
    #expect(next.entries.count == 1); #expect(next.entries[0].cardCount == 2)
    #expect(try await library.repository.card(id: first.id)?.text == "Первый")
    #expect(try await library.repository.card(id: second.id)?.text == "Второй")
    await #expect(throws: LibraryError.conflict) {
        try await manager.update(kind: kind, mutation: .rename(id: to.id, name: "Устаревшая команда"), expectedRevision: snapshot.revision)
    }
}

@Test func catalogRemovalPausesAffectedRulesAndProtectsDraftsFromStaleNames() async throws {
    let library = try TestLibrary(); defer { library.cleanup() }
    let database = try LibraryDatabase(root: library.root, accountID: library.accountID)
    let manager = LocalCatalogManagementRepository(database: database)
    let tag = Tag(name: "Старая тема"), folder = Folder(name: "Папка")
    let card = Card(text: "Фрагмент", tags: [tag], folder: folder)
    try await library.repository.save(card)
    let stale = try #require(await library.repository.card(id: card.id))
    let drafts = LocalDraftRepository(database: database)
    var draft = CardDraft(card: stale); draft.card.text = "Незаконченная правка"
    try await drafts.saveDraft(draft)
    var settings = ReturnSettings(); settings.enabled = true; settings.notificationsEnabled = true; settings.globalInclude.tags = [tag.id]
    let returns = LocalReturnRepository(database: database)
    try await returns.saveSettings(settings, now: Date(), calendar: .current)
    try await manager.update(kind: .tags, mutation: .remove(id: tag.id), expectedRevision: manager.entries(kind: .tags).revision)
    #expect(try await !returns.settings().enabled)
    #expect(try await library.repository.card(id: card.id)?.tags.isEmpty == true)
    await #expect(throws: LibraryError.conflict) { try await library.repository.save(stale) }
    let recovered = try #require(await drafts.draft(id: draft.id))
    #expect(recovered.tagNames.isEmpty)
    let editor = CardEditingService(library: library.repository, drafts: drafts, attachments: FileAttachmentStore(directory: database.directory))
    _ = try await editor.publish(recovered)
    #expect(try await library.repository.card(id: card.id)?.text == "Незаконченная правка")
    #expect(try await manager.entries(kind: .tags).entries.isEmpty)
}

@Test(arguments: ["rename", "merge", "remove"])
func authorManagementUpdatesUnpublishedSourceDraftBeforePublication(operation: String) async throws {
    let library = try TestLibrary(); defer { library.cleanup() }
    let db = try LibraryDatabase(root: library.root, accountID: library.accountID)
    let drafts = LocalDraftRepository(database: db), manager = LocalCatalogManagementRepository(database: db)
    let old = Author(name: "Старый Автор"), target = Author(name: "Новый Автор")
    try await library.repository.save(Card(text:"Существующий",source:Source(title:"Книга",authors:[old,target])))
    var draft = CardDraft(card:Card(text:"Новый фрагмент"))
    draft.sourceTitle = "Новый источник"; draft.authorNames = "  старый автор ; Новый Автор"
    try await drafts.saveDraft(draft)
    let mutation: CatalogMutation = operation == "rename" ? .rename(id:old.id,name:"Переименованный") : operation == "merge" ? .merge(id:old.id,into:target.id) : .remove(id:old.id)
    try await manager.update(kind:.authors,mutation:mutation,expectedRevision:manager.entries(kind:.authors).revision)
    let recovered = try #require(await drafts.draft(id:draft.id))
    let editor = CardEditingService(library:library.repository,drafts:drafts,attachments:FileAttachmentStore(directory:db.directory))
    _ = try await editor.publish(recovered)
    let saved = try #require(await library.repository.card(id:draft.card.id))
    #expect(saved.source?.authors.map(\.name) == (operation == "rename" ? ["Переименованный","Новый Автор"] : ["Новый Автор"]))
    #expect(try await manager.entries(kind:.authors).entries.contains { $0.name == "Старый Автор" } == false)
}
