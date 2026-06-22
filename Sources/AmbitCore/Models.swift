import Foundation

public enum WANInterface: Equatable, Sendable {
    case wired
    case repeater
    case tethering
    case modem
    case unknown(String)

    public var label: String {
        switch self {
        case .wired: return "Ethernet"
        case .repeater: return "Repeater"
        case .tethering: return "Tethering"
        case .modem: return "Modem"
        case .unknown(let value): return value.isEmpty ? "Unknown" : value
        }
    }

    public init(rawValue: String) {
        switch rawValue.lowercased() {
        case "ethernet", "eth", "wan", "wired": self = .wired
        case "repeater", "wifi", "wlan": self = .repeater
        case "tethering", "tether": self = .tethering
        case "modem", "cellular", "lte": self = .modem
        default: self = .unknown(rawValue)
        }
    }
}

public struct RouterStatus: Equatable, Sendable {
    public var reachable: Bool
    public var hostname: String?
    public var firmwareVersion: String?
    public var model: String?
    public var activeWAN: WANInterface?
    public var publicIP: String?
    public var lanIP: String?
    public var clientCount: Int?
    public var raw: JSONObject

    public init(reachable: Bool = false, hostname: String? = nil, firmwareVersion: String? = nil, model: String? = nil, activeWAN: WANInterface? = nil, publicIP: String? = nil, lanIP: String? = nil, clientCount: Int? = nil, raw: JSONObject = [:]) {
        self.reachable = reachable
        self.hostname = hostname
        self.firmwareVersion = firmwareVersion
        self.model = model
        self.activeWAN = activeWAN
        self.publicIP = publicIP
        self.lanIP = lanIP
        self.clientCount = clientCount
        self.raw = raw
    }

    public init(payload: JSONObject) {
        self.reachable = true
        self.hostname = payload.firstString(keys: ["hostname", "model", "name"])
        self.firmwareVersion = payload.firstString(keys: ["firmware_version", "firmware", "version"])
        self.model = nil
        self.publicIP = payload.firstString(keys: ["ip", "public_ip", "wan_ip", "ipv4"])
        if let wan = payload.firstString(keys: ["wan", "wan_type", "active_wan", "interface", "ifname"]) {
            self.activeWAN = WANInterface(rawValue: wan)
        } else {
            self.activeWAN = payload.activeNetworkInterface()
        }
        self.lanIP = payload.firstString(keys: ["lan_ip"])
        self.clientCount = RouterStatus.parseClientCount(from: payload)
        self.raw = payload
    }

    // gl.inet `system get_status` returns `client: [{cable_total, wireless_total}]`.
    private static func parseClientCount(from payload: JSONObject) -> Int? {
        guard let entry = payload["client"]?.arrayValue?.first?.objectValue else { return nil }
        let cable = entry["cable_total"]?.intValue
        let wireless = entry["wireless_total"]?.intValue
        guard cable != nil || wireless != nil else { return nil }
        return (cable ?? 0) + (wireless ?? 0)
    }
}

/// Board identity from gl.inet `system board` (ubus): hostname + friendly model.
public struct RouterBoardInfo: Equatable, Sendable {
    public var hostname: String?
    public var model: String?

    public init(hostname: String? = nil, model: String? = nil) {
        self.hostname = hostname
        self.model = model
    }
}

public enum VPNProtocol: String, Equatable, Sendable {
    case vpnClient = "VPN Client"
    case wireGuard = "WireGuard"
    case openVPN = "OpenVPN"
    case wireGuardServer = "WireGuard Server"
    case openVPNServer = "OpenVPN Server"
    case tailscale = "Tailscale"
    case tor = "Tor"
    case zeroTier = "ZeroTier"
}

public struct VPNStatus: Equatable, Sendable {
    public var isAvailable: Bool
    public var unavailableReason: String?
    public var canToggle: Bool
    public var tunnelID: Int?
    public var vpnProtocol: VPNProtocol
    public var isConnected: Bool
    public var server: String?
    public var profile: String?
    public var handshakeAge: TimeInterval?
    public var rxBytes: Int?
    public var txBytes: Int?
    public var raw: JSONObject

    public init(isAvailable: Bool = true, unavailableReason: String? = nil, canToggle: Bool = true, tunnelID: Int? = nil, protocol vpnProtocol: VPNProtocol = .wireGuard, isConnected: Bool = false, server: String? = nil, profile: String? = nil, handshakeAge: TimeInterval? = nil, rxBytes: Int? = nil, txBytes: Int? = nil, raw: JSONObject = [:]) {
        self.isAvailable = isAvailable
        self.unavailableReason = unavailableReason
        self.canToggle = canToggle
        self.tunnelID = tunnelID
        self.vpnProtocol = vpnProtocol
        self.isConnected = isConnected
        self.server = server
        self.profile = profile
        self.handshakeAge = handshakeAge
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.raw = raw
    }

    public init(protocol vpnProtocol: VPNProtocol, payload: JSONObject) {
        self.isAvailable = true
        self.unavailableReason = nil
        self.canToggle = true
        self.tunnelID = nil
        self.vpnProtocol = vpnProtocol
        self.isConnected = payload.firstBool(keys: ["connected", "up", "running", "enabled"]) ?? (payload.firstString(keys: ["status", "state"])?.lowercased().contains("connect") ?? false)
        self.server = payload.firstString(keys: ["server", "endpoint", "remote"])
        self.profile = payload.firstString(keys: ["profile", "name", "config"])
        self.handshakeAge = payload.firstNumber(keys: ["handshake_age", "latest_handshake_age"])
        self.rxBytes = payload.firstInt(keys: ["rx", "rx_bytes", "received"])
        self.txBytes = payload.firstInt(keys: ["tx", "tx_bytes", "sent"])
        self.raw = payload
    }

