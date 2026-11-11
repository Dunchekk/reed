import Foundation

public enum CloudMode: String, Codable, Sendable { case local, enabling, cloud, disabling, revoked }
public struct CloudState: Codable, Equatable, Sendable {
    public var mode: CloudMode = .local
    public var epoch: UUID?
    public var cursor: Int64 = 0
    public var automatic = true
    public var wifiOnly = true
    public var lastSyncAt: Date?
    public init() {}
    public var participates: Bool { mode == .enabling || mode == .cloud || mode == .disabling }
    public mutating func begin(epoch: UUID) throws {
        guard mode == .local || mode == .revoked else { throw CloudError.invalidTransition }
        self.epoch = epoch; cursor = 0; mode = .enabling; lastSyncAt = nil
    }
    public func check(epoch: UUID) throws { guard self.epoch == epoch else { throw CloudError.epochChanged } }
}
public enum CloudResolution: String, Sendable { case remote, local, both }
public struct CloudConflict: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let remote: CloudRecord
    public let local: CloudValue
    public let generation: Int64
    public var canKeepBoth: Bool { remote.kind == .card && local != .null }
    public init(id: UUID = UUID(), remote: CloudRecord, local: CloudValue, generation: Int64) {
        self.id = id; self.remote = remote; self.local = local; self.generation = generation
    }
}
public struct CloudMediaPart: Codable, Equatable, Sendable {
    public let size: Int64
    public let sha256: String
    public init(size: Int64, sha256: String) { self.size = size; self.sha256 = sha256 }
    public func validate(maximum: Int64) throws {
        guard (1...maximum).contains(size), sha256.count == 64,
              sha256.allSatisfy({ $0.isASCII && ("0123456789abcdef".contains($0)) }) else { throw CloudError.corruptedMedia }
    }
}
public enum CloudMediaVariant: String, Codable, CaseIterable, Sendable { case original, thumbnail }
public struct CloudMediaManifest: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let original: CloudMediaPart, thumbnail: CloudMediaPart
    public init(id: UUID, original: CloudMediaPart, thumbnail: CloudMediaPart) { self.id = id; self.original = original; self.thumbnail = thumbnail }
    public subscript(_ kind: CloudMediaVariant) -> CloudMediaPart { kind == .original ? original : thumbnail }
    public func validate() throws { try original.validate(maximum:40*1024*1024); try thumbnail.validate(maximum:10*1024*1024) }
}
