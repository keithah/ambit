import Foundation

public enum SystemSignalPermission: String, Codable, Equatable, Sendable {
    case authorized
    case notDetermined
    case denied
    case restricted
    case unavailable

    public var canRead: Bool { self == .authorized }
}
