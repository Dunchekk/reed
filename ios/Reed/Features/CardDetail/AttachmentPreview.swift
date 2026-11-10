import SwiftUI
import ReedApplication

struct AttachmentPreview: View {
    let id: UUID
    let store: any AttachmentStore
    @State private var image: UIImage?
    @State private var originalURL: URL?
    @State private var failed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("Фотография карточки")
                if let originalURL { ShareLink("Открыть или отправить оригинал", item: originalURL) }
            } else if failed { Label("Фотография недоступна", systemImage: "photo.badge.exclamationmark") }
            else { ProgressView() }
        }.task(id: id) {
            do {
                let data = try await store.thumbnail(id: id)
                image = UIImage(data: data)
                originalURL = try await store.originalURL(id: id)
                failed = image == nil
            } catch { failed = true }
        }
    }
}
