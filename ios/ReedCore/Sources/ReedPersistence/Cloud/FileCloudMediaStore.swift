import Foundation
import CryptoKit
import ReedDomain
import ReedApplication

extension FileAttachmentStore: CloudMediaStore {
    var downloads: URL { directory.deletingLastPathComponent().appendingPathComponent("cloud-downloads", isDirectory: true) }
    func staged(_ id: UUID) -> URL { downloads.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true) }
    private func filename(_ variant: CloudMediaVariant) -> String { variant == .original ? "original" : "thumbnail.jpg" }

    public func manifest(id: UUID) throws -> CloudMediaManifest {
        let value = try inspect(id: id, folder: path(id)); try value.validate()
        let url = path(id).appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: url.path) {
            guard try CloudCoding.decoder().decode(CloudMediaManifest.self, from: Data(contentsOf: url)) == value else { throw CloudError.corruptedMedia }
        } else { try CloudCoding.encoder().encode(value).write(to: url, options: .atomic) }
        return value
    }
    public func containsVerified(_ manifest: CloudMediaManifest) throws -> Bool {
        try manifest.validate()
        guard FileManager.default.fileExists(atPath: path(manifest.id).path) else { return false }
        do { return try inspect(id: manifest.id, folder: path(manifest.id)) == manifest }
        catch CocoaError.fileReadNoSuchFile { return false }
    }
    public func read(id: UUID, variant: CloudMediaVariant, offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count > 0, count <= 512*1024 else { throw CloudError.invalidRecord }
        let file = try FileHandle(forReadingFrom: path(id).appendingPathComponent(filename(variant)))
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(offset))
        return try file.read(upToCount: count) ?? Data()
    }
    public func downloadOffset(manifest: CloudMediaManifest, variant: CloudMediaVariant) throws -> Int64 {
        try prepare(manifest)
        let url = staged(manifest.id).appendingPathComponent(filename(variant))
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path), size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if try size > manifest[variant].size || (size == manifest[variant].size && hash(url) != manifest[variant]) {
            try FileManager.default.removeItem(at: url); return 0
        }
        return size
    }
    public func appendDownload(manifest: CloudMediaManifest, variant: CloudMediaVariant, offset: Int64, bytes: Data) throws {
        try prepare(manifest)
        guard offset >= 0, !bytes.isEmpty, bytes.count <= 512*1024, offset <= manifest[variant].size - Int64(bytes.count) else { throw CloudError.corruptedMedia }
        let url = staged(manifest.id).appendingPathComponent(filename(variant))
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url, options: .atomic) }
        let file = try FileHandle(forUpdating: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        guard UInt64(offset) <= size else { throw CloudError.corruptedMedia }
        let overlap = min(Int64(bytes.count),Int64(size)-offset)
        if overlap > 0 {
            try file.seek(toOffset: UInt64(offset))
            guard try file.read(upToCount: Int(overlap)) == bytes.prefix(Int(overlap)) else { throw CloudError.corruptedMedia }
        }
        try file.seek(toOffset: UInt64(offset+overlap))
        try file.write(contentsOf: bytes.dropFirst(Int(overlap)))
        try file.synchronize()
    }
    public func finishDownload(manifest: CloudMediaManifest) throws {
        try manifest.validate()
        if try containsVerified(manifest) {
            if FileManager.default.fileExists(atPath: staged(manifest.id).path) { try FileManager.default.removeItem(at: staged(manifest.id)) }
            return
        }
        try prepare(manifest)
        for variant in CloudMediaVariant.allCases {
            let url = staged(manifest.id).appendingPathComponent(filename(variant))
            guard try hash(url) == manifest[variant] else {
                try FileManager.default.removeItem(at: url)
                throw CloudError.corruptedMedia
            }
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            #endif
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: path(manifest.id).path) {
            _ = try FileManager.default.replaceItemAt(path(manifest.id), withItemAt: staged(manifest.id))
        } else { try FileManager.default.moveItem(at: staged(manifest.id), to: path(manifest.id)) }
    }

    private func prepare(_ manifest: CloudMediaManifest) throws {
        try manifest.validate()
        let folder = staged(manifest.id), url = folder.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: url.path) {
            guard try CloudCoding.decoder().decode(CloudMediaManifest.self, from: Data(contentsOf: url)) == manifest else { throw CloudError.corruptedMedia }
            return
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try CloudCoding.encoder().encode(manifest).write(to: url, options: .atomic)
    }
    private func inspect(id: UUID, folder: URL) throws -> CloudMediaManifest {
        try CloudMediaManifest(id: id, original: hash(folder.appendingPathComponent("original")), thumbnail: hash(folder.appendingPathComponent("thumbnail.jpg")))
    }
    private func hash(_ url: URL) throws -> CloudMediaPart {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256(), size: Int64 = 0
        while let bytes = try file.read(upToCount: 512*1024), !bytes.isEmpty {
            size += Int64(bytes.count); digest.update(data: bytes)
            guard size <= 40*1024*1024 else { throw CloudError.corruptedMedia }
        }
        return CloudMediaPart(size: size, sha256: digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
