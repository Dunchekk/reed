import Foundation
import Testing
import ReedDomain
import ReedApplication
import ReedNetworking

private final class RequestHandlers: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, Data)
    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    func set(_ host: String, _ handler: Handler?) { lock.withLock { handlers[host] = handler } }
    func get(_ host: String) -> Handler? { lock.withLock { handlers[host] } }
}
private final class CloudTestURLProtocol: URLProtocol, @unchecked Sendable {
    static let handlers = RequestHandlers()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let handler = Self.handlers.get(url.host ?? "") else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let (status, bytes) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    private var payloads: [Data] = []
    func append(_ value: URLRequest) {
        var data = value.httpBody ?? Data()
        if data.isEmpty, let stream = value.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
            }
        }
        lock.withLock { values.append(value); payloads.append(data) }
    }
    func bodies() -> [Data] { lock.withLock { payloads } }
    func requests() -> [URLRequest] { lock.withLock { values } }
}
private actor HTTPTestTokens: AccountTokenProvider {
    var rejected: [String?] = []
    func token(accountID: UUID, rejectedToken: String?) -> String { rejected.append(rejectedToken); return rejectedToken == nil ? "old" : "new" }
}
private struct HTTPTestIdentity: CloudDeviceIdentity {
    let id = UUID()
    func deviceID() -> UUID { id }
    func renew() {}
}

@Suite struct CloudHTTPTests {
    @Test func summaryUsesExactRouteAndRetriesUnauthorizedOnce() async throws {
        let host = UUID().uuidString.lowercased()+".example.test", log = RequestLog(), tokens = HTTPTestTokens(), identity = HTTPTestIdentity()
        let result = CloudSummary(epoch: UUID(), cards: 3, mediaBytes: 100, sequence: 4, notificationsAvailable: false)
        let bytes = try CloudCoding.encoder().encode(result)
        CloudTestURLProtocol.handlers.set(host) { request in
            log.append(request)
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer old" ? (401,Data()) : (200,bytes)
        }
        defer { CloudTestURLProtocol.handlers.set(host,nil) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [CloudTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = HTTPCloudClient(baseURL: URL(string: "https://\(host)")!, accountID: UUID(), tokens: tokens, identity: identity, wifiOnly: { true }, session: session)
        #expect(try await client.summary().cards == 3)
        let requests = log.requests()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.url?.path == "/v1/cloud" && $0.httpMethod == "GET" && !$0.allowsCellularAccess })
        #expect(requests.last?.value(forHTTPHeaderField: "X-Reed-Device") == identity.id.uuidString.lowercased())
        #expect(await tokens.rejected == [nil,"old"])
    }

    @Test func unauthorizedRetryKeepsTheImmutableMutationBody() async throws {
        let host = UUID().uuidString.lowercased()+".example.test", log = RequestLog(), epoch = UUID()
        let tag = Tag(name: "Тема")
        let mutation = try CloudMutation(key: CloudKey(.tag,tag.id), baseVersion: 0, payload: .encode(tag))
        let result = CloudMutationResult(outcome: .applied, record: .init(key: mutation.key, version: 1, sequence: 1, payload: mutation.payload))
        let bytes = try CloudCoding.encoder().encode(result)
        CloudTestURLProtocol.handlers.set(host) { request in
            log.append(request)
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer old" ? (401,Data()) : (200,bytes)
        }
        defer { CloudTestURLProtocol.handlers.set(host,nil) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [CloudTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = HTTPCloudClient(baseURL: URL(string: "https://\(host)")!, accountID: UUID(), tokens: HTTPTestTokens(), identity: HTTPTestIdentity(), wifiOnly: { true }, session: session)
        #expect(try await client.push(epoch: epoch, mutation: mutation).outcome == .applied)
        let payloads = log.bodies()
        #expect(payloads.count == 2 && payloads[0] == payloads[1])
        #expect(try CloudCoding.decoder().decode(CloudMutation.self, from: payloads[0]) == mutation)
    }

    @Test func bodylessCommandsOmitJSONContentTypeAndKeepEpoch() async throws {
        let host = UUID().uuidString.lowercased()+".example.test", log = RequestLog(), epoch = UUID(), upload = UUID()
        CloudTestURLProtocol.handlers.set(host) { request in log.append(request); return (204,Data()) }
        defer { CloudTestURLProtocol.handlers.set(host,nil) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [CloudTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = HTTPCloudClient(baseURL: URL(string: "https://\(host)")!, accountID: UUID(), tokens: HTTPTestTokens(), identity: HTTPTestIdentity(), wifiOnly: { false }, session: session)
        try await client.finishUpload(epoch: epoch, session: upload)
        let request = try #require(log.requests().first)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Reed-Epoch") == epoch.uuidString.lowercased())
        #expect(request.url?.path == "/v1/cloud/uploads/\(upload.uuidString.lowercased())/complete")
    }
}
