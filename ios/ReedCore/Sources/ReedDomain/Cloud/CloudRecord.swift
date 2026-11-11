import Foundation

public enum CloudRecordKind: String, Codable, CaseIterable, Sendable {
    case author, source, folder, tag, card, returnSettings, cardReturn, opening, historyPreference, returnHistory
    public var title: String {
        switch self {
        case .author: "Автор"
        case .source: "Источник"
        case .folder: "Папка"
        case .tag: "Тег"
        case .card: "Карточка"
        case .returnSettings, .cardReturn: "Возвращения"
        case .opening, .historyPreference: "История"
        case .returnHistory: "План возвращений"
        }
    }
}
public struct CloudKey: Codable, Hashable, Sendable {
    public let kind: CloudRecordKind
    public let id: String
    public init(_ kind: CloudRecordKind, _ id: String) { self.kind = kind; self.id = id.lowercased() }
    public init(_ kind: CloudRecordKind, _ id: UUID) { self.init(kind, id.uuidString) }
    public static let returns = CloudKey(.returnSettings, "global")
    public static let history = CloudKey(.historyPreference, "global")
}
public struct CloudRecord: Codable, Equatable, Sendable {
    public let kind: CloudRecordKind
    public let id: String
    public let version: Int64
    public let sequence: Int64
    public let payload: CloudValue
    public var key: CloudKey { CloudKey(kind,id) }
    public var isDeleted: Bool { payload == .null }
    public init(key: CloudKey, version: Int64, sequence: Int64, payload: CloudValue) {
        kind = key.kind; id = key.id; self.version = version; self.sequence = sequence; self.payload = payload
    }
}
public struct CloudCard: Codable, Equatable, Sendable {
    public var id: UUID
    public var text: String, title: String, comment: String, page: String
    public var sourceID: UUID?, folderID: UUID?
    public var tagIDs: [UUID], attachmentIDs: [UUID]
    public var createdAt: Date, updatedAt: Date
    public var isFavorite: Bool, isHidden: Bool, allowsReturns: Bool
    public var deletedAt: Date?
    public init(_ card: Card) {
        id = card.id; text = card.text; title = card.title; comment = card.comment; page = card.page
        sourceID = card.source?.id; folderID = card.folder?.id; tagIDs = card.tags.map(\.id); attachmentIDs = card.attachmentIDs
        createdAt = card.createdAt; updatedAt = card.updatedAt; isFavorite = card.isFavorite
        isHidden = card.isHidden; allowsReturns = card.allowsReturns; deletedAt = card.deletedAt
    }
    public func validate() throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 2_000_000,
              Set(tagIDs).count == tagIDs.count, Set(attachmentIDs).count == attachmentIDs.count,
              tagIDs.count <= 100, attachmentIDs.count <= 100,
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite else { throw CloudError.invalidRecord }
    }
}
public struct CloudSource: Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var authorIDs: [UUID]
    public var url: String?
    public init(_ source: Source) { id = source.id; title = source.title; authorIDs = source.authors.map(\.id); url = source.url }
}
public struct CloudOpening: Codable, Equatable, Sendable {
    public let id: UUID, cardID: UUID
    public let date: Date
    public let origin: OpeningOrigin
    public init(id: UUID, cardID: UUID, date: Date, origin: OpeningOrigin) { self.id = id; self.cardID = cardID; self.date = date; self.origin = origin }
}
public struct CloudHistoryPreference: Codable, Equatable, Sendable {
    public var enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}
public struct CloudReturnHistory: Codable, Equatable, Sendable {
    public let slot: ReturnTimeSlot
    public let decision: ReturnDecision
    public init(slot: ReturnTimeSlot, decision: ReturnDecision) { self.slot = slot; self.decision = decision }
}
