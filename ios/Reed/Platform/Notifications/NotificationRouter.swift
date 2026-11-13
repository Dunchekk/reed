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
    var activeAccountID: UUID?
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let account = response.notification.request.content.userInfo["accountID"] as? String,
              let card = response.notification.request.content.userInfo["cardID"] as? String,
              let slot = response.notification.request.content.userInfo["slotID"] as? String,
              let accountID = UUID(uuidString: account), let cardID = UUID(uuidString: card) else { return }
        await MainActor.run { self.route = NotificationRoute(accountID: accountID, cardID: cardID, slotID: slot) }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let account = notification.request.content.userInfo["accountID"] as? String
        return await MainActor.run {
            guard let account, UUID(uuidString: account) == self.activeAccountID else { return [] }
            return [.banner, .sound, .list]
        }
    }
}
@MainActor final class RemotePushRegistration {
    static let shared = RemotePushRegistration()
    static let changed = Notification.Name("reed.remotePushTokenChanged")
    private(set) var token: String?
    func update(_ data: Data?) {
        let value = data.map { $0.map { String(format: "%02x", $0) }.joined() }
        guard value != token else { return }; token = value
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}
final class ReedAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        RemotePushRegistration.shared.update(deviceToken)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        RemotePushRegistration.shared.update(nil)
    }
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: UIFont.systemFont(ofSize: 40, weight: .regular))]
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        BackgroundReturnRefresh.shared.register()
        return true
    }
}
