import Foundation
import ReedDomain
import ReedApplication
import ReedPersistence
import ReedNetworking

struct CloudConnectionConfiguration: Sendable {
    let baseURL: URL
    let tokens: SessionTokenProvider
}

/// Composition and lifecycle for one account. Presentation models receive its ports, not its storage.
@MainActor final class CloudRuntime {
    let repository: any CloudRepository
    let remote: HTTPCloudClient?
    let identity: any CloudDeviceIdentity
    let engine: CloudSyncEngine?
    var didChange: (@MainActor () -> Void)?
    private let storage: LocalCloudRepository
    private let returns: ReturnCoordinator
    private var scheduled: Task<Void,Never>?
    private var observation: Task<Void,Never>?

    init(accountID: UUID, database: LibraryDatabase, files: FileAttachmentStore, returns: ReturnCoordinator, connection: CloudConnectionConfiguration?) {
        let storage = LocalCloudRepository(database: database), identity = FileCloudDeviceIdentity(directory: database.directory)
        self.storage = storage; repository = storage; self.identity = identity; self.returns = returns
        if let connection {
            let remote = HTTPCloudClient(baseURL: connection.baseURL, accountID: accountID, tokens: connection.tokens, identity: identity, wifiOnly: { try await storage.state().wifiOnly })
            self.remote = remote
            engine = CloudSyncEngine(local: storage, remote: remote, media: CloudMediaTransfer(local: files, remote: remote),
                participation: AppleCloudParticipation(remote: remote, identity: identity, returns: returns), network: AppleCloudNetworkPolicy())
        } else { remote = nil; engine = nil }
    }
    deinit { scheduled?.cancel(); observation?.cancel() }

    func prepare() async throws {
        if try await repository.state().mode != .local { try await returns.suspendForCloud() }
        if let engine {
            observation = Task { [weak self] in
                for await event in await engine.events() {
                    guard !Task.isCancelled else { return }
                    if event.phase == .idle || event.phase == .conflicts || event.phase == .failed { self?.didChange?(); self?.returns.refresh() }
                }
            }
        }
    }
    func schedule() {
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)); _ = await self?.refresh() }
            catch is CancellationError {} catch {}
        }
    }
    @discardableResult func refresh() async -> Bool {
        do {
            let state = try await repository.state()
            if state.mode == .local { returns.resume(); returns.refresh(); return true }
            try await returns.suspendForCloud()
            guard let engine else { return false }
            if state.mode == .leaving || state.mode == .disabling { try await engine.disable(); return true }
            guard state.participates, state.automatic else { returns.refresh(); return true }
            try await engine.synchronize()
            let remaining = try await repository.summary()
            if remaining.pending > 0 && remaining.conflicts == 0 { try await engine.synchronize() }
            return true
        } catch { return false }
    }
    func refreshInBackground() async -> Bool {
        do {
            if try await repository.state().mode == .local { return await returns.refreshInBackground() }
            return await withTaskCancellationHandler { await refresh() } onCancel: { [engine] in Task { await engine?.cancelCurrent() } }
        } catch { return false }
    }
    func stop() async { scheduled?.cancel(); observation?.cancel(); await engine?.stop() }
    func resumeAfterFailedSignOut() async throws {
        try await engine?.activate()
        try await prepare()
        if try await repository.state().mode == .local { returns.resume() }
        schedule()
    }
    func eraseReplicationForAccountDeletion() async throws {
        await stop()
        try await storage.eraseReplicationForAccountDeletion()
    }
}
