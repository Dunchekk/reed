import Foundation
import Observation
import ReedApplication

@MainActor @Observable
final class PhotoReviewModel {
    var region = PhotoRegion()
    var text = ""
    private(set) var result: ProcessedPhoto?
    private(set) var working = false
    private(set) var message: String?
    @ObservationIgnored private let data: Data
    @ObservationIgnored private let processor: any PhotoProcessing
    init(data: Data, processor: any PhotoProcessing = PhotoProcessor()) { self.data = data; self.processor = processor }
    func recognize() async {
        guard !working else { return }
        working = true; defer { working = false }
        do {
            let photo = try await processor.process(data, region: region)
            guard !Task.isCancelled else { return }
            result = photo; text = photo.recognizedText
            message = photo.recognitionFailed ? "Не удалось распознать текст. Можно ввести его вручную." : photo.recognizedText.isEmpty ? "Текст не найден. Выберите другой участок или введите текст." : nil
        } catch { message = (error as? LocalizedError)?.errorDescription ?? "Не удалось обработать фотографию." }
    }
}
