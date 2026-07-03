import Foundation

#if canImport(CoreLocation)
import CoreLocation
#endif

public enum SystemSignalPermission: String, Codable, Equatable, Sendable {
    case authorized
    case notDetermined
    case denied
    case restricted
    case unavailable

    public var canRead: Bool { self == .authorized }
}

#if canImport(CoreLocation)
extension SystemSignalPermission {
    static func from(_ status: CLAuthorizationStatus) -> SystemSignalPermission {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            return .authorized
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .unavailable
        }
    }
}
#endif
