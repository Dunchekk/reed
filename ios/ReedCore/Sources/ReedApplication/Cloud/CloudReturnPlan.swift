import Foundation
import ReedDomain

public struct CloudReturnPlan: Codable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let slot: ReturnTimeSlot, decision: ReturnDecision, revision: UUID
        public init(slot: ReturnTimeSlot, decision: ReturnDecision, revision: UUID) { self.slot = slot; self.decision = decision; self.revision = revision }
    }
    public let epoch: UUID, sequence: Int64, timeZone: String, issue: ReturnPlanIssue?, entries: [Entry]
    public let history: [Entry]
    public let snapshotAt: Date?
    public init(epoch: UUID, sequence: Int64, timeZone: String, issue: ReturnPlanIssue?, entries: [Entry], history: [Entry] = [], snapshotAt: Date? = Date()) {
        self.epoch = epoch; self.sequence = sequence; self.timeZone = timeZone; self.issue = issue; self.entries = entries; self.history = history; self.snapshotAt = snapshotAt
    }
    private enum CodingKeys: String, CodingKey { case epoch, sequence, timeZone, issue, entries, history, snapshotAt }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        epoch = try container.decode(UUID.self, forKey: .epoch); sequence = try container.decode(Int64.self, forKey: .sequence)
        timeZone = try container.decode(String.self, forKey: .timeZone); issue = try container.decodeIfPresent(ReturnPlanIssue.self, forKey: .issue)
        entries = try container.decode([Entry].self, forKey: .entries)
        history = try container.decodeIfPresent([Entry].self, forKey: .history) ?? []
        snapshotAt = try container.decodeIfPresent(Date.self, forKey: .snapshotAt)
    }

}
public protocol CloudReturnRemote: Sendable { func returnPlan(epoch: UUID) async throws -> CloudReturnPlan }
public protocol CloudReturnProjection: Sendable { func applyReturnPlan(_ plan: CloudReturnPlan, now: Date) async throws }
public protocol CloudPlanSynchronizing: Sendable { func synchronize(epoch: UUID) async throws }
public struct CloudPlanSynchronizer: CloudPlanSynchronizing {
    private let remote: any CloudReturnRemote
    private let local: any CloudReturnProjection
    public init(remote: any CloudReturnRemote, local: any CloudReturnProjection) { self.remote = remote; self.local = local }
    public func synchronize(epoch: UUID) async throws { try await local.applyReturnPlan(remote.returnPlan(epoch: epoch), now: Date()) }
}
