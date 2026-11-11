import SwiftUI
import ReedApplication

struct PhotoReviewInput: Identifiable { let id = UUID(); let data: Data }

struct PhotoReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let savesPhotos: Bool
    let apply: (ProcessedPhoto, String, Bool) async -> Bool
    @State private var model: PhotoReviewModel
    @State private var applying = false
    @State private var savedFragment = false
    init(data: Data, savesPhotos: Bool, apply: @escaping (ProcessedPhoto, String, Bool) async -> Bool) {
        self.savesPhotos = savesPhotos; self.apply = apply
        _model = State(initialValue: PhotoReviewModel(data: data))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Выберите участок страницы") {
                    if let photo = model.result, let image = UIImage(data: photo.thumbnail) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .overlay {
                                GeometryReader { proxy in
                                    Rectangle().stroke(.white, style: StrokeStyle(lineWidth: 2, dash: [6]))
                                        .background(.white.opacity(0.08))
                                        .frame(width: proxy.size.width * model.region.width, height: proxy.size.height * model.region.height)
                                        .offset(x: proxy.size.width * model.region.x, y: proxy.size.height * model.region.y)
                                    Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 3).onChanged { value in
                                        let x1 = min(max(value.startLocation.x / proxy.size.width, 0), 1)
                                        let y1 = min(max(value.startLocation.y / proxy.size.height, 0), 1)
                                        let x2 = min(max(value.location.x / proxy.size.width, 0), 1)
                                        let y2 = min(max(value.location.y / proxy.size.height, 0), 1)
                                        if abs(x2-x1) > 0.02 && abs(y2-y1) > 0.02 { model.region = PhotoRegion(x: min(x1,x2), y: min(y1,y2), width: abs(x2-x1), height: abs(y2-y1)) }
                                    })
                                }
                            }.accessibilityLabel("Страница. Проведите пальцем, чтобы выделить участок для распознавания.")
                    }
                    HStack {
                        Button("Вся страница") { model.region = PhotoRegion() }
                        Spacer()
                        Button("Распознать участок") { Task { await model.recognize() } }
                    }.buttonStyle(.borderless)
                    Text("Выделение ограничивает распознавание. Если сохранение фото включено, прикрепляется полный оригинал.").reedFont(.metadata)
                }
                Section("Оставьте нужный фрагмент") {
                    TextEditor(text: $model.text).frame(minHeight: 200).reedFont(.body)
                    if let message = model.message { Text(message).foregroundStyle(ReedTheme.secondary) }
                    if savedFragment { Text("Фрагмент добавлен в черновики. Можно выбрать следующий.").foregroundStyle(ReedTheme.secondary) }
                    Text(savesPhotos ? "Оригинал будет прикреплён." : "Будет сохранён только текст.").reedFont(.metadata)
                    Button("Добавить отдельный черновик") {
                        guard let photo = model.result else { return }
                        applying = true
                        Task { savedFragment = await apply(photo, model.text, true); applying = false }
                    }.disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if model.working || applying { ProgressView("Обрабатываем…") }
            }.disabled(model.working || applying)
            .navigationTitle("Фото и текст").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(applying) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить") {
                        guard let photo = model.result else { return }
                        applying = true
                        Task { if await apply(photo, model.text, false) { dismiss() }; applying = false }
                    }.disabled(model.result == nil || model.working || applying)
                }
            }.interactiveDismissDisabled(applying)
            .task { await model.recognize() }
        }
    }
}