    public static func unavailable(_ reason: String) -> VPNStatus {
        VPNStatus(isAvailable: false, unavailableReason: reason, canToggle: false, protocol: .wireGuard, isConnected: false)
    }

    public static func vpnClient(statusPayload: JSONObject, tunnelPayload: JSONObject, configPayload: JSONObject) -> VPNStatus {
        let statusList = statusPayload["status_list"]?.arrayValue?.compactMap(\.objectValue) ?? []
        let tunnelList = tunnelPayload["tunnels"]?.arrayValue?.compactMap(\.objectValue) ?? []
        let firstStatus = statusList.first
        let firstTunnel = tunnelList.first
        let tunnelID = firstStatus?["tunnel_id"]?.intValue ?? firstTunnel?["tunnel_id"]?.intValue
        let profile = firstStatus?["name"]?.stringValue ?? firstTunnel?["name"]?.stringValue
        let enabled = firstStatus?["enabled"]?.boolValue ?? firstTunnel?["enabled"]?.boolValue ?? false
        let statusCode = firstStatus?["status"]?.intValue
        let connected = enabled && (statusCode == nil || statusCode == 1 || statusCode == 2)
        let configs = configPayload["configs"]?.objectValue
        let wireGuardConfigs = configs?["wireguard"]?.arrayValue ?? []
        let openVPNConfigs = configs?["openvpn"]?.arrayValue ?? []
        let hasConfig = !(wireGuardConfigs.isEmpty && openVPNConfigs.isEmpty)
        return VPNStatus(
            isAvailable: true,
            unavailableReason: hasConfig ? nil : "No VPN client configuration selected.",
            canToggle: hasConfig && tunnelID != nil,
            tunnelID: tunnelID,
            protocol: .vpnClient,
            isConnected: connected,
            profile: profile,
            raw: statusPayload
        )
    }

    public static func tailscale(payload: JSONObject) -> VPNStatus {
        let statusCode = payload["status"]?.intValue
        let connected = statusCode == 2 || payload.firstBool(keys: ["enabled", "running", "connected"]) == true
        return VPNStatus(
            protocol: .tailscale,
            isConnected: connected,
            server: payload.firstString(keys: ["dns", "tailnet", "hostname"]),
            raw: payload
        )
    }

    public static func tor(payload: JSONObject) -> VPNStatus {
        let statusCode = payload["status"]?.intValue
        let connected = statusCode == 1 || statusCode == 2 || payload.firstBool(keys: ["enabled", "running", "connected"]) == true
        return VPNStatus(
            protocol: .tor,
            isConnected: connected,
            server: payload.firstString(keys: ["exit_node", "relay", "country", "region"]),
            raw: payload
        )
    }

    public static func wireGuardServer(payload: JSONObject) -> VPNStatus {
        let server = payload["server"]?.objectValue
        let connected = server?["status"]?.intValue == 1 || server?.firstBool(keys: ["enabled", "running"]) == true
        return VPNStatus(
            protocol: .wireGuardServer,
            isConnected: connected,
            profile: "Server",
            raw: payload
        )
    }

    public static func openVPNServer(payload: JSONObject) -> VPNStatus {
        let connected = payload["status"]?.intValue == 1 || payload.firstBool(keys: ["enabled", "running"]) == true
        return VPNStatus(
            protocol: .openVPNServer,
            isConnected: connected,
            server: payload.firstString(keys: ["tunnel_ip"]),
            rxBytes: payload.firstInt(keys: ["rx_bytes"]),
            txBytes: payload.firstInt(keys: ["tx_bytes"]),
            raw: payload
        )
    }
}

public enum ReachabilityState: Equatable, Sendable {
    case unknown
    case offline
    case online(latency: TimeInterval)
}

public struct ReachabilityStatus: Equatable, Sendable {
    public var hasNetworkPath: Bool
    public var state: ReachabilityState

    public init(hasNetworkPath: Bool = false, state: ReachabilityState = .unknown) {
        self.hasNetworkPath = hasNetworkPath
        self.state = state
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    func firstString(keys: [String]) -> String? {
        for key in keys {
            if let value = self[key]?.stringValue { return value }
        }
        for value in values {
            if let object = value.objectValue, let match = object.firstString(keys: keys) { return match }
        }
        return nil
    }

    func firstBool(keys: [String]) -> Bool? {
        for key in keys {
            if let value = self[key]?.boolValue { return value }
        }
        for value in values {
            if let object = value.objectValue, let match = object.firstBool(keys: keys) { return match }
        }
        return nil
    }

    func firstNumber(keys: [String]) -> Double? {
        for key in keys {
            if case .number(let value) = self[key] { return value }
        }
        for value in values {
            if let object = value.objectValue, let match = object.firstNumber(keys: keys) { return match }
        }
        return nil
    }

    func firstInt(keys: [String]) -> Int? {
        firstNumber(keys: keys).map(Int.init)
    }

    func activeNetworkInterface() -> WANInterface? {
        guard let network = self["network"]?.arrayValue else { return nil }
        for value in network {
            guard let object = value.objectValue else { continue }
            let up = object["up"]?.boolValue ?? false
            let online = object["online"]?.boolValue ?? false
            guard up && online, let interface = object["interface"]?.stringValue else { continue }
            return WANInterface(rawValue: interface)
        }
        return nil
    }
}
