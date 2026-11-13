import Foundation
import ReedDomain

public protocol AccountTokenProvider: Sendable {
    func token(accountID: UUID, rejectedToken: String?) async throws -> String
}

/// All foreground/background consumers share refresh. A response cannot restore a signed-out session.
public actor SessionTokenProvider: AccountTokenProvider {
    private let store: any SessionStore
    private let client: any AuthenticationClient
    private var refreshing: (id: UUID, accountID: UUID, token: String, task: Task<AuthSession, Error>)?
    public init(store: any SessionStore, client: any AuthenticationClient) { self.store = store; self.client = client }

    public func token(accountID: UUID, rejectedToken: String? = nil) async throws -> String {
        try await session(accountID: accountID, rejectedToken: rejectedToken).accessToken
    }
    public func session(accountID: UUID, rejectedToken: String? = nil) async throws -> AuthSession {
        guard let current = try store.load(), current.deletionProgress == nil else { throw URLError(.userAuthenticationRequired) }
        guard current.account.id == accountID else { throw CloudError.wrongAccount }
        if current.expiresAt.timeIntervalSinceNow >= 60 && current.accessToken != rejectedToken { return current }
        let operation: (id: UUID, accountID: UUID, token: String, task: Task<AuthSession, Error>)
        if let refreshing, refreshing.accountID == accountID, refreshing.token == current.refreshToken { operation = refreshing }
        else {
            let client = client
            operation = (UUID(),accountID,current.refreshToken,Task { try await client.refresh(token: current.refreshToken) })
            refreshing = operation
        }
        defer { if refreshing?.id == operation.id { refreshing = nil } }
        let refreshed = try await operation.task.value
        guard refreshed.account.id == accountID,
              let latest = try store.load(), latest.account.id == accountID,
              latest.deletionProgress == nil else { throw CloudError.wrongAccount }
        // Another accepted login/contact update takes precedence over this request's snapshot.
        if latest.refreshToken != current.refreshToken { return latest }
        let result = latest.account == current.account ? refreshed : refreshed.withAccount(latest.account)
        try store.save(result)
        return result
    }
}
