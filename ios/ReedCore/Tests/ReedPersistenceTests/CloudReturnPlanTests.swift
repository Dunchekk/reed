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
    try await cloud.applyReturnPlan(plan, now: now)
    #expect(try await returns.currentPlan(now: now, calendar: .current).entries.isEmpty)
    try await cloud.apply(CloudPage(epoch: epoch, records: [.init(key: CloudKey(.card,card.id), version: 1, sequence: 1, payload: .encode(CloudCard(card)))], cursor: 1, hasMore: false))
    try await cloud.applyReturnPlan(plan, now: now)
    let saved = try await returns.currentPlan(now: now, calendar: .current)
    #expect(saved.entries.first?.card?.id == card.id)
    #expect(saved.entries.first?.revision == entry.revision)
    #expect(try await cloud.nextPending() == nil)
    try await cloud.applyReturnPlan(CloudReturnPlan(epoch: epoch, sequence: 1, timeZone: "UTC", issue: .noPrimaryDevice, entries: []), now: now)
    let paused = try await returns.currentPlan(now: now, calendar: .current)
    #expect(paused.entries.isEmpty); #expect(paused.issue == .noPrimaryDevice)
}
