import SwiftUI

struct SignInView: View {
    @Bindable var model: AuthenticationModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Сохраняйте важное. Возвращайтесь к своим мыслям.")
                        .font(.title2)
                }
                if let phone = model.requestedPhone {
                    Section("Код из SMS для \(phone.value)") {
                        TextField("Шесть цифр", text: $model.codeInput)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .accessibilityIdentifier("auth.code")
                        Button("Войти") { Task { await model.verifyCode() } }
                            .disabled(model.isWorking || model.codeInput.count != 6)
                            .accessibilityIdentifier("auth.verify")
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let remaining = max(0, Int(ceil(model.retryAt.timeIntervalSince(context.date))))
                            Button(remaining > 0 ? "Повторить через \(remaining) с" : "Отправить код повторно") {
                                Task { await model.requestCode() }
                            }
                            .disabled(model.isWorking || remaining > 0)
                        }
                        Button("Изменить номер") { model.changePhone() }.disabled(model.isWorking)
                    }
                } else {
                    Section("Вход по номеру телефона") {
                        TextField("+7", text: $model.phoneInput)
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                            .disabled(model.isWorking)
                            .accessibilityIdentifier("auth.phone")
                        Button("Получить код") { Task { await model.requestCode() } }
                            .disabled(model.isWorking || !model.isConfigured)
                            .accessibilityIdentifier("auth.request")
                    }
                }
                if model.isWorking { ProgressView("Подождите…") }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red).accessibilityIdentifier("auth.error") }
                if !model.isConfigured {
                    Text("Сервер входа ещё не настроен для этой сборки.").foregroundStyle(.secondary)
                }
                #if DEBUG
                Section("Локальная разработка") {
                    Text("Тестовый номер: +70000000001. Код после запроса: 123456. Настоящее SMS не отправляется.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                #endif
            }
            .navigationTitle("Reed")
        }
    }
}
