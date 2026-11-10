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
    let returns: any ReturnRepository
    let returnCoordinator: ReturnCoordinator
    let feed: any FeedRepository
    let activity: any ActivityRepository
    let attachments: any AttachmentStore
    let directory: URL
    private(set) var revision = 0

    init(account: Account, database: LibraryDatabase) {
        self.account = account
        repository = LocalLibraryRepository(database: database)
        activity = LocalActivityRepository(database: database)
        feed = LocalFeedRepository(database: database)
        let returns = LocalReturnRepository(database: database)
        self.returns = returns
        returnCoordinator = ReturnCoordinator(repository: returns, queue: AppleNotificationQueue(), accountID: account.id)
        directory = database.directory
        attachments = FileAttachmentStore(directory: database.directory)
    }

    func prepare() async throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date().addingTimeInterval(-604800)
        _ = try await repository.purgeTrash(before: cutoff)
        _ = try await activity.activity(now: Date())
        try await attachments.collectOrphans(retaining: repository.attachmentIDs())
    }

    func markChanged() { revision += 1; returnCoordinator.refresh() }
}
