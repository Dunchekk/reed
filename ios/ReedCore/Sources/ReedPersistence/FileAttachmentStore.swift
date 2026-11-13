import Foundation
import ReedApplication

/// Paths are derived exclusively from UUIDs, never user filenames or source URLs.
public actor FileAttachmentStore: AttachmentStore {
    let directory: URL
    public init(directory: URL) { self.directory = directory.appendingPathComponent("attachments", isDirectory: true) }

    public func write(original: Data, thumbnail: Data) throws -> UUID {
        let id = UUID(), folder = path(UUID())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try original.write(to: folder.appendingPathComponent("original"), options: .atomic)
            try thumbnail.write(to: folder.appendingPathComponent("thumbnail.jpg"), options: .atomic)
            #if os(iOS)
            for name in ["original", "thumbnail.jpg"] {
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: folder.appendingPathComponent(name).path)
            }
            #endif
            try FileManager.default.moveItem(at: folder, to: path(id))
            return id
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    public func thumbnail(id: UUID) throws -> Data { try Data(contentsOf: path(id).appendingPathComponent("thumbnail.jpg")) }
    public func original(id: UUID) throws -> Data { try Data(contentsOf: originalURL(id: id)) }
    public func originalURL(id: UUID) throws -> URL {
        let url = path(id).appendingPathComponent("original")
        guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
        return url
    }
    public func remove(id: UUID) throws {
        if FileManager.default.fileExists(atPath: path(id).path) { try FileManager.default.removeItem(at: path(id)) }
    }
    public func collectOrphans(retaining ids: Set<UUID>) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if let id = UUID(uuidString: url.lastPathComponent), !ids.contains(id) { try FileManager.default.removeItem(at: url) }
        }
    }
    func path(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true) }
}
