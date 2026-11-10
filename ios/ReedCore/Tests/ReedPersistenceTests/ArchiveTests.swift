import Foundation
import Testing
import ReedDomain
import ReedPersistence

@Test func archiveMatchesTheSharedSearchExamples() async throws {
    struct Fixture: Decodable {
        struct Entry: Decodable { let id: UUID; let text, title, comment, source, author: String }
        struct Example: Decodable { let query: String; let expected: [UUID] }
        let cards: [Entry]
        let cases: [Example]
    }
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("contracts/fixtures/archive-search.json")))
    let library = try TestLibrary()
    defer { library.cleanup() }
    for entry in fixture.cards {
        try await library.repository.save(Card(id: entry.id, text: entry.text, title: entry.title, comment: entry.comment,
            source: Source(title: entry.source, authors: [Author(name: entry.author)])))
    }
    for example in fixture.cases {
        var query = ArchiveQuery(); query.search = example.query
        #expect(Set(try await library.repository.archive(query).cards.map(\.id)) == Set(example.expected))
    }
}

@Test func archiveCombinesPrefixSearchAndAllMetadataFilters() async throws {
    let library = try TestLibrary()
    defer { library.cleanup() }
    let author = Author(name: "Автор Ёлкин")
    let source = Source(title: "Синтетическая книга", authors: [author])
    let tag = Tag(name: "Мысли")
    let folder = Folder(name: "Прочитать")
    let card = Card(text: "Ёжик смотрит на ель", comment: "Личный комментарий", source: source,
        tags: [tag], folder: folder, createdAt: Date(timeIntervalSince1970: 100), isFavorite: true)
    try await library.repository.save(card)
    try await library.repository.save(Card(text: "Ёжик в другой карточке"))
    var query = ArchiveQuery()
    query.search = "еж"
    query.keywords = "личн коммент"
    query.tagIDs = [UUID(), tag.id]
    query.folderID = folder.id
    query.authorID = author.id
    query.sourceID = source.id
    query.createdAfter = Date(timeIntervalSince1970: 99)
    query.createdBefore = Date(timeIntervalSince1970: 101)
    query.favoritesOnly = true
    #expect(try await library.repository.archive(query).cards.map(\.id) == [card.id])
    query.keywords = "отсутствует"
    #expect(try await library.repository.archive(query).cards.isEmpty)
    query.keywords = ""
    query.search = "жик"
    #expect(try await library.repository.archive(query).cards.isEmpty)
}

@Test func sharedSourceChangesReindexEveryRelatedCard() async throws {
    let library = try TestLibrary()
    defer { library.cleanup() }
    let source = Source(title: "Старое название", authors: [Author(name: "Первый автор")])
    let first = Card(text: "Первый текст", source: source)
    let second = Card(text: "Второй текст", source: source)
    try await library.repository.save(first)
    try await library.repository.save(second)
    var edited = try #require(await library.repository.card(id: first.id))
    edited.source?.title = "Новое название"
    edited.source?.authors[0].name = "Обновлённый автор"
    try await library.repository.save(edited)
    var query = ArchiveQuery()
    query.search = "новое обновленный"
    #expect(Set(try await library.repository.archive(query).cards.map(\.id)) == Set([first.id, second.id]))
    query.search = "старое"
    #expect(try await library.repository.archive(query).cards.isEmpty)
}

@Test(arguments: ArchiveSort.allCases)
func cursorsPageEveryCardExactlyOnce(sort: ArchiveSort) async throws {
    let library = try TestLibrary()
    defer { library.cleanup() }
    var expected = Set<UUID>()
    for index in 0..<13 {
        let card = Card(text: "Фрагмент \(index)", title: "Повторяющееся название", createdAt: Date(timeIntervalSince1970: 100))
        expected.insert(card.id)
        try await library.repository.save(card)
    }
    var query = ArchiveQuery()
    query.sort = sort; query.pageSize = 4; query.randomSeed = 42
    var cursor: String?
    var received: [UUID] = []
    repeat {
        let page = try await library.repository.archive(query, after: cursor)
        received += page.cards.map(\.id)
        cursor = page.nextCursor
    } while cursor != nil
    #expect(received.count == expected.count)
    #expect(Set(received) == expected)
    let page = try await library.repository.archive(query)
    #expect(page.cards.map(\.id) == Array(received.prefix(4)))
    try await library.repository.save(Card(text: "Изменение библиотеки"))
    await #expect(throws: LibraryError.staleCursor) { try await library.repository.archive(query, after: page.nextCursor) }
}

@Test func visibilityAndEmptyQueriesAreExplicit() async throws {
    let library = try TestLibrary()
    defer { library.cleanup() }
    let hidden = Card(text: "Скрыто", isHidden: true)
    let deleted = Card(text: "Корзина", deletedAt: Date())
    try await library.repository.save(hidden)
    try await library.repository.save(deleted)
    var query = ArchiveQuery()
    #expect(try await library.repository.archive(query).cards.isEmpty)
    query.visibility = .hidden
    #expect(try await library.repository.archive(query).cards.map(\.id) == [hidden.id])
    query.visibility = .trash
    #expect(try await library.repository.archive(query).cards.map(\.id) == [deleted.id])
    await #expect(throws: LibraryError.invalidCursor) { try await library.repository.archive(query, after: "invalid") }
}

@Test func searchKeysSurviveEditsAndDoNotLeakDeletedTextToNewCards() async throws {
    let library = try TestLibrary(); defer { library.cleanup() }
    let original = Card(text: "Устаревший текст")
    try await library.repository.save(original)
    var edited = try #require(await library.repository.card(id: original.id)); edited.text = "Обновлённый текст"
    try await library.repository.save(edited)
    var query = ArchiveQuery(); query.search = "устарев"
    #expect(try await library.repository.archive(query).cards.isEmpty)
    edited = try #require(await library.repository.card(id: original.id)); edited.deletedAt = Date(timeIntervalSince1970: 0)
    try await library.repository.save(edited); _ = try await library.repository.purgeTrash(before: Date())
    let fresh = Card(text: "Новая карточка")
    try await library.repository.save(fresh)
    query.search = "обновлен"
    #expect(try await library.repository.archive(query).cards.isEmpty)
    query.search = "новая"
    #expect(try await library.repository.archive(query).cards.map(\.id) == [fresh.id])
}
