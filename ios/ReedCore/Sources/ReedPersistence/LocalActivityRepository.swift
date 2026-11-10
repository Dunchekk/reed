import Foundation
import GRDB
import ReedDomain
import ReedApplication

public final class LocalActivityRepository: ActivityRepository {
    private let database: LibraryDatabase
    public init(database: LibraryDatabase) { self.database = database }

    public func activity(now: Date) async throws -> ActivitySnapshot {
        try await database.writer.write { db in
            try Self.prune(db, now: now)
            let enabled = try Bool.fetchOne(db, sql: "SELECT enabled FROM activity_preferences WHERE id=1") ?? true
            let cards = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards WHERE deleted_at IS NULL") ?? 0
            let favorites = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards WHERE deleted_at IS NULL AND is_favorite=1") ?? 0
            let rows = enabled ? try Row.fetchAll(db, sql: "SELECT o.*, c.title, c.preview FROM openings o JOIN cards c ON c.id=o.card_id WHERE c.deleted_at IS NULL ORDER BY o.opened_at DESC, o.id LIMIT 100") : []
            let openings = try rows.map { row -> Opening in
                let title: String = row["title"], preview: String = row["preview"]
                return Opening(id: try LocalLibraryRepository.uuid(row["id"]), cardID: try LocalLibraryRepository.uuid(row["card_id"]),
                    title: title.isEmpty ? String(preview.prefix(64)) : title, date: Date(timeIntervalSince1970: row["opened_at"]),
                    origin: OpeningOrigin(rawValue: row["origin"]) ?? .manual)
            }
            return ActivitySnapshot(enabled: enabled, cards: cards, favorites: favorites, openings: openings)
        }
    }
    public func setHistoryEnabled(_ enabled: Bool) async throws {
        try await database.writer.write { db in try db.execute(sql: "UPDATE activity_preferences SET enabled=? WHERE id=1", arguments: [enabled]) }
    }
    public func clearOpenings() async throws {
        try await database.writer.write { db in try db.execute(sql: "DELETE FROM openings") }
    }
    public func recordOpening(cardID: UUID, origin: OpeningOrigin, now: Date) async throws {
        try await database.writer.write { db in
            try Self.prune(db, now: now)
            guard try Bool.fetchOne(db, sql: "SELECT enabled FROM activity_preferences WHERE id=1") == true,
                try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM cards WHERE id=? AND deleted_at IS NULL)", arguments: [cardID.uuidString]) == true else { return }
            try db.execute(sql: "INSERT INTO openings VALUES (?, ?, ?, ?)", arguments: [UUID().uuidString, cardID.uuidString, now.timeIntervalSince1970, origin.rawValue])
        }
    }
    private static func prune(_ db: Database, now: Date) throws {
        try db.execute(sql: "DELETE FROM openings WHERE opened_at < ?", arguments: [now.addingTimeInterval(-90 * 86400).timeIntervalSince1970])
    }
}
