import Foundation
import Observation
import ReedDomain
import ReedApplication
import ReedPersistence

/// Account-scoped composition root. Features only see repository contracts.
@MainActor @Observable
final class LibraryContext {
    let account: Account
    let repository: any LibraryRepository
    let directory: URL
    private(set) var revision = 0

    init(account: Account, database: LibraryDatabase) {
        self.account = account
        repository = LocalLibraryRepository(database: database)
        directory = database.directory
    }

    func markChanged() { revision += 1 }
}
