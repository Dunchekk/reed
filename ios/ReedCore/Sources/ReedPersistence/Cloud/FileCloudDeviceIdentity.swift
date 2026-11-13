import Foundation
import ReedApplication

public actor FileCloudDeviceIdentity: CloudDeviceIdentity {
    private let url: URL
    public init(directory: URL) { url = directory.appendingPathComponent("cloud-device.json") }
    public func deviceID() throws -> UUID {
        if FileManager.default.fileExists(atPath: url.path) { return try JSONDecoder().decode(UUID.self, from: Data(contentsOf: url)) }
        let id = UUID(); try write(id); return id
    }
    public func renew() throws { try write(UUID()) }
    private func write(_ id: UUID) throws {
        try JSONEncoder().encode(id).write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}
