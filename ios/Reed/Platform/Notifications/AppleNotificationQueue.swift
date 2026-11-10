import Foundation
import UserNotifications
import ReedApplication

struct AppleNotificationQueue: CardNotificationQueue {
    private var center: UNUserNotificationCenter { .current() }
    func permission() async -> NotificationPermission {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .allowed
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
    func requestPermission() async throws -> Bool { try await center.requestAuthorization(options: [.alert, .sound]) }
    func pending() async -> [QueuedNotification] {
        await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix("reed.") }.map {
            QueuedNotification(id: $0.identifier, revision: ($0.content.userInfo["revision"] as? String).flatMap(UUID.init(uuidString:)))
        }
    }
    func add(_ notification: CardNotification) async throws {
        guard notification.entry.slot.date > Date() else { throw CocoaError(.validationDateTooSoon) }
        guard let card = notification.entry.card else { return }
        let content = UNMutableNotificationContent()
        content.title = String(card.title.prefix(80)); content.body = String(card.preview.prefix(180))
        content.sound = .default
        content.userInfo = ["accountID": notification.accountID.uuidString, "cardID": card.id.uuidString,
                            "slotID": notification.entry.id, "revision": notification.entry.revision.uuidString]
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var date = calendar.dateComponents([.year,.month,.day,.hour,.minute,.second], from: notification.entry.slot.date)
        date.calendar = calendar; date.timeZone = calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: date, repeats: false)
        try await center.add(UNNotificationRequest(identifier: notification.id, content: content, trigger: trigger))
    }
    func remove(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        let remaining = Set(await pending().map(\.id)).intersection(ids)
        if !remaining.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(remaining))
            if !Set(await pending().map(\.id)).isDisjoint(with: remaining) { throw CocoaError(.userCancelled) }
        }
    }
    func clear() async throws {
        try await remove(ids: pending().map(\.id))
        let delivered = await center.deliveredNotifications().map(\.request.identifier).filter { $0.hasPrefix("reed.") }
        center.removeDeliveredNotifications(withIdentifiers: delivered)
    }
}
