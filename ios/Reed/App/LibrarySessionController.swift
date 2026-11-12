import Foundation
import ReedDomain
import ReedPersistence

@MainActor final class LibrarySessionController {
    static let shared = LibrarySessionController()
    private var current: LibraryContext?
    private var opening: (id: UUID, task: Task<LibraryContext, Error>)?
    func open(_ account: Account) async throws -> LibraryContext {
        if let current, current.account.id == account.id { return current }
        if let opening {
            let result = try await opening.task.value
            if opening.id == account.id { return result }
            self.opening = nil; current = result
            return try await open(account)
        }
        let task = Task { @MainActor in
            if let current { try await current.returnCoordinator.stop() }
            var root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("Reed", isDirectory: true)
            #if DEBUG
            if let testRoot = UITestBootstrap.root { root = testRoot }
            #endif
            let databaseRoot = root
            let database = try await Task.detached(priority: .userInitiated) { try LibraryDatabase(root: databaseRoot, accountID: account.id) }.value
            let context = LibraryContext(account: account, database: database)
            try await context.prepare()
            #if DEBUG
            try await UITestBootstrap.seed(context)
            #endif
            return context
        }
        opening = (account.id, task)
        defer { opening = nil }
        let result = try await task.value
        current = result
        return result
    }
    func forget() { current = nil }
}
