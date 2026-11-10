import Foundation
import Testing
import ReedDomain
import ReedPersistence

@Test func historyRespectsDisableExpiryAndOpeningOrigin() async throws {
    let library = try TestLibrary(); defer { library.cleanup() }
    let activity = LocalActivityRepository(database: try LibraryDatabase(root: library.root, accountID: library.accountID))
    let card = Card(text: "История")
    try await library.repository.save(card)
    let now = Date()
    try await activity.recordOpening(cardID: card.id, origin: .manual, now: now.addingTimeInterval(-91 * 86400))
    try await activity.recordOpening(cardID: card.id, origin: .notification, now: now)
    #expect(try await activity.activity(now: now).openings.map(\.origin) == [.notification])
    try await activity.setHistoryEnabled(false)
    try await activity.recordOpening(cardID: card.id, origin: .manual, now: now)
    #expect(try await activity.activity(now: now).openings.isEmpty)
    try await activity.setHistoryEnabled(true)
    #expect(try await activity.activity(now: now).openings.count == 1)
    try await activity.clearOpenings()
    #expect(try await activity.activity(now: now).openings.isEmpty)
}
