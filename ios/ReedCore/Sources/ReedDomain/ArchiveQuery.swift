import Foundation

public enum ArchiveSort: String, CaseIterable, Codable, Sendable { case newest, oldest, alphabetical, random }
public enum ArchiveVisibility: String, Codable, Sendable { case active, hidden, trash }

public struct ArchiveQuery: Codable, Equatable, Sendable {
    public var search = ""
    public var keywords = ""
    public var tagIDs: [UUID] = []
    public var authorID: UUID?
    public var sourceID: UUID?
    public var folderID: UUID?
    public var favoritesOnly = false
    public var createdAfter: Date?
    public var createdBefore: Date?
    public var visibility: ArchiveVisibility = .active
    public var sort: ArchiveSort = .newest
    public var randomSeed: Int64 = Int64.random(in: 0..<2_147_483_647)
    public var pageSize = 30
    public init() {}

    public func validate() throws {
        guard (1...100).contains(pageSize), (0..<2_147_483_647).contains(randomSeed),
              tagIDs.count <= 100 else { throw LibraryError.invalidQuery }
        if let after = createdAfter, let before = createdBefore, after >= before { throw LibraryError.invalidQuery }
    }
}

/// Small list projection: never carries the full text or photo bytes.
public struct CardSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let preview: String
    public let source: String?
    public let createdAt: Date
    public let isFavorite: Bool
    public let tags: [Tag]
    public init(id: UUID, title: String, preview: String, source: String?, createdAt: Date, isFavorite: Bool, tags: [Tag]) {
        self.id = id; self.title = title; self.preview = preview; self.source = source
        self.createdAt = createdAt; self.isFavorite = isFavorite; self.tags = tags
    }
}

public struct ArchivePage: Sendable {
    public let cards: [CardSummary]
    public let nextCursor: String?
    public init(cards: [CardSummary], nextCursor: String?) { self.cards = cards; self.nextCursor = nextCursor }
}

public struct LibraryCatalog: Sendable {
    public var sources: [Source]
    public var authors: [Author]
    public var tags: [Tag]
    public var folders: [Folder]
    public init(sources: [Source] = [], authors: [Author] = [], tags: [Tag] = [], folders: [Folder] = []) {
        self.sources = sources; self.authors = authors; self.tags = tags; self.folders = folders
    }
}
