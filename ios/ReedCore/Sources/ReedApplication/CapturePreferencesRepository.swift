import ReedDomain

public protocol CapturePreferencesRepository: Sendable {
    func capturePreferences() async throws -> CapturePreferences
    func setCapturePreferences(_ value: CapturePreferences) async throws
}
