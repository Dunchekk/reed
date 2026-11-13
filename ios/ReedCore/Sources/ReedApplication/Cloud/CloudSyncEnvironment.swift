import Foundation
import ReedDomain

public struct CloudProgress: Equatable, Sendable {
    public enum Phase: String, Sendable { case idle, preparing, pulling, pushing, uploading, downloading, finishing, conflicts, failed }
    public let phase: Phase
    public let completed: Int64
    public let total: Int64?
    public let error: CloudError?
    public init(_ phase: Phase, completed: Int64 = 0, total: Int64? = nil, error: CloudError? = nil) {
        self.phase = phase; self.completed = completed; self.total = total; self.error = error
    }
}
public typealias CloudProgressHandler = @Sendable (CloudProgress) async -> Void

public protocol CloudMediaTransferring: Sendable {
    func upload(epoch: UUID, id: UUID, progress: CloudProgressHandler) async throws
    func download(epoch: UUID, id: UUID, progress: CloudProgressHandler) async throws
    func verifyLocal(ids: [UUID]) async throws
}
public protocol CloudNetworkPolicy: Sendable {
    func allowsTransfer(wifiOnly: Bool) async -> Bool
}
/// Platform owns device identity, APNs token, and local notification lifecycle.
public protocol CloudParticipation: Sendable {
    func synchronizationCompleted(epoch: UUID) async throws
    func prepareJoin() async throws
    func refreshRegistration() async throws
    func leave() async throws
    func suspendLocalNotifications() async throws
    func resumeLocalNotifications() async throws
}

public extension CloudParticipation { func synchronizationCompleted(epoch: UUID) async throws {} }
