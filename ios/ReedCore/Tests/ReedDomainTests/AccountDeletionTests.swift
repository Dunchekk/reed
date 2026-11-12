import Foundation
import Testing
import ReedDomain
import ReedApplication

private final class DeletionSessions: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: AuthSession?
    func load() throws -> AuthSession? { lock.withLock { value } }
    func save(_ session: AuthSession) throws { lock.withLock { value = session } }
    func clear() throws { lock.withLock { value = nil } }
}
private actor DeletionLocal: AccountLocalCleanup {
    var fails = false, stopped = false, cleared = false
    func setFailure(_ value: Bool) { fails = value }
    func prepareForDeletion() async throws { stopped = true }
    func stopAndClear() async throws { stopped = true; if fails { throw URLError(.cannotWriteToFile) }; cleared = true }
}
private actor DeletionClient: AccountManagementClient {
    var calls = 0
    var fails = false
    func setFailure(_ value: Bool) { fails = value }
    func deleteAccount(token: String) async throws { calls += 1; if fails { throw URLError(.timedOut) } }
    func profile(token: String) async throws -> AccountProfile { throw URLError(.unsupportedURL) }
    func requestContact(token: String, kind: ContactKind, value: String) async throws -> CodeRequest { throw URLError(.unsupportedURL) }
    func verifyContact(token: String, kind: ContactKind, code: String) async throws -> ContactConfirmation { throw URLError(.unsupportedURL) }
    func requestRecovery(email: String) async throws -> CodeRequest { throw URLError(.unsupportedURL) }
    func verifyRecovery(email: String, code: String) async throws -> AuthSession { throw URLError(.unsupportedURL) }
}
private func deletionSession() throws -> AuthSession {
    AuthSession(account: Account(id: UUID(),phone: try PhoneNumber("+70000000001")),accessToken:"access",refreshToken:"refresh",expiresAt:Date().addingTimeInterval(3600))
}
@Test func acceptedDeletionResumesLocalCleanupWithoutRepeatingRemoteDelete() async throws {
    let sessions = DeletionSessions(), local = DeletionLocal(), client = DeletionClient()
    let service = AccountDeletionService(client: client,sessions:sessions,local:local)
    await local.setFailure(true)
    await #expect(throws: (any Error).self) { try await service.delete(deletionSession()) }
    let pending = try #require(try sessions.load())
    #expect(pending.deletionProgress == .accepted)
    #expect(await local.stopped)
    await local.setFailure(false)
    try await service.delete(pending)
    #expect(await client.calls == 1)
    #expect(await local.cleared)
    #expect(try sessions.load() == nil)
}
@Test func timedOutDeletionPersistsUnconfirmedIntentWithoutClearingLibrary() async throws {
    let sessions = DeletionSessions(), local = DeletionLocal(), client = DeletionClient()
    await client.setFailure(true)
    let service = AccountDeletionService(client:client,sessions:sessions,local:local)
    await #expect(throws: (any Error).self) { try await service.delete(deletionSession()) }
    #expect(try sessions.load()?.deletionProgress == .requested)
    #expect(await local.stopped)
    #expect(await local.cleared == false)
    try await service.finishLocal()
    #expect(await local.cleared)
    #expect(try sessions.load() == nil)
}
