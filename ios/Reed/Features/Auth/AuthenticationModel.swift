import Foundation
import Observation
import ReedApplication
import ReedDomain

@MainActor @Observable
final class AuthenticationModel {
    var phoneInput = "+7"
    var codeInput = ""
    private(set) var requestedPhone: PhoneNumber?
    private(set) var retryAt = Date.distantPast
    private(set) var session: AuthSession?
    private(set) var isWorking = false
    private(set) var isRestored = false
    private(set) var errorMessage: String?
    private(set) var serverNeedsSignIn = false
    @ObservationIgnored private let client: (any AuthenticationClient)?
    @ObservationIgnored private let store: any SessionStore
    @ObservationIgnored private let tokens: SessionTokenProvider?
    @ObservationIgnored private var generation = UUID()

    init(client: (any AuthenticationClient)?, store: any SessionStore, tokens: SessionTokenProvider? = nil) {
        self.client = client
        self.store = store
        self.tokens = tokens ?? client.map { SessionTokenProvider(store: store, client: $0) }
    }

    var accountClient: (any AccountManagementClient)? { client as? any AccountManagementClient }
    var isConfigured: Bool { client != nil }
    var account: Account? { session?.account }

    func restore() {
        do {
            session = try store.load()
            isRestored = true
            errorMessage = nil
            serverNeedsSignIn = session.map { $0.expiresAt <= Date() } ?? false
        } catch {
            errorMessage = "Не удалось прочитать сохранённый вход. Попробуйте ещё раз."
        }
    }

    func accept(_ newSession: AuthSession) throws {
        try store.save(newSession)
        session = newSession; serverNeedsSignIn = false; errorMessage = nil
    }
    func updateAccount(_ account: Account) throws {
        guard let latest = try store.load(), latest.account.id == account.id, session?.account.id == account.id else { throw LibraryError.conflict }
        try accept(latest.withAccount(account))
    }
    func accessToken() async throws -> String {
        guard let current = session, let tokens else { throw URLError(.userAuthenticationRequired) }
        let expected = generation
        let refreshed = try await tokens.session(accountID: current.account.id)
        guard generation == expected, session?.account.id == current.account.id else { throw CloudError.wrongAccount }
        session = refreshed; serverNeedsSignIn = false
        return refreshed.accessToken
    }
    func deleteAccount(local: any AccountLocalCleanup, onlyLocal: Bool = false) async throws {
        guard !isWorking, let session else { throw URLError(.userAuthenticationRequired) }
        generation = UUID(); isWorking = true
        defer { isWorking = false }
        do {
            if onlyLocal || session.deletionProgress == .accepted {
                try await AccountDeletionService.finishLocal(sessions: store, local: local)
            } else {
                guard let accountClient, let client else { throw URLError(.unsupportedURL) }
                let expected = generation
                let current: AuthSession
                if session.deletionProgress == nil, let tokens { current = try await tokens.session(accountID: session.account.id) }
                else { current = session }
                guard generation == expected, self.session?.account.id == current.account.id else { throw CloudError.wrongAccount }
                try await AccountDeletionService(client: accountClient, authentication: client, sessions: store, local: local).delete(current)
            }
            BackgroundReturnRefresh.shared.cancel(); LibrarySessionController.shared.forget()
            self.session = nil; requestedPhone = nil; codeInput = ""; errorMessage = nil
        } catch {
            // Re-read the durable phase even when the network/local cleanup failed.
            if let recorded = try? store.load() { self.session = recorded }
            throw error
        }
    }

    func requestCode() async {
        guard !isWorking, let client else { return }
        await perform {
            let phone = try PhoneNumber(self.phoneInput)
            let response = try await client.requestCode(phone: phone)
            return { self.requestedPhone = phone; self.retryAt = response.retryAt; self.codeInput = "" }
        }
    }

    func verifyCode() async {
        guard !isWorking, let client, let phone = requestedPhone else { return }
        let code = codeInput
        await perform {
            let session = try await client.verifyCode(phone: phone, code: code)
            return {
                try self.store.save(session)
                self.session = session
                self.serverNeedsSignIn = false
                self.codeInput = ""
            }
        }
    }

    func changePhone() {
        guard !isWorking else { return }
        requestedPhone = nil
        codeInput = ""
        errorMessage = nil
    }

    func refreshIfNeeded() async {
        guard !isWorking, let current = session, current.deletionProgress == nil, let tokens else { return }
        let expectedGeneration = generation
        isWorking = true
        defer { if generation == expectedGeneration { isWorking = false } }
        do {
            let refreshed = try await tokens.session(accountID: current.account.id)
            guard generation == expectedGeneration, refreshed.account.id == current.account.id else { return }
            session = refreshed
            serverNeedsSignIn = false
        } catch {
            guard generation == expectedGeneration else { return }
            // Local data remains available after server expiry or a network failure.
            serverNeedsSignIn = true
        }
    }

    func signOut() async {
        let token = session?.accessToken
        do { try store.clear() }
        catch { errorMessage = "Не удалось завершить вход на устройстве. Попробуйте ещё раз."; return }
        BackgroundReturnRefresh.shared.cancel()
        LibrarySessionController.shared.forget()
        generation = UUID()
        session = nil
        requestedPhone = nil
        codeInput = ""
        isWorking = false
        errorMessage = nil
        if let token, let client { try? await client.revoke(token: token) }
    }

    private func perform(_ operation: () async throws -> () throws -> Void) async {
        let expectedGeneration = generation
        isWorking = true
        errorMessage = nil
        defer { if generation == expectedGeneration { isWorking = false } }
        do {
            let apply = try await operation()
            guard generation == expectedGeneration else { return }
            try apply()
        } catch {
            guard generation == expectedGeneration else { return }
            if let error = error as? APIError {
                errorMessage = error.message
                if let retryAt = error.retryAt { self.retryAt = retryAt }
            } else if error is ValidationError {
                errorMessage = "Введите номер +7 и десять цифр."
            } else if error is URLError {
                errorMessage = "Не удалось связаться с сервером. Проверьте интернет и попробуйте снова."
            } else {
                errorMessage = "Не удалось сохранить вход. Попробуйте ещё раз."
            }
        }
    }
}
