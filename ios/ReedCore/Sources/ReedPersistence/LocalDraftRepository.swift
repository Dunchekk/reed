import Foundation
import GRDB
import ReedDomain
import ReedApplication

public struct LocalDraftRepository: DraftRepository {
    private let database: LibraryDatabase
    public init(database: LibraryDatabase) { self.database = database }
    public func drafts() async throws -> [DraftSummary] {
        try await database.writer.read { db in
            try Data.fetchAll(db, sql: "SELECT value FROM drafts WHERE state='active' ORDER BY updated_at DESC,id")
                .map { DraftSummary(try JSONDecoder().decode(CardDraft.self, from: $0)) }
        }
    }
    public func draft(id: UUID) async throws -> CardDraft? {
        try await database.writer.read { db in
            try Data.fetchOne(db, sql: "SELECT value FROM drafts WHERE id=? AND state='active'", arguments: [id.uuidString])
                .map { try JSONDecoder().decode(CardDraft.self, from: $0) }
        }
    }
    public func saveDraft(_ draft: CardDraft) async throws {
        let data = try JSONEncoder().encode(draft)
        try await database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO drafts VALUES (?,?,'active',?) ON CONFLICT(id) DO UPDATE
                SET updated_at=excluded.updated_at,value=excluded.value WHERE drafts.state='active'
                """, arguments: [draft.id.uuidString, draft.updatedAt.timeIntervalSince1970, data])
            guard db.changesCount == 1 else { throw LibraryError.notFound }
            try db.execute(sql: "DELETE FROM draft_attachments WHERE draft_id=?", arguments: [draft.id.uuidString])
            for id in Set(draft.card.attachmentIDs) {
                try db.execute(sql: "INSERT INTO draft_attachments VALUES (?,?)", arguments: [draft.id.uuidString,id.uuidString])
            }
        }
    }
    public func discardDraft(id: UUID) async throws {
        try await database.writer.write { db in try Self.close(id: id, state: "discarded", db: db) }
    }
    public func publishDraft(id: UUID, card: Card) async throws {
        try await database.writer.write { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT value FROM drafts WHERE id=? AND state='active'", arguments: [id.uuidString]),
                  try JSONDecoder().decode(CardDraft.self, from: data).card.id == card.id else { throw LibraryError.notFound }
            try LocalLibraryRepository.save(card, db: db, now: Date(), calendar: .current)
            try Self.close(id: id, state: "published", db: db)
        }
    }
    private static func close(id: UUID, state: String, db: Database) throws {
        // Tombstones prevent a late autosave from resurrecting a closed draft.
        try db.execute(sql: "INSERT INTO drafts VALUES (?, ?, ?, NULL) ON CONFLICT(id) DO UPDATE SET state=excluded.state,value=NULL", arguments: [id.uuidString,Date().timeIntervalSince1970,state])
        try db.execute(sql: "DELETE FROM draft_attachments WHERE draft_id=?", arguments: [id.uuidString])
    }
}
