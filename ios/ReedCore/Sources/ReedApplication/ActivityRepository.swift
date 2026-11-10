import Foundation
import ReedDomain

public protocol ActivityRepository: Sendable {
    func activity(now: Date) async throws -> ActivitySnapshot
    func setHistoryEnabled(_ enabled: Bool) async throws
    func clearOpenings() async throws
    func recordOpening(cardID: UUID, origin: OpeningOrigin, now: Date) async throws
}
