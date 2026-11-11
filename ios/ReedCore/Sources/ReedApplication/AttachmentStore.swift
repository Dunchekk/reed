import Foundation

public protocol AttachmentStore: Sendable {
    func write(original: Data, thumbnail: Data) async throws -> UUID
    func thumbnail(id: UUID) async throws -> Data
    func original(id: UUID) async throws -> Data
    func originalURL(id: UUID) async throws -> URL
    func remove(id: UUID) async throws
    /// Run before allowing edits; staged files are otherwise indistinguishable from orphans.
    func collectOrphans(retaining ids: Set<UUID>) async throws
}
