import Foundation
import Testing
import ReedDomain

private func scheduleCalendar(_ zone: String = "Europe/Moscow") -> Calendar {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}
@Test func defaultTimesVaryAroundThreeAnchorsButRemainStableForTheDay() throws {
    var settings = ReturnSettings(); settings.enabled = true; settings.notificationsEnabled = true
    let calendar = scheduleCalendar(), day = Date(timeIntervalSince1970: 1_800_000_000)
    let first = try SlotPlanner.slots(day: day, seed: 42, settings: settings, explicit: [], calendar: calendar)
    #expect(first == (try SlotPlanner.slots(day: day, seed: 42, settings: settings, explicit: [], calendar: calendar)))
    #expect(first != (try SlotPlanner.slots(day: day, seed: 43, settings: settings, explicit: [], calendar: calendar)))
    #expect(first.count == 3)
    for (slot, center) in zip(first, [600,900,1200]) {
        let minute = calendar.component(.hour, from: slot.date) * 60 + calendar.component(.minute, from: slot.date)
        #expect(abs(minute-center) <= 30)
    }
}
@Test func explicitTimesConsumeQuotaAndConflictsAreRejected() throws {
    var settings = ReturnSettings(); settings.enabled = true; settings.notificationsEnabled = true
    var card = CardReturnSettings(cardID: UUID()); card.minutes = [600,900]
    let slots = try SlotPlanner.slots(day: Date(), seed: 10, settings: settings, explicit: [card], calendar: scheduleCalendar())
    #expect(slots.count == 3)
    #expect(slots.filter { $0.explicitCardID == card.cardID }.count == 2)
    card.minutes = [600,620]
    #expect(throws: ReturnError.conflictingExplicitTimes) { try SlotPlanner.slots(day: Date(), seed: 10, settings: settings, explicit: [card], calendar: scheduleCalendar()) }
}
@Test func slotsStayOnLocalDayAcrossDaylightSavingTransitions() throws {
    let calendar = scheduleCalendar("America/New_York")
    var settings = ReturnSettings(); settings.enabled = true; settings.notificationsEnabled = true
    settings.firstMinute = 60; settings.lastMinute = 300; settings.jitterMinutes = 0
    for parts in [DateComponents(year: 2026, month: 3, day: 8), DateComponents(year: 2026, month: 11, day: 1)] {
        let day = calendar.date(from: parts)!
        let slots = try SlotPlanner.slots(day: day, seed: 1, settings: settings, explicit: [], calendar: calendar)
        #expect(slots.allSatisfy { calendar.isDate($0.date, inSameDayAs: day) })
        for pair in zip(slots, slots.dropFirst()) { #expect(pair.1.date.timeIntervalSince(pair.0.date) >= 3600) }
    }
}
