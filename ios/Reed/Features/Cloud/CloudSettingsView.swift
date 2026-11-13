import SwiftUI
import ReedDomain
import ReedApplication

struct CloudSettingsView: View {
    let context: LibraryContext
    @State private var model: CloudSettingsModel
    @State private var confirmsDisable = false
    @State private var confirmsKeepLocal = false
    @State private var deletingEpoch: UUID?
    init(context: LibraryContext) {
        self.context = context
        _model = State(initialValue: CloudSettingsModel(repository: context.cloud.repository, remote: context.cloud.remote, engine: context.cloud.engine))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Синхронизация хранит тексты, фотографии и связи на сервере Reed. Библиотека доступна на других iPhone с этим аккаунтом; на каждом устройстве остаётся полная копия для работы без интернета.").reedFont(.body)
                    Toggle("Синхронизация", isOn: Binding(get: { model.enabled }, set: { enabled in
                        if enabled { Task { await model.requestEnable() } } else { confirmsDisable = true }
                    })).tint(.green).reedFont(.caption).padding(8).background(ReedTheme.surface, in: RoundedRectangle(cornerRadius: ReedTheme.radius))
                        .disabled(model.busy || !model.available || model.state.mode == .leaving || model.state.mode == .disabling)
                        .accessibilityIdentifier("cloud.enabled")
                    Text(model.available ? model.status : "Синхронизация недоступна в этой сборке.").reedFont(.metadata).foregroundStyle(ReedTheme.secondary)
                }
                separator
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("Данные синхронизации")
                    VStack(alignment: .leading, spacing: 8) {
                        statistic("Всего карточек на iPhone:", "\(model.local.cards)")
                        statistic("Подтверждены облаком:", "\(model.local.confirmedCards)")
                        statistic(model.state.mode == .local ? "Только на iPhone:" : "Ожидают обмена:", "\(max(0,model.local.cards-model.local.confirmedCards))")
                        statistic("Карточек в облаке:", model.server.map { "\($0.cards)" } ?? "—")
                        statistic("Объём фото в облаке:", model.server.map { ByteCountFormatter.string(fromByteCount: $0.mediaBytes, countStyle: .file) } ?? "—")
                    }.padding(16).background(ReedTheme.raised, in: RoundedRectangle(cornerRadius: ReedTheme.radius))
                    Text(model.state.lastSyncAt.map { "Последняя синхронизация: \(ReedDatePresentation.dateTime($0))" } ?? "Синхронизация ещё не завершалась").reedFont(.metadata).foregroundStyle(ReedTheme.tertiary)
                    if model.enabled {
                        Button(model.state.mode == .leaving || model.state.mode == .disabling ? "Завершить отключение" : "Синхронизировать сейчас") { Task { await model.synchronize() } }
                            .buttonStyle(CloudOutlineButtonStyle()).disabled(model.busy || !model.available).accessibilityIdentifier("cloud.sync")
                    }
                    if model.progress.isTransferring {
                        if let total = model.progress.total, total > 0 {
                            ProgressView(model.progress.title, value: Double(model.progress.completed), total: Double(total))
                        } else { ProgressView(model.progress.title) }
                    }
                    if model.local.pending > 0 { Text("Изменений в очереди: \(model.local.pending)").reedFont(.metadata) }
                    if model.local.pendingMedia > 0 { Text("Фото ожидают проверки или загрузки: \(model.local.pendingMedia)").reedFont(.metadata) }
                    if model.local.conflicts > 0 {
                        NavigationLink("Выбрать версии · \(model.local.conflicts)") { CloudConflictsView(context: context) }
                            .reedFont(.caption).foregroundStyle(.orange).accessibilityIdentifier("cloud.conflicts")
                    }
                    if let error = model.errorMessage { Text(error).reedFont(.caption).foregroundStyle(.red) }
                    if let message = model.connectionMessage { Text(message).reedFont(.metadata).foregroundStyle(ReedTheme.secondary) }
                }
                separator
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("Настройки синхронизации")
                    VStack(spacing: 8) {
                        Toggle("Автоматическая синхронизация", isOn: Binding(get: { model.state.automatic }, set: { value in Task { await model.configure(automatic: value); context.cloud.schedule() } }))
                        Divider()
                        Toggle("Только через Wi-Fi", isOn: Binding(get: { model.state.wifiOnly }, set: { value in Task { await model.configure(wifiOnly: value) } }))
                    }.tint(.green).reedFont(.caption).padding(8).background(ReedTheme.surface, in: RoundedRectangle(cornerRadius: ReedTheme.radius)).disabled(model.busy)
                    Text("Автоматический обмен выполняется при открытии и изменениях библиотеки. Фоновый запуск зависит от iOS. Черновики и настройка сохранения фото остаются на этом iPhone.").reedFont(.metadata).foregroundStyle(ReedTheme.secondary)
                    if model.enabled, model.server?.notificationsAvailable == false {
                        Text("Доставка облачных уведомлений ещё не подключена. Общий план доступен в приложении.").reedFont(.caption).foregroundStyle(.orange)
                    }
                }
                if model.state.mode == .revoked {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Обмен остановлен").reedFont(.section)
                        Text("Облако изменилось или этот iPhone отключён. Локальные правки сохранены. Можно подтвердить новое объединение или оставить проверенную локальную библиотеку.").reedFont(.caption)
                        Button("Подключить заново") { Task { await model.requestEnable() } }
                        Button("Оставить только локальную копию") { confirmsKeepLocal = true }
                    }.buttonStyle(CloudOutlineButtonStyle()).disabled(model.busy || !model.available)
                }
                if model.enabled, let remote = context.cloud.remote, let engine = context.cloud.engine, model.state.mode != .leaving {
                    NavigationLink("Устройства и уведомления") { CloudDevicesView(remote: remote, identity: context.cloud.identity, engine: engine) }
                        .reedFont(.caption).accessibilityIdentifier("cloud.devices")
                }
                NavigationLink("Резервная копия и локальные данные") { DataSettingsView(context: context) }.reedFont(.caption)
                if model.state.participates {
                    separator
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Удаление облачных данных").reedFont(.caption).foregroundStyle(ReedTheme.secondary)
                        Text("Сначала проверим полную копию на этом iPhone. Облачная библиотека будет удалена, обмен на других устройствах остановится. Их локальные копии останутся.").reedFont(.caption)
                        Button("Удалить библиотеку из облака", role: .destructive) { deletingEpoch = model.state.epoch }
                            .buttonStyle(CloudOutlineButtonStyle()).disabled(model.busy || !model.available || model.local.conflicts > 0)
                        if model.local.conflicts > 0 { Text("Перед удалением выберите версии конфликтующих изменений.").reedFont(.metadata) }
                    }
                }
            }.padding(ReedTheme.inset)
        }.background(ReedTheme.background).foregroundStyle(ReedTheme.foreground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("Данные и синхронизация").reedFont(.settingsTitle).lineLimit(1).minimumScaleFactor(0.75) } }
        .task { await model.observe() }
        .alert("Объединить библиотеки?", isPresented: Binding(get: { model.preview != nil }, set: { if !$0 { model.cancelPreview() } })) {
            if let preview = model.preview { Button("Объединить") { Task { await model.enable(epoch: preview.epoch) } } }
            Button("Отмена", role: .cancel) { model.cancelPreview() }
        } message: {
            if let preview = model.preview {
                Text("На iPhone: \(model.local.cards) карточек. В облаке: \(preview.cards). Совпадающие записи объединятся, различающиеся версии потребуют выбора. Локальные данные не удаляются." + (preview.notificationsAvailable ? "" : " В этой сборке облачные уведомления пока не доставляются."))
            }
        }
        .confirmationDialog("Отключить облако на этом iPhone?", isPresented: $confirmsDisable, titleVisibility: .visible) {
            Button("Сохранить полную копию и отключить") { Task { await model.disable() } }
        } message: { Text("Сначала завершим обмен и проверим все фото. Облако и другие устройства сохранят данные. Следующие правки на этом iPhone останутся локальными.") }
        .confirmationDialog("Оставить библиотеку только на этом iPhone?", isPresented: $confirmsKeepLocal, titleVisibility: .visible) {
            Button("Проверить копию и отключить") { Task { await model.keepLocal() } }
        } message: { Text("Сохранится показанная локальная версия. Неотправленные правки останутся на устройстве. Облачные варианты конфликтов перестанут быть доступны на этом экране.") }
        .confirmationDialog("Удалить всю библиотеку из облака?", isPresented: Binding(get: { deletingEpoch != nil }, set: { if !$0 { deletingEpoch = nil } }), titleVisibility: .visible) {
            if let epoch = deletingEpoch { Button("Удалить из облака", role: .destructive) { Task { await model.deleteCloud(epoch: epoch) } } }
        } message: { Text("Действие нельзя отменить на сервере. На этом iPhone останется полная локальная копия; её можно экспортировать или явно загрузить заново.") }
    }
    private var separator: some View { Rectangle().fill(ReedTheme.foreground.opacity(0.5)).frame(height: ReedTheme.border) }
    private func sectionTitle(_ title: String) -> some View { Text(title).reedFont(.caption).foregroundStyle(ReedTheme.secondary) }
    private func statistic(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 16) { Text(label).frame(maxWidth: .infinity, alignment: .leading); Text(value).frame(minWidth: 86, alignment: .leading) }
            .reedFont(.caption).foregroundStyle(ReedTheme.secondary).accessibilityElement(children: .combine)
    }
}
struct CloudOutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.reedFont(.caption).frame(maxWidth: .infinity, minHeight: 44)
            .overlay(RoundedRectangle(cornerRadius: ReedTheme.radius).stroke(ReedTheme.foreground, lineWidth: ReedTheme.border))
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.4)
    }
}
