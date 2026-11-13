import Foundation
import UIKit
import UserNotifications
import ReedDomain
import ReedApplication

@MainActor final class AppleCloudParticipation: CloudParticipation {
    private let remote: any CloudDeviceRemote
    private let identity: any CloudDeviceIdentity
    private let returns: ReturnCoordinator
    init(remote: any CloudDeviceRemote, identity: any CloudDeviceIdentity, returns: ReturnCoordinator) {
        self.remote = remote; self.identity = identity; self.returns = returns
    }
    func prepareJoin() async throws {
        try await identity.renew()
        try await refreshRegistration()
        if try await !remote.devices().contains(where: \.isPrimary) { try await remote.selectPrimary(id: identity.deviceID()) }
    }
    func refreshRegistration() async throws {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let allowed = status == .authorized || status == .provisional
        if allowed { UIApplication.shared.registerForRemoteNotifications() }
        _ = try await remote.registerDevice(id: identity.deviceID(), name: String(UIDevice.current.name.prefix(120)), timeZone: TimeZone.current.identifier, pushToken: allowed ? RemotePushRegistration.shared.token : nil)
    }
    func synchronizationCompleted(epoch: UUID) async throws { try await remote.markReady(epoch: epoch) }
    func leave() async throws { try await remote.unregisterDevice(id: identity.deviceID()) }
    func suspendLocalNotifications() async throws { try await returns.suspendForCloud() }
    func resumeLocalNotifications() { returns.resume() }
}
