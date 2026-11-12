import SwiftUI
import ReedDomain
import ReedPersistence

struct LibraryHostView: View {
    let account: Account
    let authentication: AuthenticationModel
    @State private var context: LibraryContext?
    @State private var errorMessage: String?
    @State private var retry = 0

    var body: some View {
        Group {
            if let context { RootView(authentication: authentication, context: context) }
            else if let errorMessage {
                ContentUnavailableView {
                    Label("Не удалось открыть библиотеку", systemImage: "externaldrive.badge.exclamationmark")
                } description: { Text(errorMessage) } actions: { Button("Повторить") { retry += 1 } }
            } else { ProgressView("Открываем библиотеку…") }
        }
        .task(id: retry) {
            do {
                let library = try await LibrarySessionController.shared.open(account)
                guard !Task.isCancelled else { return }
                context = library
                errorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "Данные сохранены на устройстве. Повторите попытку; библиотека не будет сброшена."
            }
        }
    }
}
