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
    @ObservationIgnored private var cloudOwnsPlan = false
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
        if cloudOwnsPlan { refreshCloudSnapshot(); return }
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
                var message = returnErrorMessage(error)
                // A failed rebuild must not leave obsolete private card text scheduled.
                do {
                    report = try await reconciler.reconcile(ReturnPlan(entries: [], horizon: nil), now: Date())
                    try await repository.cancelFuture(now: Date())
                    plan = ReturnPlan(entries: [], horizon: nil)
                } catch { message += " Не удалось подтвердить отмену старой очереди. Повторите обновление." }
                if generation == token { errorMessage = message }
            }
        }
    }
    func refreshInBackground() async -> Bool {
        guard active else { return false }
        refresh()
        let captured = work
        await withTaskCancellationHandler { await captured?.value } onCancel: { captured?.cancel() }
        return !Task.isCancelled && errorMessage == nil && active
    }
    func stop() async throws {
        active = false; work?.cancel()
        await work?.value
        do {
            try await reconciler.stop()
            if !cloudOwnsPlan { try await repository.cancelFuture(now: Date()) }
            report = NotificationQueueReport(count: 0, until: nil, failures: 0)
        } catch {
            // The account remains open after a failed logout, so its coordinator must recover too.
            if !cloudOwnsPlan { resume() }
            throw error
        }
    }
    func suspendForCloud() async throws {
        guard !cloudOwnsPlan else { return }
        active = false; work?.cancel(); await work?.value
        try await reconciler.stop()
        cloudOwnsPlan = true
        report = NotificationQueueReport(count: 0, until: nil, failures: 0)
        refreshCloudSnapshot()
    }
    private func refreshCloudSnapshot() {
        work?.cancel()
        work = Task {
            do {
                permission = await queue.permission()
                let saved = try await repository.currentPlan(now: Date(), calendar: .current)
                guard !Task.isCancelled, cloudOwnsPlan else { return }
                plan = saved; errorMessage = saved.issue.map(cloudPlanIssueMessage)
            } catch { if !Task.isCancelled { errorMessage = returnErrorMessage(error) } }
        }
    }
    func resume() {
        guard !active || cloudOwnsPlan else { return }
        cloudOwnsPlan = false
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

private func cloudPlanIssueMessage(_ issue: ReturnPlanIssue) -> String {
    switch issue {
    case .noPrimaryDevice: "Выберите основное устройство в настройках облака, чтобы продолжить возвращения."
    case .invalidFilter: "Проверьте фильтры возвращений: связанные папки, теги или авторы могли быть удалены на другом устройстве."
    case .invalidSchedule: returnErrorMessage(ReturnError.invalidSchedule)
    case .conflictingExplicitTimes: returnErrorMessage(ReturnError.conflictingExplicitTimes)
    case .tooManyExplicitTimes: returnErrorMessage(ReturnError.tooManyExplicitTimes)
    }
}
