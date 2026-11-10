import Foundation
import Testing
import ReedDomain
import ReedPersistence

struct TestLibrary {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reed-test-\(UUID())")
    let accountID = UUID()
    let repository: LocalLibraryRepository
    init() throws {
        repository = LocalLibraryRepository(database: try LibraryDatabase(root: root, accountID: accountID))
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Test func cardsSurviveReopeningAndRemainAccountScoped() async throws {
    let library = try TestLibrary()
    defer { library.cleanup() }
    let source = Source(title: "Синтетический источник", authors: [Author(name: "Автор Один"), Author(name: "Автор Два")])
    let card = Card(text: "Проверяем сохранность фрагмента", source: source, tags: [Tag(name: "Тема")], folder: Folder(name: "Чтение"))
    try await library.repository.save(card)
    let reopened = LocalLibraryRepository(database: try LibraryDatabase(root: library.root, accountID: library.accountID))
    let saved = try #require(await reopened.card(id: card.id))
    #expect(saved.text == card.text)
    #expect(saved.source == source)
    #expect(saved.tags == card.tags)
    #expect(saved.version == 1)
    let another = LocalLibraryRepository(database: try LibraryDatabase(root: library.root, accountID: UUID()))
    #expect(try await another.card(id: card.id) == nil)
}

@Test func staleEditsCannotOverwriteNewerChanges() async throws {
    let library = try TestLibrary()
    defer { library.cleanup() }
    let card = Card(text: "Первая редакция")
    try await library.repository.save(card)
    var firstEditor = try #require(await library.repository.card(id: card.id))
    var secondEditor = firstEditor
    firstEditor.text = "Сохранённая редакция"
    try await library.repository.save(firstEditor)
    secondEditor.text = "Устаревшая редакция"
    await #expect(throws: LibraryError.conflict) { try await library.repository.save(secondEditor) }
    #expect(try await library.repository.card(id: card.id)?.text == "Сохранённая редакция")
}

@Test func trashCanBeRestoredAndOnlyExpiredItemsArePurged() async throws {
    let library = try TestLibrary()
    defer { library.cleanup() }
    let card = Card(text: "Удалённая карточка", deletedAt: Date(timeIntervalSince1970: 100))
    try await library.repository.save(card)
    #expect(try await library.repository.purgeTrash(before: Date(timeIntervalSince1970: 99)).isEmpty)
    var restored = try #require(await library.repository.card(id: card.id))
    restored.deletedAt = nil
    try await library.repository.save(restored)
    #expect(try await library.repository.purgeTrash(before: Date()).isEmpty)
    var deleted = try #require(await library.repository.card(id: card.id))
    deleted.deletedAt = Date(timeIntervalSince1970: 100)
    try await library.repository.save(deleted)
    #expect(try await library.repository.purgeTrash(before: Date(timeIntervalSince1970: 100)) == [card.id])
    #expect(try await library.repository.card(id: card.id) == nil)
}
