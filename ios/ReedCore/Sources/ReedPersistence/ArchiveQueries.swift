import Foundation
import GRDB
import ReedDomain
import ReedApplication

private struct ArchiveCursor: Codable {
    let query: ArchiveQuery
    let revision: Int64
    let id: String
    let number: Double?
    let text: String?
}

extension LocalLibraryRepository: LibraryRepository {
    public func archive(_ query: ArchiveQuery, after cursor: String? = nil) async throws -> ArchivePage {
        try query.validate()
        let previous: ArchiveCursor?
        if let cursor {
            guard cursor.count < 32_768, let data = Data(base64Encoded: cursor),
                  let decoded = try? JSONDecoder().decode(ArchiveCursor.self, from: data), decoded.query == query else {
                throw LibraryError.invalidCursor
            }
            previous = decoded
        } else { previous = nil }
        return try await database.writer.read { db in
            let revision = try Int64.fetchOne(db, sql: "SELECT revision FROM library_state WHERE id=1") ?? 0
            if let previous, previous.revision != revision { throw LibraryError.staleCursor }
            var clauses: [String] = []
            var arguments = StatementArguments()
            func add(_ sql: String, _ values: StatementArguments = StatementArguments()) {
                clauses.append(sql); arguments += values
            }
            switch query.visibility {
            case .active: add("c.deleted_at IS NULL AND c.is_hidden=0")
            case .hidden: add("c.deleted_at IS NULL AND c.is_hidden=1")
            case .trash: add("c.deleted_at IS NOT NULL")
            }
            if query.favoritesOnly { add("c.is_favorite=1") }
            if let value = query.authorID {
                add("EXISTS (SELECT 1 FROM source_authors sa WHERE sa.source_id=c.source_id AND sa.author_id=?)", [value.uuidString])
            }
            if let value = query.sourceID { add("c.source_id=?", [value.uuidString]) }
            if let value = query.folderID { add("c.folder_id=?", [value.uuidString]) }
            if let value = query.createdAfter { add("c.created_at>=?", [value.timeIntervalSince1970]) }
            if let value = query.createdBefore { add("c.created_at<?", [value.timeIntervalSince1970]) }
            if !query.tagIDs.isEmpty {
                let placeholders = Array(repeating: "?", count: query.tagIDs.count).joined(separator: ",")
                add("EXISTS (SELECT 1 FROM card_tags ct WHERE ct.card_id=c.id AND ct.tag_id IN (\(placeholders)))", StatementArguments(query.tagIDs.map(\.uuidString)))
            }
            let tokens = TextNormalization.tokens(query.search + " " + query.keywords)
            if !tokens.isEmpty {
                let pattern = tokens.map { "\"\($0)\"*" }.joined(separator: " AND ")
                add("c.id IN (SELECT card_id FROM card_search WHERE card_search MATCH ?)", [pattern])
            }
            let key: String
            let direction: String
            switch query.sort {
            case .newest: key = "c.created_at"; direction = "DESC"
            case .oldest: key = "c.created_at"; direction = "ASC"
            case .alphabetical: key = "c.sort_title"; direction = "ASC"
            case .random:
                // A validated integer seed rotates a persisted random key; no per-page reshuffle.
                key = "((c.shuffle_key + \(query.randomSeed)) % 2147483647)"; direction = "ASC"
            }
            if let previous {
                let comparison = query.sort == .newest ? "<" : ">"
                if query.sort == .alphabetical {
                    guard let text = previous.text else { throw LibraryError.invalidCursor }
                    add("(\(key) \(comparison) ? OR (\(key)=? AND c.id \(comparison) ?))", [text, text, previous.id])
                } else {
                    guard let number = previous.number, number.isFinite else { throw LibraryError.invalidCursor }
                    add("(\(key) \(comparison) ? OR (\(key)=? AND c.id \(comparison) ?))", [number, number, previous.id])
                }
            }
            arguments += [query.pageSize + 1]
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.id, c.title, c.preview, c.source_id, c.created_at, c.is_favorite, \(key) AS cursor_key
                FROM cards c WHERE \(clauses.joined(separator: " AND "))
                ORDER BY cursor_key \(direction), c.id \(direction) LIMIT ?
                """, arguments: arguments)
            let page = Array(rows.prefix(query.pageSize))
            let cards = try page.map { try Self.summary($0, db: db) }
            var nextCursor: String?
            if rows.count > query.pageSize, let last = page.last {
                let next = ArchiveCursor(query: query, revision: revision, id: last["id"],
                    number: query.sort == .alphabetical ? nil : last["cursor_key"],
                    text: query.sort == .alphabetical ? last["cursor_key"] : nil)
                nextCursor = try JSONEncoder().encode(next).base64EncodedString()
            }
            return ArchivePage(cards: cards, nextCursor: nextCursor)
        }
    }
}

extension LocalLibraryRepository {
    static func summary(_ row: Row, db: Database) throws -> CardSummary {
                let id: String = row["id"]
                let title: String = row["title"]
                let preview: String = row["preview"]
                var sourceName: String?
                if let sourceID: String = row["source_id"], let sourceRow = try Row.fetchOne(db, sql: "SELECT * FROM sources WHERE id=?", arguments: [sourceID]) {
                    sourceName = try Self.source(sourceRow, db: db).displayName
                }
                return CardSummary(id: try Self.uuid(id), title: title.isEmpty ? String(preview.prefix(64)) : title,
                    preview: preview, source: sourceName, createdAt: Date(timeIntervalSince1970: row["created_at"]),
                    isFavorite: row["is_favorite"], tags: try Self.tags(id, db: db))
    }
}
