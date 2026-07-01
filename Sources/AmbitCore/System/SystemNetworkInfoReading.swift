import Foundation

#if canImport(CoreLocation)
import CoreLocation
#endif

#if canImport(CoreWLAN)
@preconcurrency import CoreWLAN
#endif

public struct SystemNetworkInfoSnapshot: Equatable, Sendable {
    public var permission: SystemSignalPermission
    public var ssid: String?
    public var bssid: String?

    public init(permission: SystemSignalPermission, ssid: String? = nil, bssid: String? = nil) {
        self.permission = permission
        self.ssid = ssid
        self.bssid = bssid
    }
}

public protocol SystemNetworkInfoReading: Sendable {
    func snapshot() async -> SystemNetworkInfoSnapshot
}

public struct DarwinSystemNetworkInfoReader: SystemNetworkInfoReading {
    private let locationPermission: @Sendable () -> SystemSignalPermission
    private let wifiIdentifiers: @Sendable () -> (ssid: String?, bssid: String?)?

    public init() {
        self.init(
            locationPermission: DarwinSystemNetworkInfoReader.currentLocationPermission,
            wifiIdentifiers: DarwinSystemNetworkInfoReader.currentWiFiIdentifiers
        )
    }

    init(locationPermission: @escaping @Sendable () -> SystemSignalPermission,
         wifiIdentifiers: @escaping @Sendable () -> (ssid: String?, bssid: String?)?) {
        self.locationPermission = locationPermission
        self.wifiIdentifiers = wifiIdentifiers
    }

    public func snapshot() async -> SystemNetworkInfoSnapshot {
        let permission = locationPermission()
        guard permission.canRead else {
            return SystemNetworkInfoSnapshot(permission: permission)
        }

        guard let identifiers = wifiIdentifiers() else {
            return SystemNetworkInfoSnapshot(permission: .unavailable)
        }
        let ssid = identifiers.ssid
        let bssid = identifiers.bssid
        guard ssid != nil || bssid != nil else {
            // macOS exposes SSID/BSSID only to a signed app bundle with Location
            // authorization. Empty identifiers are neutral unavailable data, not failure.
            return SystemNetworkInfoSnapshot(permission: .unavailable)
        }
        return SystemNetworkInfoSnapshot(permission: .authorized, ssid: ssid, bssid: bssid)
    }

    private static func currentLocationPermission() -> SystemSignalPermission {
        #if canImport(CoreLocation)
        switch CLLocationManager().authorizationStatus {
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
        #else
        return .unavailable
        #endif
    }

    private static func currentWiFiIdentifiers() -> (ssid: String?, bssid: String?)? {
        #if canImport(CoreWLAN)
        guard let interface = CWWiFiClient.shared().interface() else {
            return nil
        }
        return (ssid: interface.ssid(), bssid: interface.bssid())
        #else
        return nil
        #endif
    }
}
