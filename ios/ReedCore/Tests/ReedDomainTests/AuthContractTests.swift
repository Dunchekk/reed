import Foundation
import Testing
import ReedApplication

@Test func decodesTheSharedServerSessionContract() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: repository.appendingPathComponent("contracts/fixtures/session.json"))
    let session = try WireJSON.decoder().decode(AuthSession.self, from: data)
    #expect(session.account.phone.value == "+70000000001")
    #expect(session.accessToken == "synthetic-access-token")
    #expect(try WireJSON.decoder().decode(AuthSession.self, from: WireJSON.encoder().encode(session)) == session)
}
