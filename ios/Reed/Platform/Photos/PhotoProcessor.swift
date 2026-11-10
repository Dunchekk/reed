import Foundation
import ImageIO
import Vision
import UniformTypeIdentifiers

struct PhotoDraft: Sendable {
    let original: Data
    let thumbnail: Data
    let recognizedText: String
    let recognitionFailed: Bool
}

enum PhotoError: LocalizedError {
    case invalid, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalid: "Не удалось прочитать фотографию. Выберите другое изображение."
        case .tooLarge: "Фотография слишком большая. Выберите файл до 40 МБ."
        }
    }
}

/// Actor isolation keeps decoding and recognition away from the UI executor.
actor PhotoProcessor {
    func process(_ data: Data) throws -> PhotoDraft {
        guard data.count <= 40 * 1_024 * 1_024 else { throw PhotoError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw PhotoError.invalid }
        try Task.checkCancellation()
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2400]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw PhotoError.invalid }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        var recognitionFailed = false
        var text = ""
        do {
            let supported = try request.supportedRecognitionLanguages()
            request.recognitionLanguages = ["ru-RU", "en-US"].filter { supported.contains($0) }
            try VNImageRequestHandler(cgImage: image).perform([request])
            text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        } catch { recognitionFailed = true }
        try Task.checkCancellation()
        let thumbnailOptions: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1200]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { throw PhotoError.invalid }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw PhotoError.invalid }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PhotoError.invalid }
        return PhotoDraft(original: data, thumbnail: output as Data, recognizedText: text, recognitionFailed: recognitionFailed)
    }
}
