import SwiftUI
import ReedDomain

struct ReturnSettingsView: View {
    let context: LibraryContext
    @State private var settings = ReturnSettings()
    @State private var catalog = LibraryCatalog()
    @State private var loaded = false
    @State private var saving = false
    @State private var errorMessage: String?
    var body: some View {
        Form {
            Section("Возвращения") {
                Toggle("Возвращать карточки", isOn: $settings.enabled)
                Toggle("Уведомления", isOn: $settings.notificationsEnabled)
                Text("При включении уведомлений запросим разрешение iOS. Текст карточки может быть виден на экране блокировки — настройка превью находится в iOS.").reedFont(.caption)
            }
            Section("Время по местному часовому поясу") {
                Stepper("До \(settings.dailyLimit) в день", value: $settings.dailyLimit, in: 1...10)
                DatePicker("Не раньше", selection: minuteBinding($settings.firstMinute), displayedComponents: .hourAndMinute)
                DatePicker("Не позже", selection: minuteBinding($settings.lastMinute), displayedComponents: .hourAndMinute)
                Stepper("Разброс: ±\(settings.jitterMinutes) мин", value: $settings.jitterMinutes, in: 0...60, step: 5)
                Stepper("Интервал: \(settings.minimumIntervalMinutes) мин", value: $settings.minimumIntervalMinutes, in: 60...720, step: 30)
                Text("По умолчанию — около 10, 15 и 20 часов, с разбросом до получаса. Точное время сохраняется на день. Если подходящих карточек мало, часть слотов останется пустой.").reedFont(.caption)
                NavigationLink("Дни недели · \(settings.weekdays.count)") { Form { WeekdayPicker(selection: $settings.weekdays) }.navigationTitle("Дни возвращений") }
            }
            Section("Общие правила") {
                NavigationLink("Что включать") { ReturnFilterView(filter: $settings.globalInclude, catalog: catalog, title: "Включать") }
                NavigationLink("Что исключать") { ReturnFilterView(filter: $settings.globalExclude, catalog: catalog, title: "Исключать") }
            }
            Section("Правила уведомлений") {
                NavigationLink("Включать в уведомления") { ReturnFilterView(filter: $settings.channelInclude, catalog: catalog, title: "Уведомления: включать") }
                NavigationLink("Исключать из уведомлений") { ReturnFilterView(filter: $settings.channelExclude, catalog: catalog, title: "Уведомления: исключать") }
                Text("Общие и канальные включения пересекаются, исключения сильнее. Индивидуальное назначение обходит эти списки и паузу, но сохраняет главные тумблеры.").reedFont(.caption)
            }
            Section("Возвращать чаще") {
                Toggle("Повысить приоритет", isOn: $settings.boostEnabled)
                Picker("Какие карточки", selection: $settings.boostFolderID) {
                    Text("Избранное").tag(UUID?.none)
                    ForEach(catalog.folders) { Text($0.name).tag(Optional($0.id)) }
                }
                Text("Удваиваем вес ожидания. Пауза 72 часа сохраняется; точная частота зависит от архива и фильтров.").reedFont(.caption)
            }
            Section("Локальный план") {
                Text("До 7 дней вперёд и не более 48 уведомлений. Открывайте приложение для продления. iOS сама определяет фактический момент показа.").reedFont(.caption)
                if let until = context.returnCoordinator.report.until { Text("В очереди до \(ReedDatePresentation.dateTime(until))") }
                if context.returnCoordinator.permission == .denied { Link("Разрешить уведомления в iOS", destination: URL(string: UIApplication.openSettingsURLString)!) }
                Button("Обновить план") { context.returnCoordinator.refresh() }
                if let error = context.returnCoordinator.errorMessage { Text(error).foregroundStyle(.red) }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            if !loaded { Button("Загрузить настройки") { Task { await load() } } }
            Button("Сохранить настройки") { Task { await save() } }.disabled(!loaded || saving)
            Button("Вернуть значения по умолчанию") { settings = ReturnSettings() }
        }.disabled(saving)
        .navigationTitle("Возвращения").navigationBarTitleDisplayMode(.inline)
        .task { if !loaded { await load() } }
    }
    private func load() async {
        do { settings = try await context.returns.settings(); catalog = try await context.repository.catalog(); loaded = true; errorMessage = nil }
        catch { errorMessage = returnErrorMessage(error) }
    }
    private func save() async {
        saving = true; defer { saving = false }
        do {
            try await context.returns.saveSettings(settings, now: Date(), calendar: .current)
            if settings.enabled && settings.notificationsEnabled { try await context.returnCoordinator.requestPermission() }
            context.markChanged(); errorMessage = nil
        } catch { errorMessage = returnErrorMessage(error); context.returnCoordinator.refresh() }
    }
}
