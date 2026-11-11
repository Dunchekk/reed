import Foundation
import Testing
import ReedDomain
import ReedApplication
@testable import ReedPersistence

@Test func cloudConflictChoiceCannotDiscardAnEditMadeAfterTheScreenOpened() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reed-conflict-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try LibraryDatabase(root: root, accountID: UUID()), epoch = UUID()
    let library = LocalLibraryRepository(database: database), cloud = LocalCloudRepository(database: database)
    try await cloud.begin(epoch: epoch)
    var remote = Card(text: "Исходная версия")
    try await cloud.apply(CloudPage(epoch: epoch, records: [.init(key: CloudKey(.card,remote.id), version: 1, sequence: 1, payload: .encode(CloudCard(remote)))], cursor: 1, hasMore: false))
    var local = try #require(await library.card(id: remote.id)); local.text = "Моя версия"; try await library.save(local)
    remote.text = "На другом iPhone"
    try await cloud.apply(CloudPage(epoch: epoch, records: [.init(key: CloudKey(.card,remote.id), version: 2, sequence: 2, payload: .encode(CloudCard(remote)))], cursor: 2, hasMore: false))
    let first = try #require(await cloud.conflicts().first)
    local = try #require(await library.card(id: remote.id)); local.text = "Ещё одна правка"; try await library.save(local)
    await #expect(throws: CloudError.conflict) { try await cloud.resolve(id: first.id, choice: .remote) }
    let refreshed = try #require(await cloud.conflicts().first)
    #expect(refreshed.id != first.id)
    try await cloud.resolve(id: refreshed.id, choice: .local)
    let next = try #require(await cloud.nextPending())
    #expect(next.mutation.baseVersion == 2)
    #expect(try next.mutation.payload.decode(CloudCard.self).text == "Ещё одна правка")
}

@Test func cloudKeepBothCopiesLocalCardWithoutResurrectingRemoteTombstone() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reed-conflict-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try LibraryDatabase(root: root, accountID: UUID()), epoch = UUID()
    let library = LocalLibraryRepository(database: database), cloud = LocalCloudRepository(database: database)
    try await cloud.begin(epoch: epoch)
    let remote = Card(text: "Исходная версия")
    try await cloud.apply(CloudPage(epoch: epoch, records: [.init(key: CloudKey(.card,remote.id), version: 1, sequence: 1, payload: .encode(CloudCard(remote)))], cursor: 1, hasMore: false))
    var local = try #require(await library.card(id: remote.id)); local.text = "Оставить этот текст"; try await library.save(local)
    try await cloud.apply(CloudPage(epoch: epoch, records: [.init(key: CloudKey(.card,remote.id), version: 2, sequence: 2, payload: .null)], cursor: 2, hasMore: false))
    let conflict = try #require(await cloud.conflicts().first)
    #expect(!conflict.canKeepLocal && conflict.canKeepBoth)
    await #expect(throws: CloudError.invalidTransition) { try await cloud.resolve(id: conflict.id, choice: .local) }
    try await cloud.resolve(id: conflict.id, choice: .both)
    #expect(try await library.card(id: remote.id) == nil)
    let copies = try await library.archive(ArchiveQuery()).cards
    #expect(copies.count == 1 && copies.first?.id != remote.id)
    let next = try #require(await cloud.nextPending())
    #expect(next.mutation.baseVersion == 0)
    #expect(try next.mutation.payload.decode(CloudCard.self).text == "Оставить этот текст")
}
