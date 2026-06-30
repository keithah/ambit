import Foundation

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
    public init() {}

    public func snapshot() async -> SystemNetworkInfoSnapshot {
        #if canImport(CoreWLAN)
        guard let interface = CWWiFiClient.shared().interface() else {
            return SystemNetworkInfoSnapshot(permission: .unavailable)
        }
        let ssid = interface.ssid()
        let bssid = interface.bssid()
        guard ssid != nil || bssid != nil else {
            // macOS gates SSID/BSSID behind Location authorization. If CoreWLAN
            // returns no identifiers, expose a neutral unavailable signal.
            return SystemNetworkInfoSnapshot(permission: .unavailable)
        }
        return SystemNetworkInfoSnapshot(permission: .authorized, ssid: ssid, bssid: bssid)
        #else
        return SystemNetworkInfoSnapshot(permission: .unavailable)
        #endif
    }
}
