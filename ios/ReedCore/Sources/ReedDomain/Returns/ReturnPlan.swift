import Foundation

public enum ReturnDeliveryState: String, Codable, Sendable { case planned, queued, cancelled }
public struct PlannedReturn: Sendable, Identifiable {
    public var id: String { slot.id }
    public let slot: ReturnTimeSlot
    public let decision: ReturnDecision
    public let card: CardSummary?
    public let state: ReturnDeliveryState
    public let revision: UUID
    public init(slot: ReturnTimeSlot, decision: ReturnDecision, card: CardSummary?, state: ReturnDeliveryState, revision: UUID) {
        self.slot = slot; self.decision = decision; self.card = card; self.state = state; self.revision = revision
    }
}
public struct ReturnPlan: Sendable {
    public let entries: [PlannedReturn]
    public let horizon: Date?
    public init(entries: [PlannedReturn], horizon: Date?) { self.entries = entries; self.horizon = horizon }
}
