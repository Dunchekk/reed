import UIKit
import UserNotifications
import Observation

struct NotificationRoute: Equatable, Identifiable {
    let id = UUID()
    let accountID: UUID
    let cardID: UUID
    let slotID: String
}
@MainActor @Observable
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()
    var route: NotificationRoute?
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let account = response.notification.request.content.userInfo["accountID"] as? String,
              let card = response.notification.request.content.userInfo["cardID"] as? String,
              let slot = response.notification.request.content.userInfo["slotID"] as? String,
              let accountID = UUID(uuidString: account), let cardID = UUID(uuidString: card) else { return }
        await MainActor.run { self.route = NotificationRoute(accountID: accountID, cardID: cardID, slotID: slot) }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
final class ReedAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        return true
    }
}
