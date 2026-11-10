import Foundation
import ReedDomain

public protocol ReturnDeliveryRepository: Sendable {
    func markQueued(id: String, revision: UUID) async throws
}

public protocol ReturnRepository: ReturnDeliveryRepository {
    func settings() async throws -> ReturnSettings
    func saveSettings(_ settings: ReturnSettings, now: Date, calendar: Calendar) async throws
    func cardSettings(id: UUID) async throws -> CardReturnSettings
    func saveCardSettings(_ settings: CardReturnSettings, now: Date, calendar: Calendar) async throws
    func replan(now: Date, calendar: Calendar, authorized: Bool) async throws -> ReturnPlan
    func currentPlan(now: Date, calendar: Calendar) async throws -> ReturnPlan
    func cancelFuture(now: Date) async throws
}
