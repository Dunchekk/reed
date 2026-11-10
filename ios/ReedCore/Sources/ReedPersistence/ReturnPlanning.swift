import Foundation
import GRDB
import ReedDomain

extension LocalReturnRepository {
    public func replan(now: Date, calendar: Calendar, authorized: Bool) async throws -> ReturnPlan {
        try await database.writer.write { db in
            let settings = try Self.settings(db)
            try settings.validate()
            let oldRows = try Row.fetchAll(db, sql: "SELECT * FROM return_slots WHERE scheduled_at>?", arguments: [now.timeIntervalSince1970])
            let old = Dictionary(uniqueKeysWithValues: oldRows.map { ($0["id"] as String, $0) })
            try db.execute(sql: "UPDATE return_slots SET state='cancelled' WHERE scheduled_at>?", arguments: [now.timeIntervalSince1970])
            guard authorized, settings.enabled, settings.notificationsEnabled else { return try Self.readPlan(db, now: now, calendar: calendar) }
            let candidates = try Self.candidates(db, settings: settings, now: now, calendar: calendar)
            let eligibleIDs = Set(candidates.filter { ReturnPolicy.admits($0, settings: settings, explicit: true) }.map(\.id))
            let individual = try Self.individualSettings(db).filter { eligibleIDs.contains($0.cardID) }
            let libraryRevision = try Int64.fetchOne(db, sql: "SELECT revision FROM library_state WHERE id=1") ?? 0
            var slots: [ReturnTimeSlot] = []
            for offset in 0..<7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { continue }
                let key = SlotPlanner.dayKey(day, calendar: calendar)
                let seed: UInt64
                if let stored = try String.fetchOne(db, sql: "SELECT seed FROM return_days WHERE day_key=?", arguments: [key]), let value = UInt64(stored) { seed = value }
                else {
                    seed = UInt64.random(in: 0...UInt64.max)
                    try db.execute(sql: "INSERT INTO return_days VALUES (?, ?)", arguments: [key, String(seed)])
                }
                slots += try SlotPlanner.slots(day: day, seed: seed, settings: settings, explicit: individual, calendar: calendar).filter { $0.date > now }
            }
            // Leave space below the system queue ceiling and expose the actual shorter horizon.
            slots = Array(slots.prefix(48))
            let past = try Row.fetchAll(db, sql: "SELECT card_id,scheduled_at,automatic_ordinal FROM return_slots WHERE scheduled_at<=? AND state!='cancelled' AND card_id IS NOT NULL", arguments: [now.timeIntervalSince1970])
            var reservations = try past.map { ReturnReservation(cardID: try LocalLibraryRepository.uuid($0["card_id"]), date: Date(timeIntervalSince1970: $0["scheduled_at"])) }
            reservations += slots.compactMap { slot in slot.explicitCardID.map { ReturnReservation(cardID: $0, date: slot.date) } }
            var ordinal = past.compactMap { $0["automatic_ordinal"] as Int? }.max() ?? 0
            let historyEnabled = try Bool.fetchOne(db, sql: "SELECT enabled FROM activity_preferences WHERE id=1") ?? true
            let sourceByCard = Dictionary(uniqueKeysWithValues: candidates.compactMap { card in card.sourceID.map { (card.id, $0) } })
            var usedByDay: [String: Set<UUID>] = [:]
            for event in reservations where event.date <= now {
                if let source = sourceByCard[event.cardID] { usedByDay[SlotPlanner.dayKey(event.date, calendar: calendar), default: []].insert(source) }
            }
            var previousTime = past.map { Date(timeIntervalSince1970: $0["scheduled_at"]) }.max()
            for slot in slots {
                // Day-local generation also observes the previous day's last occupied slot.
                if let previousTime, slot.date.timeIntervalSince(previousTime) < Double(settings.minimumIntervalMinutes * 60) { continue }
                let key = SlotPlanner.dayKey(slot.date, calendar: calendar)
                let decision = ReturnSelector.select(slot: slot, candidates: candidates, settings: settings, reservations: reservations,
                    previousAutomaticOrdinal: ordinal, historyEnabled: historyEnabled, sourcesUsedToday: usedByDay[key] ?? [])
                if let id = decision.cardID {
                    reservations.append(ReturnReservation(cardID: id, date: slot.date))
                    ordinal = decision.automaticOrdinal ?? ordinal; previousTime = slot.date
                    if let source = sourceByCard[id] { usedByDay[key, default: []].insert(source) }
                }
                let slotData = try JSONEncoder().encode(slot), decisionData = try JSONEncoder().encode(decision)
                var revision = UUID(), state = ReturnDeliveryState.planned
                if let existing = old[slot.id], (existing["state"] as String) != "cancelled",
                   (existing["library_revision"] as Int64) == libraryRevision,
                   try JSONDecoder().decode(ReturnTimeSlot.self, from: existing["slot"]) == slot,
                   try JSONDecoder().decode(ReturnDecision.self, from: existing["decision"]) == decision {
                    revision = try LocalLibraryRepository.uuid(existing["revision"])
                    state = ReturnDeliveryState(rawValue: existing["state"]) ?? .planned
                }
                try db.execute(sql: """
                    INSERT INTO return_slots(id,scheduled_at,card_id,automatic_ordinal,slot,decision,state,revision,library_revision)
                    VALUES (?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET scheduled_at=excluded.scheduled_at,
                    card_id=excluded.card_id,automatic_ordinal=excluded.automatic_ordinal,slot=excluded.slot,
                    decision=excluded.decision,state=excluded.state,revision=excluded.revision,library_revision=excluded.library_revision
                    """, arguments: [slot.id,slot.date.timeIntervalSince1970,decision.cardID?.uuidString,
                        decision.automaticOrdinal,slotData,decisionData,state.rawValue,revision.uuidString,libraryRevision])
            }
            return try Self.readPlan(db, now: now, calendar: calendar)
        }
    }
}
