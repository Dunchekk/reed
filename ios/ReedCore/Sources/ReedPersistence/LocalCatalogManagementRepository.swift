import Foundation
import GRDB
import ReedDomain
import ReedApplication

public struct LocalCatalogManagementRepository: CatalogManagementRepository {
    private let database: LibraryDatabase
    public init(database: LibraryDatabase) { self.database = database }
    public func entries(kind: CatalogKind) async throws -> CatalogSnapshot {
        try await database.writer.read { db in
            let name = kind == .sources ? "title" : "name"
            let relation: String
            switch kind {
            case .sources: relation = "SELECT COUNT(*) FROM cards c WHERE c.source_id=e.id"
            case .folders: relation = "SELECT COUNT(*) FROM cards c WHERE c.folder_id=e.id"
            case .tags: relation = "SELECT COUNT(*) FROM card_tags ct WHERE ct.tag_id=e.id"
            case .authors: relation = "SELECT COUNT(DISTINCT c.id) FROM cards c JOIN source_authors sa ON sa.source_id=c.source_id WHERE sa.author_id=e.id"
            }
            let entries = try Row.fetchAll(db, sql: "SELECT e.id,e.\(name) AS name,(\(relation)) AS count FROM \(kind.rawValue) e ORDER BY e.\(name),e.id").map {
                CatalogEntry(id: try LocalLibraryRepository.uuid($0["id"]), name: $0["name"], cardCount: $0["count"])
            }
            return CatalogSnapshot(entries: entries, revision: try Int64.fetchOne(db, sql: "SELECT revision FROM library_state WHERE id=1") ?? 0)
        }
    }
    public func update(kind: CatalogKind, mutation: CatalogMutation, expectedRevision: Int64) async throws {
        try await database.writer.write { db in
            guard try Int64.fetchOne(db, sql: "SELECT revision FROM library_state WHERE id=1") == expectedRevision else { throw LibraryError.conflict }
            let column = kind == .sources ? "title" : "name", id = mutation.id.uuidString
            guard let oldName = try String.fetchOne(db, sql: "SELECT \(column) FROM \(kind.rawValue) WHERE id=?", arguments: [id]) else { throw LibraryError.notFound }
            let affected = try Self.affectedCards(kind: kind, id: id, db: db)
            let versions = try Dictionary(uniqueKeysWithValues: affected.map { id in
                (id, try Int.fetchOne(db, sql: "SELECT version FROM cards WHERE id=?", arguments: [id]) ?? 0)
            })
            var target: UUID?, resultingName: String?
            switch mutation {
            case let .rename(_, rawName):
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.count <= 300 else { throw CatalogError.invalidName }
                let others = try String.fetchAll(db, sql: "SELECT \(column) FROM \(kind.rawValue) WHERE id!=?", arguments: [id])
                guard !others.contains(where: { TextNormalization.normalize($0) == TextNormalization.normalize(name) }) else { throw CatalogError.duplicateName }
                try db.execute(sql: "UPDATE \(kind.rawValue) SET \(column)=? WHERE id=?", arguments: [name,id])
                target = mutation.id; resultingName = name
            case let .merge(_, destination):
                guard destination != mutation.id else { throw CatalogError.sameTarget }
                guard let name = try String.fetchOne(db, sql: "SELECT \(column) FROM \(kind.rawValue) WHERE id=?", arguments: [destination.uuidString]) else { throw LibraryError.notFound }
                target = destination; resultingName = name
                try Self.removeOrMerge(kind: kind, id: id, target: destination.uuidString, db: db)
            case .remove:
                try Self.removeOrMerge(kind: kind, id: id, target: nil, db: db)
            }
            for card in affected {
                try db.execute(sql: "UPDATE cards SET version=version+1,updated_at=? WHERE id=?", arguments: [Date().timeIntervalSince1970,card])
                try LocalLibraryRepository.reindex(card, db: db)
            }
            try Self.updateRules(kind: kind, id: mutation.id, target: target, db: db)
            try Self.updateDrafts(kind: kind, id: mutation.id, oldName: oldName, target: target, newName: resultingName, versions: versions, db: db)
            try LocalLibraryRepository.bumpRevision(db)
        }
    }
    private static func affectedCards(kind: CatalogKind, id: String, db: Database) throws -> [String] {
        let sql: String
        switch kind {
        case .sources: sql = "SELECT id FROM cards WHERE source_id=?"
        case .folders: sql = "SELECT id FROM cards WHERE folder_id=?"
        case .tags: sql = "SELECT card_id FROM card_tags WHERE tag_id=?"
        case .authors: sql = "SELECT DISTINCT c.id FROM cards c JOIN source_authors sa ON sa.source_id=c.source_id WHERE sa.author_id=?"
        }
        return try String.fetchAll(db, sql: sql, arguments: [id])
    }
    private static func removeOrMerge(kind: CatalogKind, id: String, target: String?, db: Database) throws {
        switch kind {
        case .sources:
            try db.execute(sql: "UPDATE cards SET source_id=? WHERE source_id=?", arguments: [target,id])
        case .folders:
            try db.execute(sql: "UPDATE cards SET folder_id=? WHERE folder_id=?", arguments: [target,id])
        case .tags:
            if let target { try db.execute(sql: "INSERT OR IGNORE INTO card_tags SELECT card_id,? FROM card_tags WHERE tag_id=?", arguments: [target,id]) }
            try db.execute(sql: "DELETE FROM card_tags WHERE tag_id=?", arguments: [id])
        case .authors:
            if let target { try db.execute(sql: "INSERT OR IGNORE INTO source_authors SELECT source_id,?,position FROM source_authors WHERE author_id=?", arguments: [target,id]) }
            try db.execute(sql: "DELETE FROM source_authors WHERE author_id=?", arguments: [id])
        }
        try db.execute(sql: "DELETE FROM \(kind.rawValue) WHERE id=?", arguments: [id])
        try db.execute(sql: "INSERT INTO catalog_tombstones VALUES (?,?)", arguments: [kind.rawValue,id])
    }
    private static func updateRules(kind: CatalogKind, id: UUID, target: UUID?, db: Database) throws {
        var settings = try LocalReturnRepository.settings(db)
        let before = settings
        var removedReference = false
        func replace(_ values: inout Set<UUID>) {
            guard values.remove(id) != nil else { return }
            if let target { values.insert(target) } else { removedReference = true }
        }
        func update(_ filter: inout ReturnFilter) {
            switch kind {
            case .tags: replace(&filter.tags)
            case .authors: replace(&filter.authors)
            case .folders: replace(&filter.folders)
            case .sources: break
            }
        }
        update(&settings.globalInclude); update(&settings.globalExclude)
        update(&settings.channelInclude); update(&settings.channelExclude)
        if kind == .folders && settings.boostFolderID == id {
            settings.boostFolderID = target
            if target == nil { settings.boostEnabled = false }
        }
        if removedReference { settings.enabled = false }
        if settings != before {
            try db.execute(sql: "INSERT INTO preferences VALUES ('returns',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [try JSONEncoder().encode(settings)])
        }
    }
    private static func updateDrafts(kind: CatalogKind, id: UUID, oldName: String, target: UUID?, newName: String?, versions: [String:Int], db: Database) throws {
        for data in try Data.fetchAll(db, sql: "SELECT value FROM drafts WHERE state='active'") {
            var draft = try JSONDecoder().decode(CardDraft.self, from: data)
            if kind == .sources && draft.sourceID == id { draft.sourceID = target }
            if kind == .folders && draft.folderID == id { draft.folderID = target }
            if kind == .tags {
                var seen = Set<String>()
                draft.tagNames = draft.tagNames.split(separator: ",").compactMap { part -> String? in
                    let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    let next = TextNormalization.normalize(name) == TextNormalization.normalize(oldName) ? newName : name
                    guard let next, seen.insert(TextNormalization.normalize(next)).inserted else { return nil }; return next
                }.joined(separator: ", ")
            }
            // Only rebase metadata-only changes; a draft already stale before this command stays stale.
            if versions[draft.card.id.uuidString] == draft.card.version {
                draft.card = draft.card.replacingVersion(draft.card.version + 1)
            }
            try db.execute(sql: "UPDATE drafts SET value=? WHERE id=?", arguments: [try JSONEncoder().encode(draft),draft.id.uuidString])
        }
    }
}
