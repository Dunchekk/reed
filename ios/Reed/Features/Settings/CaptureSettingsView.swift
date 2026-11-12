import SwiftUI
import ReedDomain

struct CaptureSettingsView: View {
    let context: LibraryContext
    @State private var preferences = CapturePreferences()
    @State private var loaded = false
    @State private var errorMessage: String?
    var body: some View {
        Form {
            Toggle("Сохранять фото", isOn: Binding(get: { preferences.savesPhotos }, set: { value in
                loaded = false
                Task {
                    var updated = preferences; updated.savesPhotos = value
                    do { try await context.capturePreferences.setCapturePreferences(updated); preferences = updated; errorMessage = nil }
                    catch { errorMessage = "Не удалось сохранить настройку. Повторите попытку." }
                    loaded = true
                }
            })).disabled(!loaded)
            Text("При добавлении страницы распознанный текст сохраняется в любом случае. Выключите, чтобы не прикреплять новые фотографии к карточке. Уже сохранённые фото останутся.").reedFont(.caption)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }.navigationTitle("Добавление").navigationBarTitleDisplayMode(.inline)
        .task {
            do { preferences = try await context.capturePreferences.capturePreferences(); loaded = true }
            catch { errorMessage = "Не удалось прочитать настройку. Откройте экран повторно." }
        }
    }
}
