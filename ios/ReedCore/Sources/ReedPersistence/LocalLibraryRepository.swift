import Foundation
import GRDB
import ReedDomain
import ReedApplication

public final class LocalLibraryRepository: Sendable {
    let database: LibraryDatabase
    public init(database: LibraryDatabase) { self.database = database }

    public func card(id: UUID) async throws -> Card? {
        try await database.writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM cards WHERE id = ?", arguments: [id.uuidString]) else { return nil }
            return try Self.card(row, db: db)
        }
    }

    public func save(_ card: Card) async throws {
        try card.validate()
        try await database.writer.write { db in
            let existing = try Row.fetchOne(db, sql: "SELECT version, created_at FROM cards WHERE id = ?", arguments: [card.id.uuidString])
            if let existing {
                guard card.version == existing["version"] else { throw LibraryError.conflict }
            } else if card.version != 0 { throw LibraryError.notFound }
            let createdAt: Double = existing?["created_at"] ?? card.createdAt.timeIntervalSince1970
            var sourceChanged = false
            var changedAuthors: [UUID] = []
            if let source = card.source {
                let previous = try Row.fetchOne(db, sql: "SELECT * FROM sources WHERE id=?", arguments: [source.id.uuidString]).map { try Self.source($0, db: db) }
                sourceChanged = previous != source
                for author in source.authors {
                    let name = try String.fetchOne(db, sql: "SELECT name FROM authors WHERE id=?", arguments: [author.id.uuidString])
                    if let name, name != author.name { changedAuthors.append(author.id) }
                }
                if sourceChanged { try Self.save(source, db: db) }
            }
            if let folder = card.folder {
                try db.execute(sql: "INSERT INTO folders(id, name) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name", arguments: [folder.id.uuidString, folder.name])
            }
            let text = card.text.trimmingCharacters(in: .whitespacesAndNewlines)
            try db.execute(sql: """
                INSERT INTO cards(id, text, title, comment, page, source_id, folder_id, created_at, updated_at,
                    is_favorite, is_hidden, deleted_at, allows_returns, version, preview, sort_title, shuffle_key, attachment_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET text=excluded.text, title=excluded.title, comment=excluded.comment,
                    page=excluded.page, source_id=excluded.source_id, folder_id=excluded.folder_id,
                    updated_at=excluded.updated_at, is_favorite=excluded.is_favorite, is_hidden=excluded.is_hidden,
                    deleted_at=excluded.deleted_at, allows_returns=excluded.allows_returns, version=excluded.version,
                    preview=excluded.preview, sort_title=excluded.sort_title, attachment_id=excluded.attachment_id
                """, arguments: [card.id.uuidString, text, card.title, card.comment, card.page,
                    card.source?.id.uuidString, card.folder?.id.uuidString, createdAt, card.updatedAt.timeIntervalSince1970,
                    card.isFavorite, card.isHidden, card.deletedAt?.timeIntervalSince1970, card.allowsReturns,
                    card.version + 1, String(text.prefix(360)), TextNormalization.normalize(card.displayTitle), Self.shuffleKey(card.id), card.attachmentID?.uuidString])
            try db.execute(sql: "DELETE FROM card_tags WHERE card_id = ?", arguments: [card.id.uuidString])
            for tag in card.tags {
                try db.execute(sql: "INSERT INTO tags(id, name) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET name=excluded.name", arguments: [tag.id.uuidString, tag.name])
                try db.execute(sql: "INSERT INTO card_tags(card_id, tag_id) VALUES (?, ?)", arguments: [card.id.uuidString, tag.id.uuidString])
            }
            // Shared source/author edits must update every affected search document.
            var affected = Set([card.id.uuidString])
            if sourceChanged, let source = card.source {
                affected.formUnion(try String.fetchAll(db, sql: "SELECT id FROM cards WHERE source_id = ?", arguments: [source.id.uuidString]))
                for authorID in changedAuthors {
                    affected.formUnion(try String.fetchAll(db, sql: "SELECT c.id FROM cards c JOIN source_authors sa ON sa.source_id=c.source_id WHERE sa.author_id=?", arguments: [authorID.uuidString]))
                }
            }
            for id in affected { try Self.reindex(id, db: db) }
            try Self.bumpRevision(db)
        }
    }

    public func attachmentIDs() async throws -> Set<UUID> {
        try await database.writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT attachment_id FROM cards WHERE attachment_id IS NOT NULL").map(Self.uuid))
        }
    }

    public func catalog() async throws -> LibraryCatalog {
        try await database.writer.read { db in
            let sources = try Row.fetchAll(db, sql: "SELECT * FROM sources ORDER BY title, id").map { try Self.source($0, db: db) }
            let authors = try Row.fetchAll(db, sql: "SELECT * FROM authors ORDER BY name, id").map { Author(id: try Self.uuid($0["id"]), name: $0["name"]) }
            let tags = try Row.fetchAll(db, sql: "SELECT * FROM tags ORDER BY name, id").map { Tag(id: try Self.uuid($0["id"]), name: $0["name"]) }
            let folders = try Row.fetchAll(db, sql: "SELECT * FROM folders ORDER BY name, id").map { Folder(id: try Self.uuid($0["id"]), name: $0["name"]) }
            return LibraryCatalog(sources: sources, authors: authors, tags: tags, folders: folders)
        }
    }

    public func purgeTrash(before date: Date) async throws -> [UUID] {
        try await database.writer.write { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM cards WHERE deleted_at IS NOT NULL AND deleted_at <= ?", arguments: [date.timeIntervalSince1970])
            for id in ids {
                try db.execute(sql: "DELETE FROM card_search WHERE card_id = ?", arguments: [id])
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
            allowsReturns: row["allows_returns"], version: row["version"], attachmentID: try (row["attachment_id"] as String?).map(Self.uuid))
    }

    private static func save(_ source: Source, db: Database) throws {
        try db.execute(sql: "INSERT INTO sources(id, title, url) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET title=excluded.title, url=excluded.url", arguments: [source.id.uuidString, source.title, source.url])
        try db.execute(sql: "DELETE FROM source_authors WHERE source_id=?", arguments: [source.id.uuidString])
        for (index, author) in source.authors.enumerated() {
            try db.execute(sql: "INSERT INTO authors(id, name) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET name=excluded.name", arguments: [author.id.uuidString, author.name])
            try db.execute(sql: "INSERT INTO source_authors(source_id, author_id, position) VALUES (?, ?, ?)", arguments: [source.id.uuidString, author.id.uuidString, index])
        }
    }

    static func bumpRevision(_ db: Database) throws { try db.execute(sql: "UPDATE library_state SET revision=revision+1 WHERE id=1") }

    private static func reindex(_ id: String, db: Database) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM cards WHERE id=?", arguments: [id]) else { return }
        let card = try card(row, db: db)
        let document = TextNormalization.normalize([card.text, card.title, card.comment, card.source?.displayName ?? ""].joined(separator: " "))
        try db.execute(sql: "DELETE FROM card_search WHERE card_id=?", arguments: [id])
        try db.execute(sql: "INSERT INTO card_search(card_id, document) VALUES (?, ?)", arguments: [id, document])
    }

    private static func shuffleKey(_ id: UUID) -> Int64 {
        let hash = id.uuidString.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return Int64(hash % 2_147_483_647)
    }
}
