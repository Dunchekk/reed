import Foundation
import Testing
import ReedDomain

private struct ReturnFixtures: Codable { var slots: [SlotFixture]; var selections: [SelectionFixture] }
private struct SlotFixture: Codable {
    let name: String, day: Date, timeZone: String, seed: String
    let settings: ReturnSettings, explicit: [CardReturnSettings]
    var expectedSlots: [ReturnTimeSlot]?
    var expectedError: String?
}
private struct ReservationFixture: Codable { let cardID: UUID; let date: Date }
private struct CandidateFixture: Codable {
    let id: UUID, createdAt: Date
    let sourceID: UUID?, folderID: UUID?, tags: Set<UUID>?, authors: Set<UUID>?
    let isFavorite: Bool?, isHidden: Bool?, isDeleted: Bool?, allowsReturns: Bool?, notificationsEnabled: Bool?
    let wordMatches: Set<WordRule>?, deferredUntil: Date?, lastManualOpening: Date?, manualOpeningDays: Int?
    var candidate: ReturnCandidate {
        var value = ReturnCandidate(id: id, createdAt: createdAt)
        value.sourceID = sourceID; value.folderID = folderID; value.tags = tags ?? []; value.authors = authors ?? []
        value.isFavorite = isFavorite ?? false; value.isHidden = isHidden ?? false; value.isDeleted = isDeleted ?? false
        value.allowsReturns = allowsReturns ?? true; value.notificationsEnabled = notificationsEnabled ?? true
        value.wordMatches = wordMatches ?? []; value.deferredUntil = deferredUntil; value.lastManualOpening = lastManualOpening; value.manualOpeningDays = manualOpeningDays ?? 0
        return value
    }
}
private struct SelectionFixture: Codable {
    let name: String, slot: ReturnTimeSlot, settings: ReturnSettings
    let candidates: [CandidateFixture], reservations: [ReservationFixture]
    let previousAutomaticOrdinal: Int, historyEnabled: Bool, sourcesUsedToday: Set<UUID>
    var expected: ReturnDecision?
}

@Test func swiftReturnRulesMatchSharedServerFixtures() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent("contracts/fixtures/returns.json")
    let fixtures = try CloudCoding.decoder().decode(ReturnFixtures.self, from: Data(contentsOf: url))
    for index in fixtures.slots.indices {
        let fixture = fixtures.slots[index]
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try #require(TimeZone(identifier: fixture.timeZone))
        do {
            let result = try SlotPlanner.slots(day: fixture.day, seed: #require(UInt64(fixture.seed)), settings: fixture.settings, explicit: fixture.explicit, calendar: calendar)
            #expect(fixture.expectedError == nil, "\(fixture.name)"); #expect(result == fixture.expectedSlots, "\(fixture.name)")
        } catch let error as ReturnError {
            #expect(String(describing: error) == fixture.expectedError, "\(fixture.name)")
        }
    }
    for index in fixtures.selections.indices {
        let fixture = fixtures.selections[index]
        let result = ReturnSelector.select(slot: fixture.slot, candidates: fixture.candidates.map(\.candidate), settings: fixture.settings,
            reservations: fixture.reservations.map { ReturnReservation(cardID: $0.cardID, date: $0.date) }, previousAutomaticOrdinal: fixture.previousAutomaticOrdinal,
            historyEnabled: fixture.historyEnabled, sourcesUsedToday: fixture.sourcesUsedToday)
        #expect(result == fixture.expected, "\(fixture.name)")
    }
}
