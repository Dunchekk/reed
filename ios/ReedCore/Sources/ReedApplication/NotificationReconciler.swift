import Foundation
import ReedDomain

/// Serialize platform writes. Stop cancels and drains in-flight work before clearing the queue.
public actor NotificationReconciler {
    private let queue: any CardNotificationQueue
    private let repository: any ReturnDeliveryRepository
    private let accountID: UUID
    private var active = true
    private var tail: Task<NotificationQueueReport, Error>?
    public init(queue: any CardNotificationQueue, repository: any ReturnDeliveryRepository, accountID: UUID) {
        self.queue = queue; self.repository = repository; self.accountID = accountID
    }
    public func reconcile(_ plan: ReturnPlan, now: Date) async throws -> NotificationQueueReport {
        guard active else { throw CancellationError() }
        let previous = tail, queue = queue, repository = repository, accountID = accountID
        let task = Task {
            if let previous { _ = try? await previous.value }
            try Task.checkCancellation()
            return try await Self.apply(plan, now: now, accountID: accountID, queue: queue, repository: repository)
        }
        tail = task
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    public func stop() async throws {
        active = false; tail?.cancel()
        _ = try? await tail?.value
        try await queue.clear()
    }
    private static func apply(_ plan: ReturnPlan, now: Date, accountID: UUID, queue: any CardNotificationQueue,
                              repository: any ReturnDeliveryRepository) async throws -> NotificationQueueReport {
        let desired = plan.entries.filter { $0.card != nil && $0.slot.date > now && $0.state != .cancelled }.prefix(48)
            .map { CardNotification(accountID: accountID, entry: $0) }
        let pending = await queue.pending()
        let revisions = Dictionary(uniqueKeysWithValues: desired.map { ($0.id, $0.entry.revision) })
        try Task.checkCancellation()
        // A failed replacement must never leave a now-ineligible card's old text scheduled.
        try await queue.remove(ids: pending.filter { revisions[$0.id] == nil || revisions[$0.id] != $0.revision }.map(\.id))
        let existing = Dictionary(pending.map { ($0.id, $0.revision) }, uniquingKeysWith: { first, _ in first })
        var confirmed: [Date] = [], failures = 0
        for request in desired {
            try Task.checkCancellation()
            guard request.entry.slot.date > now else { continue }
            do {
                if existing[request.id] != request.entry.revision { try await queue.add(request) }
                try Task.checkCancellation()
                try await repository.markQueued(id: request.entry.id, revision: request.entry.revision)
                confirmed.append(request.entry.slot.date)
            } catch is CancellationError { throw CancellationError() }
            catch { failures += 1 }
        }
        return NotificationQueueReport(count: confirmed.count, until: confirmed.max(), failures: failures)
    }
}
