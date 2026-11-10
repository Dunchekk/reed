import SwiftUI
import ReedDomain

struct ActivityView: View {
    let context: LibraryContext
    let open: (UUID) -> Void
    @State private var snapshot: ActivitySnapshot?
    @State private var errorMessage: String?
    @State private var confirmsClear = false
    var body: some View {
        Form {
            if let snapshot {
                Section("Библиотека") {
                    LabeledContent("Карточек", value: "\(snapshot.cards)")
                    LabeledContent("В избранном", value: "\(snapshot.favorites)")
                }
                Section {
                    Toggle("История открытий", isOn: Binding(get: { snapshot.enabled }, set: { enabled in
                        Task { do { try await context.activity.setHistoryEnabled(enabled); context.markChanged(); await load() } catch { errorMessage = libraryErrorMessage(error) } }
                    }))
                    Button("Очистить историю", role: .destructive) { confirmsClear = true }
                } footer: { Text("Храним открытия 90 дней. Когда история выключена, новые открытия не записываются, а сохранённые не используются в подборках. Журнал возвращений хранится отдельно.") }
                if snapshot.enabled {
                    Section("Последние 100 открытий") {
                        ForEach(snapshot.openings) { event in
                            Button { open(event.cardID) } label: {
                                VStack(alignment: .leading) {
                                    Text(event.title).lineLimit(2)
                                    Text("\(ReedDatePresentation.dateTime(event.date)) · \(event.origin == .manual ? "Вручную" : "Из уведомления")")
                                        .reedFont(.metadata).foregroundStyle(ReedTheme.secondary)
                                }
                            }
                        }
                    }
                }
            } else { ProgressView() }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red); Button("Повторить") { Task { await load() } } }
        }.navigationTitle("Активность")
        .task { await load() }
        .confirmationDialog("Очистить историю открытий?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Очистить", role: .destructive) {
                Task { do { try await context.activity.clearOpenings(); context.markChanged(); await load() } catch { errorMessage = libraryErrorMessage(error) } }
            }
        }
    }
    private func load() async {
        do { snapshot = try await context.activity.activity(now: Date()); errorMessage = nil }
        catch { errorMessage = libraryErrorMessage(error) }
    }
}
