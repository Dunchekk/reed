import SwiftUI

struct SettingsView: View {
    let context: LibraryContext
    let authentication: AuthenticationModel
    let open: (UUID) -> Void
    @State private var signingOut = false
    @State private var errorMessage: String?
    var body: some View {
        Form {
            Section("Библиотека") {
                NavigationLink("Возвращения") { ReturnSettingsView(context: context) }
                NavigationLink("Активность") { ActivityView(context: context, open: open) }
                NavigationLink("Скрытые карточки") { ArchiveView(context: context, visibility: .hidden, open: open).navigationTitle("Скрытые") }
                NavigationLink("Корзина · 7 дней") { ArchiveView(context: context, visibility: .trash, open: open).navigationTitle("Корзина") }
            }
            Section("Хранение") {
                NavigationLink("Добавление карточек") { CaptureSettingsView(context: context) }
                NavigationLink("Данные и синхронизация") { CloudSettingsView(context: context) }
                if let error = context.maintenanceError { Text(error).foregroundStyle(.red) }
                Text("Локальная копия доступна без интернета. Выход сохраняет библиотеку для повторного входа в тот же аккаунт.").reedFont(.caption)
            }
            Section("Аккаунт") {
                NavigationLink("Управление аккаунтом") { AccountSettingsView(authentication: authentication, context: context) }
                Text(authentication.account?.phone.value ?? "")
                if authentication.serverNeedsSignIn { Text("Серверная сессия требует обновления. Локальная библиотека доступна.").reedFont(.caption) }
                Button("Выйти", role: .destructive) {
                    signingOut = true
                    Task {
                        defer { signingOut = false }
                        do {
                            try await context.stopSession()
                            await authentication.signOut()
                            if authentication.account != nil { try await context.resumeAfterFailedSignOut() }
                        } catch { try? await context.resumeAfterFailedSignOut(); errorMessage = "Не удалось завершить фоновые операции. Повторите выход." }
                    }
                }.disabled(signingOut)
                if let error = authentication.errorMessage ?? errorMessage { Text(error).foregroundStyle(.red) }
            }
            Section("О Reed") {
                Text("Сохраняйте фрагменты, возвращайтесь к ним в своё время.")
                Text("Версия 0.1 · Локальный прототип").reedFont(.caption).foregroundStyle(ReedTheme.secondary)
            }
        }
    }
}
