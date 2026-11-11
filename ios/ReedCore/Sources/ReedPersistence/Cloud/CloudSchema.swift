import GRDB

/// Dirty markers share the writer transaction with existing library commands.
/// The suppression flag is transaction-local in practice: remote apply never commits it as 1.
enum CloudSchema {
    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE cloud_state (
                id INTEGER PRIMARY KEY CHECK(id=1), mode TEXT NOT NULL DEFAULT 'local', epoch TEXT,
                cursor INTEGER NOT NULL DEFAULT 0, automatic INTEGER NOT NULL DEFAULT 1,
                wifi_only INTEGER NOT NULL DEFAULT 1, last_sync REAL,
                generation INTEGER NOT NULL DEFAULT 0, suppress INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO cloud_state(id) VALUES(1);
            CREATE TABLE cloud_shadow (kind TEXT NOT NULL, id TEXT NOT NULL, version INTEGER NOT NULL,
                sequence INTEGER NOT NULL, value BLOB NOT NULL, PRIMARY KEY(kind,id));
            CREATE TABLE cloud_dirty (kind TEXT NOT NULL, id TEXT NOT NULL, generation INTEGER NOT NULL, PRIMARY KEY(kind,id));
            CREATE TABLE cloud_outbox (kind TEXT NOT NULL, id TEXT NOT NULL, value BLOB NOT NULL, PRIMARY KEY(kind,id));
            CREATE TABLE cloud_conflicts (kind TEXT NOT NULL, record_id TEXT NOT NULL, id TEXT NOT NULL UNIQUE,
                value BLOB NOT NULL, PRIMARY KEY(kind,record_id));
            CREATE TABLE cloud_projection (kind TEXT NOT NULL, id TEXT NOT NULL, PRIMARY KEY(kind,id));
            CREATE TABLE cloud_media_needed (id TEXT PRIMARY KEY NOT NULL);
            CREATE TABLE cloud_return_exports (slot_id TEXT PRIMARY KEY NOT NULL, id TEXT NOT NULL UNIQUE);
            """)
        for (table, kind, key) in [
            ("authors","author","id"), ("sources","source","id"), ("folders","folder","id"),
            ("tags","tag","id"), ("cards","card","id"), ("card_returns","cardReturn","card_id"),
            ("openings","opening","id"), ("card_tags","card","card_id"),
            ("card_attachments","card","card_id"), ("source_authors","source","source_id")
        ] {
            try triggers(db, table: table, kind: kind, key: key)
        }
        try triggers(db, table: "preferences", kind: "returnSettings", key: "key", constant: "global", condition: "$ROW.key='returns'")
        try triggers(db, table: "activity_preferences", kind: "historyPreference", key: "id", constant: "global")
    }

    private static func triggers(_ db: Database, table: String, kind: String, key: String,
                                 constant: String? = nil, condition: String = "1") throws {
        for action in ["INSERT", "UPDATE", "DELETE"] {
            let row = action == "DELETE" ? "OLD" : "NEW"
            let id = constant.map { "'\($0)'" } ?? "lower(\(row).\(key))"
            let predicate = condition.replacingOccurrences(of: "$ROW", with: row)
            try db.execute(sql: """
                CREATE TRIGGER cloud_\(table)_\(action.lowercased()) AFTER \(action) ON \(table)
                WHEN (SELECT suppress=0 AND mode!='local' FROM cloud_state WHERE id=1) AND (\(predicate))
                BEGIN
                    UPDATE cloud_state SET generation=generation+1 WHERE id=1;
                    INSERT INTO cloud_dirty(kind,id,generation) VALUES('\(kind)',\(id),(SELECT generation FROM cloud_state WHERE id=1))
                    ON CONFLICT(kind,id) DO UPDATE SET generation=excluded.generation;
                END;
                """)
        }
    }
}
