import Foundation
import GRDB
import ReedDomain
import ReedApplication

public final class LocalReturnRepository: ReturnRepository {
    let database: LibraryDatabase
    public init(database: LibraryDatabase) { self.database = database }
    public func settings() async throws -> ReturnSettings { try await database.writer.read(Self.settings) }
    static func settings(_ db: Database) throws -> ReturnSettings {
        guard let data = try Data.fetchOne(db, sql: "SELECT value FROM preferences WHERE key='returns'") else { return ReturnSettings() }
        return try JSONDecoder().decode(ReturnSettings.self, from: data)
    }
    public func saveSettings(_ settings: ReturnSettings, now: Date, calendar: Calendar) async throws {
        try settings.validate()
        try await database.writer.write { db in
            try Self.validate(settings, explicit: Self.individualSettings(db), now: now, calendar: calendar)
            try db.execute(sql: "INSERT INTO preferences VALUES ('returns', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [try JSONEncoder().encode(settings)])
        }
    }
    public func cardSettings(id: UUID) async throws -> CardReturnSettings {
        try await database.writer.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT value FROM card_returns WHERE card_id=?", arguments: [id.uuidString]) else { return CardReturnSettings(cardID: id) }
            return try JSONDecoder().decode(CardReturnSettings.self, from: data)
        }
    }
    public func saveCardSettings(_ settings: CardReturnSettings, now: Date, calendar: Calendar) async throws {
        try settings.validate()
        try await database.writer.write { db in
            let rules = try Self.individualSettings(db).filter { $0.cardID != settings.cardID } + [settings]
            try Self.validate(Self.settings(db), explicit: rules, now: now, calendar: calendar)
            try db.execute(sql: "INSERT INTO card_returns VALUES (?, ?) ON CONFLICT(card_id) DO UPDATE SET value=excluded.value", arguments: [settings.cardID.uuidString, try JSONEncoder().encode(settings)])
        }
    }
    static func individualSettings(_ db: Database) throws -> [CardReturnSettings] {
        try Data.fetchAll(db, sql: "SELECT cr.value FROM card_returns cr JOIN cards c ON c.id=cr.card_id WHERE c.deleted_at IS NULL AND c.is_hidden=0 AND c.allows_returns=1")
            .map { try JSONDecoder().decode(CardReturnSettings.self, from: $0) }
    }
    private static func validate(_ settings: ReturnSettings, explicit: [CardReturnSettings], now: Date, calendar: Calendar) throws {
        var settings = settings; settings.enabled = true; settings.notificationsEnabled = true
        var previous: Date?
        // Eight days also validates the boundary between this week and the next.
        for offset in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { continue }
            let slots = try SlotPlanner.slots(day: day, seed: 0, settings: settings, explicit: explicit, calendar: calendar)
            for slot in slots where slot.explicitCardID != nil {
                if let previous, slot.date.timeIntervalSince(previous) < Double(settings.minimumIntervalMinutes * 60) { throw ReturnError.conflictingExplicitTimes }
                previous = slot.date
            }
        }
    }
    public func currentPlan(now: Date, calendar: Calendar) async throws -> ReturnPlan {
        try await database.writer.read { try Self.readPlan($0, now: now, calendar: calendar) }
    }
    public func markQueued(id: String, revision: UUID) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE return_slots SET state='queued' WHERE id=? AND revision=? AND state!='cancelled'", arguments: [id, revision.uuidString])
        }
    }
    public func cancelFuture(now: Date) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE return_slots SET state='cancelled' WHERE scheduled_at>?", arguments: [now.timeIntervalSince1970])
        }
    }
    static func readPlan(_ db: Database, now: Date, calendar: Calendar) throws -> ReturnPlan {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM return_slots WHERE scheduled_at>=? AND state!='cancelled' ORDER BY scheduled_at,id", arguments: [calendar.startOfDay(for: now).timeIntervalSince1970])
        let entries = try rows.map { row -> PlannedReturn in
            let slot = try JSONDecoder().decode(ReturnTimeSlot.self, from: row["slot"])
            let decision = try JSONDecoder().decode(ReturnDecision.self, from: row["decision"])
            var card: CardSummary?
            if let id = decision.cardID, let projection = try Row.fetchOne(db, sql: "SELECT id,title,preview,source_id,created_at,is_favorite FROM cards WHERE id=? AND deleted_at IS NULL AND is_hidden=0", arguments: [id.uuidString]) {
                card = try LocalLibraryRepository.summary(projection, db: db)
            }
            return PlannedReturn(slot: slot, decision: decision, card: card,
                state: ReturnDeliveryState(rawValue: row["state"]) ?? .planned, revision: try LocalLibraryRepository.uuid(row["revision"]))
        }
        return ReturnPlan(entries: entries, horizon: entries.filter { $0.card != nil && $0.slot.date > now }.last?.slot.date)
    }
}
