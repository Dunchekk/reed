import Foundation

public enum FeedKind: String, CaseIterable, Codable, Sendable {
    case forgotten, tag, author, folder, anniversary, favorites
    public var title: String {
        switch self {
        case .forgotten: "Давно не открывали"
        case .tag: "Общая тема"
        case .author: "По автору"
        case .folder: "Из одной папки"
        case .anniversary: "В этот день"
        case .favorites: "Избранное"
        }
    }
}
public struct FeedSection: Sendable, Identifiable {
    public let id: FeedKind
    public let explanation: String
    public let cards: [CardSummary]
    public init(id: FeedKind, explanation: String, cards: [CardSummary]) {
        self.id = id; self.explanation = explanation; self.cards = cards
    }
}
