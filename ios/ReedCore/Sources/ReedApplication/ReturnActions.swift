import Foundation
import ReedDomain

/// User intent is independent of notification delivery and SwiftUI presentation.
public struct ReturnActions: Sendable {
    private let library: any LibraryRepository
    private let returns: any ReturnRepository
    public init(library: any LibraryRepository, returns: any ReturnRepository) { self.library = library; self.returns = returns }
    public func deferUntilTomorrow(cardID: UUID, now: Date, calendar: Calendar) async throws -> Date {
        guard let card = try await library.card(id: cardID), card.deletedAt == nil, !card.isHidden, card.allowsReturns else { throw LibraryError.notFound }
        let settings = try await returns.settings()
        guard settings.enabled, settings.notificationsEnabled,
              let date = calendar.date(byAdding: .day, value: 1, to: now),
              settings.weekdays.contains(calendar.component(.weekday, from: date)) else { throw ReturnError.invalidSchedule }
        var rule = try await returns.cardSettings(id: cardID)
        guard rule.notificationsEnabled else { throw ReturnError.invalidSchedule }
        rule.deferredUntil = date
        try await returns.saveCardSettings(rule, now: now, calendar: calendar)
        return date
    }
    public func stop(cardID: UUID) async throws {
        guard var card = try await library.card(id: cardID) else { throw LibraryError.notFound }
        card.allowsReturns = false; card.updatedAt = Date()
        try await library.save(card)
    }
}
