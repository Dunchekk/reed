import Foundation
import GRDB
import ReedDomain
import ReedApplication

public struct LocalCapturePreferencesRepository: CapturePreferencesRepository {
    private let database: LibraryDatabase
    public init(database: LibraryDatabase) { self.database = database }
    public func capturePreferences() async throws -> CapturePreferences {
        try await database.writer.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT value FROM preferences WHERE key='capture'") else { return CapturePreferences() }
            return try JSONDecoder().decode(CapturePreferences.self, from: data)
        }
    }
    public func setCapturePreferences(_ value: CapturePreferences) async throws {
        let data = try JSONEncoder().encode(value)
        try await database.writer.write { db in
            try db.execute(sql: "INSERT INTO preferences VALUES ('capture',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [data])
        }
    }
}
