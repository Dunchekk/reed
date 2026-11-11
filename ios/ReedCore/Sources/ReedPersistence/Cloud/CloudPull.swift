import Foundation
import GRDB
import ReedDomain
import ReedApplication

extension LocalCloudRepository {
    public func apply(_ page: CloudPage) async throws {
        try await database.writer.write { db in
            let state = try Self.state(db)
            guard state.participates else { throw CloudError.invalidTransition }
            try state.check(epoch: page.epoch)
            guard page.cursor >= state.cursor, page.records.last?.sequence ?? state.cursor == page.cursor else { throw CloudError.invalidRecord }
            var previous = state.cursor
            for incoming in page.records {
                guard incoming.sequence == previous + 1, incoming.version > 0 else { throw CloudError.invalidRecord }
                previous = incoming.sequence
                let key = incoming.key, existing = try Self.shadow(key, db: db)
                if let existing, existing.version >= incoming.version { continue }
                let remote = CloudRecord(key: key, version: incoming.version, sequence: incoming.sequence, payload: incoming.payload.normalized())
                if let generation = try Int64.fetchOne(db, sql: "SELECT generation FROM cloud_dirty WHERE kind=? AND id=?", arguments: [key.kind.rawValue,key.id]) {
                    let local = try CloudPayload.read(key, db: db)
                    let pending = try Data.fetchOne(db, sql: "SELECT value FROM cloud_outbox WHERE kind=? AND id=?", arguments: [key.kind.rawValue,key.id]).map {
                        try CloudCoding.decoder().decode(CloudPending.self, from: $0)
                    }
                    let confirmsAttempt = pending.map { $0.mutation.payload == remote.payload && $0.mutation.baseVersion + 1 == remote.version } ?? false
                    if local == remote.payload && pending == nil {
                        try db.execute(sql: "DELETE FROM cloud_dirty WHERE kind=? AND id=?", arguments: [key.kind.rawValue,key.id])
                        try db.execute(sql: "DELETE FROM cloud_conflicts WHERE kind=? AND record_id=?", arguments: [key.kind.rawValue,key.id])
                    } else if local != remote.payload && !confirmsAttempt && existing?.payload != remote.payload {
                        try Self.storeConflict(remote: remote, local: local, generation: generation, db: db)
                    }
                }
                try Self.saveShadow(remote, db: db)
                try Self.queueProjection(key, db: db)
            }
            try CloudProjection.run(db)
            try db.execute(sql: "UPDATE cloud_state SET cursor=? WHERE id=1", arguments: [page.cursor])
        }
    }
}
