import Foundation
import ReedDomain

/// One engine per account context. UI, foreground refresh and background refresh share its task.
public actor CloudSyncEngine {
    let local: any CloudRepository
    let remote: any CloudRemote
    let media: any CloudMediaTransferring
    let participation: any CloudParticipation
    let network: any CloudNetworkPolicy
    private var operation: (id: UUID, task: Task<Void, Error>)?
    private var stopped = false
    private var progress = CloudProgress(.idle)
    private var observers: [UUID: AsyncStream<CloudProgress>.Continuation] = [:]

    public init(local: any CloudRepository, remote: any CloudRemote, media: any CloudMediaTransferring,
                participation: any CloudParticipation, network: any CloudNetworkPolicy) {
        self.local = local; self.remote = remote; self.media = media
        self.participation = participation; self.network = network
    }

    public func events() -> AsyncStream<CloudProgress> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation; continuation.yield(progress)
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    func emit(_ value: CloudProgress) { progress = value; for observer in observers.values { observer.yield(value) } }

    public func synchronize() async throws {
        if let operation { return try await operation.task.value }
        try await exclusively { try await self.exchange() }
    }
    public func resolve(id: UUID, choice: CloudResolution) async throws {
        try await exclusively {
            try await self.local.resolve(id: id, choice: choice)
            try await self.exchange()
        }
    }
    /// Used before closing/deleting an account's local context. It drains the last SQL acknowledgement.
    public func stop() async {
        stopped = true
        guard let operation else { return }
        operation.task.cancel()
        _ = await operation.task.result
    }
    public func cancelCurrent() async {
        guard let operation else { return }
        operation.task.cancel(); _ = await operation.task.result
    }
    public func activate() throws {
        guard operation == nil else { throw CloudError.busy }
        stopped = false
    }
    func exclusively(_ work: @escaping @Sendable () async throws -> Void) async throws {
        guard !stopped else { throw CancellationError() }
        guard operation == nil else { throw CloudError.busy }
        let id = UUID(), task = Task { try await work() }
        operation = (id, task)
        defer { if operation?.id == id { operation = nil } }
        do { try await task.value }
        catch {
            if let error = error as? CloudError, error == .epochChanged || error == .deviceRevoked,
               try await local.state().participates { try await local.setMode(.revoked) }
            if !(error is CancellationError) { emit(CloudProgress(.failed, error: (error as? CloudError) ?? .unavailable)) }
            throw error
        }
    }

    func exchange() async throws {
        try Task.checkCancellation()
        let state = try await local.state()
        guard state.participates, let epoch = state.epoch else { throw CloudError.invalidTransition }
        guard await network.allowsTransfer(wifiOnly: state.wifiOnly) else { throw CloudError.networkRestricted }
        emit(CloudProgress(.preparing))
        try await participation.suspendLocalNotifications()
        let summary = try await remote.summary(); try state.check(epoch: summary.epoch)
        try await participation.refreshRegistration()
        try await pull(epoch: epoch)
        var uploaded: Int64 = 0
        while let pending = try await local.nextPending() {
            try Task.checkCancellation()
            if pending.mutation.kind == .card, pending.mutation.payload != .null {
                for id in try pending.mutation.payload.decode(CloudCard.self).attachmentIDs {
                    try await media.upload(epoch: epoch, id: id) { await self.emit($0) }
                }
            }
            emit(CloudProgress(.pushing, completed: uploaded))
            let result = try await remote.push(epoch: epoch, mutation: pending.mutation)
            try await local.acknowledge(pending, result: result)
            uploaded += 1
        }
        try await pull(epoch: epoch)
        for id in try await local.mediaToDownload() {
            try Task.checkCancellation()
            try await media.download(epoch: epoch, id: id) { await self.emit($0) }
            try await local.markMediaAvailable(id: id)
        }
        emit(CloudProgress(.finishing))
        let remaining = try await local.summary()
        if remaining.pending == 0 && remaining.conflicts == 0 && remaining.unapplied == 0 {
            try await local.completed(at: Date())
            if try await local.state().mode == .enabling { try await local.setMode(.cloud) }
        }
        emit(CloudProgress(remaining.conflicts > 0 ? .conflicts : .idle))
    }

    private func pull(epoch: UUID) async throws {
        while true {
            try Task.checkCancellation()
            let state = try await local.state()
            emit(CloudProgress(.pulling, completed: state.cursor))
            let page = try await remote.pull(epoch: epoch, after: state.cursor, limit: 20)
            guard !page.hasMore || page.cursor > state.cursor else { throw CloudError.invalidRecord }
            try await local.apply(page)
            if !page.hasMore { return }
        }
    }
}
