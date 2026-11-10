import Foundation
import ReedDomain

public protocol FeedRepository: Sendable {
    func enabledGroups() async throws -> Set<FeedKind>
    func setEnabledGroups(_ kinds: Set<FeedKind>) async throws
    func feed(now: Date, calendar: Calendar) async throws -> [FeedSection]
}
