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
    let drafts: any DraftRepository
    let capturePreferences: any CapturePreferencesRepository
    let editor: CardEditingService
    let catalogManagement: any CatalogManagementRepository
    let directory: URL
    private(set) var revision = 0
    private(set) var draftRevision = 0
    private(set) var maintenanceError: String?

    init(account: Account, database: LibraryDatabase) {
        self.account = account
        repository = LocalLibraryRepository(database: database)
        catalogManagement = LocalCatalogManagementRepository(database: database)
        activity = LocalActivityRepository(database: database)
        feed = LocalFeedRepository(database: database)
        let returns = LocalReturnRepository(database: database)
        self.returns = returns
        var queue: any CardNotificationQueue = AppleNotificationQueue()
        #if DEBUG
        if UITestBootstrap.enabled { queue = UITestNotificationQueue() }
        #endif
        returnCoordinator = ReturnCoordinator(repository: returns, queue: queue, accountID: account.id)
        directory = database.directory
        let attachments = FileAttachmentStore(directory: database.directory)
        self.attachments = attachments
        let drafts = LocalDraftRepository(database: database)
        self.drafts = drafts
        capturePreferences = LocalCapturePreferencesRepository(database: database)
        editor = CardEditingService(library: repository, drafts: drafts, attachments: attachments)
    }

    func prepare() async throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date().addingTimeInterval(-604800)
        _ = try await repository.purgeTrash(before: cutoff)
        _ = try await activity.activity(now: Date())
        try await attachments.collectOrphans(retaining: repository.attachmentIDs())
    }

    func refreshAfterActivation() async {
        do {
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date().addingTimeInterval(-604800)
            let removed = try await repository.purgeTrash(before: cutoff)
            _ = try await activity.activity(now: Date())
            if !removed.isEmpty { revision += 1 }
            maintenanceError = nil
        } catch { maintenanceError = "Не удалось выполнить очистку просроченных данных. Повторим при следующем открытии." }
        returnCoordinator.refresh()
    }

    func markChanged() { revision += 1; returnCoordinator.refresh() }
    func markDraftsChanged() { draftRevision += 1 }
}
