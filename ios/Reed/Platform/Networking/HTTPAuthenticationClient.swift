import Foundation
import ReedApplication
import ReedDomain

final class HTTPAuthenticationClient: AuthenticationClient {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func requestCode(phone: PhoneNumber) async throws -> CodeRequest {
        try await send("v1/auth/otp", body: ["phone": phone.value])
    }

    func verifyCode(phone: PhoneNumber, code: String) async throws -> AuthSession {
        try await send("v1/auth/verify", body: ["phone": phone.value, "code": code])
    }

    func refresh(token: String) async throws -> AuthSession {
        try await send("v1/auth/refresh", body: ["refreshToken": token])
    }

    func revoke(token: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/auth/logout"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try await execute(request)
    }

    private func send<T: Decodable>(_ path: String, body: [String: String]) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try WireJSON.decoder().decode(T.self, from: await execute(request))
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(response.statusCode) else {
            struct Envelope: Decodable { let error: APIError }
            if let envelope = try? WireJSON.decoder().decode(Envelope.self, from: data) { throw envelope.error }
            throw URLError(.badServerResponse)
        }
        return data
    }
}
