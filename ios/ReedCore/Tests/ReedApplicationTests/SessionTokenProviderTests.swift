import Foundation
import Testing
import ReedDomain
import ReedApplication

private final class TokenTestStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: AuthSession?
    init(_ value: AuthSession) { self.value = value }
    func load() -> AuthSession? { lock.withLock { value } }
    func save(_ session: AuthSession) { lock.withLock { value = session } }
    func clear() { lock.withLock { value = nil } }
}
private actor SuspendedRefreshClient: AuthenticationClient {
    let result: AuthSession
    var count = 0
    var continuation: CheckedContinuation<AuthSession, any Error>?
    var started: CheckedContinuation<Void,Never>?
    init(_ result: AuthSession) { self.result = result }
    func waitUntilStarted() async { if count == 0 { await withCheckedContinuation { started = $0 } } }
    func finish() { continuation?.resume(returning: result); continuation = nil }
    func refresh(token: String) async throws -> AuthSession {
        count += 1; started?.resume(); started = nil
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func requestCode(phone: PhoneNumber) throws -> CodeRequest { throw CloudError.unavailable }
    func verifyCode(phone: PhoneNumber, code: String) throws -> AuthSession { throw CloudError.unavailable }
    func revoke(token: String) {}
}

@Test func tokenRefreshCannotRestoreAnAccountAfterLocalSignOut() async throws {
    let account = Account(id: UUID(), phone: try PhoneNumber("+70000000001"))
    let old = AuthSession(account: account, accessToken: "old", refreshToken: "old-refresh", expiresAt: .distantPast)
    let new = AuthSession(account: account, accessToken: "new", refreshToken: "new-refresh", expiresAt: .distantFuture)
    let store = TokenTestStore(old), client = SuspendedRefreshClient(new), tokens = SessionTokenProvider(store: store, client: client)
    let request = Task { try await tokens.token(accountID: account.id) }
    await client.waitUntilStarted(); store.clear(); await client.finish()
    await #expect(throws: CloudError.wrongAccount) { _ = try await request.value }
    #expect(store.load() == nil)
}

@Test func tokenProviderUsesAlreadyRefreshedCredentialsAndRejectsAnotherAccount() async throws {
    let account = Account(id: UUID(), phone: try PhoneNumber("+70000000001"))
    let current = AuthSession(account: account, accessToken: "new", refreshToken: "refresh", expiresAt: .distantFuture)
    let store = TokenTestStore(current), client = SuspendedRefreshClient(current), tokens = SessionTokenProvider(store: store, client: client)
    #expect(try await tokens.token(accountID: account.id, rejectedToken: "old") == "new")
    #expect(await client.count == 0)
    await #expect(throws: CloudError.wrongAccount) { _ = try await tokens.token(accountID: UUID()) }
}
