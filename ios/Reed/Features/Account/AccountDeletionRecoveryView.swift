import SwiftUI
import ReedDomain

/// The library stays closed while a confirmed deletion intent is unfinished.
struct AccountDeletionRecoveryView: View {
    let authentication: AuthenticationModel
    let account: Account
    @State private var working = false
    @State private var errorMessage: String?
    @State private var confirmsLocal = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Удаление не завершено") {
                    Text(authentication.session?.deletionProgress == .accepted
                         ? "Сервер принял удаление аккаунта. Осталось удалить данные с этого устройства."
                         : "Запрос удаления начат, но ответ сервера не подтверждён. Повторите запрос при подключении к сети.")
                    Button("Продолжить удаление") { finish(onlyLocal: false) }.disabled(working)
                }
                Section {
                    Button("Очистить устройство и выйти", role: .destructive) { confirmsLocal = true }.disabled(working)
                    Text("Удалит только локальные карточки и вход. Если сервер не принял запрос, аккаунт останется — для его удаления понадобится войти снова.").reedFont(.caption)
                }
                if working { ProgressView() }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }.navigationTitle("Аккаунт")
        }
        .confirmationDialog("Удалить локальную библиотеку и выйти?", isPresented: $confirmsLocal, titleVisibility: .visible) {
            Button("Удалить данные с устройства", role: .destructive) { finish(onlyLocal: true) }
        }
    }
    private func finish(onlyLocal: Bool) {
        guard !working else { return }; working = true; errorMessage = nil
        Task {
            defer { working = false }
            do {
                let context = try await LibrarySessionController.shared.open(account)
                try await authentication.deleteAccount(local: context, onlyLocal: onlyLocal)
            } catch { errorMessage = accountErrorMessage(error) }
        }
    }
}
