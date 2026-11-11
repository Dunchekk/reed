import Foundation
import ReedDomain

public protocol DraftRepository: Sendable {
    func drafts() async throws -> [DraftSummary]
    func draft(id: UUID) async throws -> CardDraft?
    func saveDraft(_ draft: CardDraft) async throws
    func discardDraft(id: UUID) async throws
    /// Publishes and closes the draft in one database transaction.
    func publishDraft(id: UUID, card: Card) async throws
}
