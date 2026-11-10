import Foundation
import Testing
import ReedDomain
import ReedPersistence

@Test func feedExplainsGroupsAndExcludesHiddenAndTrashedCards() async throws {
    let library = try TestLibrary(); defer { library.cleanup() }
    let database = try LibraryDatabase(root: library.root, accountID: library.accountID)
    let feed = LocalFeedRepository(database: database), activity = LocalActivityRepository(database: database)
    let now = Date(), old = Date().addingTimeInterval(-40*86400), tag = Tag(name: "Тема")
    for i in 0..<4 { try await library.repository.save(Card(text: "Карточка \(i)", tags: [tag], createdAt: old, isFavorite: true, isHidden: i == 2, deletedAt: i == 3 ? now : nil)) }
    let groups = try await feed.feed(now: now, calendar: .current)
    #expect(groups.first { $0.id == .tag }?.cards.count == 2)
    #expect(groups.first { $0.id == .forgotten }?.cards.count == 2)
    try await activity.setHistoryEnabled(false)
    #expect(try await feed.feed(now: now, calendar: .current).allSatisfy { $0.id != .forgotten })
    try await feed.setEnabledGroups([.favorites])
    #expect(try await feed.feed(now: now, calendar: .current).map(\.id) == [.favorites])
}
