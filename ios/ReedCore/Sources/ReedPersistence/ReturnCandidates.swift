import Foundation
import GRDB
import ReedDomain

extension LocalReturnRepository {
    static func candidates(_ db: Database, settings: ReturnSettings, now: Date, calendar: Calendar) throws -> [ReturnCandidate] {
        let rows = try Row.fetchAll(db, sql: "SELECT id,created_at,source_id,folder_id,is_favorite,is_hidden,deleted_at,allows_returns FROM cards WHERE deleted_at IS NULL AND is_hidden=0 AND allows_returns=1")
        var tags: [String: Set<UUID>] = [:], authors: [String: Set<UUID>] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT card_id,tag_id FROM card_tags") {
            tags[row["card_id"], default: []].insert(try LocalLibraryRepository.uuid(row["tag_id"]))
        }
        for row in try Row.fetchAll(db, sql: "SELECT source_id,author_id FROM source_authors") {
            authors[row["source_id"], default: []].insert(try LocalLibraryRepository.uuid(row["author_id"]))
        }
        var matches: [WordRule: Set<String>] = [:]
        for (rule, filter) in [(WordRule.globalInclude,settings.globalInclude),(.globalExclude,settings.globalExclude),(.channelInclude,settings.channelInclude),(.channelExclude,settings.channelExclude)] {
            let tokens = TextNormalization.tokens(filter.words)
            if !tokens.isEmpty {
                let pattern = tokens.map { "\"\($0)\"*" }.joined(separator: filter.wordMode == .all ? " AND " : " OR ")
                matches[rule] = Set(try String.fetchAll(db, sql: "SELECT card_id FROM card_search WHERE card_search MATCH ?", arguments: [pattern]))
            }
        }
        var openingDays: [String: Set<Date>] = [:], lastOpening: [String: Date] = [:]
        if try Bool.fetchOne(db, sql: "SELECT enabled FROM activity_preferences WHERE id=1") == true {
            for row in try Row.fetchAll(db, sql: "SELECT card_id,opened_at FROM openings WHERE origin='manual' AND opened_at>=?", arguments: [now.addingTimeInterval(-90*86400).timeIntervalSince1970]) {
                let id: String = row["card_id"], date = Date(timeIntervalSince1970: row["opened_at"])
                openingDays[id, default: []].insert(calendar.startOfDay(for: date))
                lastOpening[id] = max(lastOpening[id] ?? .distantPast, date)
            }
        }
        let individual = try Self.individualSettings(db)
        let disabled = Set(individual.filter { !$0.notificationsEnabled }.map(\.cardID))
        return try rows.map { row in
            let id: String = row["id"], source: String? = row["source_id"], folder: String? = row["folder_id"]
            var card = ReturnCandidate(id: try LocalLibraryRepository.uuid(id), createdAt: Date(timeIntervalSince1970: row["created_at"]))
            card.sourceID = try source.map(LocalLibraryRepository.uuid); card.folderID = try folder.map(LocalLibraryRepository.uuid)
            card.tags = tags[id] ?? []; card.authors = source.flatMap { authors[$0] } ?? []
            card.isFavorite = row["is_favorite"]; card.notificationsEnabled = !disabled.contains(card.id)
            card.wordMatches = Set(matches.compactMap { $0.value.contains(id) ? $0.key : nil })
            card.manualOpeningDays = openingDays[id]?.count ?? 0; card.lastManualOpening = lastOpening[id]
            return card
        }
    }
}
