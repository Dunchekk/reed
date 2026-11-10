import Foundation
import Testing
import ReedDomain
import ReedPersistence

/// Opt-in diagnostic, not a device-performance claim or a timing-sensitive CI assertion.
@Test(.enabled(if: ProcessInfo.processInfo.environment["REED_BENCHMARK_CARDS"] != nil))
func largeArchiveDiagnostic() async throws {
    let count = Int(ProcessInfo.processInfo.environment["REED_BENCHMARK_CARDS"] ?? "10000") ?? 10000
    #expect([10000,50000,100000].contains(count))
    guard [10000,50000,100000].contains(count) else { return }
    let library = try TestLibrary(); defer { library.cleanup() }
    let source = Source(title: "Синтетический сборник", authors: [Author(name: "Автор")]), tag = Tag(name: "Общая тема")
    let started = Date()
    for index in 0..<count {
        try await library.repository.save(Card(text: "Синтетический фрагмент о чтении \(index)", source: source, tags: [tag]))
    }
    let seeded = Date()
    var query = ArchiveQuery(); query.search = "синтетич чтени"
    let page = try await library.repository.archive(query)
    #expect(page.cards.count == 30 && page.nextCursor != nil)
    let searched = Date()
    let returns = LocalReturnRepository(database: try LibraryDatabase(root: library.root, accountID: library.accountID))
    var settings = ReturnSettings(); settings.enabled = true; settings.notificationsEnabled = true
    try await returns.saveSettings(settings, now: Date(), calendar: .current)
    let plan = try await returns.replan(now: Date(), calendar: .current, authorized: true)
    #expect(!plan.entries.isEmpty)
    print("REED_BENCHMARK cards=\(count) seed_seconds=\(seeded.timeIntervalSince(started)) search_seconds=\(searched.timeIntervalSince(seeded)) plan_seconds=\(Date().timeIntervalSince(searched))")
}
