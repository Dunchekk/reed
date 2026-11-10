import Foundation
import GRDB
import ReedDomain
import ReedApplication

public final class LocalFeedRepository: FeedRepository {
    private let database: LibraryDatabase
    public init(database: LibraryDatabase) { self.database = database }
    public func enabledGroups() async throws -> Set<FeedKind> {
        try await database.writer.read(Self.groups)
    }
    public func setEnabledGroups(_ kinds: Set<FeedKind>) async throws {
        let data = try JSONEncoder().encode(kinds)
        try await database.writer.write { db in
            try db.execute(sql: "INSERT INTO preferences VALUES ('feed', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [data])
        }
    }
    private static func groups(_ db: Database) throws -> Set<FeedKind> {
        if let data = try Data.fetchOne(db, sql: "SELECT value FROM preferences WHERE key='feed'") {
            return try JSONDecoder().decode(Set<FeedKind>.self, from: data)
        }
        return Set(FeedKind.allCases)
    }
    public func feed(now: Date, calendar: Calendar) async throws -> [FeedSection] {
        try await database.writer.read { db in
            let enabled = try Self.groups(db)
            let historyEnabled = try Bool.fetchOne(db, sql: "SELECT enabled FROM activity_preferences WHERE id=1") ?? true
            var sections: [FeedSection] = []
            let day = Int(calendar.startOfDay(for: now).timeIntervalSince1970 / 86400)
            for kind in FeedKind.allCases where enabled.contains(kind) {
                var condition = "1=1", order = "c.created_at DESC, c.id"
                var arguments = StatementArguments()
                var explanation = kind.title
                switch kind {
                case .forgotten:
                    guard historyEnabled else { continue }
                    condition = "c.created_at < ? AND NOT EXISTS(SELECT 1 FROM openings o WHERE o.card_id=c.id AND o.opened_at>=?)"
                    arguments = [now.addingTimeInterval(-30*86400).timeIntervalSince1970, now.addingTimeInterval(-30*86400).timeIntervalSince1970]
                    order = "c.created_at ASC, c.id"
                    explanation = "Сохранены больше месяца назад; нет открытий за последние 30 дней"
                case .favorites: condition = "c.is_favorite=1"; explanation = "Вы отметили эти карточки звездой"
                case .anniversary:
                    // Convert the user's local month/day explicitly; SQLite must not use the host timezone.
                    let month = calendar.component(.month, from: now), dayOfMonth = calendar.component(.day, from: now)
                    var intervals: [String] = []
                    for year in (calendar.component(.year, from: now)-10)..<calendar.component(.year, from: now) {
                        if let start = calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth)),
                           calendar.component(.month, from: start) == month,
                           let end = calendar.date(byAdding: .day, value: 1, to: start) {
                            intervals.append("(c.created_at>=? AND c.created_at<?)")
                            arguments += [start.timeIntervalSince1970, end.timeIntervalSince1970]
                        }
                    }
                    condition = intervals.isEmpty ? "0=1" : "(" + intervals.joined(separator: " OR ") + ")"
                    explanation = "Сохранены в этот день в течение прошлых 10 лет"
                case .tag, .author, .folder:
                    let sql: String
                    switch kind {
                    case .tag: sql = "SELECT t.id, t.name FROM tags t JOIN card_tags ct ON ct.tag_id=t.id JOIN cards c ON c.id=ct.card_id WHERE c.deleted_at IS NULL AND c.is_hidden=0 GROUP BY t.id HAVING COUNT(*)>=2 ORDER BY t.id"
                    case .author: sql = "SELECT a.id, a.name FROM authors a JOIN source_authors sa ON sa.author_id=a.id JOIN cards c ON c.source_id=sa.source_id WHERE c.deleted_at IS NULL AND c.is_hidden=0 GROUP BY a.id HAVING COUNT(*)>=2 ORDER BY a.id"
                    default: sql = "SELECT f.id, f.name FROM folders f JOIN cards c ON c.folder_id=f.id WHERE c.deleted_at IS NULL AND c.is_hidden=0 GROUP BY f.id HAVING COUNT(*)>=2 ORDER BY f.id"
                    }
                    let groups = try Row.fetchAll(db, sql: sql)
                    guard !groups.isEmpty else { continue }
                    let group = groups[abs(day % groups.count)], id: String = group["id"]
                    explanation = "\(kind.title): \(group["name"] as String)"
                    if kind == .tag { condition = "EXISTS(SELECT 1 FROM card_tags ct WHERE ct.card_id=c.id AND ct.tag_id=?)" }
                    else if kind == .author { condition = "EXISTS(SELECT 1 FROM source_authors sa WHERE sa.source_id=c.source_id AND sa.author_id=?)" }
                    else { condition = "c.folder_id=?" }
                    arguments = [id]
                }
                let rows = try Row.fetchAll(db, sql: "SELECT c.id,c.title,c.preview,c.source_id,c.created_at,c.is_favorite FROM cards c WHERE c.deleted_at IS NULL AND c.is_hidden=0 AND \(condition) ORDER BY \(order) LIMIT 12", arguments: arguments)
                let cards = try rows.map { try LocalLibraryRepository.summary($0, db: db) }
                if !cards.isEmpty { sections.append(FeedSection(id: kind, explanation: explanation, cards: cards)) }
            }
            return sections
        }
    }
}
