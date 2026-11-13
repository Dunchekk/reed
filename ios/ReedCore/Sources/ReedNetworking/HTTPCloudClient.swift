import Foundation
import ReedDomain
import ReedApplication

/// Transport owns authentication and bytes; it never merges records or changes the local library.
public final class HTTPCloudClient: CloudRemote, CloudMediaRemote, CloudDeviceRemote, CloudReturnRemote {
    private let baseURL: URL
    private let accountID: UUID
    private let tokens: any AccountTokenProvider
    private let identity: any CloudDeviceIdentity
    private let wifiOnly: @Sendable () async throws -> Bool
    private let session: URLSession

    public init(baseURL: URL, accountID: UUID, tokens: any AccountTokenProvider, identity: any CloudDeviceIdentity,
         wifiOnly: @escaping @Sendable () async throws -> Bool, session: URLSession? = nil) {
        self.baseURL = baseURL; self.accountID = accountID; self.tokens = tokens; self.identity = identity; self.wifiOnly = wifiOnly
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 90
            configuration.httpCookieStorage = nil; configuration.urlCache = nil
            self.session = URLSession(configuration: configuration, delegate: CloudRedirectPolicy(), delegateQueue: nil)
        }
    }
    public func returnPlan(epoch: UUID) async throws -> CloudReturnPlan { try await json("returns", method: "GET", epoch: epoch) }
    public func summary() async throws -> CloudSummary { try await json("", method: "GET") }
    public func push(epoch: UUID, mutation: CloudMutation) async throws -> CloudMutationResult {
        try await json("mutations", method: "POST", epoch: epoch, body: CloudCoding.encoder().encode(mutation))
    }
    public func pull(epoch: UUID, after: Int64, limit: Int) async throws -> CloudPage {
        try await json("changes", method: "GET", epoch: epoch, query: ["after":String(after),"limit":String(limit)])
    }
    public func reset(epoch: UUID) async throws -> CloudSummary { try await json("reset", method: "POST", epoch: epoch) }
    public func beginUpload(epoch: UUID, manifest: CloudMediaManifest) async throws -> CloudUpload {
        try await json("uploads", method: "POST", epoch: epoch, body: CloudCoding.encoder().encode(manifest))
    }
    public func upload(epoch: UUID, session: UUID, variant: CloudMediaVariant, offset: Int64, bytes: Data) async throws -> CloudUpload {
        try await json("uploads/\(session.uuidString.lowercased())/\(variant.rawValue)", method: "PUT", epoch: epoch,
            query: ["offset":String(offset)], body: bytes, contentType: "application/octet-stream")
    }
    public func finishUpload(epoch: UUID, session: UUID) async throws {
        _ = try await send("uploads/\(session.uuidString.lowercased())/complete", method: "POST", epoch: epoch)
    }
    public func manifest(epoch: UUID, id: UUID) async throws -> CloudMediaManifest {
        try await json("media/\(id.uuidString.lowercased())", method: "GET", epoch: epoch)
    }
    public func download(epoch: UUID, id: UUID, variant: CloudMediaVariant, offset: Int64, count: Int) async throws -> Data {
        try await send("media/\(id.uuidString.lowercased())/\(variant.rawValue)", method: "GET", epoch: epoch,
            query: ["offset":String(offset),"count":String(count)])
    }
    public func registerDevice(id: UUID, name: String, timeZone: String, pushToken: String?) async throws -> CloudDevice {
        let body = CloudValue.object(["id":.string(id.uuidString.lowercased()),"name":.string(name),"timeZone":.string(timeZone),"pushToken":pushToken.map(CloudValue.string) ?? .null])
        return try await json("devices", method: "POST", body: CloudCoding.encoder().encode(body))
    }
    public func markReady(epoch: UUID) async throws { _ = try await send("device/ready", method: "POST", epoch: epoch) }
    public func pauseDevice() async throws { _ = try await send("device/pause", method: "POST") }
    public func devices() async throws -> [CloudDevice] { try await json("devices", method: "GET") }
    public func selectPrimary(id: UUID) async throws { _ = try await send("devices/\(id.uuidString.lowercased())/primary", method: "PUT") }
    public func unregisterDevice(id: UUID) async throws { _ = try await send("devices/\(id.uuidString.lowercased())", method: "DELETE") }

    private func json<T: Decodable>(_ path: String, method: String, epoch: UUID? = nil, query: [String:String] = [:], body: Data? = nil,
                                    contentType: String = "application/json") async throws -> T {
        try await CloudCoding.decoder().decode(T.self, from: send(path, method: method, epoch: epoch, query: query, body: body, contentType: contentType))
    }
    private func send(_ path: String, method: String, epoch: UUID? = nil, query: [String:String] = [:], body: Data? = nil,
                      contentType: String = "application/json") async throws -> Data {
        let endpoint = baseURL.appendingPathComponent("v1/cloud")
        var components = URLComponents(url: path.isEmpty ? endpoint : endpoint.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components?.url else { throw CloudError.unavailable }
        var request = URLRequest(url: url)
        if path == "device/pause" { request.timeoutInterval = 5 }
        request.httpMethod = method; request.httpBody = body
        request.allowsCellularAccess = try await !wifiOnly()
        if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.setValue(try await identity.deviceID().uuidString.lowercased(), forHTTPHeaderField: "X-Reed-Device")
        if let epoch { request.setValue(epoch.uuidString.lowercased(), forHTTPHeaderField: "X-Reed-Epoch") }
        var token = try await tokens.token(accountID: accountID, rejectedToken: nil)
        for attempt in 0...1 {
            try Task.checkCancellation()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if response.statusCode == 401 && attempt == 0 {
                token = try await tokens.token(accountID: accountID, rejectedToken: token); continue
            }
            guard (200..<300).contains(response.statusCode) else { throw Self.error(data) }
            return data
        }
        throw URLError(.userAuthenticationRequired)
    }
    private static func error(_ data: Data) -> any Error {
        struct Envelope: Decodable { let error: APIError }
        guard let error = try? WireJSON.decoder().decode(Envelope.self, from: data).error else { return URLError(.badServerResponse) }
        switch error.code {
        case "epoch_changed": return CloudError.epochChanged
        case "device_revoked": return CloudError.deviceRevoked
        case "operation_reused": return CloudError.operationReused
        case "missing_media", "not_found": return CloudError.missingMedia
        case "corrupted_media": return CloudError.corruptedMedia
        case "invalid_record": return CloudError.invalidRecord
        case "quota_exceeded": return CloudError.quotaExceeded
        default: return error
        }
    }
}

private final class CloudRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
