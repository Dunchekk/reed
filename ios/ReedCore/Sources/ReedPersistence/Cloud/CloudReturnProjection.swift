import Foundation
import GRDB
import ReedDomain
import ReedApplication

extension LocalCloudRepository: CloudReturnProjection {
    public func applyReturnPlan(_ plan: CloudReturnPlan, now: Date) async throws {
        try await database.writer.write { db in
            let state = try Self.state(db)
            guard state.participates else { throw CloudError.invalidTransition }
            try state.check(epoch: plan.epoch)
            // A newer server plan waits for the next replication pass; never replace with an older snapshot.
            guard plan.sequence <= state.cursor else { return }
            if let data = try Data.fetchOne(db, sql: "SELECT value FROM preferences WHERE key='cloud.plan'"),
               let old = try? CloudCoding.decoder().decode(CloudReturnPlan.self, from: data), old.epoch == plan.epoch, old.sequence > plan.sequence { return }
            guard plan.entries.count <= 100, Set(plan.entries.map { $0.slot.id }).count == plan.entries.count,
                  plan.entries.allSatisfy({ $0.slot.date.timeIntervalSince1970.isFinite }) else { throw CloudError.invalidRecord }
            try db.execute(sql: "UPDATE return_slots SET state='cancelled' WHERE scheduled_at>?", arguments: [now.timeIntervalSince1970])
            for entry in plan.entries {
                try db.execute(sql: """
                    INSERT INTO return_slots(id,scheduled_at,card_id,automatic_ordinal,slot,decision,state,revision,library_revision)
                    VALUES(?,?,?,?,?,?,'planned',?,0) ON CONFLICT(id) DO UPDATE SET scheduled_at=excluded.scheduled_at,
                    card_id=excluded.card_id,automatic_ordinal=excluded.automatic_ordinal,slot=excluded.slot,decision=excluded.decision,
                    state='planned',revision=excluded.revision,library_revision=0
                    """, arguments: [entry.slot.id, entry.slot.date.timeIntervalSince1970, entry.decision.cardID?.uuidString,
                        entry.decision.automaticOrdinal, try JSONEncoder().encode(entry.slot), try JSONEncoder().encode(entry.decision), entry.revision.uuidString])
                // Server owns these slots; do not turn them into local return-history mutations later.
                try db.execute(sql: "INSERT OR IGNORE INTO cloud_return_exports VALUES (?,?)", arguments: [entry.slot.id, UUID().uuidString.lowercased()])
            }
            try db.execute(sql: "INSERT INTO preferences VALUES ('cloud.plan',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [try CloudCoding.encoder().encode(plan)])
        }
    }
}
