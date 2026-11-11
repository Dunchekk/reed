import Foundation
import ReedDomain

public struct CloudMutation: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let kind: CloudRecordKind
    public let id: String
    public let baseVersion: Int64
    public let payload: CloudValue
    public var key: CloudKey { CloudKey(kind,id) }
    public init(operationID: UUID = UUID(), key: CloudKey, baseVersion: Int64, payload: CloudValue) {
        self.operationID = operationID; kind = key.kind; id = key.id; self.baseVersion = baseVersion; self.payload = payload
    }
}
public struct CloudPending: Codable, Equatable, Sendable {
    public let mutation: CloudMutation
    public let generation: Int64
    public init(mutation: CloudMutation, generation: Int64) { self.mutation = mutation; self.generation = generation }
}
public struct CloudMutationResult: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case applied, conflict }
    public let outcome: Outcome
    public let record: CloudRecord
    public init(outcome: Outcome, record: CloudRecord) { self.outcome = outcome; self.record = record }
}
public struct CloudPage: Codable, Sendable {
    public let epoch: UUID
    public let records: [CloudRecord]
    public let cursor: Int64
    public let hasMore: Bool
    public init(epoch: UUID, records: [CloudRecord], cursor: Int64, hasMore: Bool) { self.epoch = epoch; self.records = records; self.cursor = cursor; self.hasMore = hasMore }
}
public struct CloudSummary: Codable, Sendable {
    public let epoch: UUID
    public let cards: Int
    public let mediaBytes: Int64
    public let sequence: Int64
    public let notificationsAvailable: Bool
    public init(epoch: UUID, cards: Int, mediaBytes: Int64, sequence: Int64, notificationsAvailable: Bool) {
        self.epoch = epoch; self.cards = cards; self.mediaBytes = mediaBytes; self.sequence = sequence; self.notificationsAvailable = notificationsAvailable
    }
}
public struct CloudLocalSummary: Sendable {
    public let cards: Int, pending: Int, conflicts: Int
    public init(cards: Int, pending: Int, conflicts: Int) { self.cards = cards; self.pending = pending; self.conflicts = conflicts }
}
public protocol CloudRepository: Sendable {
    func state() async throws -> CloudState
    func configure(automatic: Bool, wifiOnly: Bool) async throws
    func begin(epoch: UUID) async throws
    func setMode(_ mode: CloudMode) async throws
    func summary() async throws -> CloudLocalSummary
    func nextPending() async throws -> CloudPending?
    func acknowledge(_ pending: CloudPending, result: CloudMutationResult) async throws
    func apply(_ page: CloudPage) async throws
    func conflicts() async throws -> [CloudConflict]
    func resolve(id: UUID, choice: CloudResolution) async throws
    func mediaToDownload() async throws -> [UUID]
    func markMediaAvailable(id: UUID) async throws
    func completed(at date: Date) async throws
    func disconnect() async throws
}
public protocol CloudRemote: Sendable {
    func summary() async throws -> CloudSummary
    func push(epoch: UUID, mutation: CloudMutation) async throws -> CloudMutationResult
    func pull(epoch: UUID, after: Int64, limit: Int) async throws -> CloudPage
    func reset(epoch: UUID) async throws -> CloudSummary
}
