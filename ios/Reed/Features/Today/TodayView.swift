import SwiftUI
import ReedDomain

enum CardInput: String { case text, photo, camera }

struct TodayView: View {
    let context: LibraryContext
    let open: (UUID) -> Void
    let add: (CardInput, String) -> Void
    @State private var position: String?
    private var entries: [PlannedReturn] { context.returnCoordinator.plan.entries.filter { Calendar.current.isDateInToday($0.slot.date) && $0.card != nil } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Reed / Сегодня").reedFont(.display)
                Text("Ваши сохранённые тексты.\nПлан на \(Date().formatted(date: .numeric, time: .omitted)).").reedFont(.body)
                if context.returnCoordinator.isRefreshing { ProgressView("Обновляем план…") }
                if let error = context.returnCoordinator.errorMessage {
                    Text(error).foregroundStyle(.red)
                    Button("Повторить") { context.returnCoordinator.refresh() }
                }
                if entries.isEmpty && !context.returnCoordinator.isRefreshing {
                    ContentUnavailableView("Сегодня без возвращений", systemImage: "sun.max", description: Text("Добавьте карточки и включите возвращения. Если всё включено, проверьте дни, правила и паузу 72 часа."))
                    NavigationLink("Настроить возвращения") { ReturnSettingsView(context: context) }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(entries) { entry in
                            if let card = entry.card {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Text(entry.slot.date, style: .time)
                                        Spacer()
                                        Text(entry.slot.date < Date() ? "Выбрано на сегодня" : entry.state == .queued ? "В очереди iOS" : "Запланировано")
                                    }.reedFont(.metadata).foregroundStyle(ReedTheme.secondary)
                                    CardPreview(card: card, compact: false, open: { open(card.id) }, favorite: { favorite(card.id) })
                                    Text(entry.decision.reason.explanation).reedFont(.caption).foregroundStyle(ReedTheme.secondary)
                                }.containerRelativeFrame(.horizontal).id(entry.id)
                            }
                        }
                    }.scrollTargetLayout()
                }.scrollTargetBehavior(.viewAligned).scrollPosition(id: $position)
                if !entries.isEmpty {
                    HStack {
                        Button("Предыдущая", systemImage: "arrow.left") { move(-1) }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        Text("\(selectedIndex + 1) / \(entries.count)").reedFont(.caption)
                        Button("Следующая", systemImage: "arrow.right") { move(1) }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    }.frame(maxWidth: .infinity)
                }
                HStack(spacing: 8) {
                    PasteButton(payloadType: String.self) { values in if let value = values.first { add(.text, value) } }
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 56).accessibilityLabel("Добавить из буфера")
                    Button { add(.camera, "") } label: { Image(systemName: "camera").frame(width: 44, height: 56).reedField() }.accessibilityLabel("Снять страницу")
                    Button("Добавить карточку") { add(.text, "") }.buttonStyle(ReedPrimaryButtonStyle())
                }
                if let until = context.returnCoordinator.report.until {
                    Text("Уведомления в очереди до \(until.formatted(date: .abbreviated, time: .shortened)). Открывайте Reed, чтобы продлевать план.")
                        .reedFont(.metadata).foregroundStyle(ReedTheme.secondary)
                }
            }.padding(ReedTheme.inset)
        }.background(ReedTheme.background)
    }
    private var selectedIndex: Int { entries.firstIndex { $0.id == position } ?? 0 }
    private func move(_ delta: Int) {
        let index = min(max(0, selectedIndex + delta), entries.count - 1)
        guard entries.indices.contains(index) else { return }
        withAnimation { position = entries[index].id }
    }
    private func favorite(_ id: UUID) {
        Task {
            do {
                guard var card = try await context.repository.card(id: id) else { throw LibraryError.notFound }
                card.isFavorite.toggle(); try await context.repository.save(card); context.markChanged()
            } catch { context.returnCoordinator.refresh() }
        }
    }
}
