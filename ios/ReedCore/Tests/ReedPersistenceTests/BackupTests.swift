import Foundation
import Testing
import ReedDomain
import ReedApplication
import ReedPersistence

@Test func backupRoundTripIncludesPhotosDraftsAndPreferencesWithoutDuplicates() async throws {
    let source = try TestLibrary(), target = try TestLibrary()
    defer { source.cleanup(); target.cleanup() }
    let db = try LibraryDatabase(root: source.root, accountID: source.accountID)
    let files = FileAttachmentStore(directory: db.directory)
    let first = try await files.write(original: Data([1,2,3]), thumbnail: Data([4]))
    let second = try await files.write(original: Data(repeating: 9, count: 150_000), thumbnail: Data([5]))
    let card = Card(text: "Фрагмент с фотографиями", source: Source(title: "Книга", authors: [Author(name: "Автор")]), tags: [Tag(name: "Тема")], attachmentIDs: [second,first])
    try await source.repository.save(card)
    var draft = CardDraft(card: Card(text: "Незаконченный фрагмент", attachmentIDs: [first]))
    draft.newAttachmentIDs = [first]
    try await LocalDraftRepository(database: db).saveDraft(draft)
    try await LocalCapturePreferencesRepository(database: db).setCapturePreferences(CapturePreferences(savesPhotos: false))
    try await LocalActivityRepository(database: db).recordOpening(cardID: card.id, origin: .manual, now: Date())
    let sourceStore = FileBackupArchive(directory: db.directory)
    let service = LibraryTransferService(repository: LocalLibraryBackupRepository(database: db), attachments: files, archive: sourceStore)
    let file = try await service.export()
    let targetDB = try LibraryDatabase(root: target.root, accountID: target.accountID)
    let targetFiles = FileAttachmentStore(directory: targetDB.directory)
    let targetStore = FileBackupArchive(directory: targetDB.directory)
    let restore = LibraryTransferService(repository: LocalLibraryBackupRepository(database: targetDB), attachments: targetFiles, archive: targetStore)
    let prepared = try await restore.inspect(file)
    #expect(try await restore.restore(prepared) == .restored)
    #expect(try await restore.restore(prepared) == .alreadyImported)
    let loaded = try #require(await target.repository.card(id: card.id))
    #expect(loaded.text == card.text); #expect(loaded.source == card.source)
    #expect(try await targetFiles.original(id: loaded.attachmentIDs[0]) == Data(repeating: 9, count: 150_000))
    #expect(try await targetFiles.original(id: loaded.attachmentIDs[1]) == Data([1,2,3]))
    #expect(try await LocalDraftRepository(database: targetDB).draft(id: draft.id)?.card.attachmentIDs == [loaded.attachmentIDs[1]])
    #expect(try await !LocalCapturePreferencesRepository(database: targetDB).capturePreferences().savesPhotos)
    #expect(try await LocalActivityRepository(database: targetDB).activity(now: Date()).openings.count == 1)
    #expect(try await restore.summary().cards == 1)
    await restore.discard(prepared)
}

@Test func corruptBackupAndNonemptyDestinationNeverReplaceLiveCards() async throws {
    let library = try TestLibrary(); defer { library.cleanup() }
    let db = try LibraryDatabase(root: library.root, accountID: library.accountID)
    let files = FileAttachmentStore(directory: db.directory)
    let id = try await files.write(original: Data([1,2]), thumbnail: Data([3]))
    let card = Card(text: "Не терять", attachmentIDs: [id]); try await library.repository.save(card)
    let store = FileBackupArchive(directory: db.directory)
    let service = LibraryTransferService(repository: LocalLibraryBackupRepository(database: db), attachments: files, archive: store)
    let url = try await service.export(), prepared = try await service.inspect(url)
    await #expect(throws: BackupError.nonemptyLibrary) { _ = try await service.restore(prepared) }
    #expect(try await library.repository.card(id: card.id)?.text == card.text)
    var bytes = try Data(contentsOf: url); bytes[bytes.count-1] ^= 0xff; try bytes.write(to: url)
    await #expect(throws: BackupError.invalidArchive) { _ = try await service.inspect(url) }
    #expect(try await files.original(id: id) == Data([1,2]))
    await service.discard(prepared)
}

@Test func localClearRemovesPhotosAndDoesNotResurrectLateDrafts() async throws {
    let library = try TestLibrary(); defer { library.cleanup() }
    let db = try LibraryDatabase(root: library.root, accountID: library.accountID)
    let files = FileAttachmentStore(directory: db.directory), drafts = LocalDraftRepository(database: db)
    let id = try await files.write(original: Data([1]), thumbnail: Data([2]))
    let orphan = try await files.write(original: Data([3]), thumbnail: Data([4]))
    let draft = CardDraft(card: Card(text: "Черновик", attachmentIDs: [id]))
    try await drafts.saveDraft(draft)
    let service = LibraryTransferService(repository: LocalLibraryBackupRepository(database: db), attachments: files, archive: FileBackupArchive(directory: db.directory))
    try await service.clear()
    #expect(try await service.summary().isEmpty)
    await #expect(throws: LibraryError.notFound) { try await drafts.saveDraft(draft) }
    await #expect(throws: (any Error).self) { _ = try await files.original(id: id) }
    await #expect(throws: (any Error).self) { _ = try await files.original(id: orphan) }
}
