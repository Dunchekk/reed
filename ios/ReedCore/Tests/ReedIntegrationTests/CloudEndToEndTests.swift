import Foundation
import Testing
import ReedDomain
import ReedApplication
import ReedPersistence
import ReedNetworking

private struct Configuration: Decodable { let baseURL: URL, accountID: UUID, accessToken: String }
private struct FixedToken: AccountTokenProvider {
    let accountID: UUID, accessToken: String
    func token(accountID: UUID, rejectedToken: String?) throws -> String {
        guard accountID == self.accountID, rejectedToken == nil else { throw CloudError.wrongAccount }; return accessToken
    }
}
private struct Environment: CloudParticipation, CloudNetworkPolicy {
    let remote: HTTPCloudClient, identity: FileCloudDeviceIdentity
    func allowsTransfer(wifiOnly: Bool) -> Bool { true }
    func prepareJoin() async throws { try await identity.renew(); try await refreshRegistration() }
    func refreshRegistration() async throws { _ = try await remote.registerDevice(id: identity.deviceID(), name: "Integration iPhone", timeZone: "Europe/Moscow", pushToken: nil) }
    func synchronizationCompleted(epoch: UUID) async throws { try await remote.markReady(epoch: epoch) }
    func leave() async throws { try await remote.unregisterDevice(id: identity.deviceID()) }
    func suspendLocalNotifications() {}
    func resumeLocalNotifications() {}
}
private actor LostCardResponse: CloudRemote {
    let remote: HTTPCloudClient
    var lose = true
    init(_ remote: HTTPCloudClient) { self.remote = remote }
    func summary() async throws -> CloudSummary { try await remote.summary() }
    func pull(epoch: UUID, after: Int64, limit: Int) async throws -> CloudPage { try await remote.pull(epoch: epoch, after: after, limit: limit) }
    func reset(epoch: UUID) async throws -> CloudSummary { try await remote.reset(epoch: epoch) }
    func push(epoch: UUID, mutation: CloudMutation) async throws -> CloudMutationResult {
        let result = try await remote.push(epoch: epoch, mutation: mutation)
        if lose, mutation.kind == .card { lose = false; throw CloudError.unavailable }
        return result
    }
}
private actor InterruptedPhoto: CloudMediaTransferring {
    let transfer: CloudMediaTransfer
    var interrupted = false
    init(_ transfer: CloudMediaTransfer) { self.transfer = transfer }
    func upload(epoch: UUID, id: UUID, progress: CloudProgressHandler) async throws { try await transfer.upload(epoch: epoch, id: id, progress: progress) }
    func download(epoch: UUID, id: UUID, progress: CloudProgressHandler) async throws {
        if !interrupted { interrupted = true; throw CloudError.unavailable }
        try await transfer.download(epoch: epoch, id: id, progress: progress)
    }
    func verifyLocal(ids: [UUID]) async throws { try await transfer.verifyLocal(ids: ids) }
}
private struct Replica {
    let database: LibraryDatabase, cloud: LocalCloudRepository, library: LocalLibraryRepository, files: FileAttachmentStore
    let remote: HTTPCloudClient, identity: FileCloudDeviceIdentity, environment: Environment
    init(root: URL, configuration: Configuration) throws {
        database = try LibraryDatabase(root: root, accountID: configuration.accountID)
        cloud = LocalCloudRepository(database: database); library = LocalLibraryRepository(database: database)
        files = FileAttachmentStore(directory: database.directory); identity = FileCloudDeviceIdentity(directory: database.directory)
        remote = HTTPCloudClient(baseURL: configuration.baseURL, accountID: configuration.accountID,
            tokens: FixedToken(accountID: configuration.accountID, accessToken: configuration.accessToken), identity: identity, wifiOnly: { false })
        environment = Environment(remote: remote, identity: identity)
    }
    func engine(remote override: (any CloudRemote)? = nil) -> CloudSyncEngine {
        CloudSyncEngine(local: cloud, remote: override ?? remote, media: CloudMediaTransfer(local: files, remote: remote),
            participation: environment, network: environment, plan: CloudPlanSynchronizer(remote: remote, local: cloud))
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["REED_CLOUD_E2E_CONFIG"] != nil))
func twoSwiftReplicasUseRealHTTPPostgresPhotosConflictsAndEpochs() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["REED_CLOUD_E2E_CONFIG"])
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    #expect(configuration.baseURL.host == "127.0.0.1")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reed-cloud-e2e-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try Replica(root: root.appendingPathComponent("first"), configuration: configuration)
    let second = try Replica(root: root.appendingPathComponent("second"), configuration: configuration)
    try await first.environment.refreshRegistration(); try await second.environment.refreshRegistration()
    try await first.remote.selectPrimary(id: first.identity.deviceID())
    let epoch = try await first.remote.summary().epoch
    let bytes = Data(repeating: 37, count: 700_000), thumbnail = Data([1,3,5])
    let attachmentID = try await first.files.write(original: bytes, thumbnail: thumbnail)
    let card = Card(text: "Исходный текст", source: Source(title: "Книга", authors: [Author(name: "Автор")]), attachmentIDs: [attachmentID])
    try await first.library.save(card); try await first.cloud.begin(epoch: epoch); try await second.cloud.begin(epoch: epoch)
    let broken = first.engine(remote: LostCardResponse(first.remote))
    await #expect(throws: CloudError.unavailable) { try await broken.synchronize() }
    // A fresh repository/engine must recover the durable outbox after the response was lost.
    let restarted = try Replica(root: root.appendingPathComponent("first"), configuration: configuration), a = restarted.engine(), b = second.engine()
    try await a.synchronize()
    let interrupted = CloudSyncEngine(local: second.cloud, remote: second.remote,
        media: InterruptedPhoto(CloudMediaTransfer(local: second.files, remote: second.remote)), participation: second.environment, network: second.environment)
    await #expect(throws: CloudError.unavailable) { try await interrupted.synchronize() }
    var withoutPhoto = try #require(await second.library.card(id: card.id)); withoutPhoto.comment = "Правка до скачивания фото"
    try await second.library.save(withoutPhoto)
    try await b.synchronize(); try await a.synchronize()
    #expect(try await second.library.card(id: card.id)?.source == card.source)
    #expect(try await second.files.original(id: attachmentID) == bytes)
    var left = try #require(await restarted.library.card(id: card.id)), right = try #require(await second.library.card(id: card.id))
    left.text = "Правка первого"; right.text = "Офлайн-правка второго"
    try await restarted.library.save(left); try await second.library.save(right)
    try await a.synchronize(); try await b.synchronize()
    let conflict = try #require(await second.cloud.conflicts().first)
    #expect(try await second.library.card(id: card.id)?.text == right.text)
    try await b.resolve(id: conflict.id, choice: .both); try await a.synchronize()
    #expect(try await restarted.library.archive(ArchiveQuery(), after: nil).cards.count == 2)
    right = try #require(await second.library.card(id: card.id)); right.comment = "Офлайн после синхронизации"; try await second.library.save(right)
    left = try #require(await restarted.library.card(id: card.id)); left.deletedAt = Date().addingTimeInterval(-8*86400); try await restarted.library.save(left)
    _ = try await restarted.library.purgeTrash(before: Date())
    try await a.synchronize(); try await b.synchronize()
    let deletion = try #require(await second.cloud.conflicts().first)
    #expect(deletion.remote.isDeleted)
    await #expect(throws: CloudError.invalidTransition) { try await b.resolve(id: deletion.id, choice: .local) }
    try await b.resolve(id: deletion.id, choice: .both); try await a.synchronize()
    #expect(try await restarted.library.card(id: card.id) == nil)
    #expect(try await second.library.card(id: card.id) == nil)
    #expect(try await restarted.library.archive(ArchiveQuery(), after: nil).cards.count == 2)
    try await a.deleteCloud(expectedEpoch: epoch)
    await #expect(throws: CloudError.epochChanged) { try await b.synchronize() }
    #expect(try await second.cloud.state().mode == .revoked)
    #expect(try await second.remote.summary().cards == 0)
    #expect(try await second.files.original(id: attachmentID) == bytes)
    try await b.keepLocalAfterRevocation()
    #expect(try await second.cloud.state().mode == .local)
}
