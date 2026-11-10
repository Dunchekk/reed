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

@Test func changingWindowsMiddayDoesNotResetTheDailyQuota() async throws {
    let fixture = try PlanningFixture(); defer { fixture.library.cleanup() }
    for index in 0..<20 { try await fixture.library.repository.save(Card(text: "Quota \(index)", createdAt: fixture.now.addingTimeInterval(-86400))) }
    try await fixture.enable()
    let initial = try await fixture.returns.replan(now: fixture.now, calendar: fixture.calendar, authorized: true)
    let today = initial.entries.filter { fixture.calendar.isDate($0.slot.date, inSameDayAs: fixture.now) }
    let afterSecond = today[1].slot.date.addingTimeInterval(1)
    var settings = try await fixture.returns.settings(); settings.firstMinute = 1080; settings.lastMinute = 1380
    try await fixture.returns.saveSettings(settings, now: afterSecond, calendar: fixture.calendar)
    let changed = try await fixture.returns.replan(now: afterSecond, calendar: fixture.calendar, authorized: true)
    #expect(changed.entries.filter { fixture.calendar.isDate($0.slot.date, inSameDayAs: fixture.now) && $0.card != nil }.count == 3)
}

@Test func nextDayExplicitAppointmentWinsOverLateAutomaticSlot() async throws {
    let fixture = try PlanningFixture(); defer { fixture.library.cleanup() }
    let explicitCard = Card(text: "Early appointment")
    try await fixture.library.repository.save(explicitCard)
    for index in 0..<20 { try await fixture.library.repository.save(Card(text: "Automatic \(index)")) }
    var settings = ReturnSettings(); settings.enabled = true; settings.notificationsEnabled = true
    settings.firstMinute = 1410; settings.lastMinute = 1410; settings.dailyLimit = 1; settings.jitterMinutes = 0
    try await fixture.returns.saveSettings(settings, now: fixture.now, calendar: fixture.calendar)
    var rule = CardReturnSettings(cardID: explicitCard.id); rule.minutes = [0]; rule.weekdays = [2]
    try await fixture.returns.saveCardSettings(rule, now: fixture.now, calendar: fixture.calendar)
    let plan = try await fixture.returns.replan(now: fixture.now, calendar: fixture.calendar, authorized: true)
    let appointment = try #require(plan.entries.first { $0.decision.reason == .explicit })
    #expect(fixture.calendar.component(.hour, from: appointment.slot.date) == 0)
    #expect(plan.entries.filter { $0.card != nil && $0.id != appointment.id }.allSatisfy { abs($0.slot.date.timeIntervalSince(appointment.slot.date)) >= 3600 })
}

@Test(arguments: ["disabled", "hidden", "trashed"])
func reactivatingConflictingCardRollsBackWithoutDisturbingExistingPlan(mode: String) async throws {
    let fixture = try PlanningFixture(); defer { fixture.library.cleanup() }
    let now = fixture.now, calendar = fixture.calendar
    let library = LocalLibraryRepository(database: try LibraryDatabase(root: fixture.library.root, accountID: fixture.library.accountID), now: { now }, calendar: { calendar })
    let first = Card(text: "First"), second = Card(text: "Second")
    try await library.save(first); try await library.save(second); try await fixture.enable()
    var firstRule = CardReturnSettings(cardID: first.id); firstRule.minutes = [720]
    try await fixture.returns.saveCardSettings(firstRule, now: now, calendar: calendar)
    var card = try #require(await library.card(id: first.id))
    if mode == "disabled" { card.allowsReturns = false }
    if mode == "hidden" { card.isHidden = true }
    if mode == "trashed" { card.deletedAt = now }
    try await library.save(card)
    var secondRule = CardReturnSettings(cardID: second.id); secondRule.minutes = [720]
    try await fixture.returns.saveCardSettings(secondRule, now: now, calendar: calendar)
    let original = try await fixture.returns.replan(now: now, calendar: calendar, authorized: true)
    card = try #require(await library.card(id: first.id)); card.allowsReturns = true; card.isHidden = false; card.deletedAt = nil
    await #expect(throws: ReturnError.conflictingExplicitTimes) { try await library.save(card) }
    let unchanged = try await fixture.returns.currentPlan(now: now, calendar: calendar)
    #expect(unchanged.entries.map(\.decision) == original.entries.map(\.decision))
    let stored = try #require(await library.card(id: first.id))
    #expect(!stored.allowsReturns || stored.isHidden || stored.deletedAt != nil)
}

@Test func midnightAppointmentBeyondHorizonPreventsConflictingLastEveningSlot() async throws {
    let fixture = try PlanningFixture(); defer { fixture.library.cleanup() }
    let appointed = Card(text: "Sunday appointment")
    try await fixture.library.repository.save(appointed)
    for index in 0..<20 { try await fixture.library.repository.save(Card(text: "Evening \(index)")) }
    var settings = ReturnSettings(); settings.enabled = true; settings.notificationsEnabled = true
    settings.dailyLimit = 1; settings.firstMinute = 1410; settings.lastMinute = 1410; settings.jitterMinutes = 0
    try await fixture.returns.saveSettings(settings, now: fixture.now, calendar: fixture.calendar)
    var rule = CardReturnSettings(cardID: appointed.id); rule.minutes = [0]; rule.weekdays = [1]
    try await fixture.returns.saveCardSettings(rule, now: fixture.now, calendar: fixture.calendar)
    let first = try await fixture.returns.replan(now: fixture.now, calendar: fixture.calendar, authorized: true)
    let lastEvening = fixture.calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 23, minute: 30))!
    let midnight = fixture.calendar.date(from: DateComponents(year: 2026, month: 11, day: 8))!
    #expect(first.entries.allSatisfy { $0.slot.date != lastEvening && $0.slot.date < midnight })
    let extended = try await fixture.returns.replan(now: lastEvening.addingTimeInterval(15*60), calendar: fixture.calendar, authorized: true)
    #expect(extended.entries.contains { $0.slot.date == midnight && $0.decision.cardID == appointed.id && $0.decision.reason == .explicit })
}
