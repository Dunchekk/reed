import SwiftUI
import PhotosUI
import AVFoundation

struct PhotoInputView: View {
    let apply: (PhotoDraft) -> Void
    @Binding var isProcessing: Bool
    @State private var selection: PhotosPickerItem?
    @State private var showsCamera = false
    @State private var errorMessage: String?
    @State private var work: Task<Void, Never>?
    @State private var generation = UUID()
    private let processor = PhotoProcessor()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
                Label("Выбрать фотографию", systemImage: "photo")
            }.disabled(isProcessing)
            Button("Снять страницу", systemImage: "camera") {
                Task {
                    guard UIImagePickerController.isSourceTypeAvailable(.camera) else { errorMessage = "Камера недоступна на этом устройстве."; return }
                    let allowed = await AVCaptureDevice.requestAccess(for: .video)
                    if allowed { showsCamera = true }
                    else { errorMessage = "Разрешите доступ к камере в настройках iOS или выберите фотографию." }
                }
            }.disabled(isProcessing)
            if isProcessing { ProgressView("Распознаём на устройстве…") }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .onChange(of: selection) { _, item in
            guard let item else { return }
            begin { try await item.loadTransferable(type: Data.self) }
        }
        .sheet(isPresented: $showsCamera) {
            CameraPicker { data in
                showsCamera = false
                if let data { begin { data } }
            }.ignoresSafeArea()
        }
        .onDisappear { generation = UUID(); work?.cancel(); isProcessing = false }
    }

    private func begin(load: @escaping @Sendable () async throws -> Data?) {
        work?.cancel(); let token = UUID(); generation = token; isProcessing = true; errorMessage = nil
        work = Task {
            defer { if generation == token { isProcessing = false; selection = nil } }
            do {
                guard let data = try await load() else { throw PhotoError.invalid }
                let draft = try await processor.process(data)
                guard !Task.isCancelled, generation == token else { return }
                apply(draft)
                if draft.recognizedText.isEmpty { errorMessage = "Текст не найден. Фото сохранится как вложение; добавьте текст вручную." }
            } catch is CancellationError {} catch {
                if generation == token { errorMessage = (error as? PhotoError)?.errorDescription ?? "Не удалось загрузить или распознать фото. Повторите попытку." }
            }
        }
    }
}
