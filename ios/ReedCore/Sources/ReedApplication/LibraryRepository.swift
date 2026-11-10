import Foundation
import ReedDomain

/// A repository instance belongs to exactly one confirmed account.
public protocol LibraryRepository: Sendable {
    func card(id: UUID) async throws -> Card?
    func save(_ card: Card) async throws
    func archive(_ query: ArchiveQuery, after cursor: String?) async throws -> ArchivePage
    func attachmentIDs() async throws -> Set<UUID>
    func catalog() async throws -> LibraryCatalog
    func purgeTrash(before date: Date) async throws -> [UUID]
}
