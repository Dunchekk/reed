import Foundation
import Testing
import ReedDomain

@Test func cardsRequireTextButAllowLongFragmentsAndOptionalMetadata() throws {
    #expect(throws: LibraryError.emptyText) { try Card(text: " \n ").validate() }
    try Card(text: String(repeating: "Длинный фрагмент. ", count: 10_000)).validate()
    let tag = Tag(name: "Философия")
    #expect(throws: LibraryError.duplicateRelationship) { try Card(text: "Текст", tags: [tag, tag]).validate() }
}

@Test func searchNormalizesRussianTokensWithoutStemming() {
    #expect(TextNormalization.tokens("ЁЖ, ель! ЛИЧНЫЙ комментарий") == ["еж", "ель", "личный", "комментарий"])
}

@Test func archiveRejectsImpossibleRangesAndUnboundedPages() {
    var query = ArchiveQuery()
    query.pageSize = 101
    #expect(throws: LibraryError.invalidQuery) { try query.validate() }
    query.pageSize = 30
    query.createdAfter = Date(timeIntervalSince1970: 10)
    query.createdBefore = Date(timeIntervalSince1970: 5)
    #expect(throws: LibraryError.invalidQuery) { try query.validate() }
}
