import SwiftUI
import Observation
import ReedDomain
import ReedApplication

@MainActor @Observable
final class CloudDevicesModel {
    private(set) var devices: [CloudDevice] = []
    private(set) var currentID: UUID?
    private(set) var locallyDisconnected = false
    private(set) var working = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let remote: any CloudDeviceRemote
    @ObservationIgnored private let identity: any CloudDeviceIdentity
    @ObservationIgnored private let engine: CloudSyncEngine
    init(remote: any CloudDeviceRemote, identity: any CloudDeviceIdentity, engine: CloudSyncEngine) {
        self.remote = remote; self.identity = identity; self.engine = engine
    }
    func load() async {
        do { currentID = try await identity.deviceID(); devices = try await remote.devices() }
        catch { errorMessage = cloudErrorMessage(error) }
    }
    func select(_ device: CloudDevice) async {
        await perform { try await self.remote.selectPrimary(id: device.id) }
    }
    func disconnect(_ device: CloudDevice) async {
        await perform {
            if device.id == self.currentID { try await self.engine.disable(); self.locallyDisconnected = true; self.devices = [] }
            else { try await self.remote.unregisterDevice(id: device.id) }
        }
    }
    private func perform(_ operation: () async throws -> Void) async {
        guard !working else { return }
        working = true; errorMessage = nil
        defer { working = false }
        do { try await operation(); if !locallyDisconnected { await load() } }
        catch { errorMessage = cloudErrorMessage(error) }
    }
}

struct CloudDevicesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: CloudDevicesModel
    @State private var disconnecting: CloudDevice?
    @State private var selecting: CloudDevice?
    init(remote: any CloudDeviceRemote, identity: any CloudDeviceIdentity, engine: CloudSyncEngine) {
        _model = State(initialValue: CloudDevicesModel(remote: remote, identity: identity, engine: engine))
    }
    var body: some View {
        List {
            Section {
                Text("Уведомления получает один выбранный iPhone. Общий план строится в его часовом поясе; остальные устройства не создают дубли.").reedFont(.caption)
                if !model.devices.contains(where: \.isPrimary) { Text("Получатель уведомлений не выбран.").reedFont(.caption).foregroundStyle(.orange) }
            }
            ForEach(model.devices) { device in
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(device.name, systemImage: device.isPrimary ? "bell.badge" : "iphone").reedFont(.body)
                        if device.id == model.currentID { Text("Этот iPhone").reedFont(.metadata).foregroundStyle(ReedTheme.secondary) }
                        Text("Часовой пояс: \(device.timeZone)").reedFont(.caption)
                        Text("Последняя связь: \(ReedDatePresentation.dateTime(device.lastSeenAt))").reedFont(.metadata).foregroundStyle(ReedTheme.secondary)
                    }
                    if device.isPrimary { Label("Получает уведомления", systemImage: "checkmark").foregroundStyle(.green).reedFont(.caption) }
                    else { Button("Получать уведомления здесь") { selecting = device } }
                    Button(device.id == model.currentID ? "Отключить облако на этом iPhone" : "Отключить синхронизацию устройства", role: .destructive) { disconnecting = device }
                }
            }
            if model.working { ProgressView("Обновляем устройства…") }
            if let error = model.errorMessage { Text(error).reedFont(.caption).foregroundStyle(.red) }
        }.disabled(model.working)
        .navigationTitle("Устройства").navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }.refreshable { await model.load() }
        .onChange(of: model.locallyDisconnected) { _, disconnected in if disconnected { dismiss() } }
        .confirmationDialog("Изменить получателя уведомлений?", isPresented: Binding(get: { selecting != nil }, set: { if !$0 { selecting = nil } }), titleVisibility: .visible) {
            if let selecting { Button("Выбрать \(selecting.name)") { Task { await model.select(selecting) } } }
        } message: { Text("Следующие облачные уведомления будут адресованы этому устройству. Уже доставленные уведомления на другом iPhone не удаляются.") }
        .confirmationDialog("Отключить устройство?", isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }), titleVisibility: .visible) {
            if let disconnecting { Button("Отключить", role: .destructive) { Task { await model.disconnect(disconnecting) } } }
        } message: {
            Text(disconnecting?.id == model.currentID ? "Сначала завершим обмен и проверим полную локальную копию. Облако останется доступно другим устройствам." : "Устройство прекратит обмен при следующем обращении к серверу. Его локальные данные сохранятся; новые правки не попадут в облако без явного подключения заново.")
        }
    }
}
