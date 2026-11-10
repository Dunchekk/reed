import Foundation
import Observation
import ReedDomain
import ReedApplication

@MainActor @Observable
final class CardEditorModel {
    var text: String
    var title: String
    var comment: String
    var page: String
    var tagNames: String
    var selectedSourceID: UUID?
    var sourceTitle = ""
    var authorNames = ""
    var selectedFolderID: UUID?
    var newFolderName = ""
    private(set) var catalog = LibraryCatalog()
    private(set) var isSaving = false
    private(set) var isCatalogLoaded = false
    private(set) var errorMessage: String?
    let original: Card?
    @ObservationIgnored private let repository: any LibraryRepository

    init(repository: any LibraryRepository, card: Card? = nil, initialText: String = "") {
        self.repository = repository; original = card
        text = card?.text ?? initialText; title = card?.title ?? ""; comment = card?.comment ?? ""
        page = card?.page ?? ""; tagNames = card?.tags.map(\.name).joined(separator: ", ") ?? ""
        selectedSourceID = card?.source?.id; selectedFolderID = card?.folder?.id
    }

    var canSave: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving && isCatalogLoaded }
    var isChanged: Bool {
        text != (original?.text ?? "") || title != (original?.title ?? "") || comment != (original?.comment ?? "")
            || page != (original?.page ?? "") || tagNames != (original?.tags.map(\.name).joined(separator: ", ") ?? "")
            || selectedSourceID != original?.source?.id || selectedFolderID != original?.folder?.id
            || !sourceTitle.isEmpty || !authorNames.isEmpty || !newFolderName.isEmpty
    }

    func loadCatalog() async {
        do { catalog = try await repository.catalog(); isCatalogLoaded = true; errorMessage = nil }
        catch { errorMessage = libraryErrorMessage(error) }
    }

    func save() async -> UUID? {
        guard canSave else { return nil }
        isSaving = true; errorMessage = nil
        defer { isSaving = false }
        do {
            var card = original ?? Card(text: text)
            card.text = text; card.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            card.comment = comment; card.page = page; card.updatedAt = Date()
            if let selectedSourceID {
                guard let source = catalog.sources.first(where: { $0.id == selectedSourceID }) else { throw LibraryError.notFound }
                card.source = source
            } else if !sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let names = Self.names(authorNames, separator: ";")
                let authors = names.map { name in
                    catalog.authors.first(where: { TextNormalization.normalize($0.name) == TextNormalization.normalize(name) }) ?? Author(name: name)
                }
                let title = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                card.source = catalog.sources.first { $0.title == title && $0.authors == authors } ?? Source(title: title, authors: authors)
            } else { card.source = nil }
            card.tags = Self.names(tagNames, separator: ",").map { name in
                catalog.tags.first(where: { TextNormalization.normalize($0.name) == TextNormalization.normalize(name) }) ?? Tag(name: name)
            }
            if let selectedFolderID {
                guard let folder = catalog.folders.first(where: { $0.id == selectedFolderID }) else { throw LibraryError.notFound }
                card.folder = folder
            } else if !newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                card.folder = catalog.folders.first(where: { TextNormalization.normalize($0.name) == TextNormalization.normalize(name) }) ?? Folder(name: name)
            } else { card.folder = nil }
            try await repository.save(card)
            return card.id
        } catch { errorMessage = libraryErrorMessage(error); return nil }
    }

    private static func names(_ input: String, separator: Character) -> [String] {
        var seen = Set<String>()
        return input.split(separator: separator).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert(TextNormalization.normalize($0)).inserted }
    }
}
