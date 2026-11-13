import Foundation
import GRDB
import ReedDomain
import ReedApplication

/// Keeps startup GC independent of large JSON records and unacknowledged user edits.
enum CloudMediaReferences {
    static func backfill(_ db: Database) throws {
        for data in try Data.fetchAll(db, sql: "SELECT value FROM cloud_shadow WHERE kind='card'") {
            let record = try CloudCoding.decoder().decode(CloudRecord.self, from: data)
            try set(owner: "shadow", key: record.key, payload: record.payload, db: db)
        }
        for data in try Data.fetchAll(db, sql: "SELECT value FROM cloud_outbox WHERE kind='card'") {
            let pending = try CloudCoding.decoder().decode(CloudPending.self, from: data)
            try set(owner: "outbox", key: pending.mutation.key, payload: pending.mutation.payload, db: db)
        }
        for data in try Data.fetchAll(db, sql: "SELECT value FROM cloud_conflicts WHERE kind='card'") {
            let conflict = try CloudCoding.decoder().decode(CloudConflict.self, from: data)
            try set(owner: "conflict", key: conflict.remote.key, payload: conflict.local, db: db)
        }
    }
    static func clear(owner: String, key: CloudKey, db: Database) throws {
        guard key.kind == .card else { return }
        try db.execute(sql: "DELETE FROM cloud_media_references WHERE owner=? AND record_id=?", arguments: [owner,key.id])
    }
    static func set(owner: String, key: CloudKey, payload: CloudValue, db: Database) throws {
        guard key.kind == .card else { return }
        try clear(owner: owner, key: key, db: db)
        guard payload != .null else { return }
        for id in try payload.decode(CloudCard.self).attachmentIDs {
            try db.execute(sql: "INSERT OR IGNORE INTO cloud_media_references VALUES (?,?,?)", arguments: [owner,key.id,id.uuidString.lowercased()])
        }
    }
}
