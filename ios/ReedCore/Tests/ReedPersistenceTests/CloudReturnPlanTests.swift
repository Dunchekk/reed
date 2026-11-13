import Foundation
import Testing
import ReedDomain
import ReedApplication
@testable import ReedPersistence

@Test func cloudReturnPlanPersistsWithoutLocalEchoAndWaitsForMissingRecords() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reed-plan-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try LibraryDatabase(root: root, accountID: UUID()), epoch = UUID()
    let cloud = LocalCloudRepository(database: database), returns = LocalReturnRepository(database: database), now = Date()
    try await cloud.begin(epoch: epoch)
    let card = Card(text: "Общая карточка")
    let slot = ReturnTimeSlot(id: "server-slot", date: now.addingTimeInterval(600))
    let entry = CloudReturnPlan.Entry(slot: slot, decision: ReturnDecision(cardID: card.id, reason: .firstReturn), revision: UUID())
    let plan = CloudReturnPlan(epoch: epoch, sequence: 1, timeZone: "UTC", issue: nil, entries: [entry])
    await #expect(throws: CloudError.pendingChanges) { try await cloud.applyReturnPlan(plan, now: now) }
    #expect(try await returns.currentPlan(now: now, calendar: .current).entries.isEmpty)
    try await cloud.apply(CloudPage(epoch: epoch, records: [.init(key: CloudKey(.card,card.id), version: 1, sequence: 1, payload: .encode(CloudCard(card)))], cursor: 1, hasMore: false))
    try await cloud.applyReturnPlan(plan, now: now)
    let saved = try await returns.currentPlan(now: now, calendar: .current)
    #expect(saved.entries.first?.card?.id == card.id)
    #expect(saved.entries.first?.revision == entry.revision)
    #expect(try await cloud.nextPending() == nil)
    try await cloud.applyReturnPlan(CloudReturnPlan(epoch: epoch, sequence: 1, timeZone: "UTC", issue: .noPrimaryDevice, entries: []), now: now.addingTimeInterval(1200))
    let paused = try await returns.currentPlan(now: now, calendar: .current)
    #expect(paused.entries.isEmpty); #expect(paused.issue == .noPrimaryDevice)
}

@Test func leavingCloudKeepsServerCooldownAndAutomaticOrdinalOnANewPhone() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reed-history-leave-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try LibraryDatabase(root: root, accountID: UUID()), epoch = UUID(), now = Date()
    let cloud = LocalCloudRepository(database: database), returns = LocalReturnRepository(database: database), card = Card(text: "Вчера вернулась")
    var settings = ReturnSettings(); settings.enabled = true; settings.notificationsEnabled = true
    try await cloud.begin(epoch: epoch)
    try await cloud.apply(CloudPage(epoch: epoch, records: [
        .init(key: CloudKey(.card,card.id), version: 1, sequence: 1, payload: .encode(CloudCard(card))),
        .init(key: .returns, version: 1, sequence: 2, payload: .encode(settings))
    ], cursor: 2, hasMore: false))
    let yesterday = ReturnTimeSlot(id: "server-yesterday", date: now.addingTimeInterval(-86400), explicitCardID: card.id)
    let oldAutomatic = ReturnTimeSlot(id: "server-old-automatic", date: now.addingTimeInterval(-100*86400))
    let history = [
        CloudReturnPlan.Entry(slot: oldAutomatic, decision: ReturnDecision(cardID: card.id, reason: .longWait, automaticOrdinal: 17), revision: UUID()),
        CloudReturnPlan.Entry(slot: yesterday, decision: ReturnDecision(cardID: card.id, reason: .explicit), revision: UUID())
    ]
    try await cloud.applyReturnPlan(CloudReturnPlan(epoch: epoch, sequence: 2, timeZone: "UTC", issue: nil, entries: [], history: history, snapshotAt: now), now: now)
    try await cloud.setMode(.disabling); try await cloud.disconnect(); try await cloud.finishDisconnect()
    let localPlan = try await returns.replan(now: now, calendar: .current, authorized: true)
    let choices = localPlan.entries.filter { $0.decision.cardID == card.id }
    #expect(!choices.isEmpty)
    #expect(choices.allSatisfy { $0.slot.date.timeIntervalSince(yesterday.date) >= 72*3600 })
    #expect(choices.first?.decision.automaticOrdinal == 18)
    #expect(choices.first?.decision.reason == .longWait)
}

@Test func sameEpochRejoinKeepsOwnershipUntilCancelledServerSlotsAreReconciled() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reed-history-rejoin-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try LibraryDatabase(root: root, accountID: UUID()), epoch = UUID(), now = Date()
    let cloud = LocalCloudRepository(database: database), returns = LocalReturnRepository(database: database), card = Card(text: "Отменённый слот")
    let record = try CloudRecord(key: CloudKey(.card,card.id), version: 1, sequence: 1, payload: .encode(CloudCard(card)))
    let page = CloudPage(epoch: epoch, records: [record], cursor: 1, hasMore: false)
    try await cloud.begin(epoch: epoch); try await cloud.apply(page)
    let elapsed = CloudReturnPlan.Entry(slot: ReturnTimeSlot(id: "cancelled-while-revoked", date: now.addingTimeInterval(-60)),
        decision: ReturnDecision(cardID: card.id, reason: .firstReturn, automaticOrdinal: 10), revision: UUID())
    try await cloud.applyReturnPlan(CloudReturnPlan(epoch: epoch, sequence: 1, timeZone: "UTC", issue: nil, entries: [elapsed]), now: now.addingTimeInterval(-120))
    try await cloud.setMode(.revoked)
    try await cloud.begin(epoch: epoch); try await cloud.apply(page)
    #expect(try await cloud.nextPending() == nil)
    try await cloud.applyReturnPlan(CloudReturnPlan(epoch: epoch, sequence: 1, timeZone: "UTC", issue: nil, entries: []), now: now)
    try await cloud.setMode(.disabling); try await cloud.disconnect(); try await cloud.finishDisconnect()
    #expect(try await returns.currentPlan(now: now, calendar: .current).entries.isEmpty)
}
