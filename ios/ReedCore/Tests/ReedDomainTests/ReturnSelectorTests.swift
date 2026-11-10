import Foundation
import Testing
import ReedDomain

private func enabledSettings() -> ReturnSettings { var value = ReturnSettings(); value.enabled = true; value.notificationsEnabled = true; return value }
@Test func aSingleCardDoesNotFillSlotsInsideTheCooldown() {
    let now = Date(), card = ReturnCandidate(id: UUID(), createdAt: Date().addingTimeInterval(-86400))
    let first = ReturnSelector.select(slot: ReturnTimeSlot(id: "1", date: now), candidates: [card], settings: enabledSettings(), reservations: [], previousAutomaticOrdinal: 0, historyEnabled: false)
    #expect(first.cardID == card.id)
    let reservation = ReturnReservation(cardID: card.id, date: now)
    for delta in [3600.0, 71.0*3600] {
        #expect(ReturnSelector.select(slot: ReturnTimeSlot(id: "2", date: now.addingTimeInterval(delta)), candidates: [card], settings: enabledSettings(), reservations: [reservation], previousAutomaticOrdinal: 1, historyEnabled: false).cardID == nil)
    }
    #expect(ReturnSelector.select(slot: ReturnTimeSlot(id: "3", date: now.addingTimeInterval(72*3600)), candidates: [card], settings: enabledSettings(), reservations: [reservation], previousAutomaticOrdinal: 1, historyEnabled: false).cardID == card.id)
}
@Test func futureReservationsBlockAutomaticButNotExplicitChoices() {
    let now = Date(), card = ReturnCandidate(id: UUID(), createdAt: Date())
    let reservations = [ReturnReservation(cardID: card.id, date: now.addingTimeInterval(3600))]
    #expect(ReturnSelector.select(slot: ReturnTimeSlot(id: "a", date: now), candidates: [card], settings: enabledSettings(), reservations: reservations, previousAutomaticOrdinal: 0, historyEnabled: false).cardID == nil)
    #expect(ReturnSelector.select(slot: ReturnTimeSlot(id: "e", date: now, explicitCardID: card.id), candidates: [card], settings: enabledSettings(), reservations: reservations, previousAutomaticOrdinal: 0, historyEnabled: false).reason == .explicit)
}
@Test(arguments: [5, 10]) func coverageUsesTheEntireFiveHundredCardArchive(slotsPerDay: Int) {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var candidates = (0..<500).map { index in ReturnCandidate(id: UUID(), createdAt: now.addingTimeInterval(Double(-500 + index) * 86400)) }
    for index in 0..<50 { candidates[index].isFavorite = true }
    var settings = enabledSettings(); settings.boostEnabled = true
    var reservations: [ReturnReservation] = [], ordinal = 0, seen = Set<UUID>(), coverageCount = 0
    for day in 0..<200 {
        for index in 0..<slotsPerDay {
            let slot = ReturnTimeSlot(id: "\(day).\(index)", date: now.addingTimeInterval(Double(day * 86400 + index * 3600)))
            let choice = ReturnSelector.select(slot: slot, candidates: candidates, settings: settings, reservations: reservations,
                previousAutomaticOrdinal: ordinal, historyEnabled: false)
            if let id = choice.cardID {
                reservations.append(ReturnReservation(cardID: id, date: slot.date)); seen.insert(id)
                ordinal = choice.automaticOrdinal ?? ordinal
                if choice.reason == .coverage { coverageCount += 1 }
            }
        }
    }
    #expect(seen.count == 500)
    #expect(coverageCount == ordinal / 5)
}
@Test func disablingHistoryRemovesAllOpeningSignalsAndKeepsSelectionDeterministic() {
    let now = Date(), slot = ReturnTimeSlot(id: "fixed", date: Date())
    var cards = (0..<20).map { _ in ReturnCandidate(id: UUID(), createdAt: now.addingTimeInterval(-86400)) }
    let original = ReturnSelector.select(slot: slot, candidates: cards, settings: enabledSettings(), reservations: [], previousAutomaticOrdinal: 0, historyEnabled: false)
    for index in cards.indices { cards[index].manualOpeningDays = index; cards[index].lastManualOpening = now }
    #expect(ReturnSelector.select(slot: slot, candidates: cards.reversed(), settings: enabledSettings(), reservations: [], previousAutomaticOrdinal: 0, historyEnabled: false) == original)
}
