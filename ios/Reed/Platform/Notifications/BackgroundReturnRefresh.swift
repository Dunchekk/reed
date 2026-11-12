import BackgroundTasks
import Foundation

/// iOS decides when (or whether) this task runs. Foreground renewal remains authoritative.
@MainActor final class BackgroundReturnRefresh {
    static let shared = BackgroundReturnRefresh()
    static let identifier = "dev.dunchekk.reed.returns"
    private var work: Task<Void, Never>?
    private var generation = UUID()
    func register() {
        #if DEBUG
        if UITestBootstrap.enabled { return }
        #endif
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { task in
            Task { @MainActor in self.run(task) }
        }
    }
    func schedule() {
        #if DEBUG
        if UITestBootstrap.enabled { return }
        #endif
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = Date().addingTimeInterval(6 * 3600)
        // Failure to schedule does not affect the already prepared local queue.
        try? BGTaskScheduler.shared.submit(request)
    }
    func cancel() {
        generation = UUID(); work?.cancel()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
    }
    private func run(_ task: BGTask) {
        let token = generation
        let operation = Task { @MainActor in
            var success = false
            defer { task.setTaskCompleted(success: success) }
            do {
                guard let session = try KeychainSessionStore().load() else { return }
                let context = try await LibrarySessionController.shared.open(session.account)
                guard !Task.isCancelled, token == generation,
                      try KeychainSessionStore().load()?.account.id == session.account.id else { return }
                success = await context.returnCoordinator.refreshInBackground()
                if token == generation && !Task.isCancelled { schedule() }
            } catch { success = false }
        }
        work = operation
        task.expirationHandler = { operation.cancel() }
    }
}
