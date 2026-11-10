import Foundation
import Observation
import ReedDomain
import ReedApplication

@MainActor @Observable
final class ReturnCoordinator {
    private(set) var permission: NotificationPermission = .notDetermined
    private(set) var plan = ReturnPlan(entries: [], horizon: nil)
    private(set) var report = NotificationQueueReport(count: 0, until: nil, failures: 0)
    private(set) var errorMessage: String?
    private(set) var isRefreshing = false
    @ObservationIgnored private let repository: any ReturnRepository
    @ObservationIgnored private let queue: any CardNotificationQueue
    @ObservationIgnored private let accountID: UUID
    @ObservationIgnored private var reconciler: NotificationReconciler
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var active = true
    @ObservationIgnored private var generation = UUID()

    init(repository: any ReturnRepository, queue: any CardNotificationQueue, accountID: UUID) {
        self.repository = repository; self.queue = queue; self.accountID = accountID
        reconciler = NotificationReconciler(queue: queue, repository: repository, accountID: accountID)
    }
    func requestPermission() async throws {
        _ = try await queue.requestPermission()
        permission = await queue.permission()
    }
    func refresh() {
        guard active else { return }
        work?.cancel(); let token = UUID(); generation = token
        work = Task {
            isRefreshing = true
            defer { if generation == token { isRefreshing = false } }
            do {
                let status = await queue.permission()
                guard active, !Task.isCancelled else { return }
                permission = status
                let newPlan = try await repository.replan(now: Date(), calendar: .current, authorized: status == .allowed)
                guard active, !Task.isCancelled else { return }
                plan = newPlan
                let result = try await reconciler.reconcile(newPlan, now: Date())
                guard active, !Task.isCancelled else { return }
                report = result
                plan = try await repository.currentPlan(now: Date(), calendar: .current)
                errorMessage = result.failures == 0 ? nil : "Часть уведомлений не поставлена. Нажмите «Обновить план», чтобы повторить."
            } catch is CancellationError {} catch {
                guard active, generation == token else { return }
                errorMessage = returnErrorMessage(error)
            }
        }
    }
    func stop() async throws {
        active = false; work?.cancel()
        await work?.value
        try await reconciler.stop()
        try await repository.cancelFuture(now: Date())
        report = NotificationQueueReport(count: 0, until: nil, failures: 0)
    }
    func resume() {
        guard !active else { return }
        reconciler = NotificationReconciler(queue: queue, repository: repository, accountID: accountID)
        active = true; refresh()
    }
}

func returnErrorMessage(_ error: any Error) -> String {
    switch error as? ReturnError {
    case .invalidSchedule: "Проверьте расписание: до 10 слотов в сутки, минимум час между ними и достаточно широкое окно времени."
    case .invalidFilter: "Проверьте слова и период в правилах."
    case .conflictingExplicitTimes: "Индивидуальные назначения слишком близки: между ними должен быть выбранный минимальный интервал."
    case .tooManyExplicitTimes: "Индивидуальных назначений больше дневного лимита. Увеличьте лимит или уберите лишнее время."
    default: "Не удалось обновить возвращения. Попробуйте ещё раз."
    }
}
