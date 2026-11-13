import Foundation
import ReedDomain

public struct CloudReturnPlan: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let slot: ReturnTimeSlot, decision: ReturnDecision, revision: UUID
        public init(slot: ReturnTimeSlot, decision: ReturnDecision, revision: UUID) { self.slot = slot; self.decision = decision; self.revision = revision }
    }
    public let epoch: UUID, sequence: Int64, timeZone: String, issue: ReturnPlanIssue?, entries: [Entry]
    public init(epoch: UUID, sequence: Int64, timeZone: String, issue: ReturnPlanIssue?, entries: [Entry]) {
        self.epoch = epoch; self.sequence = sequence; self.timeZone = timeZone; self.issue = issue; self.entries = entries
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
