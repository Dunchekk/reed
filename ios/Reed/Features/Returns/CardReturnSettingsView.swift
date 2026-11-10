import SwiftUI
import ReedDomain

struct CardReturnSettingsView: View {
    let context: LibraryContext
    let cardID: UUID
    @State private var rule: CardReturnSettings
    @State private var allowsReturns = true
    @State private var loaded = false
    @State private var saving = false
    @State private var time = Date()
    @State private var errorMessage: String?
    init(context: LibraryContext, cardID: UUID) {
        self.context = context; self.cardID = cardID
        _rule = State(initialValue: CardReturnSettings(cardID: cardID))
    }
    var body: some View {
        Form {
            Section {
                Toggle("Разрешить возвращения карточки", isOn: Binding(get: { allowsReturns }, set: { value in setAllowed(value) }))
                Text("Этот переключатель сохраняется сразу и действует для всех возвращений карточки.").reedFont(.caption)
            }
            Section("Уведомления") {
                Toggle("Разрешить уведомления", isOn: $rule.notificationsEnabled)
                Text("Без назначенного времени карточка участвует в общем выборе. Время ниже — явное назначение, которое обходит списки и паузу 72 часа.").reedFont(.caption)
            }
            Section("Точное время") {
                ForEach(rule.minutes.sorted(), id: \.self) { minute in
                    HStack {
                        Text(String(format: "%02d:%02d", minute / 60, minute % 60))
                        Spacer()
                        Button("Удалить время", systemImage: "minus.circle", role: .destructive) { rule.minutes.removeAll { $0 == minute } }.labelStyle(.iconOnly)
                    }
                }
                DatePicker("Новое время", selection: $time, displayedComponents: .hourAndMinute)
                Button("Добавить время") {
                    let minute = Calendar.current.component(.hour, from: time) * 60 + Calendar.current.component(.minute, from: time)
                    if !rule.minutes.contains(minute) { rule.minutes.append(minute) }
                }.disabled(rule.minutes.count >= 10)
                Text("Назначения входят в дневной лимит. Между ними нужен минимум час. Конфликтующее расписание не сохранится.").reedFont(.caption)
            }
            Section("Дни недели") { WeekdayPicker(selection: $rule.weekdays) }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            Button("Сохранить расписание") { Task { await save() } }.disabled(!loaded)
            if !loaded { Button("Загрузить настройки") { Task { await load() } } }
        }.disabled(saving)
        .navigationTitle("Возвращения карточки").navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }
    private func load() async {
        do {
            guard let card = try await context.repository.card(id: cardID) else { throw LibraryError.notFound }
            rule = try await context.returns.cardSettings(id: cardID); allowsReturns = card.allowsReturns; loaded = true
        } catch { errorMessage = returnErrorMessage(error) }
    }
    private func setAllowed(_ allowed: Bool) {
        guard loaded, !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                guard var card = try await context.repository.card(id: cardID) else { throw LibraryError.notFound }
                card.allowsReturns = allowed; card.updatedAt = Date()
                try await context.repository.save(card); allowsReturns = allowed; context.markChanged(); errorMessage = nil
            } catch { errorMessage = libraryErrorMessage(error) }
        }
    }
    private func save() async {
        saving = true; defer { saving = false }
        do { try await context.returns.saveCardSettings(rule, now: Date(), calendar: .current); context.markChanged(); errorMessage = nil }
        catch { errorMessage = returnErrorMessage(error) }
    }
}
