#if DEBUG
import Foundation
import ReedDomain
import ReedApplication

enum UITestBootstrap {
    static var runID: UUID? {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--ui-testing"), let index = args.firstIndex(of: "--ui-test-run"), args.indices.contains(index + 1) else { return nil }
        return UUID(uuidString: args[index + 1])
    }
    static var enabled: Bool { runID != nil }
    static var root: URL? { runID.map { FileManager.default.temporaryDirectory.appendingPathComponent("ReedUITests/\($0.uuidString)", isDirectory: true) } }
    static let accountID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static func seed(_ context: LibraryContext) async throws {
        guard enabled, try await context.repository.archive(ArchiveQuery(), after: nil).cards.isEmpty else { return }
        let tag = Tag(name: "Чтение"), folder = Folder(name: "Идеи"), source = Source(title: "Тестовый сборник", authors: [Author(name: "Автор примера")])
        for index in 1...6 {
            try await context.repository.save(Card(text: "Это синтетическая карточка для проверки интерфейса. Мы сохраняем мысли, чтобы вернуться к ним позже и увидеть новые связи. Текст можно изменить, найти в архиве и добавить в избранное.", title: "Фрагмент \(index)", source: source, tags: [tag], folder: folder,
                createdAt: Date().addingTimeInterval(Double(-40-index)*86400), isFavorite: index == 1))
        }
        var settings = ReturnSettings(); settings.enabled = true; settings.notificationsEnabled = true
        try await context.returns.saveSettings(settings, now: Date(), calendar: .current)
    }
}
struct UITestSessionStore: SessionStore {
    func load() throws -> AuthSession? {
        AuthSession(account: Account(id: UITestBootstrap.accountID, phone: try PhoneNumber("+70000000000")), accessToken: "ui-test-only", refreshToken: "ui-test-only", expiresAt: Date().addingTimeInterval(86400))
    }
    func save(_ session: AuthSession) throws {}
    func clear() throws {}
}
actor UITestNotificationQueue: CardNotificationQueue {
    private var requests: [String: UUID] = [:]
    func permission() -> NotificationPermission { .allowed }
    func requestPermission() -> Bool { true }
    func pending() -> [QueuedNotification] { requests.map { QueuedNotification(id: $0.key, revision: $0.value) } }
    func add(_ notification: CardNotification) { requests[notification.id] = notification.entry.revision }
    func remove(ids: [String]) { for id in ids { requests.removeValue(forKey: id) } }
    func clear() { requests = [:] }
}
#endif
