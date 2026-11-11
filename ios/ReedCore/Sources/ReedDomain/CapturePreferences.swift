import Foundation

public struct CapturePreferences: Codable, Equatable, Sendable {
    public var savesPhotos: Bool
    public init(savesPhotos: Bool = true) { self.savesPhotos = savesPhotos }
}
