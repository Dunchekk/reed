import SwiftUI
import Observation
import ReedApplication

@MainActor @Observable final class RecoveryModel {
    var email = ""
    var code = ""
    private(set) var requestedEmail: String?
    private(set) var working = false
    private(set) var retryAt = Date.distantPast
    private(set) var errorMessage: String?
    @ObservationIgnored private let authentication: AuthenticationModel
    init(authentication: AuthenticationModel) { self.authentication = authentication }
    func request() async {
        await perform { client in
            let value = self.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let response = try await client.requestRecovery(email: value)
            self.requestedEmail = value; self.retryAt = response.retryAt; self.code = ""
        }
    }
    func verify() async {
        guard let email = requestedEmail else { return }
        await perform { client in try self.authentication.accept(await client.verifyRecovery(email: email, code: self.code)) }
    }
    func reset() { guard !working else { return }; requestedEmail = nil; code = ""; errorMessage = nil }
    private func perform(_ work: (any AccountManagementClient) async throws -> Void) async {
        guard !working else { return }; working = true; errorMessage = nil
        defer { working = false }
        do {
            guard let client = authentication.accountClient else { throw URLError(.unsupportedURL) }
            try await work(client)
        } catch {
            errorMessage = accountErrorMessage(error)
            if let retry = (error as? APIError)?.retryAt { retryAt = retry }
        }
    }
}
struct RecoveryView: View {
    @State private var model: RecoveryModel
    init(authentication: AuthenticationModel) { _model = State(initialValue: RecoveryModel(authentication: authentication)) }
    var body: some View {
        Form {
            Section {
                Text("Введите резервную почту, которую ранее подтвердили в Настройках. Вход откроет ту же локальную библиотеку.")
                Text("Если резервной почты нет, восстановить доступ без номера пока нельзя.").reedFont(.caption)
            }
            Section("Резервная почта") {
                TextField("name@example.com", text: $model.email).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(model.requestedEmail != nil || model.working)
                if model.requestedEmail == nil { Button("Получить код") { Task { await model.request() } }.disabled(model.working || model.email.isEmpty) }
            }
            if model.requestedEmail != nil {
                Section("Код из письма") {
                    Text("Если адрес связан с аккаунтом, письмо с кодом будет отправлено.").reedFont(.caption)
                    TextField("Шесть цифр", text: $model.code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                    Button("Войти") { Task { await model.verify() } }.disabled(model.working || model.code.count != 6)
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        let wait = max(0,Int(ceil(model.retryAt.timeIntervalSince(timeline.date))))
                        Button(wait > 0 ? "Повторить через \(wait) с" : "Отправить код повторно") { Task { await model.request() } }
                            .disabled(wait > 0 || model.working)
                    }
                    Button("Изменить адрес") { model.reset() }.disabled(model.working)
                }
            }
            if model.working { ProgressView() }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
        }.navigationTitle("Нет доступа к номеру").navigationBarTitleDisplayMode(.inline)
    }
}
