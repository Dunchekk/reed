import Foundation
import GRDB
import Testing
import ReedDomain
@testable import ReedPersistence

@Test func populatedVersionFiveDatabaseUpgradesSearchKeysWithoutLosingDocuments() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reed-migration-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let account = UUID(), cardID = UUID(), now = Date()
    let directory = root.appendingPathComponent(account.uuidString.lowercased())
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let old = try DatabaseQueue(path: directory.appendingPathComponent("library.sqlite").path)
    try LibraryDatabase.migrator.migrate(old, upTo: "005_returns")
    try await old.write { db in
        try db.execute(sql: """
            INSERT INTO cards(id,text,title,comment,page,created_at,updated_at,is_favorite,is_hidden,allows_returns,version,preview,sort_title,shuffle_key)
            VALUES (?,?,'','','',?,?,0,0,1,1,?,?,1)
            """, arguments: [cardID.uuidString,"Старый фрагмент",now.timeIntervalSince1970,now.timeIntervalSince1970,"Старый фрагмент","старый фрагмент"])
        // Old edits could give FTS a rowid unrelated to the cards table's rowid.
        try db.execute(sql: "INSERT INTO card_search(rowid,card_id,document) VALUES (91,?,?)", arguments: [cardID.uuidString,"старый фрагмент"])
    }
    try old.close()
    let repository = LocalLibraryRepository(database: try LibraryDatabase(root: root, accountID: account))
    var query = ArchiveQuery(); query.search = "старый"
    #expect(try await repository.archive(query).cards.map(\.id) == [cardID])
    var edited = try #require(await repository.card(id: cardID)); edited.text = "Новая редакция"
    try await repository.save(edited)
    #expect(try await repository.archive(query).cards.isEmpty)
    query.search = "новая"
    #expect(try await repository.archive(query).cards.map(\.id) == [cardID])
    edited = try #require(await repository.card(id: cardID)); edited.deletedAt = now.addingTimeInterval(-8*86400)
    try await repository.save(edited); _ = try await repository.purgeTrash(before: now)
    #expect(try await repository.archive(query).cards.isEmpty)
}
