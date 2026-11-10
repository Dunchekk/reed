import Foundation
import Testing
import ReedDomain
import ReedApplication

@Test(arguments: ["+7 (000) 000-00-01", "70000000001", "8 000 000 00 01"])
func normalizesPhoneNumber(input: String) throws {
    #expect(try PhoneNumber(input).value == "+70000000001")
}

@Test(arguments: ["+10000000001", "+80000000001", "7+0000000001", "call 70000000001", "7000", ""])
func rejectsInvalidPhoneNumber(input: String) {
    #expect(throws: ValidationError.invalidPhone) { try PhoneNumber(input) }
}

@Test func expiredServerAccessPreservesTheLocalAccountUntilLogout() throws {
    let account = Account(id: UUID(), phone: try PhoneNumber("+70000000001"))
    let expired = SessionAccess.local(account)
    #expect(expired.localAccount == account)
    #expect(!expired.allowsServerOperations)
    #expect(SessionAccess.signedOut.localAccount == nil)
}

@Test func decodedPhoneNumbersAreValidated() {
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(PhoneNumber.self, from: Data("\"invalid\"".utf8))
    }
}
