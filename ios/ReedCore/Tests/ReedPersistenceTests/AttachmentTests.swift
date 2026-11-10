import Foundation
import Testing
import ReedDomain
import ReedPersistence

@Test func attachmentsRemainUntilTheirCardLeavesTrash() async throws {
    let library = try TestLibrary()
    defer { library.cleanup() }
    let files = FileAttachmentStore(directory: library.root)
    let id = try await files.write(original: Data([1,2,3]), thumbnail: Data([4]))
    let orphan = try await files.write(original: Data([9]), thumbnail: Data([8]))
    let card = Card(text: "Фото и текст", deletedAt: Date(timeIntervalSince1970: 100), attachmentID: id)
    try await library.repository.save(card)
    #expect(try await library.repository.card(id: card.id)?.attachmentID == id)
    try await files.collectOrphans(retaining: library.repository.attachmentIDs())
    #expect(try await files.thumbnail(id: id) == Data([4]))
    await #expect(throws: (any Error).self) { _ = try await files.originalURL(id: orphan) }
    _ = try await library.repository.purgeTrash(before: Date())
    try await files.collectOrphans(retaining: library.repository.attachmentIDs())
    await #expect(throws: (any Error).self) { _ = try await files.originalURL(id: id) }
}
