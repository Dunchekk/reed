import Foundation

public enum OpeningOrigin: String, Codable, Sendable { case manual, notification }
public struct Opening: Sendable, Identifiable {
    public let id: UUID
    public let cardID: UUID
    public let title: String
    public let date: Date
    public let origin: OpeningOrigin
    public init(id: UUID, cardID: UUID, title: String, date: Date, origin: OpeningOrigin) {
        self.id = id; self.cardID = cardID; self.title = title; self.date = date; self.origin = origin
    }
}
public struct ActivitySnapshot: Sendable {
    public let enabled: Bool
    public let cards: Int
    public let favorites: Int
    public let openings: [Opening]
    public init(enabled: Bool, cards: Int, favorites: Int, openings: [Opening]) {
        self.enabled = enabled; self.cards = cards; self.favorites = favorites; self.openings = openings
    }
}
