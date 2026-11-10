import Foundation
import Observation
import ReedDomain
import ReedApplication

@MainActor @Observable
final class ArchiveModel {
    var query: ArchiveQuery
    private(set) var cards: [CardSummary] = []
    private(set) var catalog = LibraryCatalog()
    private(set) var nextCursor: String?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let repository: any LibraryRepository
    @ObservationIgnored private var generation = UUID()

    init(repository: any LibraryRepository, visibility: ArchiveVisibility) {
        self.repository = repository
        var query = ArchiveQuery(); query.visibility = visibility
        self.query = query
    }

    func reload(debounce: Bool = false) async {
        let generation = UUID(); self.generation = generation
        let query = query
        isLoading = true; errorMessage = nil; nextCursor = nil
        defer { if self.generation == generation { isLoading = false } }
        do {
            if debounce { try await Task.sleep(for: .milliseconds(220)) }
            let page = try await repository.archive(query, after: nil)
            let catalog = try await repository.catalog()
            guard self.generation == generation, !Task.isCancelled else { return }
            cards = page.cards; nextCursor = page.nextCursor; self.catalog = catalog
        } catch is CancellationError {
        } catch {
            guard self.generation == generation else { return }
            cards = []; errorMessage = libraryErrorMessage(error)
        }
    }

    func loadMore() async {
        guard !isLoading, let cursor = nextCursor else { return }
        let generation = generation
        isLoading = true
        defer { if self.generation == generation { isLoading = false } }
        do {
            let page = try await repository.archive(query, after: cursor)
            guard self.generation == generation, !Task.isCancelled else { return }
            cards += page.cards; nextCursor = page.nextCursor
        } catch LibraryError.staleCursor { await reload() }
        catch { if self.generation == generation { errorMessage = libraryErrorMessage(error) } }
    }

    func toggleFavorite(_ id: UUID, changed: () -> Void) async {
        do {
            guard var card = try await repository.card(id: id) else { throw LibraryError.notFound }
            card.isFavorite.toggle(); card.updatedAt = Date()
            try await repository.save(card)
            changed()
        } catch { errorMessage = libraryErrorMessage(error) }
    }
}
