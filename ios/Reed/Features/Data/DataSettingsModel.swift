import Foundation
import Observation
import ReedDomain
import ReedApplication

@MainActor @Observable
final class DataSettingsModel {
    private(set) var summary: LibraryStorageSummary?
    private(set) var exportedURL: URL?
    private(set) var prepared: PreparedLibraryBackup?
    private(set) var allowsLocalChanges = true
    private(set) var working = false
    private(set) var message: String?
    private(set) var errorMessage: String?
    @ObservationIgnored private let context: LibraryContext
    init(context: LibraryContext) { self.context = context }
    func load() async {
        do { summary = try await context.transfer.summary(); allowsLocalChanges = try await context.cloud.repository.state().mode == .local }
        catch { errorMessage = Self.message(error) }
    }
    func export() async {
        await perform {
            self.exportedURL = try await self.context.transfer.export()
            self.message = "Резервная копия готова. Сохраните её через меню «Поделиться»."
        }
    }
    func inspect(_ url: URL) async {
        await perform {
            if let previous = self.prepared { await self.context.transfer.discard(previous); self.prepared = nil }
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            self.prepared = try await self.context.transfer.inspect(url)
            self.message = nil
        }
    }
    func restore() async {
        guard let prepared else { return }
        await perform {
            let result = try await self.context.transfer.restore(prepared)
            await self.context.transfer.discard(prepared); self.prepared = nil
            self.context.markChanged(); self.context.markDraftsChanged()
            self.message = result == .restored ? "Библиотека восстановлена." : "Эта копия уже восстановлена. Дубликаты не созданы."
            await self.load()
        }
    }
    func clear() async {
        await perform {
            guard try await self.context.cloud.repository.state().mode == .local else { throw CloudError.invalidTransition }
            try await self.context.returnCoordinator.stop()
            do {
                try await self.context.transfer.clear()
                self.exportedURL = nil; self.prepared = nil
                self.context.returnCoordinator.resume(); self.context.markChanged(); self.context.markDraftsChanged()
                self.message = "Локальная библиотека очищена. Аккаунт сохранён."
                await self.load()
            } catch { self.context.returnCoordinator.resume(); throw error }
        }
    }
    func discardPreview() async {
        if let prepared { await context.transfer.discard(prepared); self.prepared = nil }
    }
    private func perform(_ work: () async throws -> Void) async {
        guard !working else { return }; working = true; errorMessage = nil
        defer { working = false }
        do { try await work() } catch { errorMessage = Self.message(error) }
    }
    private static func message(_ error: any Error) -> String {
        if error is CloudError { return "Для очистки или восстановления сначала отключите синхронизацию на этом iPhone. Облачная библиотека останется сохранённой." }
        if let error = error as? BackupError {
            return switch error {
            case .invalidArchive: "Файл повреждён или имеет неверную структуру. Данные приложения не заменены."
            case .unsupportedVersion: "Эта копия создана другой версией формата. Обновите Reed."
            case .nonemptyLibrary: "Восстановление доступно только в пустую библиотеку. Сначала экспортируйте текущие данные, затем очистите их."
            case .tooLarge: "Файл превышает поддерживаемый размер: описание до 128 МБ, отдельное фото до 40 МБ."
            }
        }
        return "Операция не завершена. Проверьте файл и свободное место, затем повторите."
    }
}
