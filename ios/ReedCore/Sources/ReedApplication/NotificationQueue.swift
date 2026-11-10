import Foundation
import ReedDomain

public enum NotificationPermission: Sendable { case notDetermined, allowed, denied }
public struct QueuedNotification: Sendable {
    public let id: String
    public let revision: UUID?
    public init(id: String, revision: UUID?) { self.id = id; self.revision = revision }
}
public struct CardNotification: Sendable {
    public let id: String
    public let accountID: UUID
    public let entry: PlannedReturn
    public init(accountID: UUID, entry: PlannedReturn) {
        self.accountID = accountID; self.entry = entry; id = "reed.\(accountID.uuidString).\(entry.id)"
    }
}
public protocol CardNotificationQueue: Sendable {
    func permission() async -> NotificationPermission
    func requestPermission() async throws -> Bool
    func pending() async -> [QueuedNotification]
    func add(_ notification: CardNotification) async throws
    func remove(ids: [String]) async throws
    func clear() async throws
}
public struct NotificationQueueReport: Sendable {
    public let count: Int
    public let until: Date?
    public let failures: Int
    public init(count: Int, until: Date?, failures: Int) { self.count = count; self.until = until; self.failures = failures }
}
