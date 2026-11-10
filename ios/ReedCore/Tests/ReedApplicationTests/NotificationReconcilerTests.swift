import Foundation
import Testing
import ReedDomain
import ReedApplication

private actor FakeQueue: CardNotificationQueue {
    var requests: [String: CardNotification] = [:]
    var additions = 0
    var failuresLeft = 0
    var slow = false
    func permission() -> NotificationPermission { .allowed }
    func requestPermission() -> Bool { true }
    func pending() -> [QueuedNotification] { requests.values.map { QueuedNotification(id: $0.id, revision: $0.entry.revision) } }
    func configure(failures: Int = 0, slow: Bool = false) { failuresLeft = failures; self.slow = slow }
    func add(_ notification: CardNotification) async throws {
        additions += 1
        if slow { try await Task.sleep(for: .milliseconds(100)) }
        if failuresLeft > 0 { failuresLeft -= 1; throw CocoaError(.fileWriteUnknown) }
        requests[notification.id] = notification
    }
    func remove(ids: [String]) { for id in ids { requests.removeValue(forKey: id) } }
    func clear() { requests = [:] }
}
private actor FakeDelivery: ReturnDeliveryRepository {
    var marked: Set<String> = []
    func markQueued(id: String, revision: UUID) { marked.insert(id) }
}
private func entry(_ index: Int, now: Date) -> PlannedReturn {
    let card = CardSummary(id: UUID(), title: "Тест", preview: "Текст", source: nil, createdAt: now, isFavorite: false, tags: [])
    return PlannedReturn(slot: ReturnTimeSlot(id: "slot\(index)", date: now.addingTimeInterval(Double(index+1)*3600)),
        decision: ReturnDecision(cardID: card.id, reason: .firstReturn), card: card, state: .planned, revision: UUID())
}
@Test func notificationQueueRepairsPartialFailuresAndRemovesObsoleteEntries() async throws {
    let now = Date(), queue = FakeQueue(), delivery = FakeDelivery()
    let reconciler = NotificationReconciler(queue: queue, repository: delivery, accountID: UUID())
    let entries = [entry(0, now: now),entry(1, now: now)], plan = ReturnPlan(entries: [], horizon: nil)
    await queue.configure(failures: 1)
    let first = try await reconciler.reconcile(ReturnPlan(entries: entries, horizon: entries.last?.slot.date), now: now)
    #expect(first.count == 1 && first.failures == 1)
    let retry = try await reconciler.reconcile(ReturnPlan(entries: entries, horizon: entries.last?.slot.date), now: now)
    #expect(retry.count == 2 && retry.failures == 0)
    #expect(await queue.additions == 3)
    _ = try await reconciler.reconcile(ReturnPlan(entries: entries, horizon: nil), now: now)
    #expect(await queue.additions == 3)
    _ = try await reconciler.reconcile(plan, now: now)
    #expect(await queue.pending().isEmpty)
}
@Test func stoppingDrainsInFlightAddsAndCannotRescheduleAfterLogout() async throws {
    let now = Date(), queue = FakeQueue(), delivery = FakeDelivery()
    let reconciler = NotificationReconciler(queue: queue, repository: delivery, accountID: UUID())
    await queue.configure(slow: true)
    let plan = ReturnPlan(entries: [entry(0, now: now)], horizon: nil)
    let work = Task { try await reconciler.reconcile(plan, now: now) }
    try await Task.sleep(for: .milliseconds(20))
    try await reconciler.stop()
    _ = try? await work.value
    #expect(await queue.pending().isEmpty)
    await #expect(throws: CancellationError.self) { try await reconciler.reconcile(plan, now: now) }
}

@Test func failedRevisionReplacementCannotLeaveTheOldCardScheduled() async throws {
    let now = Date(), queue = FakeQueue(), delivery = FakeDelivery()
    let reconciler = NotificationReconciler(queue: queue, repository: delivery, accountID: UUID())
    let old = entry(0, now: now)
    _ = try await reconciler.reconcile(ReturnPlan(entries: [old], horizon: nil), now: now)
    let replacement = PlannedReturn(slot: old.slot, decision: old.decision, card: old.card, state: .planned, revision: UUID())
    await queue.configure(failures: 1)
    let result = try await reconciler.reconcile(ReturnPlan(entries: [replacement], horizon: nil), now: now)
    #expect(result.failures == 1)
    #expect(await queue.pending().isEmpty)
    _ = try await reconciler.reconcile(ReturnPlan(entries: [replacement], horizon: nil), now: now)
    #expect(await queue.pending().first?.revision == replacement.revision)
}
