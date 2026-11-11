import SwiftUI
import PhotosUI
import AVFoundation
import ReedApplication

struct PhotoInputView: View {
    let initialInput: CardInput
    let savesPhotos: Bool
    let apply: (ProcessedPhoto, String, Bool) async -> Bool
    @State private var selection: [PhotosPickerItem] = []
    @State private var queued: [PhotosPickerItem] = []
    @State private var showsLibrary = false
    @State private var started = false
    @State private var showsCamera = false
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var review: PhotoReviewInput?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Выбрать фотографии", systemImage: "photo.on.rectangle.angled") { showsLibrary = true }.disabled(loading)
            Button("Снять страницу", systemImage: "camera") { Task { await openCamera() } }.disabled(loading)
            if loading { ProgressView("Загружаем фотографию…") }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .photosPicker(isPresented: $showsLibrary, selection: $selection, maxSelectionCount: 10, matching: .images, preferredItemEncoding: .current)
        .task {
            guard !started else { return }; started = true
            if initialInput == .photo { showsLibrary = true }
            else if initialInput == .camera { await openCamera() }
        }
        .onChange(of: selection) { _, items in
            guard !items.isEmpty else { return }
            queued = items; selection = []; advance()
        }
        .sheet(isPresented: $showsCamera) {
            CameraPicker { data in
                showsCamera = false
                if let data { review = PhotoReviewInput(data: data) }
            }.ignoresSafeArea()
        }
        .sheet(item: $review, onDismiss: { advance() }) { input in
            PhotoReviewView(data: input.data, savesPhotos: savesPhotos, apply: apply)
        }
    }
    private func openCamera() async {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { errorMessage = "Камера недоступна на этом устройстве."; return }
        let allowed = await AVCaptureDevice.requestAccess(for: .video)
        if allowed { showsCamera = true }
        else { errorMessage = "Разрешите доступ к камере в настройках iOS или выберите фотографию." }
    }
    private func advance() {
        guard !loading, review == nil, !queued.isEmpty else { return }
        let item = queued.removeFirst(); loading = true; errorMessage = nil
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw PhotoError.invalid }
                review = PhotoReviewInput(data: data)
            } catch { errorMessage = "Не удалось загрузить фото. Выберите его повторно."; queued = [] }
            loading = false
        }
    }
}
