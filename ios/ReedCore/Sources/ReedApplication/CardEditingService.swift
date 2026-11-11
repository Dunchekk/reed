import Foundation
import ReedDomain

/// The UI sends editable input; this boundary owns metadata resolution and publication.
public struct CardEditingService: Sendable {
    private let library: any LibraryRepository
    private let drafts: any DraftRepository
    private let attachments: any AttachmentStore
    public init(library: any LibraryRepository, drafts: any DraftRepository, attachments: any AttachmentStore) {
        self.library = library; self.drafts = drafts; self.attachments = attachments
    }
    public func autosave(_ input: CardDraft) async throws {
        if input.isEmpty, try await drafts.draft(id: input.id) == nil { return }
        var draft = input; draft.updatedAt = Date()
        try await drafts.saveDraft(draft)
    }
    public func attach(original: Data, thumbnail: Data, to input: CardDraft) async throws -> CardDraft {
        let id = try await attachments.write(original: original, thumbnail: thumbnail)
        do {
            var draft = input
            draft.card.attachmentIDs.append(id); draft.newAttachmentIDs.insert(id)
            try await autosave(draft)
            return draft
        } catch { try? await attachments.remove(id: id); throw error }
    }
    public func publish(_ draft: CardDraft) async throws -> UUID {
        let catalog = try await library.catalog()
        let card = try Self.card(from: draft, catalog: catalog)
        try card.validate()
        try await drafts.saveDraft(draft)
        try await drafts.publishDraft(id: draft.id, card: card)
        return card.id
    }
    public static func fragment(from input: CardDraft, text: String) -> CardDraft {
        var result = CardDraft(card: Card(text: text))
        result.sourceID = input.sourceID; result.folderID = input.folderID
        result.sourceTitle = input.sourceTitle; result.authorNames = input.authorNames
        result.tagNames = input.tagNames; result.folderName = input.folderName
        result.card.page = input.card.page
        return result
    }
    public static func card(from draft: CardDraft, catalog: LibraryCatalog) throws -> Card {
        var card = draft.card
        card.title = card.title.trimmingCharacters(in: .whitespacesAndNewlines); card.updatedAt = Date()
        if let id = draft.sourceID {
            guard let source = catalog.sources.first(where: { $0.id == id }) else { throw LibraryError.conflict }
            card.source = source
        } else if !draft.sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let authors = names(draft.authorNames, separator: ";").map { name in
                catalog.authors.first { equal($0.name, name) } ?? Author(name: name)
            }
            let title = draft.sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            card.source = catalog.sources.first { equal($0.title,title) && $0.authors == authors } ?? Source(title: title, authors: authors)
        } else { card.source = nil }
        card.tags = names(draft.tagNames, separator: ",").map { name in catalog.tags.first { equal($0.name,name) } ?? Tag(name: name) }
        if let id = draft.folderID {
            guard let folder = catalog.folders.first(where: { $0.id == id }) else { throw LibraryError.conflict }
            card.folder = folder
        } else if !draft.folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let name = draft.folderName.trimmingCharacters(in: .whitespacesAndNewlines)
            card.folder = catalog.folders.first { equal($0.name,name) } ?? Folder(name: name)
        } else { card.folder = nil }
        return card
    }
    private static func equal(_ a: String, _ b: String) -> Bool { TextNormalization.normalize(a) == TextNormalization.normalize(b) }
    private static func names(_ input: String, separator: Character) -> [String] {
        var seen = Set<String>()
        return input.split(separator: separator).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert(TextNormalization.normalize($0)).inserted }
    }
}
