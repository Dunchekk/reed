import Foundation

public struct BackupOpening: Codable, Sendable {
    public let id: UUID, cardID: UUID
    public let date: Date
    public let origin: OpeningOrigin
    public init(id: UUID, cardID: UUID, date: Date, origin: OpeningOrigin) { self.id = id; self.cardID = cardID; self.date = date; self.origin = origin }
}
public struct BackupReturn: Codable, Sendable {
    public let slot: ReturnTimeSlot
    public let decision: ReturnDecision
    public init(slot: ReturnTimeSlot, decision: ReturnDecision) { self.slot = slot; self.decision = decision }
}
public struct LibraryBackup: Codable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var cards: [Card]
    public let catalog: LibraryCatalog
    public var drafts: [CardDraft]
    public let capture: CapturePreferences
    public let returns: ReturnSettings
    public let cardReturns: [CardReturnSettings]
    public let feed: Set<FeedKind>
    public let historyEnabled: Bool
    public let openings: [BackupOpening]
    public let returnHistory: [BackupReturn]
    public init(id: UUID = UUID(), createdAt: Date = Date(), cards: [Card], catalog: LibraryCatalog, drafts: [CardDraft], capture: CapturePreferences,
                returns: ReturnSettings, cardReturns: [CardReturnSettings], feed: Set<FeedKind>, historyEnabled: Bool,
                openings: [BackupOpening], returnHistory: [BackupReturn]) {
        self.id = id; self.createdAt = createdAt; self.cards = cards; self.catalog = catalog; self.drafts = drafts
        self.capture = capture; self.returns = returns; self.cardReturns = cardReturns; self.feed = feed
        self.historyEnabled = historyEnabled; self.openings = openings; self.returnHistory = returnHistory
    }
    public var attachmentIDs: Set<UUID> { Set(cards.flatMap(\.attachmentIDs) + drafts.flatMap { $0.card.attachmentIDs }) }
    public func validate() throws {
        func unique<T: Hashable>(_ values: [T]) -> Bool { Set(values).count == values.count }
        guard unique(cards.map(\.id)), unique(drafts.map(\.id)), unique(catalog.sources.map(\.id)), unique(catalog.authors.map(\.id)),
              unique(catalog.tags.map(\.id)), unique(catalog.folders.map(\.id)), unique(openings.map(\.id)),
              unique(cardReturns.map(\.cardID)), unique(returnHistory.map { $0.slot.id }), createdAt.timeIntervalSince1970.isFinite else { throw BackupError.invalidArchive }
        let sources = Dictionary(uniqueKeysWithValues: catalog.sources.map { ($0.id,$0) })
        let authors = Dictionary(uniqueKeysWithValues: catalog.authors.map { ($0.id,$0) })
        let tags = Dictionary(uniqueKeysWithValues: catalog.tags.map { ($0.id,$0) })
        let folders = Dictionary(uniqueKeysWithValues: catalog.folders.map { ($0.id,$0) })
        let ids = Set(cards.map(\.id))
        for source in catalog.sources {
            guard !source.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  unique(source.authors.map(\.id)), source.authors.allSatisfy({ authors[$0.id] == $0 }) else { throw BackupError.invalidArchive }
        }
        guard (catalog.authors.map(\.name) + catalog.tags.map(\.name) + catalog.folders.map(\.name)).allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw BackupError.invalidArchive }
        for card in cards {
            try card.validate()
            guard card.version >= 1, card.source.map({ sources[$0.id] == $0 }) ?? true,
                  card.folder.map({ folders[$0.id] == $0 }) ?? true, card.tags.allSatisfy({ tags[$0.id] == $0 }),
                  card.createdAt.timeIntervalSince1970.isFinite, card.updatedAt.timeIntervalSince1970.isFinite,
                  card.deletedAt?.timeIntervalSince1970.isFinite ?? true else { throw BackupError.invalidArchive }
        }
        for draft in drafts {
            guard unique(draft.card.attachmentIDs), draft.newAttachmentIDs.isSubset(of: Set(draft.card.attachmentIDs)),
                  draft.updatedAt.timeIntervalSince1970.isFinite,
                  draft.sourceID.map({ sources[$0] != nil }) ?? true, draft.folderID.map({ folders[$0] != nil }) ?? true else { throw BackupError.invalidArchive }
        }
        try returns.validate()
        for rule in cardReturns { guard ids.contains(rule.cardID) else { throw BackupError.invalidArchive }; try rule.validate() }
        guard openings.allSatisfy({ ids.contains($0.cardID) && $0.date.timeIntervalSince1970.isFinite }),
              returnHistory.allSatisfy({ $0.slot.date <= createdAt && $0.slot.date.timeIntervalSince1970.isFinite && ($0.decision.automaticOrdinal ?? 0) >= 0 }) else { throw BackupError.invalidArchive }
    }
    public func remappingAttachments(_ mapping: [UUID: UUID]) throws -> LibraryBackup {
        func map(_ ids: [UUID]) throws -> [UUID] {
            try ids.map { guard let value = mapping[$0] else { throw BackupError.invalidArchive }; return value }
        }
        var copy = self
        for index in copy.cards.indices { copy.cards[index].attachmentIDs = try map(copy.cards[index].attachmentIDs) }
        for index in copy.drafts.indices {
            copy.drafts[index].card.attachmentIDs = try map(copy.drafts[index].card.attachmentIDs)
            copy.drafts[index].newAttachmentIDs = Set(try map(Array(copy.drafts[index].newAttachmentIDs)))
        }
        return copy
    }
}
public enum BackupError: Error, Sendable { case invalidArchive, unsupportedVersion, nonemptyLibrary, tooLarge }
public enum RestoreResult: Sendable, Equatable { case restored, alreadyImported }
public struct LibraryStorageSummary: Sendable {
    public let cards: Int, drafts: Int, photos: Int, catalogEntries: Int
    public var isEmpty: Bool { cards == 0 && drafts == 0 && catalogEntries == 0 }
    public init(cards: Int, drafts: Int, photos: Int, catalogEntries: Int) {
        self.cards = cards; self.drafts = drafts; self.photos = photos; self.catalogEntries = catalogEntries
    }
}
