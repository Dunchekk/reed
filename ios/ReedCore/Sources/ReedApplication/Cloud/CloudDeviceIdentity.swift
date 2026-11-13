import Foundation

public protocol CloudDeviceIdentity: Sendable {
    func deviceID() async throws -> UUID
    func renew() async throws
}
