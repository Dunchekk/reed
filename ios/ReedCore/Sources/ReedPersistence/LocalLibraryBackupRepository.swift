import Foundation
import GRDB
import ReedDomain
import ReedApplication

public struct LocalLibraryBackupRepository: LibraryBackupRepository {
    private let database: LibraryDatabase
    public init(database: LibraryDatabase) { self.database = database }
    public func summary() async throws -> LibraryStorageSummary {
        try await database.writer.read { db in
            func count(_ sql: String) throws -> Int { try Int.fetchOne(db, sql: sql) ?? 0 }
            return try LibraryStorageSummary(cards: count("SELECT COUNT(*) FROM cards"),
                drafts: count("SELECT COUNT(*) FROM drafts WHERE state='active'"),
                photos: count("SELECT COUNT(*) FROM (SELECT attachment_id FROM card_attachments UNION SELECT attachment_id FROM draft_attachments)"),
                catalogEntries: count("SELECT (SELECT COUNT(*) FROM sources)+(SELECT COUNT(*) FROM authors)+(SELECT COUNT(*) FROM folders)+(SELECT COUNT(*) FROM tags)"))
        }
    }
    public func snapshot() async throws -> LibraryBackup {
        try await database.writer.read { db in
            let now = Date()
            func preference<T: Decodable>(_ key: String, fallback: T) throws -> T {
                guard let data = try Data.fetchOne(db, sql: "SELECT value FROM preferences WHERE key=?", arguments: [key]) else { return fallback }
                return try JSONDecoder().decode(T.self, from: data)
            }
            let cards = try Row.fetchAll(db, sql: "SELECT * FROM cards ORDER BY id").map { try LocalLibraryRepository.card($0, db: db) }
            let drafts = try Data.fetchAll(db, sql: "SELECT value FROM drafts WHERE state='active' ORDER BY id").map { try JSONDecoder().decode(CardDraft.self, from: $0) }
            let rules = try Data.fetchAll(db, sql: "SELECT value FROM card_returns ORDER BY card_id").map { try JSONDecoder().decode(CardReturnSettings.self, from: $0) }
            let openings = try Row.fetchAll(db, sql: "SELECT * FROM openings WHERE opened_at>=? ORDER BY id", arguments: [now.addingTimeInterval(-90*86400).timeIntervalSince1970]).map {
                BackupOpening(id: try LocalLibraryRepository.uuid($0["id"]), cardID: try LocalLibraryRepository.uuid($0["card_id"]), date: Date(timeIntervalSince1970: $0["opened_at"]), origin: OpeningOrigin(rawValue: $0["origin"]) ?? .manual)
            }
            let history = try Row.fetchAll(db, sql: "SELECT slot,decision FROM return_slots WHERE state!='cancelled' AND scheduled_at<=? ORDER BY scheduled_at,id", arguments: [now.timeIntervalSince1970]).map {
                BackupReturn(slot: try JSONDecoder().decode(ReturnTimeSlot.self, from: $0["slot"]), decision: try JSONDecoder().decode(ReturnDecision.self, from: $0["decision"]))
            }
            return try LibraryBackup(createdAt: now, cards: cards, catalog: LocalLibraryRepository.catalog(db), drafts: drafts,
                capture: preference("capture", fallback: CapturePreferences()), returns: LocalReturnRepository.settings(db),
                cardReturns: rules, feed: preference("feed", fallback: Set(FeedKind.allCases)),
                historyEnabled: Bool.fetchOne(db, sql: "SELECT enabled FROM activity_preferences WHERE id=1") ?? true,
                openings: openings, returnHistory: history)
        }
    }
    public func hasImported(id: UUID) async throws -> Bool {
        try await database.writer.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM backup_imports WHERE id=?)", arguments: [id.uuidString]) ?? false }
    }
    public func restore(_ backup: LibraryBackup) async throws -> RestoreResult {
        try backup.validate()
        return try await database.writer.write { db in
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM backup_imports WHERE id=?)", arguments: [backup.id.uuidString]) == true { return .alreadyImported }
            for table in ["cards", "sources", "authors", "tags", "folders"] {
                guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0 else { throw BackupError.nonemptyLibrary }
            }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM drafts WHERE state='active'") == 0 else { throw BackupError.nonemptyLibrary }
            try db.execute(sql: "DELETE FROM catalog_tombstones; DELETE FROM return_slots; DELETE FROM return_days; DELETE FROM preferences;")
            for author in backup.catalog.authors { try LocalLibraryRepository.ensureName(kind: .authors, id: author.id, name: author.name, db: db) }
            for source in backup.catalog.sources { try LocalLibraryRepository.save(source, db: db) }
            for tag in backup.catalog.tags { try LocalLibraryRepository.ensureName(kind: .tags, id: tag.id, name: tag.name, db: db) }
            for folder in backup.catalog.folders { try LocalLibraryRepository.ensureName(kind: .folders, id: folder.id, name: folder.name, db: db) }
            for card in backup.cards {
                try Task.checkCancellation()
                try LocalLibraryRepository.save(card.replacingVersion(0), db: db, now: Date(), calendar: .current)
                try db.execute(sql: "UPDATE cards SET version=? WHERE id=?", arguments: [card.version,card.id.uuidString])
            }
            for original in backup.drafts {
                let occupied = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM drafts WHERE id=?)", arguments: [original.id.uuidString]) ?? false
                let draft = occupied ? original.replacingID(UUID()) : original
                try db.execute(sql: "INSERT INTO drafts VALUES (?,?,'active',?)", arguments: [draft.id.uuidString,draft.updatedAt.timeIntervalSince1970,try JSONEncoder().encode(draft)])
                for id in draft.card.attachmentIDs { try db.execute(sql: "INSERT INTO draft_attachments VALUES (?,?)", arguments: [draft.id.uuidString,id.uuidString]) }
            }
            for rule in backup.cardReturns { try db.execute(sql: "INSERT INTO card_returns VALUES (?,?)", arguments: [rule.cardID.uuidString,try JSONEncoder().encode(rule)]) }
            for (key, data) in [("capture",try JSONEncoder().encode(backup.capture)),("returns",try JSONEncoder().encode(backup.returns)),("feed",try JSONEncoder().encode(backup.feed))] {
                try db.execute(sql: "INSERT INTO preferences VALUES (?,?)", arguments: [key,data])
            }
            try db.execute(sql: "UPDATE activity_preferences SET enabled=? WHERE id=1", arguments: [backup.historyEnabled])
            for event in backup.openings { try db.execute(sql: "INSERT INTO openings VALUES (?,?,?,?)", arguments: [event.id.uuidString,event.cardID.uuidString,event.date.timeIntervalSince1970,event.origin.rawValue]) }
            for event in backup.returnHistory {
                try db.execute(sql: "INSERT INTO return_slots VALUES (?,?,?,?,? ,?,'planned',?,0)", arguments: [event.slot.id,event.slot.date.timeIntervalSince1970,event.decision.cardID?.uuidString,event.decision.automaticOrdinal,try JSONEncoder().encode(event.slot),try JSONEncoder().encode(event.decision),UUID().uuidString])
            }
            try LocalReturnRepository.validateCurrentSchedules(db, now: Date(), calendar: .current)
            try db.execute(sql: "INSERT INTO backup_imports VALUES (?)", arguments: [backup.id.uuidString])
            try LocalLibraryRepository.bumpRevision(db)
            return .restored
        }
    }
    public func clearLibrary() async throws -> Set<UUID> {
        try await database.writer.write { db in
            let photos = Set(try String.fetchAll(db, sql: "SELECT attachment_id FROM card_attachments UNION SELECT attachment_id FROM draft_attachments").map(LocalLibraryRepository.uuid))
            try db.execute(sql: """
                DELETE FROM card_search; DELETE FROM return_slots; DELETE FROM return_days;
                DELETE FROM draft_attachments; UPDATE drafts SET state='discarded',value=NULL;
                DELETE FROM cards; DELETE FROM sources; DELETE FROM authors;
                DELETE FROM tags; DELETE FROM folders; DELETE FROM preferences; DELETE FROM catalog_tombstones;
                DELETE FROM backup_imports; UPDATE activity_preferences SET enabled=1 WHERE id=1;
                """)
            try LocalLibraryRepository.bumpRevision(db)
            return photos
        }
    }
}
