import Foundation

public enum CatalogKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case sources, authors, folders, tags
    public var id: Self { self }
    public var title: String {
        switch self { case .sources: "Источники"; case .authors: "Авторы"; case .folders: "Папки"; case .tags: "Теги" }
    }
}
public struct CatalogEntry: Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let cardCount: Int
    public init(id: UUID, name: String, cardCount: Int) { self.id = id; self.name = name; self.cardCount = cardCount }
}
public struct CatalogSnapshot: Sendable {
    public let entries: [CatalogEntry]
    public let revision: Int64
    public init(entries: [CatalogEntry], revision: Int64) { self.entries = entries; self.revision = revision }
}
public enum CatalogMutation: Sendable {
    case rename(id: UUID, name: String)
    case merge(id: UUID, into: UUID)
    case remove(id: UUID)
    public var id: UUID { switch self { case let .rename(id, _), let .merge(id, _), let .remove(id): id } }
}
public enum CatalogError: Error, Sendable { case duplicateName, invalidName, sameTarget }
