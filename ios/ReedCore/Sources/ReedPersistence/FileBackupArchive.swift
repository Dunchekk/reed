import Foundation
import CryptoKit
import ReedDomain
import ReedApplication

/// A framed file: magic, bounded JSON manifest + SHA-256, then streamed immutable photo bytes.
public actor FileBackupArchive: BackupArchiveStore {
    private struct Media: Codable {
        let id: UUID
        let originalSize: Int, thumbnailSize: Int
        let originalHash: Data, thumbnailHash: Data
    }
    private struct Manifest: Codable {
        let version: Int
        let snapshot: LibraryBackup
        let media: [Media]
    }
    private let directory: URL
    private static let magic = Data("REEDBK01".utf8)
    private static let maximumManifest = 128 * 1024 * 1024
    public init(directory: URL) { self.directory = directory.appendingPathComponent("transfers", isDirectory: true) }

    public func write(_ snapshot: LibraryBackup, attachments: any AttachmentStore) async throws -> URL {
        try snapshot.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Reed-\(UUID().uuidString).reedbackup")
        var descriptors: [Media] = [], originals: [UUID: URL] = [:]
        for id in snapshot.attachmentIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            try Task.checkCancellation()
            let original = try await attachments.originalURL(id: id)
            let thumbnail = try await attachments.thumbnail(id: id)
            let size = try original.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 40*1024*1024, !thumbnail.isEmpty, thumbnail.count <= 10*1024*1024 else { throw BackupError.tooLarge }
            let input = try FileHandle(forReadingFrom: original); defer { try? input.close() }
            let hash = try Self.copy(input, to: nil, count: size)
            descriptors.append(Media(id: id, originalSize: size, thumbnailSize: thumbnail.count, originalHash: hash, thumbnailHash: Data(SHA256.hash(data: thumbnail))))
            originals[id] = original
        }
        let data = try JSONEncoder().encode(Manifest(version: 1, snapshot: snapshot, media: descriptors))
        guard data.count <= Self.maximumManifest else { throw BackupError.tooLarge }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let output = try FileHandle(forWritingTo: url); defer { try? output.close() }
            try output.write(contentsOf: Self.magic)
            var length = UInt64(data.count).littleEndian
            try withUnsafeBytes(of: &length) { try output.write(contentsOf: Data($0)) }
            try output.write(contentsOf: data); try output.write(contentsOf: Data(SHA256.hash(data: data)))
            for descriptor in descriptors {
                guard let original = originals[descriptor.id] else { throw BackupError.invalidArchive }
                let input = try FileHandle(forReadingFrom: original); defer { try? input.close() }
                guard try Self.copy(input, to: output, count: descriptor.originalSize) == descriptor.originalHash else { throw BackupError.invalidArchive }
                let thumbnail = try await attachments.thumbnail(id: descriptor.id)
                guard Data(SHA256.hash(data: thumbnail)) == descriptor.thumbnailHash else { throw BackupError.invalidArchive }
                try output.write(contentsOf: thumbnail)
            }
            try output.synchronize()
            return url
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }
    public func read(_ url: URL) throws -> PreparedLibraryBackup {
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        guard try Self.exact(input, count: 8) == Self.magic else { throw BackupError.invalidArchive }
        let bytes = try Self.exact(input, count: 8)
        let count = bytes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        guard count > 0, count <= Self.maximumManifest else { throw BackupError.tooLarge }
        let data = try Self.exact(input, count: Int(count)), digest = try Self.exact(input, count: 32)
        guard Data(SHA256.hash(data: data)) == digest else { throw BackupError.invalidArchive }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.version == 1 else { throw BackupError.unsupportedVersion }
        try manifest.snapshot.validate()
        guard Set(manifest.media.map(\.id)).count == manifest.media.count,
              Set(manifest.media.map(\.id)) == manifest.snapshot.attachmentIDs else { throw BackupError.invalidArchive }
        let id = UUID(), staging = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for media in manifest.media {
                guard media.originalSize > 0, media.originalSize <= 40*1024*1024,
                      media.thumbnailSize > 0, media.thumbnailSize <= 10*1024*1024,
                      media.originalHash.count == 32, media.thumbnailHash.count == 32 else { throw BackupError.invalidArchive }
                let folder = staging.appendingPathComponent(media.id.uuidString.lowercased(), isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (name, size, hash) in [("original",media.originalSize,media.originalHash),("thumbnail.jpg",media.thumbnailSize,media.thumbnailHash)] {
                    let target = folder.appendingPathComponent(name)
                    guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                    let output = try FileHandle(forWritingTo: target); defer { try? output.close() }
                    guard try Self.copy(input, to: output, count: size) == hash else { throw BackupError.invalidArchive }
                }
            }
            guard try input.read(upToCount: 1)?.isEmpty != false else { throw BackupError.invalidArchive }
            return PreparedLibraryBackup(id: id, snapshot: manifest.snapshot, mediaDirectory: staging)
        } catch { try? FileManager.default.removeItem(at: staging); throw error }
    }
    public func media(id: UUID, from backup: PreparedLibraryBackup) throws -> (original: Data, thumbnail: Data) {
        let folder = backup.mediaDirectory.appendingPathComponent(id.uuidString.lowercased())
        return (try Data(contentsOf: folder.appendingPathComponent("original")), try Data(contentsOf: folder.appendingPathComponent("thumbnail.jpg")))
    }
    public func discard(_ backup: PreparedLibraryBackup) { try? FileManager.default.removeItem(at: backup.mediaDirectory) }
    public func cleanTemporaryFiles() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    private static func exact(_ input: FileHandle, count: Int) throws -> Data {
        var data = Data(); data.reserveCapacity(count)
        while data.count < count {
            guard let part = try input.read(upToCount: count - data.count), !part.isEmpty else { throw BackupError.invalidArchive }
            data.append(part)
        }
        return data
    }
    private static func copy(_ input: FileHandle, to output: FileHandle?, count: Int) throws -> Data {
        var remaining = count, hash = SHA256()
        while remaining > 0 {
            try Task.checkCancellation()
            let part = try exact(input, count: min(remaining, 64*1024))
            hash.update(data: part); try output?.write(contentsOf: part); remaining -= part.count
        }
        return Data(hash.finalize())
    }
}
