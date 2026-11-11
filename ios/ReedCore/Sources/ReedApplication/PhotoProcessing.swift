import Foundation

public struct PhotoRegion: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var isValid: Bool { x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1.000001 && y + height <= 1.000001 }
}

public struct ProcessedPhoto: Sendable {
    public let original: Data
    public let thumbnail: Data
    public let recognizedText: String
    public let recognitionFailed: Bool
    public init(original: Data, thumbnail: Data, recognizedText: String, recognitionFailed: Bool) {
        self.original = original; self.thumbnail = thumbnail; self.recognizedText = recognizedText; self.recognitionFailed = recognitionFailed
    }
}

public protocol PhotoProcessing: Sendable {
    func process(_ data: Data, region: PhotoRegion) async throws -> ProcessedPhoto
}
