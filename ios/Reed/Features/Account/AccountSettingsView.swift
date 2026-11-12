import SwiftUI
import ReedApplication

struct AccountSettingsView: View {
    @State private var model: AccountSettingsModel
    @State private var confirmsDeletion = false
    init(authentication: AuthenticationModel, context: LibraryContext) {
        _model = State(initialValue: AccountSettingsModel(authentication: authentication, context: context))
    }
    var body: some View {
        Form {
            Section("Данные") {
                LabeledContent("Телефон", value: model.authentication.account?.phone.value ?? "—")
                NavigationLink("Изменить номер") { ContactChangeView(kind: .phone, authentication: model.authentication) }
                LabeledContent("Резервная почта", value: model.authentication.account?.recoveryEmail ?? "Не добавлена")
                NavigationLink("Настроить резервную почту") { ContactChangeView(kind: .email, authentication: model.authentication) }
            }
            Section {
                Text("Подтвердите резервную почту заранее. Если потеряете доступ к номеру, код на эту почту позволит войти в тот же аккаунт и изменить телефон.")
                Text("На новом устройстве сами карточки появятся только после восстановления резервной копии.").reedFont(.caption)
            }
            Section("Опасная зона") {
                Button("Удалить аккаунт", role: .destructive) { confirmsDeletion = true }
                    .disabled(model.working || model.profile?.deletionAvailable != true)
                Text("Удалит аккаунт, библиотеку и фото на этом устройстве. Сохранённые вне приложения резервные копии останутся. Отменить удаление нельзя.").reedFont(.caption)
                if model.profile?.deletionAvailable == false { Text("Удаление аккаунта ещё не подключено на сервере этой сборки.").reedFont(.caption) }
            }
            if model.working { ProgressView() }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red)
                Button("Обновить данные") { Task { await model.load() } }
            }
        }
        .navigationTitle("Аккаунт").navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .confirmationDialog("Удалить аккаунт и локальную библиотеку навсегда?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Удалить навсегда", role: .destructive) { Task { await model.delete() } }
        } message: { Text("Сначала сохраните резервную копию в разделе «Данные», если хотите оставить свои карточки.") }
    }
}

struct ContactChangeView: View {
    @State private var model: ContactChangeModel
    init(kind: ContactKind, authentication: AuthenticationModel) { _model = State(initialValue: ContactChangeModel(kind: kind, authentication: authentication)) }
    var body: some View {
        Form {
            Section(model.kind == .phone ? "Новый номер" : "Резервная почта") {
                TextField(model.kind == .phone ? "+7" : "name@example.com", text: $model.value)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(model.kind == .phone ? .phonePad : .emailAddress)
                    .disabled(model.requested || model.working)
                if !model.requested {
                    Button("Получить код") { Task { await model.request() } }.disabled(model.value.isEmpty || model.working)
                }
            }
            if model.requested && !model.confirmed {
                Section("Подтверждение") {
                    TextField("Шесть цифр", text: $model.code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                    Button("Подтвердить") { Task { await model.verify() } }.disabled(model.code.count != 6 || model.working)
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        let wait = max(0,Int(ceil(model.retryAt.timeIntervalSince(timeline.date))))
                        Button(wait > 0 ? "Повторить через \(wait) с" : "Отправить код повторно") { Task { await model.request() } }
                            .disabled(wait > 0 || model.working)
                    }
                    Button("Изменить ввод") { model.reset() }.disabled(model.working)
                }
            }
            if let message = model.message { Text(message) }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            if model.working { ProgressView() }
        }.navigationTitle(model.kind == .phone ? "Смена номера" : "Резервная почта").navigationBarTitleDisplayMode(.inline)
    }
}
