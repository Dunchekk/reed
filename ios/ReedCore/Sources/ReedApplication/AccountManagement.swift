import Foundation
import ReedDomain

public enum ContactKind: String, Sendable, CaseIterable { case phone, email }
public struct AccountProfile: Decodable, Sendable {
    public let account: Account
    public let deletionAvailable: Bool
    public init(account: Account, deletionAvailable: Bool) { self.account = account; self.deletionAvailable = deletionAvailable }
}
public struct ContactConfirmation: Decodable, Sendable {
    public let account: Account
    public let confirmed: Bool
    public init(account: Account, confirmed: Bool) { self.account = account; self.confirmed = confirmed }
}
public protocol AccountManagementClient: Sendable {
    func profile(token: String) async throws -> AccountProfile
    func requestContact(token: String, kind: ContactKind, value: String) async throws -> CodeRequest
    func verifyContact(token: String, kind: ContactKind, code: String) async throws -> ContactConfirmation
    func requestRecovery(email: String) async throws -> CodeRequest
    func verifyRecovery(email: String, code: String) async throws -> AuthSession
    func deleteAccount(token: String) async throws
}
public enum AccountDeletionProgress: String, Codable, Sendable { case requested, accepted }
public protocol AccountLocalCleanup: Sendable {
    func prepareForDeletion() async throws
    func stopAndClear() async throws
}

/// A persisted journal keeps a failed/unfinished deletion out of the ordinary library UI.
/// A network timeout never counts as acceptance by the server.
public struct AccountDeletionService: Sendable {
    private let client: any AccountManagementClient
    private let authentication: any AuthenticationClient
    private let sessions: any SessionStore
    private let local: any AccountLocalCleanup
    public init(client: any AccountManagementClient, authentication: any AuthenticationClient, sessions: any SessionStore, local: any AccountLocalCleanup) {
        self.client = client; self.authentication = authentication; self.sessions = sessions; self.local = local
    }
    public func delete(_ session: AuthSession) async throws {
        var current = session
        if current.deletionProgress != .accepted {
            if current.expiresAt.timeIntervalSinceNow < 60 {
                let refreshed = try await authentication.refresh(token: current.refreshToken)
                guard refreshed.account.id == current.account.id else { throw LibraryError.conflict }
                current = refreshed
                if let progress = session.deletionProgress { current = current.withDeletionProgress(progress) }
                try sessions.save(current)
            }
            try sessions.save(current.withDeletionProgress(.requested))
            try await local.prepareForDeletion()
            try await client.deleteAccount(token: current.accessToken)
            try sessions.save(current.withDeletionProgress(.accepted))
        }
        try await finishLocal()
    }
    /// Explicit escape hatch after an unconfirmed remote request; does not claim remote deletion.
    public func finishLocal() async throws { try await Self.finishLocal(sessions: sessions, local: local) }
    public static func finishLocal(sessions: any SessionStore, local: any AccountLocalCleanup) async throws {
        try await local.stopAndClear()
        try sessions.clear()
    }
}
public extension AuthSession {
    func withAccount(_ account: Account) -> AuthSession {
        AuthSession(account: account, accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, deletionProgress: deletionProgress)
    }
    func withDeletionProgress(_ progress: AccountDeletionProgress) -> AuthSession {
        AuthSession(account: account, accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, deletionProgress: progress)
    }
}
