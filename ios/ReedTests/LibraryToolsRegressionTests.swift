import XCTest
import Foundation
import ReedDomain
import ReedApplication
import ReedPersistence
@testable import Reed

@MainActor final class LibraryToolsRegressionTests: XCTestCase {
    func testPhotoPreferenceDoesNotRemoveRestoredAttachmentsAndSkipsFollowingPhotos() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let account = Account(id:UUID(),phone:try PhoneNumber("+70000000001"))
        let context = LibraryContext(account:account,database:try LibraryDatabase(root:root,accountID:account.id))
        let first = CardEditorModel(context:context)
        await first.load()
        let photo = ProcessedPhoto(original:Data([1,2]),thumbnail:Data([3]),recognizedText:"Первый",recognitionFailed:false)
        let added = await first.applyPhoto(photo,text:"Первый",separate:false)
        XCTAssertTrue(added)
        let finished = await first.finishEditing(); XCTAssertTrue(finished)
        let recoveredValue = try await context.drafts.draft(id:first.draft.id)
        let recovered = try XCTUnwrap(recoveredValue)
        let editor = CardEditorModel(context:context,draft:recovered)
        await editor.load(); await editor.setSavesPhotos(false)
        XCTAssertEqual(editor.draft.card.attachmentIDs,recovered.card.attachmentIDs)
        let nextAdded = await editor.applyPhoto(photo,text:"Второй",separate:false)
        XCTAssertTrue(nextAdded)
        XCTAssertEqual(editor.draft.card.attachmentIDs,recovered.card.attachmentIDs)
        XCTAssertEqual(editor.draft.card.text,"Первый\n\nВторой")
        let preference = try await context.capturePreferences.capturePreferences()
        XCTAssertFalse(preference.savesPhotos)
        editor.removePhoto(try XCTUnwrap(editor.draft.card.attachmentIDs.first))
        let closed = await editor.finishEditing(); XCTAssertTrue(closed)
        let storedValue = try await context.drafts.draft(id:recovered.id)
        let stored = try XCTUnwrap(storedValue)
        XCTAssertTrue(stored.card.attachmentIDs.isEmpty)
        XCTAssertEqual(stored.card.text,"Первый\n\nВторой")
    }
    func testLocalDeletionDoesNotRequireConfiguredAPI() async throws {
        let store = RegressionSessionStore()
        try store.save(AuthSession(account:Account(id:UUID(),phone:try PhoneNumber("+70000000001")),accessToken:"a",refreshToken:"r",expiresAt:Date(),deletionProgress:.requested))
        let model = AuthenticationModel(client:nil,store:store), local = RegressionCleanup()
        model.restore()
        try await model.deleteAccount(local:local,onlyLocal:true)
        XCTAssertNil(model.account); XCTAssertNil(try store.load())
        let cleared = await local.cleared; XCTAssertTrue(cleared)
    }
}
private final class RegressionSessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: AuthSession?
    func load() throws -> AuthSession? { lock.withLock { session } }
    func save(_ session: AuthSession) throws { lock.withLock { self.session = session } }
    func clear() throws { lock.withLock { session = nil } }
}
private actor RegressionCleanup: AccountLocalCleanup {
    var cleared = false
    func prepareForDeletion() async throws {}
    func stopAndClear() async throws { cleared = true }
}
