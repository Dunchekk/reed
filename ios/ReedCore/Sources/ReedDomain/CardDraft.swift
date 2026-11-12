import Foundation

/// Editable input, including incomplete metadata. A draft is not a published card.
public struct CardDraft: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var card: Card
    public var sourceID: UUID?
    public var folderID: UUID?
    public var sourceTitle: String
    public var authorNames: String
    public var tagNames: String
    public var folderName: String
    public var newAttachmentIDs: Set<UUID>
    public var updatedAt: Date

    public init(id: UUID = UUID(), card: Card = Card(text: "")) {
        self.id = id; self.card = card; sourceID = card.source?.id; folderID = card.folder?.id
        sourceTitle = ""; authorNames = ""; folderName = ""
        tagNames = card.tags.map(\.name).joined(separator: ", ")
        newAttachmentIDs = []; updatedAt = Date()
    }
    public func replacingID(_ id: UUID) -> CardDraft {
        var result = CardDraft(id: id, card: card)
        result.sourceID = sourceID; result.folderID = folderID
        result.sourceTitle = sourceTitle; result.authorNames = authorNames
        result.tagNames = tagNames; result.folderName = folderName
        result.newAttachmentIDs = newAttachmentIDs; result.updatedAt = updatedAt
        return result
    }
    public var isEmpty: Bool {
        [card.text, card.title, card.comment, card.page, sourceTitle, authorNames, tagNames, folderName]
            .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        && card.attachmentIDs.isEmpty && sourceID == nil && folderID == nil
    }
}

public struct DraftSummary: Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let updatedAt: Date
    public let photoCount: Int
    public let editsExistingCard: Bool
    public init(_ draft: CardDraft) {
        id = draft.id; title = draft.card.displayTitle.isEmpty ? "Без текста" : draft.card.displayTitle
        updatedAt = draft.updatedAt; photoCount = draft.card.attachmentIDs.count
        editsExistingCard = draft.card.version > 0
    }
}
