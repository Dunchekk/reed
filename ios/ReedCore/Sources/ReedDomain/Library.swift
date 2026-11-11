import Foundation

public struct Author: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

public struct Source: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var title: String
    public var authors: [Author]
    public var url: String?
    public init(id: UUID = UUID(), title: String, authors: [Author] = [], url: String? = nil) {
        self.id = id; self.title = title; self.authors = authors; self.url = url
    }
    public var displayName: String {
        authors.isEmpty ? title : "\(title) // \(authors.map(\.name).joined(separator: ", "))"
    }
}

public struct Tag: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

public struct Folder: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

public struct Card: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var text: String
    public var title: String
    public var comment: String
    public var source: Source?
    public var page: String
    public var tags: [Tag]
    public var folder: Folder?
    public let createdAt: Date
    public var updatedAt: Date
    public var isFavorite: Bool
    public var isHidden: Bool
    public var deletedAt: Date?
    public var allowsReturns: Bool
    public var attachmentIDs: [UUID]
    /// Compatibility for callers creating a card with one photo.
    public var attachmentID: UUID? {
        get { attachmentIDs.first }
        set { attachmentIDs = newValue.map { [$0] } ?? [] }
    }
    public let version: Int

    public init(id: UUID = UUID(), text: String, title: String = "", comment: String = "",
                source: Source? = nil, page: String = "", tags: [Tag] = [], folder: Folder? = nil,
                createdAt: Date = Date(), updatedAt: Date? = nil, isFavorite: Bool = false,
                isHidden: Bool = false, deletedAt: Date? = nil, allowsReturns: Bool = true, version: Int = 0,
                attachmentID: UUID? = nil, attachmentIDs: [UUID] = []) {
        self.id = id; self.text = text; self.title = title; self.comment = comment
        self.source = source; self.page = page; self.tags = tags; self.folder = folder
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
        self.isFavorite = isFavorite; self.isHidden = isHidden
        self.deletedAt = deletedAt; self.allowsReturns = allowsReturns
        self.version = version
        self.attachmentIDs = attachmentIDs.isEmpty ? attachmentID.map { [$0] } ?? [] : attachmentIDs
    }

    public var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(text.prefix(64)) : title
    }

    public func validate() throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.emptyText }
        let names = tags.map(\.name) + (folder.map { [$0.name] } ?? [])
            + (source.map { [$0.title] + $0.authors.map(\.name) } ?? [])
        guard names.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw LibraryError.emptyMetadata
        }
        guard Set(attachmentIDs).count == attachmentIDs.count,
              Set(tags.map(\.id)).count == tags.count,
              Set(source?.authors.map(\.id) ?? []).count == source?.authors.count ?? 0 else {
            throw LibraryError.duplicateRelationship
        }
    }
}

public enum LibraryError: Error, Equatable, Sendable {
    case emptyText, emptyMetadata, duplicateRelationship, invalidQuery, invalidCursor, staleCursor, notFound, conflict
}

public enum TextNormalization {
    public static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "ru_RU"))
            .replacingOccurrences(of: "ё", with: "е")
    }
    public static func tokens(_ text: String) -> [String] {
        normalize(text).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
}
