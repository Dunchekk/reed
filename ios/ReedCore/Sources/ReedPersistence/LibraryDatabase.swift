import Foundation
import GRDB

/// Owns one account's database. UI and domain code never receive the writer.
public final class LibraryDatabase: Sendable {
    let writer: any DatabaseWriter
    public let directory: URL

    public init(root: URL, accountID: UUID) throws {
        directory = root.appendingPathComponent(accountID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(5)
        writer = try DatabasePool(path: directory.appendingPathComponent("library.sqlite").path, configuration: configuration)
        try Self.migrator.migrate(writer)
    }

    // Internal visibility permits upgrade tests from an actual earlier schema.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("001_library") { db in
            try db.execute(sql: """
                CREATE TABLE library_state (id INTEGER PRIMARY KEY CHECK (id = 1), revision INTEGER NOT NULL);
                INSERT INTO library_state VALUES (1, 0);
                CREATE TABLE authors (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL);
                CREATE TABLE sources (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, url TEXT);
                CREATE TABLE source_authors (
                    source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                    author_id TEXT NOT NULL REFERENCES authors(id), position INTEGER NOT NULL,
                    PRIMARY KEY (source_id, author_id)
                );
                CREATE INDEX source_authors_author ON source_authors(author_id, source_id);
                CREATE TABLE tags (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL);
                CREATE TABLE folders (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL);
                CREATE TABLE cards (
                    id TEXT PRIMARY KEY NOT NULL, text TEXT NOT NULL, title TEXT NOT NULL,
                    comment TEXT NOT NULL, page TEXT NOT NULL,
                    source_id TEXT REFERENCES sources(id), folder_id TEXT REFERENCES folders(id),
                    created_at REAL NOT NULL, updated_at REAL NOT NULL,
                    is_favorite INTEGER NOT NULL DEFAULT 0, is_hidden INTEGER NOT NULL DEFAULT 0,
                    deleted_at REAL, allows_returns INTEGER NOT NULL DEFAULT 1, version INTEGER NOT NULL,
                    preview TEXT NOT NULL, sort_title TEXT NOT NULL, shuffle_key INTEGER NOT NULL
                );
                CREATE TABLE card_tags (
                    card_id TEXT NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
                    tag_id TEXT NOT NULL REFERENCES tags(id), PRIMARY KEY (card_id, tag_id)
                );
                CREATE INDEX cards_active_date ON cards(deleted_at, is_hidden, created_at, id);
                CREATE INDEX cards_title ON cards(deleted_at, is_hidden, sort_title, id);
                CREATE INDEX cards_shuffle ON cards(deleted_at, is_hidden, shuffle_key, id);
                CREATE INDEX cards_source ON cards(source_id, created_at, id);
                CREATE INDEX cards_folder ON cards(folder_id, created_at, id);
                CREATE INDEX card_tags_tag ON card_tags(tag_id, card_id);
                CREATE VIRTUAL TABLE card_search USING fts5(card_id UNINDEXED, document, tokenize = 'unicode61 remove_diacritics 0', prefix = '2 3 4');
                """)
        }
        migrator.registerMigration("002_attachments") { db in
            try db.execute(sql: "ALTER TABLE cards ADD COLUMN attachment_id TEXT")
        }
        migrator.registerMigration("003_activity") { db in
            try db.execute(sql: """
                CREATE TABLE activity_preferences (id INTEGER PRIMARY KEY CHECK(id=1), enabled INTEGER NOT NULL);
                INSERT INTO activity_preferences VALUES (1, 1);
                CREATE TABLE openings (id TEXT PRIMARY KEY NOT NULL, card_id TEXT NOT NULL REFERENCES cards(id) ON DELETE CASCADE, opened_at REAL NOT NULL, origin TEXT NOT NULL);
                CREATE INDEX openings_card_time ON openings(card_id, opened_at);
                CREATE INDEX openings_time ON openings(opened_at);
                """)
        }
        migrator.registerMigration("004_preferences") { db in
            try db.execute(sql: "CREATE TABLE preferences (key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL)")
        }
        migrator.registerMigration("005_returns") { db in
            try db.execute(sql: """
                CREATE TABLE card_returns (card_id TEXT PRIMARY KEY NOT NULL REFERENCES cards(id) ON DELETE CASCADE, value BLOB NOT NULL);
                CREATE TABLE return_days (day_key TEXT PRIMARY KEY NOT NULL, seed TEXT NOT NULL);
                CREATE TABLE return_slots (id TEXT PRIMARY KEY NOT NULL, scheduled_at REAL NOT NULL, card_id TEXT, automatic_ordinal INTEGER, slot BLOB NOT NULL, decision BLOB NOT NULL, state TEXT NOT NULL, revision TEXT NOT NULL, library_revision INTEGER NOT NULL);
                CREATE INDEX return_slots_time ON return_slots(scheduled_at, state);
                CREATE INDEX return_slots_card_time ON return_slots(card_id, scheduled_at);
                """)
        }
        migrator.registerMigration("006_search_keys") { db in
            try db.execute(sql: """
                CREATE TABLE card_search_keys (search_id INTEGER PRIMARY KEY AUTOINCREMENT, card_id TEXT NOT NULL UNIQUE REFERENCES cards(id) ON DELETE CASCADE);
                INSERT INTO card_search_keys(search_id,card_id) SELECT rowid,card_id FROM card_search;
                """)
        }
        migrator.registerMigration("007_multiple_attachments") { db in
            try db.execute(sql: """
                CREATE TABLE card_attachments (
                    card_id TEXT NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
                    attachment_id TEXT NOT NULL, position INTEGER NOT NULL,
                    PRIMARY KEY(card_id, attachment_id), UNIQUE(card_id, position)
                );
                INSERT INTO card_attachments SELECT id, attachment_id, 0 FROM cards WHERE attachment_id IS NOT NULL;
                ALTER TABLE cards DROP COLUMN attachment_id;
                """)
        }
        migrator.registerMigration("008_drafts") { db in
            try db.execute(sql: """
                CREATE TABLE drafts (id TEXT PRIMARY KEY NOT NULL, updated_at REAL NOT NULL, state TEXT NOT NULL, value BLOB);
                CREATE INDEX drafts_updated ON drafts(state,updated_at);
                CREATE TABLE draft_attachments (draft_id TEXT NOT NULL REFERENCES drafts(id) ON DELETE CASCADE, attachment_id TEXT NOT NULL, PRIMARY KEY(draft_id,attachment_id));
                """)
        }
        migrator.registerMigration("009_catalog_tombstones") { db in
            try db.execute(sql: "CREATE TABLE catalog_tombstones (kind TEXT NOT NULL,id TEXT NOT NULL,PRIMARY KEY(kind,id))")
        }
        migrator.registerMigration("010_backup_imports") { db in
            try db.execute(sql: "CREATE TABLE backup_imports (id TEXT PRIMARY KEY NOT NULL)")
        }
        migrator.registerMigration("011_cloud_replication", migrate: CloudSchema.migrate)
        migrator.registerMigration("012_cloud_media_references") { db in
            try db.execute(sql: "CREATE TABLE cloud_media_references (owner TEXT NOT NULL, record_id TEXT NOT NULL, attachment_id TEXT NOT NULL, PRIMARY KEY(owner,record_id,attachment_id))")
            try CloudMediaReferences.backfill(db)
        }
        migrator.registerMigration("013_cloud_leaving", migrate: CloudSchema.installTriggers)
        migrator.registerMigration("014_cloud_plan_ownership", migrate: LocalCloudRepository.migrateReturnOwnership)
        return migrator
    }
}
