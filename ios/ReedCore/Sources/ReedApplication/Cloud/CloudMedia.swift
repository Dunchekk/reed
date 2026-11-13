import Foundation
import ReedDomain

public struct CloudUpload: Codable, Sendable {
    public let id: UUID
    public let originalOffset: Int64, thumbnailOffset: Int64
    public let complete: Bool
    public init(id: UUID, originalOffset: Int64, thumbnailOffset: Int64, complete: Bool) {
        self.id = id; self.originalOffset = originalOffset; self.thumbnailOffset = thumbnailOffset; self.complete = complete
    }
    public subscript(_ variant: CloudMediaVariant) -> Int64 { variant == .original ? originalOffset : thumbnailOffset }
}
public protocol CloudMediaRemote: Sendable {
    func beginUpload(epoch: UUID, manifest: CloudMediaManifest) async throws -> CloudUpload
    func upload(epoch: UUID, session: UUID, variant: CloudMediaVariant, offset: Int64, bytes: Data) async throws -> CloudUpload
    func finishUpload(epoch: UUID, session: UUID) async throws
    func manifest(epoch: UUID, id: UUID) async throws -> CloudMediaManifest
    func download(epoch: UUID, id: UUID, variant: CloudMediaVariant, offset: Int64, count: Int) async throws -> Data
}
public protocol CloudMediaStore: Sendable {
    func manifest(id: UUID) async throws -> CloudMediaManifest
    func read(id: UUID, variant: CloudMediaVariant, offset: Int64, count: Int) async throws -> Data
    func downloadOffset(manifest: CloudMediaManifest, variant: CloudMediaVariant) async throws -> Int64
    func appendDownload(manifest: CloudMediaManifest, variant: CloudMediaVariant, offset: Int64, bytes: Data) async throws
    func finishDownload(manifest: CloudMediaManifest) async throws
    func containsVerified(_ manifest: CloudMediaManifest) async throws -> Bool
}
public struct CloudDevice: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String, timeZone: String
    public let isPrimary: Bool
    public let lastSeenAt: Date
    public init(id: UUID, name: String, timeZone: String, isPrimary: Bool, lastSeenAt: Date) {
        self.id = id; self.name = name; self.timeZone = timeZone; self.isPrimary = isPrimary; self.lastSeenAt = lastSeenAt
    }
}
public protocol CloudDeviceRemote: Sendable {
    func markReady(epoch: UUID) async throws
    func pauseDevice() async throws
    func registerDevice(id: UUID, name: String, timeZone: String, pushToken: String?) async throws -> CloudDevice
    func devices() async throws -> [CloudDevice]
    func selectPrimary(id: UUID) async throws
    func unregisterDevice(id: UUID) async throws
}
