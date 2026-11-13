import Foundation
import Testing
import ReedDomain
import ReedApplication
@testable import ReedPersistence

actor InMemoryCloud: CloudRemote {
    let epoch = UUID()
    var records: [CloudKey: CloudRecord] = [:]
    var journal: [CloudRecord] = []
    var receipts: [UUID: CloudMutationResult] = [:]
    var loseNextResponse = false
    func summary() -> CloudSummary { .init(epoch: epoch, cards: records.values.filter { $0.kind == .card && !$0.isDeleted }.count, mediaBytes: 0, sequence: Int64(journal.count), notificationsAvailable: false) }
    func failNextResponse() { loseNextResponse = true }
    func push(epoch: UUID, mutation: CloudMutation) throws -> CloudMutationResult {
        guard epoch == self.epoch else { throw CloudError.epochChanged }
        if let previous = receipts[mutation.operationID] { return previous }
        let current = records[mutation.key] ?? CloudRecord(key: mutation.key, version: 0, sequence: 0, payload: .null)
        let result: CloudMutationResult
        if current.version != mutation.baseVersion || (current.version > 0 && current.isDeleted && mutation.payload != .null) {
            result = .init(outcome: .conflict, record: current)
        } else {
            let next = CloudRecord(key: mutation.key, version: current.version+1, sequence: Int64(journal.count+1), payload: mutation.payload)
            records[mutation.key] = next; journal.append(next); result = .init(outcome: .applied, record: next)
        }
        receipts[mutation.operationID] = result
        if loseNextResponse { loseNextResponse = false; throw CloudError.unavailable }
        return result
    }
    func pull(epoch: UUID, after: Int64, limit: Int) throws -> CloudPage {
        guard epoch == self.epoch else { throw CloudError.epochChanged }
        let page = Array(journal.filter { $0.sequence > after }.prefix(limit)), cursor = page.last?.sequence ?? after
        return CloudPage(epoch: epoch, records: page, cursor: cursor, hasMore: cursor < journal.count)
    }
    func reset(epoch: UUID) throws -> CloudSummary { throw CloudError.unavailable }
}
struct NoPhotoTransfer: CloudMediaTransferring {
    func upload(epoch: UUID, id: UUID, progress: CloudProgressHandler) throws { throw CloudError.missingMedia }
    func download(epoch: UUID, id: UUID, progress: CloudProgressHandler) throws { throw CloudError.missingMedia }
    func verifyLocal(ids: [UUID]) throws { if !ids.isEmpty { throw CloudError.missingMedia } }
}
struct TestCloudEnvironment: CloudParticipation, CloudNetworkPolicy {
    func allowsTransfer(wifiOnly: Bool) -> Bool { true }
    func prepareJoin() {}
    func refreshRegistration() {}
    func leave() {}
    func suspendLocalNotifications() {}
    func resumeLocalNotifications() {}
}

@Test func cloudEngineRecoversLostResponseAndTransfersToASecondLibrary() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reed-engine-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try LibraryDatabase(root: root, accountID: UUID()), second = try LibraryDatabase(root: root, accountID: UUID())
    let local = LocalCloudRepository(database: first), remote = InMemoryCloud(), environment = TestCloudEnvironment()
    let library = LocalLibraryRepository(database: first), other = LocalLibraryRepository(database: second), replica = LocalCloudRepository(database: second)
    let card = Card(text: "После обрыва", source: Source(title: "Книга", authors: [Author(name: "Автор")]))
    try await library.save(card)
    let epoch = remote.epoch
    try await local.begin(epoch: epoch); try await replica.begin(epoch: epoch)
    func engine(_ repository: LocalCloudRepository) -> CloudSyncEngine {
        CloudSyncEngine(local: repository, remote: remote, media: NoPhotoTransfer(), participation: environment, network: environment)
    }
    await remote.failNextResponse()
    await #expect(throws: CloudError.unavailable) { try await engine(local).synchronize() }
    try await engine(local).synchronize()
    try await engine(replica).synchronize()
    #expect(try await other.card(id: card.id)?.text == card.text)
    #expect(try await other.card(id: card.id)?.source == card.source)
    #expect(try await local.state().mode == .cloud)
    #expect(try await replica.summary().pending == 0)
    #expect(await remote.journal.count == 3)
}

actor LeavingCloudEnvironment: CloudParticipation, CloudNetworkPolicy {
    var failsLeave = true
    func allowLeave() { failsLeave = false }
    func allowsTransfer(wifiOnly: Bool) -> Bool { true }
    func prepareJoin() {}
    func refreshRegistration() {}
    func leave() throws { if failsLeave { throw CloudError.unavailable } }
    func suspendLocalNotifications() {}
    func resumeLocalNotifications() {}
}

@Test func cloudDisableCanResumeAfterRevocationResponseFailsWithoutSendingLaterLocalEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reed-disable-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try LibraryDatabase(root: root, accountID: UUID())
    let local = LocalCloudRepository(database: database), library = LocalLibraryRepository(database: database)
    let remote = InMemoryCloud(), environment = LeavingCloudEnvironment()
    let engine = CloudSyncEngine(local: local, remote: remote, media: NoPhotoTransfer(), participation: environment, network: environment)
    let card = Card(text: "Облачная версия")
    try await library.save(card)
    try await engine.enable(expectedEpoch: remote.epoch)
    await #expect(throws: CloudError.unavailable) { try await engine.disable() }
    #expect(try await local.state().mode == .leaving)
    var edited = try #require(await library.card(id: card.id)); edited.text = "Теперь только здесь"; try await library.save(edited)
    #expect(try await local.summary().pending == 0)
    await environment.allowLeave()
    try await engine.disable()
    #expect(try await local.state().mode == .local)
    let server = await remote.records[CloudKey(.card,card.id)]
    #expect(try server?.payload.decode(CloudCard.self).text == "Облачная версия")
    #expect(try await library.card(id: card.id)?.text == "Теперь только здесь")
}

private struct SuspendedSummary: CloudRemote {
    func summary() async throws -> CloudSummary { try await Task.sleep(for: .seconds(30)); throw CloudError.unavailable }
    func pull(epoch: UUID, after: Int64, limit: Int) throws -> CloudPage { throw CloudError.unavailable }
    func push(epoch: UUID, mutation: CloudMutation) throws -> CloudMutationResult { throw CloudError.unavailable }
    func reset(epoch: UUID) throws -> CloudSummary { throw CloudError.unavailable }
}
@Test func cloudCancellationRestoresIdleProgressForTheNextForegroundAttempt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reed-cancel-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try LibraryDatabase(root: root, accountID: UUID()), local = LocalCloudRepository(database: database)
    try await local.begin(epoch: UUID())
    let environment = TestCloudEnvironment(), engine = CloudSyncEngine(local: local, remote: SuspendedSummary(), media: NoPhotoTransfer(), participation: environment, network: environment)
    var events = await engine.events().makeAsyncIterator()
    _ = await events.next()
    let task = Task { try await engine.synchronize() }
    while let event = await events.next() { if event.phase == .preparing { break } }
    await engine.cancelCurrent()
    await #expect(throws: CancellationError.self) { try await task.value }
    var latest = await engine.events().makeAsyncIterator()
    #expect(await latest.next()?.phase == .idle)
    #expect(try await local.state().mode == .enabling)
}
