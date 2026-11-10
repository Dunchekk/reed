import Foundation
import ReedDomain

public protocol ReturnRepository: Sendable {
    func settings() async throws -> ReturnSettings
    func saveSettings(_ settings: ReturnSettings, now: Date, calendar: Calendar) async throws
    func cardSettings(id: UUID) async throws -> CardReturnSettings
    func saveCardSettings(_ settings: CardReturnSettings, now: Date, calendar: Calendar) async throws
    func replan(now: Date, calendar: Calendar, authorized: Bool) async throws -> ReturnPlan
    func currentPlan(now: Date, calendar: Calendar) async throws -> ReturnPlan
    func markQueued(id: String, revision: UUID) async throws
    func cancelFuture(now: Date) async throws
}
