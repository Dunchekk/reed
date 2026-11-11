import Foundation
import Observation
import ReedDomain
import ReedApplication

@MainActor @Observable
final class CatalogModel {
    var kind = CatalogKind.sources
    var search = ""
    var onlyUnused = false
    private(set) var snapshot = CatalogSnapshot(entries: [], revision: 0)
    private(set) var working = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let repository: any CatalogManagementRepository
    init(repository: any CatalogManagementRepository) { self.repository = repository }
    var visibleEntries: [CatalogEntry] {
        let query = TextNormalization.normalize(search)
        return snapshot.entries.filter { (!onlyUnused || $0.cardCount == 0) && (query.isEmpty || TextNormalization.normalize($0.name).contains(query)) }
    }
    func load() async {
        do { snapshot = try await repository.entries(kind: kind); errorMessage = nil }
        catch { errorMessage = libraryErrorMessage(error) }
    }
    func update(_ mutation: CatalogMutation) async -> Bool {
        guard !working else { return false }
        working = true; defer { working = false }
        do {
            try await repository.update(kind: kind, mutation: mutation, expectedRevision: snapshot.revision)
            await load(); return true
        } catch {
            if let error = error as? CatalogError {
                errorMessage = switch error {
                case .duplicateName: "Такое название уже есть. Используйте объединение."
                case .invalidName: "Введите название от 1 до 300 символов."
                case .sameTarget: "Выберите другой элемент для объединения."
                }
            } else { errorMessage = "Библиотека изменилась или операция недоступна. Обновите список и повторите." }
            return false
        }
    }
}
