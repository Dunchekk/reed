import Foundation
import ReedDomain

public struct CloudMediaTransfer: CloudMediaTransferring {
    private let local: any CloudMediaStore
    private let remote: any CloudMediaRemote
    private let chunkSize = 512*1024
    public init(local: any CloudMediaStore, remote: any CloudMediaRemote) { self.local = local; self.remote = remote }

    public func upload(epoch: UUID, id: UUID, progress: CloudProgressHandler) async throws {
        let manifest = try await local.manifest(id: id); try manifest.validate()
        let session = try await remote.beginUpload(epoch: epoch, manifest: manifest)
        guard session.originalOffset >= 0, session.originalOffset <= manifest.original.size,
              session.thumbnailOffset >= 0, session.thumbnailOffset <= manifest.thumbnail.size else { throw CloudError.corruptedMedia }
        if session.complete { return }
        var completed: Int64 = 0
        for variant in CloudMediaVariant.allCases {
            var offset = session[variant]
            while offset < manifest[variant].size {
                try Task.checkCancellation()
                let count = Int(min(Int64(chunkSize),manifest[variant].size-offset))
                let bytes = try await local.read(id: id, variant: variant, offset: offset, count: count)
                guard bytes.count == count else { throw CloudError.corruptedMedia }
                let next = try await remote.upload(epoch: epoch, session: session.id, variant: variant, offset: offset, bytes: bytes)
                guard next.id == session.id, next[variant] == offset + Int64(bytes.count) else { throw CloudError.corruptedMedia }
                offset = next[variant]
                await progress(CloudProgress(.uploading, completed: completed+offset, total: manifest.original.size+manifest.thumbnail.size))
            }
            completed += manifest[variant].size
        }
        try await remote.finishUpload(epoch: epoch, session: session.id)
    }
    public func download(epoch: UUID, id: UUID, progress: CloudProgressHandler) async throws {
        let manifest = try await remote.manifest(epoch: epoch, id: id); try manifest.validate()
        guard manifest.id == id else { throw CloudError.corruptedMedia }
        if try await local.containsVerified(manifest) { return }
        var completed: Int64 = 0
        for variant in CloudMediaVariant.allCases {
            var offset = try await local.downloadOffset(manifest: manifest, variant: variant)
            guard offset >= 0, offset <= manifest[variant].size else { throw CloudError.corruptedMedia }
            while offset < manifest[variant].size {
                try Task.checkCancellation()
                let count = Int(min(Int64(chunkSize),manifest[variant].size-offset))
                let bytes = try await remote.download(epoch: epoch, id: id, variant: variant, offset: offset, count: count)
                guard bytes.count == count else { throw CloudError.corruptedMedia }
                try await local.appendDownload(manifest: manifest, variant: variant, offset: offset, bytes: bytes)
                offset += Int64(bytes.count)
                await progress(CloudProgress(.downloading, completed: completed+offset, total: manifest.original.size+manifest.thumbnail.size))
            }
            completed += manifest[variant].size
        }
        try await local.finishDownload(manifest: manifest)
    }
    public func verifyLocal(ids: [UUID]) async throws {
        for id in ids { try Task.checkCancellation(); _ = try await local.manifest(id: id) }
    }
}
