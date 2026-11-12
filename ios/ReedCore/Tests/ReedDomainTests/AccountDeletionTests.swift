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
private actor DeletionClient: AccountManagementClient, AuthenticationClient {
    var refreshResult: AuthSession?
    var refreshed = 0
    var usedTokens: [String] = []
    func setRefresh(_ session: AuthSession) { refreshResult = session }
    var calls = 0
    var fails = false
    func setFailure(_ value: Bool) { fails = value }
    func deleteAccount(token: String) async throws { calls += 1; usedTokens.append(token); if fails { throw URLError(.timedOut) } }
    func requestCode(phone: PhoneNumber) async throws -> CodeRequest { throw URLError(.unsupportedURL) }
    func verifyCode(phone: PhoneNumber, code: String) async throws -> AuthSession { throw URLError(.unsupportedURL) }
    func revoke(token: String) async throws {}
    func refresh(token: String) async throws -> AuthSession {
        refreshed += 1
        guard let refreshResult else { throw URLError(.userAuthenticationRequired) }
        return refreshResult
    }
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
    let service = AccountDeletionService(client: client,authentication: client,sessions:sessions,local:local)
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
    let service = AccountDeletionService(client:client,authentication:client,sessions:sessions,local:local)
    await #expect(throws: (any Error).self) { try await service.delete(deletionSession()) }
    #expect(try sessions.load()?.deletionProgress == .requested)
    #expect(await local.stopped)
    #expect(await local.cleared == false)
    try await service.finishLocal()
    #expect(await local.cleared)
    #expect(try sessions.load() == nil)
}

@Test func unconfirmedDeletionRefreshesExpiredCredentialsAndPreservesItsJournal() async throws {
    let sessions = DeletionSessions(), local = DeletionLocal(), client = DeletionClient()
    let initial = try deletionSession()
    let service = AccountDeletionService(client:client,authentication:client,sessions:sessions,local:local)
    await client.setFailure(true)
    await #expect(throws: (any Error).self) { try await service.delete(initial) }
    let expired = AuthSession(account:initial.account,accessToken:"expired",refreshToken:"refresh",expiresAt:.distantPast,deletionProgress:.requested)
    try sessions.save(expired)
    await client.setRefresh(AuthSession(account:initial.account,accessToken:"renewed",refreshToken:"rotated",expiresAt:Date().addingTimeInterval(3600)))
    // Another timeout after refresh must retain both the phase and rotated credentials.
    await #expect(throws: (any Error).self) { try await service.delete(expired) }
    let pending = try #require(try sessions.load())
    #expect(pending.deletionProgress == .requested); #expect(pending.refreshToken == "rotated")
    await client.setFailure(false)
    try await service.delete(pending)
    #expect(await client.refreshed == 1)
    #expect(await client.usedTokens == ["access","renewed","renewed"])
    #expect(try sessions.load() == nil); #expect(await local.cleared)
}

@Test func deletionRejectsRefreshIntoAnotherAccount() async throws {
    let sessions = DeletionSessions(), local = DeletionLocal(), client = DeletionClient()
    let initial = try deletionSession()
    let expired = AuthSession(account:initial.account,accessToken:"expired",refreshToken:"refresh",expiresAt:.distantPast,deletionProgress:.requested)
    try sessions.save(expired)
    await client.setRefresh(try deletionSession())
    let service = AccountDeletionService(client:client,authentication:client,sessions:sessions,local:local)
    await #expect(throws: LibraryError.conflict) { try await service.delete(expired) }
    #expect(try sessions.load() == expired)
    #expect(await client.calls == 0); #expect(await local.cleared == false)
}
