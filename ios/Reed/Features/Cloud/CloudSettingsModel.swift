import Foundation
import Observation
import ReedDomain
import ReedApplication

@MainActor @Observable
final class CloudSettingsModel {
    private(set) var state = CloudState()
    private(set) var local = CloudLocalSummary(cards: 0, pending: 0, conflicts: 0)
    private(set) var server: CloudSummary?
    private(set) var preview: CloudSummary?
    private(set) var progress = CloudProgress(.idle)
    private(set) var working = false
    private(set) var errorMessage: String?
    private(set) var connectionMessage: String?
    @ObservationIgnored let repository: any CloudRepository
    @ObservationIgnored let remote: (any CloudRemote)?
    @ObservationIgnored let engine: CloudSyncEngine?
    init(repository: any CloudRepository, remote: (any CloudRemote)?, engine: CloudSyncEngine?) {
        self.repository = repository; self.remote = remote; self.engine = engine
    }
    var available: Bool { engine != nil }
    var enabled: Bool { state.participates || state.mode == .leaving }
    var busy: Bool { working || progress.isTransferring }
    var status: String {
        switch state.mode {
        case .local: "Библиотека на этом iPhone"
        case .enabling: "Переносим библиотеку"
        case .cloud: "Локальная копия связана с облаком"
        case .disabling: "Подготавливаем полную локальную копию"
        case .leaving: "Завершаем отключение устройства"
        case .revoked: "Подключение требует вашего решения"
        }
    }
    func load(includeRemote: Bool = true) async {
        do { state = try await repository.state(); local = try await repository.summary() }
        catch { errorMessage = cloudErrorMessage(error) }
        guard includeRemote, let remote else { return }
        do { server = try await remote.summary(); connectionMessage = nil }
        catch { connectionMessage = "Не удалось обновить сведения об облаке. Локальная библиотека остаётся доступна." }
    }
    func observe() async {
        await load()
        guard let engine else { return }
        for await event in await engine.events() {
            guard !Task.isCancelled else { return }
            let finished = progress.isTransferring && !event.isTransferring
            progress = event
            if !event.isTransferring { await load(includeRemote: finished) }
        }
    }
    func requestEnable() async {
        guard let engine, !busy else { return }
        working = true; errorMessage = nil
        defer { working = false }
        do {
            let result = try await engine.preview()
            await load(includeRemote: false)
            preview = result
        } catch { errorMessage = cloudErrorMessage(error) }
    }
    func cancelPreview() { preview = nil }
    func enable(epoch: UUID) async {
        guard let engine else { return }
        preview = nil
        await perform { try await engine.enable(expectedEpoch: epoch) }
    }
    func disable() async {
        guard let engine else { return }
        await perform { try await engine.disable() }
    }
    func synchronize() async {
        guard let engine else { return }
        await perform {
            if self.state.mode == .disabling || self.state.mode == .leaving { try await engine.disable() }
            else { try await engine.synchronize() }
        }
    }
    func configure(automatic: Bool? = nil, wifiOnly: Bool? = nil) async {
        await perform(refreshRemote: false) {
            let current = try await self.repository.state()
            try await self.repository.configure(automatic: automatic ?? current.automatic, wifiOnly: wifiOnly ?? current.wifiOnly)
        }
    }
    func perform(refreshRemote: Bool = true, _ operation: () async throws -> Void) async {
        guard !busy else { return }
        working = true; errorMessage = nil
        defer { working = false }
        do { try await operation() } catch { errorMessage = cloudErrorMessage(error) }
        await load(includeRemote: refreshRemote)
    }
}

extension CloudProgress {
    var isTransferring: Bool { ![.idle,.conflicts,.failed].contains(phase) }
    var title: String {
        switch phase {
        case .idle: "Обмен завершён"
        case .preparing: "Подготавливаем обмен…"
        case .pulling: "Получаем изменения…"
        case .pushing: "Отправляем изменения…"
        case .uploading: "Загружаем фото в облако…"
        case .downloading: "Сохраняем фото на iPhone…"
        case .finishing: "Проверяем результат…"
        case .conflicts: "Нужно выбрать версии изменений"
        case .failed: "Обмен не завершён"
        }
    }
}

func cloudErrorMessage(_ error: any Error) -> String {
    if let api = error as? APIError { return api.message }
    if error is CancellationError { return "Обмен прерван. Прогресс сохранён; его можно продолжить." }
    switch error as? CloudError {
    case .epochChanged: return "Облачная библиотека была удалена или заменена. Выберите повторное подключение или сохранение локальной копии."
    case .deviceRevoked: return "Синхронизация на этом iPhone отключена с другого устройства. Локальные данные сохранены."
    case .networkRestricted: return "Для обмена нужен Wi-Fi. Подключитесь к нему или выключите ограничение в настройках синхронизации."
    case .conflict: return "Версии снова изменились. Откройте конфликт заново перед выбором."
    case .busy: return "Сначала дождитесь текущей операции синхронизации."
    case .pendingChanges: return "Сначала завершите обмен, загрузку фото и выбор конфликтующих версий."
    case .missingMedia, .corruptedMedia: return "Не удалось получить проверенную копию фото. Повторите обмен; существующий текст сохранён."
    case .wrongAccount: return "Вход изменился. Откройте библиотеку нужного аккаунта заново."
    case .invalidTransition: return "Это действие недоступно в текущем режиме. Сначала завершите переход между локальной библиотекой и облаком."
    case .quotaExceeded: return "Достигнут лимит облачного хранилища. Новые изменения остаются на этом iPhone."
    case .invalidRecord, .operationReused: return "Данные не прошли проверку синхронизации. Локальные правки сохранены."
    default: return "Не удалось завершить обмен. Проверьте соединение и повторите; сохранённый прогресс будет использован."
    }
}
