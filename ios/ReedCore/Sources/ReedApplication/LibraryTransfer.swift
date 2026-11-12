import Foundation
import ReedDomain

public protocol LibraryBackupRepository: Sendable {
    func summary() async throws -> LibraryStorageSummary
    func snapshot() async throws -> LibraryBackup
    func restore(_ backup: LibraryBackup) async throws -> RestoreResult
    func hasImported(id: UUID) async throws -> Bool
    func clearLibrary() async throws -> Set<UUID>
}
public struct PreparedLibraryBackup: Sendable, Identifiable {
    public let id: UUID
    public let snapshot: LibraryBackup
    public let mediaDirectory: URL
    public init(id: UUID, snapshot: LibraryBackup, mediaDirectory: URL) { self.id = id; self.snapshot = snapshot; self.mediaDirectory = mediaDirectory }
}
public protocol BackupArchiveStore: Sendable {
    func write(_ snapshot: LibraryBackup, attachments: any AttachmentStore) async throws -> URL
    func read(_ url: URL) async throws -> PreparedLibraryBackup
    func media(id: UUID, from backup: PreparedLibraryBackup) async throws -> (original: Data, thumbnail: Data)
    func discard(_ backup: PreparedLibraryBackup) async
    func cleanTemporaryFiles() async throws
}

public actor LibraryTransferService {
    private let repository: any LibraryBackupRepository
    private let attachments: any AttachmentStore
    private let archive: any BackupArchiveStore
    private var busy = false
    public init(repository: any LibraryBackupRepository, attachments: any AttachmentStore, archive: any BackupArchiveStore) {
        self.repository = repository; self.attachments = attachments; self.archive = archive
    }
    public func export() async throws -> URL {
        guard !busy else { throw LibraryError.conflict }; busy = true; defer { busy = false }
        return try await archive.write(repository.snapshot(), attachments: attachments)
    }
    public func summary() async throws -> LibraryStorageSummary { try await repository.summary() }
    public func inspect(_ url: URL) async throws -> PreparedLibraryBackup { try await archive.read(url) }
    public func discard(_ backup: PreparedLibraryBackup) async { await archive.discard(backup) }
    public func restore(_ backup: PreparedLibraryBackup) async throws -> RestoreResult {
        guard !busy else { throw LibraryError.conflict }; busy = true; defer { busy = false }
        if try await repository.hasImported(id: backup.snapshot.id) { return .alreadyImported }
        var mapping: [UUID: UUID] = [:]
        do {
            try backup.snapshot.validate()
            for id in backup.snapshot.attachmentIDs {
                try Task.checkCancellation()
                let data = try await archive.media(id: id, from: backup)
                mapping[id] = try await attachments.write(original: data.original, thumbnail: data.thumbnail)
            }
            let result = try await repository.restore(backup.snapshot.remappingAttachments(mapping))
            if result == .alreadyImported { for id in mapping.values { try? await attachments.remove(id: id) } }
            return result
        } catch { for id in mapping.values { try? await attachments.remove(id: id) }; throw error }
    }
    /// Caller stops notification delivery before clearing data.
    public func clear() async throws {
        guard !busy else { throw LibraryError.conflict }; busy = true; defer { busy = false }
        let ids = try await repository.clearLibrary()
        for id in ids { try await attachments.remove(id: id) }
        try await attachments.collectOrphans(retaining: [])
        try await archive.cleanTemporaryFiles()
    }
}
