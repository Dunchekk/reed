import Foundation
import GRDB
import ReedDomain
import ReedApplication

public final class LocalLibraryRepository: Sendable {
    let database: LibraryDatabase
    private let now: @Sendable () -> Date
    private let calendar: @Sendable () -> Calendar
    public init(database: LibraryDatabase, now: @escaping @Sendable () -> Date = { Date() },
                calendar: @escaping @Sendable () -> Calendar = { .current }) {
        self.database = database; self.now = now; self.calendar = calendar
    }

    public func card(id: UUID) async throws -> Card? {
        try await database.writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM cards WHERE id = ?", arguments: [id.uuidString]) else { return nil }
            return try Self.card(row, db: db)
        }
    }

    public func save(_ card: Card) async throws {
        try card.validate()
        let operationDate = now(), operationCalendar = calendar()
        try await database.writer.write { db in
            try Self.save(card, db: db, now: operationDate, calendar: operationCalendar)
        }
    }

    static func save(_ card: Card, db: Database, now operationDate: Date, calendar operationCalendar: Calendar) throws {
        try card.validate()
        let existing = try Row.fetchOne(db, sql: "SELECT version, created_at, is_hidden, deleted_at, allows_returns FROM cards WHERE id = ?", arguments: [card.id.uuidString])
        if let existing {
            guard card.version == existing["version"] else { throw LibraryError.conflict }
        } else if card.version != 0 { throw LibraryError.notFound }
        let createdAt: Double = existing?["created_at"] ?? card.createdAt.timeIntervalSince1970
        if let source = card.source { try Self.save(source, db: db) }
        if let folder = card.folder { try Self.ensureName(kind: .folders, id: folder.id, name: folder.name, db: db) }
        let text = card.text.trimmingCharacters(in: .whitespacesAndNewlines)
        try db.execute(sql: """
            INSERT INTO cards(id, text, title, comment, page, source_id, folder_id, created_at, updated_at,
                is_favorite, is_hidden, deleted_at, allows_returns, version, preview, sort_title, shuffle_key)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET text=excluded.text, title=excluded.title, comment=excluded.comment,
                page=excluded.page, source_id=excluded.source_id, folder_id=excluded.folder_id,
                updated_at=excluded.updated_at, is_favorite=excluded.is_favorite, is_hidden=excluded.is_hidden,
                deleted_at=excluded.deleted_at, allows_returns=excluded.allows_returns, version=excluded.version,
                preview=excluded.preview, sort_title=excluded.sort_title
            """, arguments: [card.id.uuidString, text, card.title, card.comment, card.page,
                card.source?.id.uuidString, card.folder?.id.uuidString, createdAt, card.updatedAt.timeIntervalSince1970,
                card.isFavorite, card.isHidden, card.deletedAt?.timeIntervalSince1970, card.allowsReturns,
                card.version + 1, String(text.prefix(360)), TextNormalization.normalize(card.displayTitle), Self.shuffleKey(card.id)])
        try db.execute(sql: "DELETE FROM card_attachments WHERE card_id=?", arguments: [card.id.uuidString])
        for (position, id) in card.attachmentIDs.enumerated() {
            try db.execute(sql: "INSERT INTO card_attachments VALUES (?,?,?)", arguments: [card.id.uuidString, id.uuidString, position])
        }
        try db.execute(sql: "DELETE FROM card_tags WHERE card_id = ?", arguments: [card.id.uuidString])
        for tag in card.tags {
            try Self.ensureName(kind: .tags, id: tag.id, name: tag.name, db: db)
            try db.execute(sql: "INSERT INTO card_tags(card_id, tag_id) VALUES (?, ?)", arguments: [card.id.uuidString, tag.id.uuidString])
        }
        try Self.reindex(card.id.uuidString, db: db)
        if let existing {
            let wasEligible = !(existing["is_hidden"] as Bool) && (existing["deleted_at"] as Double?) == nil && (existing["allows_returns"] as Bool)
            if !wasEligible && !card.isHidden && card.deletedAt == nil && card.allowsReturns {
                try LocalReturnRepository.validateCurrentSchedules(db, now: operationDate, calendar: operationCalendar)
            }
        }
        try Self.bumpRevision(db)
    }

    public func attachmentIDs() async throws -> Set<UUID> {
        try await database.writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT attachment_id FROM card_attachments UNION SELECT attachment_id FROM draft_attachments").map(Self.uuid))
        }
    }

    public func catalog() async throws -> LibraryCatalog {
        try await database.writer.read(Self.catalog)
    }
    static func catalog(_ db: Database) throws -> LibraryCatalog {
        let sources = try Row.fetchAll(db, sql: "SELECT * FROM sources ORDER BY title,id").map { try Self.source($0, db: db) }
        let authors = try Row.fetchAll(db, sql: "SELECT * FROM authors ORDER BY name,id").map { Author(id: try Self.uuid($0["id"]), name: $0["name"]) }
        let tags = try Row.fetchAll(db, sql: "SELECT * FROM tags ORDER BY name,id").map { Tag(id: try Self.uuid($0["id"]), name: $0["name"]) }
        let folders = try Row.fetchAll(db, sql: "SELECT * FROM folders ORDER BY name,id").map { Folder(id: try Self.uuid($0["id"]), name: $0["name"]) }
        return LibraryCatalog(sources: sources, authors: authors, tags: tags, folders: folders)
    }

    public func purgeTrash(before date: Date) async throws -> [UUID] {
        try await database.writer.write { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM cards WHERE deleted_at IS NOT NULL AND deleted_at <= ?", arguments: [date.timeIntervalSince1970])
            for id in ids {
                try db.execute(sql: "DELETE FROM card_search WHERE rowid=(SELECT search_id FROM card_search_keys WHERE card_id=?)", arguments: [id])
                try db.execute(sql: "DELETE FROM cards WHERE id = ?", arguments: [id])
            }
            if !ids.isEmpty { try Self.bumpRevision(db) }
            return try ids.map(Self.uuid)
        }
    }

    static func uuid(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else { throw DatabaseError(message: "Invalid stored identifier") }
        return id
    }

    static func tags(_ id: String, db: Database) throws -> [Tag] {
        try Row.fetchAll(db, sql: "SELECT t.* FROM tags t JOIN card_tags ct ON ct.tag_id=t.id WHERE ct.card_id=? ORDER BY t.name, t.id", arguments: [id])
            .map { Tag(id: try uuid($0["id"]), name: $0["name"]) }
    }

    static func source(_ row: Row, db: Database) throws -> Source {
        let id: String = row["id"]
        let authors = try Row.fetchAll(db, sql: "SELECT a.* FROM authors a JOIN source_authors sa ON sa.author_id=a.id WHERE sa.source_id=? ORDER BY sa.position", arguments: [id])
            .map { Author(id: try uuid($0["id"]), name: $0["name"]) }
        return Source(id: try uuid(id), title: row["title"], authors: authors, url: row["url"])
    }

    static func card(_ row: Row, db: Database) throws -> Card {
        let id: String = row["id"]
        var source: Source?
        if let sourceID: String = row["source_id"], let sourceRow = try Row.fetchOne(db, sql: "SELECT * FROM sources WHERE id=?", arguments: [sourceID]) {
            source = try Self.source(sourceRow, db: db)
        }
        var folder: Folder?
        if let folderID: String = row["folder_id"], let folderRow = try Row.fetchOne(db, sql: "SELECT * FROM folders WHERE id=?", arguments: [folderID]) {
            folder = Folder(id: try uuid(folderID), name: folderRow["name"])
        }
        let deletedAt: Double? = row["deleted_at"]
        return Card(id: try uuid(id), text: row["text"], title: row["title"], comment: row["comment"], source: source,
            page: row["page"], tags: try tags(id, db: db), folder: folder,
            createdAt: Date(timeIntervalSince1970: row["created_at"]), updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
            isFavorite: row["is_favorite"], isHidden: row["is_hidden"], deletedAt: deletedAt.map(Date.init(timeIntervalSince1970:)),
            allowsReturns: row["allows_returns"], version: row["version"],
            attachmentIDs: try String.fetchAll(db, sql: "SELECT attachment_id FROM card_attachments WHERE card_id=? ORDER BY position", arguments: [id]).map(Self.uuid))
    }

    static func save(_ source: Source, db: Database) throws {
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM sources WHERE id=?", arguments: [source.id.uuidString]) {
            guard try Self.source(row, db: db) == source else { throw LibraryError.conflict }
            return
        }
        try ensureNotDeleted(kind: .sources, id: source.id, db: db)
        try db.execute(sql: "INSERT INTO sources(id,title,url) VALUES (?,?,?)", arguments: [source.id.uuidString,source.title,source.url])
        for (position, author) in source.authors.enumerated() {
            try ensureName(kind: .authors, id: author.id, name: author.name, db: db)
            try db.execute(sql: "INSERT INTO source_authors VALUES (?,?,?)", arguments: [source.id.uuidString,author.id.uuidString,position])
        }
    }
    static func ensureName(kind: CatalogKind, id: UUID, name: String, db: Database) throws {
        // Identifiers come only from the closed enum, never from user input.
        if let current = try String.fetchOne(db, sql: "SELECT name FROM \(kind.rawValue) WHERE id=?", arguments: [id.uuidString]) {
            guard current == name else { throw LibraryError.conflict }
        } else {
            try ensureNotDeleted(kind: kind, id: id, db: db)
            try db.execute(sql: "INSERT INTO \(kind.rawValue)(id,name) VALUES (?,?)", arguments: [id.uuidString,name])
        }
    }
    private static func ensureNotDeleted(kind: CatalogKind, id: UUID, db: Database) throws {
        guard try !Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM catalog_tombstones WHERE kind=? AND id=?)", arguments: [kind.rawValue,id.uuidString])! else { throw LibraryError.conflict }
    }

    static func bumpRevision(_ db: Database) throws { try db.execute(sql: "UPDATE library_state SET revision=revision+1 WHERE id=1") }

    static func reindex(_ id: String, db: Database) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM cards WHERE id=?", arguments: [id]) else { return }
        let card = try card(row, db: db)
        let document = TextNormalization.normalize([card.text, card.title, card.comment, card.source?.displayName ?? ""].joined(separator: " "))
        let searchID: Int64
        if let existing = try Int64.fetchOne(db, sql: "SELECT search_id FROM card_search_keys WHERE card_id=?", arguments: [id]) { searchID = existing }
        else {
            try db.execute(sql: "INSERT INTO card_search_keys(card_id) VALUES (?)", arguments: [id])
            searchID = db.lastInsertedRowID
        }
        try db.execute(sql: "DELETE FROM card_search WHERE rowid=?", arguments: [searchID])
        try db.execute(sql: "INSERT INTO card_search(rowid, card_id, document) VALUES (?, ?, ?)", arguments: [searchID, id, document])
    }

    private static func shuffleKey(_ id: UUID) -> Int64 {
        let hash = id.uuidString.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return Int64(hash % 2_147_483_647)
    }
}
