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
                let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true).appendingPathComponent("Reed", isDirectory: true)
                let accountID = account.id
                let database = try await Task.detached(priority: .userInitiated) {
                    try LibraryDatabase(root: root, accountID: accountID)
                }.value
                guard !Task.isCancelled else { return }
                context = LibraryContext(account: account, database: database)
                errorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "Данные сохранены на устройстве. Повторите попытку; библиотека не будет сброшена."
            }
        }
    }
}
