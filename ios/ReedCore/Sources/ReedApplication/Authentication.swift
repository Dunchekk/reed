import Foundation
import ReedDomain

public struct AuthSession: Codable, Equatable, Sendable {
    public let account: Account
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date

    public init(account: Account, accessToken: String, refreshToken: String, expiresAt: Date) {
        self.account = account
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

public struct CodeRequest: Codable, Sendable {
    public let retryAt: Date
}

public protocol AuthenticationClient: Sendable {
    func requestCode(phone: PhoneNumber) async throws -> CodeRequest
    func verifyCode(phone: PhoneNumber, code: String) async throws -> AuthSession
    func refresh(token: String) async throws -> AuthSession
    func revoke(token: String) async throws
}

public protocol SessionStore: Sendable {
    func load() throws -> AuthSession?
    func save(_ session: AuthSession) throws
    func clear() throws
}

public struct APIError: Error, Decodable, Sendable {
    public let code: String
    public let message: String
    public let retryAt: Date?
}

public enum WireJSON {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO 8601 date")
        }
        return decoder
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
