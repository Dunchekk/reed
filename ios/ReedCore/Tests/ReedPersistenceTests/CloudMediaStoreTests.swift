import Foundation
import Testing
import ReedDomain
import ReedApplication
@testable import ReedPersistence

@Test func cloudPhotoDownloadResumesAndRejectsCorruptionBeforePublication() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reed-photo-sync-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = FileAttachmentStore(directory: root.appendingPathComponent("source"))
    let destination = root.appendingPathComponent("destination")
    let original = Data(repeating: 42, count: 600_000), thumbnail = Data([1,2,3,4])
    let id = try await source.write(original: original, thumbnail: thumbnail), manifest = try await source.manifest(id: id)
    let first = FileAttachmentStore(directory: destination)
    try await first.appendDownload(manifest: manifest, variant: .original, offset: 0, bytes: original.prefix(512*1024))
    let resumed = FileAttachmentStore(directory: destination)
    #expect(try await resumed.downloadOffset(manifest: manifest, variant: .original) == 512*1024)
    try await resumed.appendDownload(manifest: manifest, variant: .original, offset: 512*1024, bytes: original.dropFirst(512*1024))
    try await resumed.appendDownload(manifest: manifest, variant: .thumbnail, offset: 0, bytes: Data([9,9,9,9]))
    await #expect(throws: CloudError.corruptedMedia) { try await resumed.finishDownload(manifest: manifest) }
    #expect(try await resumed.containsVerified(manifest) == false)
    #expect(try await resumed.downloadOffset(manifest: manifest, variant: .thumbnail) == 0)
    try await resumed.appendDownload(manifest: manifest, variant: .thumbnail, offset: 0, bytes: thumbnail)
    try await resumed.finishDownload(manifest: manifest)
    #expect(try await resumed.original(id: id) == original)
    #expect(try await resumed.thumbnail(id: id) == thumbnail)
    #expect(try await resumed.manifest(id: id) == manifest)
    // A damaged local copy is replaced only after both staged variants pass verification.
    try Data([0]).write(to: destination.appendingPathComponent("attachments/\(id.uuidString.lowercased())/original"))
    #expect(try await resumed.containsVerified(manifest) == false)
    try await resumed.appendDownload(manifest: manifest, variant: .original, offset: 0, bytes: original.prefix(512*1024))
    try await resumed.appendDownload(manifest: manifest, variant: .original, offset: 512*1024, bytes: original.dropFirst(512*1024))
    try await resumed.appendDownload(manifest: manifest, variant: .thumbnail, offset: 0, bytes: thumbnail)
    try await resumed.finishDownload(manifest: manifest)
    #expect(try await resumed.containsVerified(manifest))
}

@Test func cloudOutboxRetainsPhotoRemovedByANewerLocalEdit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reed-retention-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try LibraryDatabase(root: root, accountID: UUID())
    let library = LocalLibraryRepository(database: database), cloud = LocalCloudRepository(database: database)
    let photo = UUID(), card = Card(text: "Фото", attachmentIDs: [photo])
    try await library.save(card); try await cloud.begin(epoch: UUID())
    _ = try #require(await cloud.nextPending())
    var edited = try #require(await library.card(id: card.id)); edited.attachmentIDs = []; try await library.save(edited)
    #expect(try await library.attachmentIDs().contains(photo))
}

@Test func clearingLibraryErasesInterruptedDownloadsEvenWithoutPublishedAttachments() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reed-staging-clear-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try LibraryDatabase(root: root, accountID: UUID())
    let source = FileAttachmentStore(directory: root.appendingPathComponent("source")), files = FileAttachmentStore(directory: database.directory)
    let id = try await source.write(original: Data([1,2,3,4]), thumbnail: Data([5,6])), manifest = try await source.manifest(id: id)
    try await files.appendDownload(manifest: manifest, variant: .original, offset: 0, bytes: Data([1,2]))
    try await files.collectOrphans(retaining: [id])
    #expect(try await files.downloadOffset(manifest: manifest, variant: .original) == 2)
    let staging = database.directory.appendingPathComponent("cloud-downloads/\(id.uuidString.lowercased())/original")
    #expect(FileManager.default.fileExists(atPath: staging.path))
    let transfer = LibraryTransferService(repository: LocalLibraryBackupRepository(database: database), attachments: files, archive: FileBackupArchive(directory: database.directory))
    try await transfer.clear()
    #expect(!FileManager.default.fileExists(atPath: staging.path))
    try await transfer.clear()
    try await files.appendDownload(manifest: manifest, variant: .original, offset: 0, bytes: Data([1,2]))
    try await files.collectOrphans(retaining: [])
    #expect(!FileManager.default.fileExists(atPath: staging.path))
}
