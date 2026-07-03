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
    private let requiresLocationPermissionForWiFiIdentifiers: @Sendable () -> Bool
    private let locationPermission: @Sendable () async -> SystemSignalPermission
    private let wifiIdentifiers: @Sendable () -> (ssid: String?, bssid: String?)?

    public init() {
        self.init(
            requiresLocationPermissionForWiFiIdentifiers: DarwinSystemNetworkInfoReader.currentOSRequiresLocationPermissionForWiFiIdentifiers,
            locationPermission: DarwinSystemNetworkInfoReader.currentLocationPermission,
            wifiIdentifiers: DarwinSystemNetworkInfoReader.currentWiFiIdentifiers
        )
    }

    init(requiresLocationPermissionForWiFiIdentifiers: @escaping @Sendable () -> Bool = { true },
         locationPermission: @escaping @Sendable () async -> SystemSignalPermission,
         wifiIdentifiers: @escaping @Sendable () -> (ssid: String?, bssid: String?)?) {
        self.requiresLocationPermissionForWiFiIdentifiers = requiresLocationPermissionForWiFiIdentifiers
        self.locationPermission = locationPermission
        self.wifiIdentifiers = wifiIdentifiers
    }

    public func snapshot() async -> SystemNetworkInfoSnapshot {
        let permission: SystemSignalPermission
        if requiresLocationPermissionForWiFiIdentifiers() {
            permission = await locationPermission()
            guard permission.canRead else {
                return SystemNetworkInfoSnapshot(permission: permission)
            }
        } else {
            permission = .authorized
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

    private static func currentOSRequiresLocationPermissionForWiFiIdentifiers() -> Bool {
        if #available(macOS 14.4, *) {
            return true
        }
        return false
    }

    private static func currentLocationPermission() async -> SystemSignalPermission {
        #if canImport(CoreLocation)
        return await DarwinNetworkLocationPermissionProbe.shared.permission()
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

#if canImport(CoreLocation)
@MainActor
private final class DarwinNetworkLocationPermissionProbe {
    static let shared = DarwinNetworkLocationPermissionProbe()

    private let manager = CLLocationManager()

    func permission() -> SystemSignalPermission {
        SystemSignalPermission.from(manager.authorizationStatus)
    }
}
#endif
