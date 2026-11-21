import Foundation

/// How the router reaches the internet, from the `interface` names its firmware reports.
public enum GLiNetWAN: Sendable, Equatable {
    case ethernet, repeater, tethering, cellular
    case other(String)

    init(interface: String) {
        switch interface.lowercased() {
        case "wan", "wan6", "ethernet", "wired": self = .ethernet
        case "wwan", "repeater", "wifi": self = .repeater
        case "tethering": self = .tethering
        case "modem", "cellular": self = .cellular
        default: self = .other(interface)
        }
    }

    public var text: String {
        switch self {
        case .ethernet: "Ethernet"
        case .repeater: "Wi-Fi repeater"
        case .tethering: "USB tethering"
        case .cellular: "Cellular"
        case .other(let name): name
        }
    }
}

/// What `system get_status` reports on firmware 4.x. Payload shape taken from a v0 capture.
public struct GLiNetStatus: Sendable, Equatable {
    /// The uplink currently online; nil when the router has no working internet connection.
    public var wan: GLiNetWAN?
    public var lanIP: String?
    public var clientCount: Int?
    public var uptimeSeconds: Double?

    public init(wan: GLiNetWAN? = nil, lanIP: String? = nil, clientCount: Int? = nil, uptimeSeconds: Double? = nil) {
        self.wan = wan
        self.lanIP = lanIP
        self.clientCount = clientCount
        self.uptimeSeconds = uptimeSeconds
    }

    init(systemStatus payload: [String: Any]) {
        let networks = payload["network"] as? [[String: Any]] ?? []
        let online = networks.first { ($0["up"] as? Bool ?? false) && ($0["online"] as? Bool ?? false) }
        wan = (online?["interface"] as? String).map(GLiNetWAN.init(interface:))
        let system = payload["system"] as? [String: Any]
        lanIP = system?["lan_ip"] as? String
        uptimeSeconds = (system?["uptime"] as? NSNumber)?.doubleValue
        if let clients = (payload["client"] as? [[String: Any]])?.first {
            let cable = (clients["cable_total"] as? NSNumber)?.intValue
            let wireless = (clients["wireless_total"] as? NSNumber)?.intValue
            if cable != nil || wireless != nil { clientCount = (cable ?? 0) + (wireless ?? 0) }
        }
    }
}

/// The first VPN client tunnel from `vpn-client get_status` (firmware 4.5 and later).
public struct GLiNetVPN: Sendable, Equatable {
    public var tunnelID: Int
    public var profile: String?
    /// The tunnel is switched on in the router's settings.
    public var isOn: Bool
    /// Switched on and the router reports it as up.
    public var isConnected: Bool

    public init(tunnelID: Int, profile: String? = nil, isOn: Bool, isConnected: Bool) {
        self.tunnelID = tunnelID
        self.profile = profile
        self.isOn = isOn
        self.isConnected = isConnected
    }

    init?(vpnClientStatus payload: [String: Any]) {
        guard let tunnel = (payload["status_list"] as? [[String: Any]])?.first,
              let id = (tunnel["tunnel_id"] as? NSNumber)?.intValue else { return nil }
        tunnelID = id
        profile = tunnel["name"] as? String
        isOn = tunnel["enabled"] as? Bool ?? false
        // v0 treated status 1 and 2 as up; the meaning of each code is not yet confirmed on a router.
        let code = (tunnel["status"] as? NSNumber)?.intValue
        isConnected = isOn && (code == nil || code == 1 || code == 2)
    }
}

public enum GLiNetError: Error, Equatable, Sendable {
    case invalidHost
    case timedOut
    case http(Int)
    case noPassword
    case wrongPassword
    /// Too many failed logins; the router refuses new ones for a while.
    case lockedOut(seconds: Int?)
    case rpc(code: Int, message: String)
    case unexpectedResponse
    /// The router has no VPN client tunnel to switch.
    case noVPN
}
