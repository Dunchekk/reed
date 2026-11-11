import Foundation
import GRDB
import Testing
import ReedDomain
@testable import ReedPersistence

@Test func cloudDirtyMarkersCommitAndRollbackWithLibraryWrites() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reed-cloud-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try LibraryDatabase(root: root, accountID: UUID())
    let library = LocalLibraryRepository(database: database)
    let local = Card(text: "Локальная карточка")
    try await library.save(local)
    #expect(try await database.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM cloud_dirty") } == 0)
    try await database.writer.write { try $0.execute(sql: "UPDATE cloud_state SET mode='enabling' WHERE id=1") }
    let card = Card(text: "Карточка с метаданными", tags: [Tag(name: "Тема")])
    try await library.save(card)
    let keys = try await database.writer.read { try String.fetchAll($0, sql: "SELECT kind FROM cloud_dirty ORDER BY kind") }
    #expect(keys == ["card", "tag"])
    let before = try await database.writer.read { try Int.fetchOne($0, sql: "SELECT generation FROM cloud_state") }
    await #expect(throws: LibraryError.self) {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE cards SET text='Не должно сохраниться' WHERE id=?", arguments: [card.id.uuidString])
            throw LibraryError.conflict
        }
    }
    #expect(try await library.card(id: card.id)?.text == card.text)
    #expect(try await database.writer.read { try Int.fetchOne($0, sql: "SELECT generation FROM cloud_state") } == before)
}

@Test func cloudAcknowledgementPreservesTheNextEditAndRetriesTheSameOperation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reed-cloud-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try LibraryDatabase(root: root, accountID: UUID())
    let library = LocalLibraryRepository(database: database), cloud = LocalCloudRepository(database: database)
    let card = Card(text: "Первая версия")
    try await library.save(card)
    try await cloud.begin(epoch: UUID())
    let first = try #require(await cloud.nextPending())
    var changed = try #require(await library.card(id: card.id)); changed.text = "Следующая версия"
    try await library.save(changed)
    let reopened = LocalCloudRepository(database: database)
    #expect(try await reopened.nextPending() == first)
    try await reopened.acknowledge(first, result: .init(outcome: .applied, record: .init(key: first.mutation.key, version: 1, sequence: 1, payload: first.mutation.payload)))
    let second = try #require(await reopened.nextPending())
    #expect(second.mutation.operationID != first.mutation.operationID)
    #expect(second.mutation.baseVersion == 1)
    #expect(try second.mutation.payload.decode(CloudCard.self).text == "Следующая версия")
    #expect(second.generation > first.generation)
    try await reopened.acknowledge(second, result: .init(outcome: .applied, record: .init(key: second.mutation.key, version: 2, sequence: 2, payload: second.mutation.payload)))
    #expect(try await reopened.nextPending() == nil)
}
