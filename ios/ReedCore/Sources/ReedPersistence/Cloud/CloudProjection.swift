import Foundation
import GRDB
import ReedDomain

/// Materializes accepted remote records into the existing library schema.
/// Dependencies spanning pull pages remain queued instead of producing partial cards.
enum CloudProjection {
    static func run(_ db: Database) throws {
        try db.execute(sql: "UPDATE cloud_state SET suppress=1 WHERE id=1")
        var changed = false, progressed = true
        while progressed {
            progressed = false
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.* FROM cloud_projection p
                WHERE NOT EXISTS(SELECT 1 FROM cloud_dirty d WHERE d.kind=p.kind AND d.id=p.id)
                  AND NOT EXISTS(SELECT 1 FROM cloud_outbox o WHERE o.kind=p.kind AND o.id=p.id)
                  AND NOT EXISTS(SELECT 1 FROM cloud_conflicts c WHERE c.kind=p.kind AND c.record_id=p.id)
                ORDER BY CASE kind WHEN 'author' THEN 0 WHEN 'tag' THEN 1 WHEN 'folder' THEN 2 WHEN 'source' THEN 3 WHEN 'card' THEN 4 ELSE 5 END
                """)
            for row in rows {
                let key = try LocalCloudRepository.key(row)
                guard let record = try LocalCloudRepository.shadow(key, db: db), try materialize(record, db: db) else { continue }
                try db.execute(sql: "DELETE FROM cloud_projection WHERE kind=? AND id=?", arguments: [key.kind.rawValue,key.id])
                progressed = true; changed = true
            }
        }
        try db.execute(sql: "UPDATE cloud_state SET suppress=0 WHERE id=1")
        if changed { try LocalLibraryRepository.bumpRevision(db) }
    }

    /// nil means a known tombstone; an unknown dependency suspends this projection.
    private static func reference(_ id: UUID?, kind: CloudRecordKind, table: String, db: Database) throws -> UUID? {
        guard let id else { return nil }
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE id=?)", arguments: [id.uuidString]) == true { return id }
        if try LocalCloudRepository.shadow(CloudKey(kind,id), db: db)?.isDeleted == true { return nil }
        throw PendingDependency.missing
    }
    private enum PendingDependency: Error { case missing }

    private static func materialize(_ record: CloudRecord, db: Database) throws -> Bool {
        do {
            switch record.kind {
            case .author, .source, .tag, .folder: try catalog(record, db: db)
            case .card: try card(record, db: db)
            case .returnSettings:
                let value = record.isDeleted ? ReturnSettings() : try record.payload.decode(ReturnSettings.self)
                try value.validate()
                try db.execute(sql: "INSERT INTO preferences VALUES ('returns',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [try JSONEncoder().encode(value)])
            case .historyPreference:
                let value = record.isDeleted ? CloudHistoryPreference(enabled: false) : try record.payload.decode(CloudHistoryPreference.self)
                try db.execute(sql: "UPDATE activity_preferences SET enabled=? WHERE id=1", arguments: [value.enabled])
            case .cardReturn:
                let id = try LocalLibraryRepository.uuid(record.id)
                if record.isDeleted { try db.execute(sql: "DELETE FROM card_returns WHERE card_id=?", arguments: [id.uuidString]); break }
                let value = try record.payload.decode(CardReturnSettings.self); try value.validate()
                guard value.cardID == id else { throw CloudError.invalidRecord }
                guard try reference(id, kind: .card, table: "cards", db: db) != nil else { break }
                try db.execute(sql: "INSERT INTO card_returns VALUES (?,?) ON CONFLICT(card_id) DO UPDATE SET value=excluded.value", arguments: [id.uuidString,try JSONEncoder().encode(value)])
            case .opening:
                let id = try LocalLibraryRepository.uuid(record.id)
                if record.isDeleted { try db.execute(sql: "DELETE FROM openings WHERE id=?", arguments: [id.uuidString]); break }
                let value = try record.payload.decode(CloudOpening.self)
                guard value.id == id else { throw CloudError.invalidRecord }
                guard value.date >= Date().addingTimeInterval(-90*86400),
                      try reference(value.cardID, kind: .card, table: "cards", db: db) != nil else { break }
                try db.execute(sql: "INSERT INTO openings VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET card_id=excluded.card_id,opened_at=excluded.opened_at,origin=excluded.origin",
                    arguments: [id.uuidString,value.cardID.uuidString,value.date.timeIntervalSince1970,value.origin.rawValue])
            case .returnHistory:
                if record.isDeleted { break }
                let value = try record.payload.decode(CloudReturnHistory.self)
                guard value.slot.date <= Date().addingTimeInterval(60) else { throw CloudError.invalidRecord }
                try db.execute(sql: "INSERT OR IGNORE INTO cloud_return_exports VALUES (?,?)", arguments: [value.slot.id,record.id])
                try db.execute(sql: """
                    INSERT INTO return_slots VALUES (?,?,?,?,?,?,'planned',?,0)
                    ON CONFLICT(id) DO UPDATE SET scheduled_at=excluded.scheduled_at,card_id=excluded.card_id,
                        automatic_ordinal=excluded.automatic_ordinal,slot=excluded.slot,decision=excluded.decision
                    """, arguments: [value.slot.id,value.slot.date.timeIntervalSince1970,value.decision.cardID?.uuidString,
                        value.decision.automaticOrdinal,try JSONEncoder().encode(value.slot),try JSONEncoder().encode(value.decision),UUID().uuidString])
            }
            return true
        } catch PendingDependency.missing { return false }
    }

    static func insertCopy(_ value: CloudCard, db: Database) throws {
        var value = value; value.id = UUID()
        let record = try CloudRecord(key: CloudKey(.card,value.id), version: 0, sequence: 0, payload: .encode(value))
        try card(record, db: db, downloadMedia: false)
    }

    private static func card(_ record: CloudRecord, db: Database, downloadMedia: Bool = true) throws {
        let id = try LocalLibraryRepository.uuid(record.id)
        if record.isDeleted {
            try db.execute(sql: "DELETE FROM card_search WHERE rowid=(SELECT search_id FROM card_search_keys WHERE card_id=?)", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM cards WHERE id=?", arguments: [id.uuidString])
            return
        }
        let value = try record.payload.decode(CloudCard.self); try value.validate()
        guard value.id == id else { throw CloudError.invalidRecord }
        let sourceID = try reference(value.sourceID, kind: .source, table: "sources", db: db)
        let folderID = try reference(value.folderID, kind: .folder, table: "folders", db: db)
        var tags: [Tag] = []
        for tag in value.tagIDs {
            if let id = try reference(tag, kind: .tag, table: "tags", db: db),
               let name = try String.fetchOne(db, sql: "SELECT name FROM tags WHERE id=?", arguments: [id.uuidString]) { tags.append(Tag(id: id, name: name)) }
        }
        let source = try sourceID.flatMap { id in try Row.fetchOne(db, sql: "SELECT * FROM sources WHERE id=?", arguments: [id.uuidString]).map { try LocalLibraryRepository.source($0, db: db) } }
        let folder = try folderID.flatMap { id in try String.fetchOne(db, sql: "SELECT name FROM folders WHERE id=?", arguments: [id.uuidString]).map { Folder(id: id, name: $0) } }
        let version = try Int.fetchOne(db, sql: "SELECT version FROM cards WHERE id=?", arguments: [id.uuidString]) ?? 0
        let card = Card(id: id, text: value.text, title: value.title, comment: value.comment, source: source, page: value.page, tags: tags,
            folder: folder, createdAt: value.createdAt, updatedAt: value.updatedAt, isFavorite: value.isFavorite, isHidden: value.isHidden,
            deletedAt: value.deletedAt, allowsReturns: value.allowsReturns, version: version, attachmentIDs: value.attachmentIDs)
        try LocalLibraryRepository.writeCardRows(card, db: db, createdAt: value.createdAt.timeIntervalSince1970)
        // Existing-card UPSERT keeps creation date for local commands; replication applies the accepted document fully.
        try db.execute(sql: "UPDATE cards SET created_at=? WHERE id=?", arguments: [value.createdAt.timeIntervalSince1970,id.uuidString])
        for id in value.attachmentIDs where downloadMedia {
            try db.execute(sql: "INSERT OR IGNORE INTO cloud_media_needed VALUES (?)", arguments: [id.uuidString.lowercased()])
        }
    }

    private static func catalog(_ record: CloudRecord, db: Database) throws {
        let kind: CatalogKind
        switch record.kind { case .source: kind = .sources; case .author: kind = .authors; case .tag: kind = .tags; default: kind = .folders }
        let id = try LocalLibraryRepository.uuid(record.id), column = kind == .sources ? "title" : "name"
        let oldName = try String.fetchOne(db, sql: "SELECT \(column) FROM \(kind.rawValue) WHERE id=?", arguments: [id.uuidString])
        let affected = try LocalCatalogManagementRepository.affectedCards(kind: kind, id: id.uuidString, db: db)
        let versions = try Dictionary(uniqueKeysWithValues: affected.map { ($0, try Int.fetchOne(db, sql: "SELECT version FROM cards WHERE id=?", arguments: [$0]) ?? 0) })
        let name: String?
        if record.isDeleted {
            name = nil
            if oldName != nil { try LocalCatalogManagementRepository.removeOrMerge(kind: kind, id: id.uuidString, target: nil, db: db) }
            else { try db.execute(sql: "INSERT OR IGNORE INTO catalog_tombstones VALUES (?,?)", arguments: [kind.rawValue,id.uuidString]) }
        } else if kind == .sources {
            let value = try record.payload.decode(CloudSource.self)
            guard value.id == id, !value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudError.invalidRecord }
            let authors = try value.authorIDs.compactMap { try reference($0, kind: .author, table: "authors", db: db) }
            name = value.title
            try db.execute(sql: "INSERT INTO sources VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,url=excluded.url", arguments: [id.uuidString,value.title,value.url])
            try db.execute(sql: "DELETE FROM source_authors WHERE source_id=?", arguments: [id.uuidString])
            for (position, author) in authors.enumerated() { try db.execute(sql: "INSERT INTO source_authors VALUES (?,?,?)", arguments: [id.uuidString,author.uuidString,position]) }
        } else {
            let value = try record.payload.decode(Author.self)
            guard value.id == id, !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudError.invalidRecord }
            name = value.name
            try db.execute(sql: "INSERT INTO \(kind.rawValue) VALUES (?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name", arguments: [id.uuidString,value.name])
        }
        if !record.isDeleted { try db.execute(sql: "DELETE FROM catalog_tombstones WHERE kind=? AND id=?", arguments: [kind.rawValue,id.uuidString]) }
        for card in affected {
            try db.execute(sql: "UPDATE cards SET version=version+1 WHERE id=?", arguments: [card])
            try LocalLibraryRepository.reindex(card, db: db)
        }
        if record.isDeleted { try LocalCatalogManagementRepository.updateRules(kind: kind, id: id, target: nil, db: db) }
        if let oldName {
            try LocalCatalogManagementRepository.updateDrafts(kind: kind, id: id, oldName: oldName, target: record.isDeleted ? nil : id, newName: name, versions: versions, db: db)
        }
    }
}
