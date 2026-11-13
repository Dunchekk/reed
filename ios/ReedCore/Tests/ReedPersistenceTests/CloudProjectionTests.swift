import Foundation
import Testing
import ReedDomain
import ReedApplication
@testable import ReedPersistence

@Test func cloudPullProjectsDependenciesAcrossPagesWithoutEchoingChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reed-cloud-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try LibraryDatabase(root: root, accountID: UUID())
    let library = LocalLibraryRepository(database: database), cloud = LocalCloudRepository(database: database), epoch = UUID()
    try await cloud.begin(epoch: epoch)
    let author = Author(name: "Первый автор"), tag = Tag(name: "Тема")
    let source = Source(title: "Книга", authors: [author])
    let card = Card(text: "Текст", source: source, tags: [tag])
    try await cloud.apply(CloudPage(epoch: epoch, records: [
        CloudRecord(key: CloudKey(.tag,tag.id), version: 1, sequence: 1, payload: .encode(tag)),
        CloudRecord(key: CloudKey(.card,card.id), version: 1, sequence: 2, payload: .encode(CloudCard(card)))
    ], cursor: 2, hasMore: true))
    #expect(try await library.card(id: card.id) == nil)
    try await cloud.apply(CloudPage(epoch: epoch, records: [
        CloudRecord(key: CloudKey(.source,source.id), version: 1, sequence: 3, payload: .encode(CloudSource(source))),
        CloudRecord(key: CloudKey(.author,author.id), version: 1, sequence: 4, payload: .encode(author))
    ], cursor: 4, hasMore: false))
    #expect(try await library.card(id: card.id)?.source == source)
    #expect(try await cloud.nextPending() == nil)
    let renamed = Author(id: author.id, name: "Новое имя")
    try await cloud.apply(CloudPage(epoch: epoch, records: [CloudRecord(key: CloudKey(.author,author.id), version: 2, sequence: 5, payload: .encode(renamed))], cursor: 5, hasMore: false))
    var query = ArchiveQuery(); query.search = "новое"
    #expect(try await library.archive(query).cards.map(\.id) == [card.id])
    #expect(try await cloud.summary().pending == 0)
}

@Test func cloudPullRollsBackDocumentsAndCursorWhenAnyProjectionIsInvalid() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reed-cloud-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try LibraryDatabase(root: root, accountID: UUID()), epoch = UUID()
    let library = LocalLibraryRepository(database: database), cloud = LocalCloudRepository(database: database)
    try await cloud.begin(epoch: epoch)
    let tag = Tag(name: "Не сохранится"), card = Card(text: "")
    let page = try CloudPage(epoch: epoch, records: [
        CloudRecord(key: CloudKey(.tag,tag.id), version: 1, sequence: 1, payload: .encode(tag)),
        CloudRecord(key: CloudKey(.card,card.id), version: 1, sequence: 2, payload: .encode(CloudCard(card)))
    ], cursor: 2, hasMore: false)
    await #expect(throws: CloudError.invalidRecord) { try await cloud.apply(page) }
    #expect(try await cloud.state().cursor == 0)
    #expect(try await library.catalog().tags.isEmpty)
    try await library.save(Card(text: "После ошибки"))
    #expect(try await cloud.summary().pending == 1)
}

@Test func cloudHistoryPreferenceDoesNotErasePreviouslyCollectedOpenings() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reed-history-cloud-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try LibraryDatabase(root: root, accountID: UUID()), epoch = UUID()
    let library = LocalLibraryRepository(database: database), cloud = LocalCloudRepository(database: database), activity = LocalActivityRepository(database: database)
    let card = Card(text: "История"), now = Date()
    try await library.save(card); try await activity.recordOpening(cardID: card.id, origin: .manual, now: now)
    try await cloud.begin(epoch: epoch)
    try await cloud.apply(CloudPage(epoch: epoch, records: [.init(key: .history, version: 1, sequence: 1, payload: .encode(CloudHistoryPreference(enabled: false)))], cursor: 1, hasMore: false))
    #expect(try await activity.activity(now: now).openings.isEmpty)
    try await activity.setHistoryEnabled(true)
    #expect(try await activity.activity(now: now).openings.count == 1)
}
