import Foundation

public struct VPNServiceStatus: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var state: String
    public var isConnected: Bool
    public var server: String?
    public var detail: String?

    public init(id: String, label: String, state: String, isConnected: Bool, server: String? = nil, detail: String? = nil) {
        self.id = id
        self.label = label
        self.state = state
        self.isConnected = isConnected
        self.server = server
        self.detail = detail
    }
}

public struct AggregateVPNStatus: Equatable, Sendable {
    public var services: [VPNServiceStatus]

    public init(routerVPN: VPNStatus?, speedify: SpeedifyStatus?) {
        var services: [VPNServiceStatus] = []
        if let routerVPN, routerVPN.isAvailable {
            services.append(VPNServiceStatus(
                id: "router-vpn",
                label: routerVPN.vpnProtocol == .vpnClient ? "Router VPN Client" : routerVPN.vpnProtocol.rawValue,
                state: routerVPN.isConnected ? "Connected" : "Disconnected",
                isConnected: routerVPN.isConnected,
                server: routerVPN.server,
                detail: routerVPN.profile
            ))
        }
        if let speedify, speedify.isAvailable {
            services.append(VPNServiceStatus(
                id: "speedify",
                label: "Speedify",
                state: speedify.state,
                isConnected: speedify.isConnected,
                server: speedify.server,
                detail: speedify.bondingMode?.label
            ))
        }
        self.services = services
    }

    public var connectedServices: [VPNServiceStatus] {
        services.filter(\.isConnected)
    }

    public var activeSummary: String {
        switch connectedServices.count {
        case 0:
            return "Disconnected"
        case 1:
            return connectedServices[0].label
        default:
            return "\(connectedServices.count) active"
        }
    }
}
