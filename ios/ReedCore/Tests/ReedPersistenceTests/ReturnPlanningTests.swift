import Foundation
import Testing
import ReedDomain
import ReedPersistence

private struct PlanningFixture {
    let library: TestLibrary
    let returns: LocalReturnRepository
    let now: Date
    let calendar: Calendar
    init() throws {
        library = try TestLibrary()
        returns = LocalReturnRepository(database: try LibraryDatabase(root: library.root, accountID: library.accountID))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        self.calendar = calendar; now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 8))!
    }
    func enable() async throws {
        var settings = ReturnSettings(); settings.enabled = true; settings.notificationsEnabled = true
        try await returns.saveSettings(settings, now: now, calendar: calendar)
    }
}

@Test func savedPlanSurvivesReopeningWithoutRerollingOrDoubleCounting() async throws {
    let fixture = try PlanningFixture(); defer { fixture.library.cleanup() }
    for index in 0..<30 { try await fixture.library.repository.save(Card(text: "Текст \(index)", createdAt: fixture.now.addingTimeInterval(-86400 * 30))) }
    try await fixture.enable()
    let first = try await fixture.returns.replan(now: fixture.now, calendar: fixture.calendar, authorized: true)
    #expect(first.entries.count == 21)
    let reopened = LocalReturnRepository(database: try LibraryDatabase(root: fixture.library.root, accountID: fixture.library.accountID))
    let second = try await reopened.replan(now: fixture.now.addingTimeInterval(60), calendar: fixture.calendar, authorized: true)
    #expect(first.entries.map(\.slot) == second.entries.map(\.slot))
    #expect(first.entries.map(\.decision) == second.entries.map(\.decision))
    #expect(first.entries.map(\.revision) == second.entries.map(\.revision))
    #expect(first.entries.filter { $0.decision.reason == .coverage }.count == 4)
    let future = try await reopened.replan(now: fixture.now.addingTimeInterval(86400), calendar: fixture.calendar, authorized: true)
    #expect(future.entries.compactMap(\.decision.automaticOrdinal).min() == 4)
}

@Test func mutationAndDeniedPermissionCancelFutureChoicesButKeepPastCooldown() async throws {
    let fixture = try PlanningFixture(); defer { fixture.library.cleanup() }
    let card = Card(text: "Единственная карточка", createdAt: fixture.now.addingTimeInterval(-86400))
    try await fixture.library.repository.save(card); try await fixture.enable()
    let initial = try await fixture.returns.replan(now: fixture.now, calendar: fixture.calendar, authorized: true)
    let first = try #require(initial.entries.first { $0.card != nil })
    try await fixture.returns.markQueued(id: first.id, revision: first.revision)
    let later = first.slot.date.addingTimeInterval(1)
    let recalculated = try await fixture.returns.replan(now: later, calendar: fixture.calendar, authorized: true)
    #expect(recalculated.entries.filter { $0.card != nil && $0.slot.date > later }.allSatisfy { $0.slot.date.timeIntervalSince(first.slot.date) >= 72*3600 })
    var hidden = try #require(await fixture.library.repository.card(id: card.id)); hidden.isHidden = true
    try await fixture.library.repository.save(hidden)
    #expect(try await fixture.returns.replan(now: later, calendar: fixture.calendar, authorized: true).entries.allSatisfy { $0.card == nil })
    let denied = try await fixture.returns.replan(now: later, calendar: fixture.calendar, authorized: false)
    #expect(denied.entries.allSatisfy { $0.slot.date <= later })
}

@Test func wordRulesUseFTSAndIndividualAppointmentsOverrideThem() async throws {
    let fixture = try PlanningFixture(); defer { fixture.library.cleanup() }
    let card = Card(text: "Ёлочная история")
    try await fixture.library.repository.save(card)
    var settings = ReturnSettings(); settings.enabled = true; settings.notificationsEnabled = true
    settings.globalInclude.words = "елоч"; settings.channelExclude.words = "истор"
    try await fixture.returns.saveSettings(settings, now: fixture.now, calendar: fixture.calendar)
    #expect(try await fixture.returns.replan(now: fixture.now, calendar: fixture.calendar, authorized: true).entries.allSatisfy { $0.card == nil })
    var rule = CardReturnSettings(cardID: card.id); rule.minutes = [720]
    try await fixture.returns.saveCardSettings(rule, now: fixture.now, calendar: fixture.calendar)
    let plan = try await fixture.returns.replan(now: fixture.now, calendar: fixture.calendar, authorized: true)
    #expect(plan.entries.filter { $0.decision.reason == .explicit }.count == 7)
}
