import Foundation
import GRDB
import ReedDomain

extension LocalCloudRepository {
    public func conflicts() async throws -> [CloudConflict] {
        try await database.writer.write { db in
            var result: [CloudConflict] = []
            for data in try Data.fetchAll(db, sql: "SELECT value FROM cloud_conflicts ORDER BY kind,record_id") {
                let stored = try CloudCoding.decoder().decode(CloudConflict.self, from: data), key = stored.remote.key
                let local = try CloudPayload.read(key, db: db), remote = try Self.shadow(key, db: db) ?? stored.remote
                let generation = try Int64.fetchOne(db, sql: "SELECT generation FROM cloud_dirty WHERE kind=? AND id=?", arguments: [key.kind.rawValue,key.id]) ?? stored.generation
                if stored.local != local || stored.remote != remote || stored.generation != generation {
                    try Self.storeConflict(remote: remote, local: local, generation: generation, db: db)
                    let refreshed = try Data.fetchOne(db, sql: "SELECT value FROM cloud_conflicts WHERE kind=? AND record_id=?", arguments: [key.kind.rawValue,key.id])!
                    result.append(try CloudCoding.decoder().decode(CloudConflict.self, from: refreshed))
                } else { result.append(stored) }
            }
            return result
        }
    }

    public func resolve(id: UUID, choice: CloudResolution) async throws {
        try await database.writer.write { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT value FROM cloud_conflicts WHERE id=?", arguments: [id.uuidString]) else { throw CloudError.conflict }
            let conflict = try CloudCoding.decoder().decode(CloudConflict.self, from: data), key = conflict.remote.key
            let generation = try Int64.fetchOne(db, sql: "SELECT generation FROM cloud_dirty WHERE kind=? AND id=?", arguments: [key.kind.rawValue,key.id])
            guard generation == conflict.generation,
                  try CloudPayload.read(key, db: db) == conflict.local,
                  try Self.shadow(key, db: db) == conflict.remote else { throw CloudError.conflict }
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM cloud_outbox WHERE kind=? AND id=?)", arguments: [key.kind.rawValue,key.id]) == false else { throw CloudError.busy }
            if choice == .local && !conflict.canKeepLocal { throw CloudError.invalidTransition }
            if choice == .both {
                guard conflict.canKeepBoth else { throw CloudError.invalidTransition }
                try CloudProjection.insertCopy(conflict.local.decode(CloudCard.self), db: db)
            }
            try db.execute(sql: "DELETE FROM cloud_conflicts WHERE id=?", arguments: [id.uuidString])
            if choice == .local { try CloudPayload.mark(key, db: db) }
            else {
                try db.execute(sql: "DELETE FROM cloud_dirty WHERE kind=? AND id=?", arguments: [key.kind.rawValue,key.id])
                try Self.queueProjection(key, db: db)
            }
            try CloudProjection.run(db)
        }
    }
}
