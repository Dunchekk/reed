import Foundation
import Observation
import ReedDomain
import ReedApplication

@MainActor @Observable
final class AccountSettingsModel {
    private(set) var profile: AccountProfile?
    private(set) var working = false
    private(set) var errorMessage: String?
    @ObservationIgnored let authentication: AuthenticationModel
    @ObservationIgnored private let context: LibraryContext
    init(authentication: AuthenticationModel, context: LibraryContext) { self.authentication = authentication; self.context = context }
    func load() async {
        await perform {
            guard let client = self.authentication.accountClient else { throw URLError(.unsupportedURL) }
            let value = try await client.profile(token: self.authentication.accessToken())
            try self.authentication.updateAccount(value.account)
            self.profile = value
        }
    }
    func delete() async {
        await perform {
            _ = try await self.authentication.accessToken()
            try await self.authentication.deleteAccount(local: self.context)
        }
    }
    private func perform(_ work: () async throws -> Void) async {
        guard !working else { return }; working = true; errorMessage = nil
        defer { working = false }
        do { try await work() } catch { errorMessage = accountErrorMessage(error) }
    }
}

@MainActor @Observable
final class ContactChangeModel {
    var value = ""
    var code = ""
    private(set) var requested = false
    private(set) var confirmed = false
    private(set) var retryAt = Date.distantPast
    private(set) var working = false
    private(set) var message: String?
    private(set) var errorMessage: String?
    let kind: ContactKind
    @ObservationIgnored private let authentication: AuthenticationModel
    init(kind: ContactKind, authentication: AuthenticationModel) { self.kind = kind; self.authentication = authentication }
    func request() async {
        await perform { client, token in
            let normalized = self.kind == .phone ? try PhoneNumber(self.value).value : self.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let response = try await client.requestContact(token: token, kind: self.kind, value: normalized)
            self.value = normalized; self.retryAt = response.retryAt; self.requested = true; self.code = ""
            self.message = self.kind == .phone ? "Введите код, отправленный на новый номер." : "Введите код из письма. При замене почты может потребоваться подтверждение со старого и нового адреса."
        }
    }
    func verify() async {
        await perform { client, token in
            let result = try await client.verifyContact(token: token, kind: self.kind, code: self.code)
            try self.authentication.updateAccount(result.account)
            self.confirmed = result.confirmed; self.code = ""
            self.message = result.confirmed ? "Контакт подтверждён. Библиотека сохранена." : "Первый код принят. Теперь введите код из второго письма."
        }
    }
    func reset() { guard !working else { return }; requested = false; confirmed = false; code = ""; message = nil; errorMessage = nil }
    private func perform(_ work: (any AccountManagementClient, String) async throws -> Void) async {
        guard !working else { return }; working = true; errorMessage = nil
        defer { working = false }
        do {
            guard let client = authentication.accountClient else { throw URLError(.unsupportedURL) }
            try await work(client, authentication.accessToken())
        } catch {
            errorMessage = accountErrorMessage(error)
            if let retry = (error as? APIError)?.retryAt { retryAt = retry }
        }
    }
}

func accountErrorMessage(_ error: any Error) -> String {
    if let error = error as? APIError { return error.message }
    if error is ValidationError { return "Введите номер +7 и десять цифр." }
    if let error = error as? URLError, error.code == .userAuthenticationRequired { return "Нужен действующий вход. Выйдите и войдите снова; локальная библиотека сохранится." }
    return "Операция не завершена. Проверьте соединение и повторите попытку."
}
