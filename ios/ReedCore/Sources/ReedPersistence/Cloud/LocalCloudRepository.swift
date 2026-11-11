import Foundation
import GRDB
import ReedDomain
import ReedApplication

public final class LocalCloudRepository: CloudRepository {
    let database: LibraryDatabase
    public init(database: LibraryDatabase) { self.database = database }

    public func state() async throws -> CloudState { try await database.writer.read(Self.state) }
    static func state(_ db: Database) throws -> CloudState {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM cloud_state WHERE id=1"),
              let mode = CloudMode(rawValue: row["mode"]) else { throw CloudError.invalidRecord }
        var value = CloudState(); value.mode = mode
        let epoch: String? = row["epoch"], lastSync: Double? = row["last_sync"]
        value.epoch = try epoch.map(LocalLibraryRepository.uuid); value.cursor = row["cursor"]
        value.automatic = row["automatic"]; value.wifiOnly = row["wifi_only"]
        value.lastSyncAt = lastSync.map(Date.init(timeIntervalSince1970:))
        return value
    }
    public func configure(automatic: Bool, wifiOnly: Bool) async throws {
        try await database.writer.write { try $0.execute(sql: "UPDATE cloud_state SET automatic=?,wifi_only=? WHERE id=1", arguments: [automatic,wifiOnly]) }
    }
    public func begin(epoch: UUID) async throws {
        try await database.writer.write { db in
            var current = try Self.state(db); try current.begin(epoch: epoch)
            try Self.clearReplication(db)
            try db.execute(sql: "UPDATE cloud_state SET mode='enabling',epoch=?,cursor=0,last_sync=NULL WHERE id=1", arguments: [epoch.uuidString])
            try CloudPayload.seed(db)
        }
    }
    public func setMode(_ mode: CloudMode) async throws {
        try await database.writer.write { db in
            let current = try Self.state(db)
            guard current.participates && (mode == .cloud || mode == .disabling || mode == .revoked) else { throw CloudError.invalidTransition }
            try db.execute(sql: "UPDATE cloud_state SET mode=? WHERE id=1", arguments: [mode.rawValue])
        }
    }
    public func summary() async throws -> CloudLocalSummary {
        try await database.writer.read { db in
            try CloudLocalSummary(cards: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards") ?? 0,
                pending: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloud_dirty") ?? 0,
                conflicts: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloud_conflicts") ?? 0)
        }
    }
    public func nextPending() async throws -> CloudPending? {
        try await database.writer.write { db in
            guard try Self.state(db).participates else { return nil }
            if let data = try Data.fetchOne(db, sql: "SELECT value FROM cloud_outbox ORDER BY kind,id LIMIT 1") {
                return try CloudCoding.decoder().decode(CloudPending.self, from: data)
            }
            try CloudPayload.harvestHistory(db)
            while let row = try Row.fetchOne(db, sql: """
                SELECT d.* FROM cloud_dirty d WHERE NOT EXISTS(SELECT 1 FROM cloud_conflicts c WHERE c.kind=d.kind AND c.record_id=d.id)
                ORDER BY CASE kind WHEN 'author' THEN 0 WHEN 'tag' THEN 1 WHEN 'folder' THEN 2 WHEN 'source' THEN 3
                    WHEN 'historyPreference' THEN 4 WHEN 'returnSettings' THEN 5 WHEN 'card' THEN 6 ELSE 7 END,generation LIMIT 1
                """) {
                let key = try Self.key(row), generation: Int64 = row["generation"]
                let payload = try CloudPayload.read(key, db: db), shadow = try Self.shadow(key, db: db)
                if shadow?.payload == payload {
                    try db.execute(sql: "DELETE FROM cloud_dirty WHERE kind=? AND id=?", arguments: [key.kind.rawValue,key.id]); continue
                }
                if let shadow, shadow.isDeleted, payload != .null {
                    try Self.storeConflict(remote: shadow, local: payload, generation: generation, db: db); continue
                }
                let pending = CloudPending(mutation: CloudMutation(key: key, baseVersion: shadow?.version ?? 0, payload: payload), generation: generation)
                try db.execute(sql: "INSERT INTO cloud_outbox VALUES (?,?,?)", arguments: [key.kind.rawValue,key.id,try CloudCoding.encoder().encode(pending)])
                return pending
            }
            return nil
        }
    }
    public func acknowledge(_ pending: CloudPending, result: CloudMutationResult) async throws {
        try await database.writer.write { db in
            let key = pending.mutation.key
            guard result.record.key == key,
                  let data = try Data.fetchOne(db, sql: "SELECT value FROM cloud_outbox WHERE kind=? AND id=?", arguments: [key.kind.rawValue,key.id]),
                  try CloudCoding.decoder().decode(CloudPending.self, from: data) == pending else { throw CloudError.invalidRecord }
            try Self.saveShadow(result.record, db: db)
            try db.execute(sql: "DELETE FROM cloud_outbox WHERE kind=? AND id=?", arguments: [key.kind.rawValue,key.id])
            let local = try CloudPayload.read(key, db: db), remote = try Self.shadow(key, db: db) ?? result.record
            if result.outcome == .applied {
                try db.execute(sql: "DELETE FROM cloud_dirty WHERE kind=? AND id=? AND generation=?", arguments: [key.kind.rawValue,key.id,pending.generation])
            } else if local == remote.payload {
                try db.execute(sql: "DELETE FROM cloud_dirty WHERE kind=? AND id=?", arguments: [key.kind.rawValue,key.id])
            } else {
                let generation = try Int64.fetchOne(db, sql: "SELECT generation FROM cloud_dirty WHERE kind=? AND id=?", arguments: [key.kind.rawValue,key.id]) ?? pending.generation
                try Self.storeConflict(remote: remote, local: local, generation: generation, db: db)
            }
            // Server policy can transform an opening into a tombstone. Apply that projection on the next pull.
            if local != remote.payload { try Self.queueProjection(key, db: db) }
        }
    }
    public func mediaToDownload() async throws -> [UUID] {
        try await database.writer.read { try String.fetchAll($0, sql: "SELECT id FROM cloud_media_needed ORDER BY id").map(LocalLibraryRepository.uuid) }
    }
    public func markMediaAvailable(id: UUID) async throws {
        try await database.writer.write { try $0.execute(sql: "DELETE FROM cloud_media_needed WHERE id=?", arguments: [id.uuidString.lowercased()]) }
    }
    public func completed(at date: Date) async throws {
        try await database.writer.write { try $0.execute(sql: "UPDATE cloud_state SET last_sync=? WHERE id=1", arguments: [date.timeIntervalSince1970]) }
    }
    public func disconnect() async throws {
        try await database.writer.write { db in
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloud_dirty") == 0,
                  try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloud_conflicts") == 0,
                  try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloud_outbox") == 0,
                  try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloud_media_needed") == 0 else { throw CloudError.pendingChanges }
            try Self.clearReplication(db)
            try db.execute(sql: "UPDATE cloud_state SET mode='local',epoch=NULL,cursor=0,last_sync=NULL WHERE id=1")
        }
    }
    static func clearReplication(_ db: Database) throws {
        for table in ["cloud_shadow","cloud_dirty","cloud_outbox","cloud_conflicts","cloud_projection","cloud_media_needed","cloud_return_exports"] {
            try db.execute(sql: "DELETE FROM \(table)")
        }
    }
    static func key(_ row: Row) throws -> CloudKey {
        guard let kind = CloudRecordKind(rawValue: row["kind"]) else { throw CloudError.invalidRecord }
        return CloudKey(kind,row["id"] as String)
    }
    static func shadow(_ key: CloudKey, db: Database) throws -> CloudRecord? {
        try Data.fetchOne(db, sql: "SELECT value FROM cloud_shadow WHERE kind=? AND id=?", arguments: [key.kind.rawValue,key.id])
            .map { try CloudCoding.decoder().decode(CloudRecord.self, from: $0) }
    }
    static func saveShadow(_ record: CloudRecord, db: Database) throws {
        guard record.version >= 0, record.sequence >= 0 else { throw CloudError.invalidRecord }
        let canonical = CloudRecord(key: record.key, version: record.version, sequence: record.sequence, payload: record.payload.normalized())
        try db.execute(sql: """
            INSERT INTO cloud_shadow VALUES (?,?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET version=excluded.version,
                sequence=excluded.sequence,value=excluded.value WHERE excluded.version>=cloud_shadow.version
            """, arguments: [canonical.kind.rawValue,canonical.id,canonical.version,canonical.sequence,try CloudCoding.encoder().encode(canonical)])
    }
    static func queueProjection(_ key: CloudKey, db: Database) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO cloud_projection VALUES (?,?)", arguments: [key.kind.rawValue,key.id])
    }
    static func storeConflict(remote: CloudRecord, local: CloudValue, generation: Int64, db: Database) throws {
        let conflict = CloudConflict(remote: remote, local: local, generation: generation)
        try db.execute(sql: "INSERT INTO cloud_conflicts VALUES (?,?,?,?) ON CONFLICT(kind,record_id) DO UPDATE SET id=excluded.id,value=excluded.value",
            arguments: [remote.kind.rawValue,remote.id,conflict.id.uuidString,try CloudCoding.encoder().encode(conflict)])
    }
}
