import XCTest
import ReedApplication
import ReedDomain
@testable import Reed

@MainActor
final class ReturnCoordinatorTests: XCTestCase {
    func testFailedLogoutResumesPlanningForTheStillOpenAccount() async throws {
        for failClear in [true, false] {
            let queued = expectation(description: failClear ? "Recovered after queue failure" : "Recovered after database failure")
            let queue = RecoveryQueue(failClear: failClear, queued: queued)
            let repository = RecoveryReturns(failCancel: !failClear)
            let coordinator = ReturnCoordinator(repository: repository, queue: queue, accountID: UUID())
            do { try await coordinator.stop(); XCTFail("Expected the injected logout failure") }
            catch { /* The account stays open; recovery must schedule again. */ }
            await fulfillment(of: [queued], timeout: 3)
            try await coordinator.stop()
            let pending = await queue.pending()
            XCTAssertTrue(pending.isEmpty)
        }
    }
}

private actor RecoveryQueue: CardNotificationQueue {
    private var failClear: Bool
    private let queued: XCTestExpectation
    private var requests: [QueuedNotification] = []
    init(failClear: Bool, queued: XCTestExpectation) { self.failClear = failClear; self.queued = queued }
    func permission() -> NotificationPermission { .allowed }
    func requestPermission() -> Bool { true }
    func pending() -> [QueuedNotification] { requests }
    func add(_ notification: CardNotification) {
        requests.append(QueuedNotification(id: notification.id, revision: notification.entry.revision)); queued.fulfill()
    }
    func remove(ids: [String]) { requests.removeAll { ids.contains($0.id) } }
    func clear() throws {
        if failClear { failClear = false; throw CocoaError(.fileWriteUnknown) }
        requests = []
    }
}
private actor RecoveryReturns: ReturnRepository {
    private var failCancel: Bool
    private let plan: ReturnPlan
    init(failCancel: Bool) {
        self.failCancel = failCancel
        let now = Date(), card = CardSummary(id: UUID(), title: "Recovery", preview: "Synthetic", source: nil, createdAt: Date(), isFavorite: false, tags: [])
        let entry = PlannedReturn(slot: ReturnTimeSlot(id: "recovery", date: now.addingTimeInterval(3600)), decision: ReturnDecision(cardID: card.id, reason: .firstReturn), card: card, state: .planned, revision: UUID())
        plan = ReturnPlan(entries: [entry], horizon: entry.slot.date)
    }
    func settings() -> ReturnSettings { ReturnSettings() }
    func saveSettings(_ settings: ReturnSettings, now: Date, calendar: Calendar) {}
    func cardSettings(id: UUID) -> CardReturnSettings { CardReturnSettings(cardID: id) }
    func saveCardSettings(_ settings: CardReturnSettings, now: Date, calendar: Calendar) {}
    func replan(now: Date, calendar: Calendar, authorized: Bool) -> ReturnPlan { plan }
    func currentPlan(now: Date, calendar: Calendar) -> ReturnPlan { plan }
    func markQueued(id: String, revision: UUID) {}
    func cancelFuture(now: Date) throws {
        if failCancel { failCancel = false; throw CocoaError(.fileWriteUnknown) }
    }
}
