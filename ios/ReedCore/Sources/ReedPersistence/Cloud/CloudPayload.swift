import Foundation
import CryptoKit
import GRDB
import ReedDomain

/// Converts the local normalized schema to portable records without leaking SQLite/UI types.
enum CloudPayload {
    static func read(_ key: CloudKey, db: Database) throws -> CloudValue {
        let id = UUID(uuidString: key.id)?.uuidString ?? key.id
        switch key.kind {
        case .card:
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM cards WHERE id=?", arguments: [id]) else { return .null }
            return try .encode(CloudCard(LocalLibraryRepository.card(row, db: db)))
        case .source:
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM sources WHERE id=?", arguments: [id]) else { return .null }
            return try .encode(CloudSource(LocalLibraryRepository.source(row, db: db)))
        case .author, .tag, .folder:
            let table = key.kind == .author ? "authors" : key.kind == .tag ? "tags" : "folders"
            guard let name = try String.fetchOne(db, sql: "SELECT name FROM \(table) WHERE id=?", arguments: [id]) else { return .null }
            return .object(["id": .string(key.id), "name": .string(name)])
        case .returnSettings: return try .encode(LocalReturnRepository.settings(db))
        case .cardReturn:
            guard let value = try Data.fetchOne(db, sql: "SELECT value FROM card_returns WHERE card_id=?", arguments: [id]) else { return .null }
            return try .encode(JSONDecoder().decode(CardReturnSettings.self, from: value))
        case .historyPreference:
            return try .encode(CloudHistoryPreference(enabled: Bool.fetchOne(db, sql: "SELECT enabled FROM activity_preferences WHERE id=1") ?? true))
        case .opening:
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM openings WHERE id=? AND opened_at>=?", arguments: [id, Date().addingTimeInterval(-90*86400).timeIntervalSince1970]) else { return .null }
            return try .encode(CloudOpening(id: LocalLibraryRepository.uuid(row["id"]), cardID: LocalLibraryRepository.uuid(row["card_id"]),
                date: Date(timeIntervalSince1970: row["opened_at"]), origin: OpeningOrigin(rawValue: row["origin"]) ?? .manual))
        case .returnHistory:
            guard let row = try Row.fetchOne(db, sql: "SELECT slot,decision FROM return_slots WHERE id=(SELECT slot_id FROM cloud_return_exports WHERE id=?) AND state!='cancelled' AND scheduled_at<=?", arguments: [key.id,Date().timeIntervalSince1970]) else { return .null }
            return try .encode(CloudReturnHistory(slot: JSONDecoder().decode(ReturnTimeSlot.self, from: row["slot"]),
                decision: JSONDecoder().decode(ReturnDecision.self, from: row["decision"])))
        }
    }

    static func seed(_ db: Database) throws {
        for (table, kind, key) in [("authors","author","id"), ("sources","source","id"), ("tags","tag","id"),
                                  ("folders","folder","id"), ("cards","card","id"), ("card_returns","cardReturn","card_id")] {
            for id in try String.fetchAll(db, sql: "SELECT \(key) FROM \(table)") {
                try mark(CloudKey(CloudRecordKind(rawValue: kind)!, id), db: db)
            }
        }
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM preferences WHERE key='returns')") == true { try mark(.returns, db: db) }
        if try Bool.fetchOne(db, sql: "SELECT enabled FROM activity_preferences WHERE id=1") == false { try mark(.history, db: db) }
        for id in try String.fetchAll(db, sql: "SELECT id FROM openings WHERE opened_at>=?", arguments: [Date().addingTimeInterval(-90*86400).timeIntervalSince1970]) {
            try mark(CloudKey(.opening,id), db: db)
        }
        try harvestHistory(db)
    }

    static func harvestHistory(_ db: Database) throws {
        let slots = try String.fetchAll(db, sql: "SELECT id FROM return_slots WHERE state!='cancelled' AND scheduled_at<=? AND id NOT IN (SELECT slot_id FROM cloud_return_exports) AND id NOT IN (SELECT id FROM cloud_plan_slots)", arguments: [Date().timeIntervalSince1970])
        for slot in slots {
            let bytes = Array(SHA256.hash(data: Data(("reed-return-history:" + slot).utf8)).prefix(16))
            let id = UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15])).uuidString.lowercased()
            try db.execute(sql: "INSERT INTO cloud_return_exports VALUES (?,?)", arguments: [slot,id])
            try mark(CloudKey(.returnHistory,id), db: db)
        }
    }

    static func mark(_ key: CloudKey, db: Database) throws {
        try db.execute(sql: "UPDATE cloud_state SET generation=generation+1 WHERE id=1")
        try db.execute(sql: "INSERT INTO cloud_dirty VALUES (?,?,(SELECT generation FROM cloud_state WHERE id=1)) ON CONFLICT(kind,id) DO UPDATE SET generation=excluded.generation", arguments: [key.kind.rawValue,key.id])
    }
}
