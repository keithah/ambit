import Foundation

public enum InternetInterfaceKind: String, Equatable, Sendable {
    case cellular
    case starlink
    case tethering
    case ethernet
    case repeater
    case unknown
}

public struct InternetInterfaceStatus: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var kind: InternetInterfaceKind
    public var isConnected: Bool
    public var isPrimary: Bool
    public var qualityLabel: String?
    public var downloadBps: Int?
    public var uploadBps: Int?
    public var dataUsedBytes: Int?
    public var detail: String?

    public init(
        id: String,
        label: String,
        kind: InternetInterfaceKind,
        isConnected: Bool,
        isPrimary: Bool = false,
        qualityLabel: String? = nil,
        downloadBps: Int? = nil,
        uploadBps: Int? = nil,
        dataUsedBytes: Int? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.isConnected = isConnected
        self.isPrimary = isPrimary
        self.qualityLabel = qualityLabel
        self.downloadBps = downloadBps
        self.uploadBps = uploadBps
        self.dataUsedBytes = dataUsedBytes
        self.detail = detail
    }

    public static func overview(router: RouterStatus?, speedify: SpeedifyStatus?) -> [InternetInterfaceStatus] {
        var interfaces = speedify?.networks
            .filter { network in
                network.priority != .never && network.priority != .unknown
            }
            .map(Self.init(speedifyNetwork:)) ?? []

        if interfaces.isEmpty, let activeWAN = router?.activeWAN {
            interfaces.append(Self.routerInterface(activeWAN))
        }

        if !interfaces.contains(where: { $0.kind == .tethering }) {
            interfaces.append(InternetInterfaceStatus(
                id: "tethering",
                label: "Tethered Device",
                kind: .tethering,
                isConnected: false,
                qualityLabel: "Idle",
                detail: "No tethered device"
            ))
        }

        return interfaces.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            return sortRank(lhs.kind) < sortRank(rhs.kind)
        }
    }

    public static func topology(router: RouterStatus?, speedify: SpeedifyStatus?, starlink: StarlinkStatus?) -> [InternetInterfaceStatus] {
        var interfaces = overview(router: router, speedify: speedify)
        guard let starlink, starlink.isReachable else { return interfaces }

        let speedifyHasStarlink = speedify?.networks.contains { network in
            kind(for: network) == .starlink && network.priority != .never && network.priority != .unknown
        } ?? false

        if !speedifyHasStarlink {
            interfaces.removeAll { $0.kind == .ethernet }
        }

        if let index = interfaces.firstIndex(where: { $0.kind == .starlink }) {
            interfaces[index].isConnected = true
            interfaces[index].qualityLabel = starlink.state
            interfaces[index].downloadBps = interfaces[index].downloadBps ?? starlink.downlinkThroughputBps ?? starlink.recentDownlinkThroughputBps
            interfaces[index].uploadBps = interfaces[index].uploadBps ?? starlink.uplinkThroughputBps ?? starlink.recentUplinkThroughputBps
            interfaces[index].detail = interfaces[index].detail ?? "Ethernet"
        } else {
            interfaces.append(InternetInterfaceStatus(
                id: "starlink-grpc",
                label: "Starlink",
                kind: .starlink,
                isConnected: true,
                qualityLabel: starlink.state,
                downloadBps: starlink.downlinkThroughputBps ?? starlink.recentDownlinkThroughputBps,
                uploadBps: starlink.uplinkThroughputBps ?? starlink.recentUplinkThroughputBps,
                detail: "Ethernet"
            ))
        }

        return interfaces.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            return sortRank(lhs.kind) < sortRank(rhs.kind)
        }
    }

    private init(speedifyNetwork: SpeedifyNetwork) {
        let kind = Self.kind(for: speedifyNetwork)
        self.init(
            id: speedifyNetwork.id,
            label: Self.label(for: speedifyNetwork, kind: kind),
            kind: kind,
            isConnected: speedifyNetwork.isConnected,
            isPrimary: speedifyNetwork.priority == .always,
            qualityLabel: speedifyNetwork.statusMessage ?? speedifyNetwork.priority.label,
            downloadBps: speedifyNetwork.receiveBps,
            uploadBps: speedifyNetwork.sendBps,
            detail: speedifyNetwork.isp
        )
    }

    private static func routerInterface(_ wan: WANInterface) -> InternetInterfaceStatus {
        let kind: InternetInterfaceKind
        switch wan {
        case .modem:
            kind = .cellular
        case .tethering:
            kind = .tethering
        case .repeater:
            kind = .repeater
        case .wired:
            kind = .ethernet
        case .unknown:
            kind = .unknown
        }
        return InternetInterfaceStatus(
            id: wan.label.lowercased(),
            label: wan.label,
            kind: kind,
            isConnected: true,
            isPrimary: true,
            qualityLabel: "Primary"
        )
    }

    private static func kind(for network: SpeedifyNetwork) -> InternetInterfaceKind {
        let text = [network.id, network.name, network.type, network.isp]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if text.contains("starlink") { return .starlink }
        if text.contains("cell") || text.contains("t-mobile") || text.contains("rmnet") { return .cellular }
        if text.contains("tether") { return .tethering }
        if text.contains("repeater") || text.contains("wifi") || text.contains("wi-fi") { return .repeater }
        if text.contains("eth") || text.contains("ethernet") { return .ethernet }
        return .unknown
    }

    private static func label(for network: SpeedifyNetwork, kind: InternetInterfaceKind) -> String {
        switch kind {
        case .cellular:
            return "Cellular"
        case .starlink:
            return "Starlink"
        case .tethering:
            return "Tethered Device"
        case .ethernet:
            return network.name.isEmpty ? "Ethernet" : network.name
        case .repeater:
            return "Repeater"
        case .unknown:
            return network.name.isEmpty ? network.id : network.name
        }
    }

    private static func sortRank(_ kind: InternetInterfaceKind) -> Int {
        switch kind {
        case .cellular: return 0
        case .starlink: return 1
        case .tethering: return 2
        case .ethernet: return 3
        case .repeater: return 4
        case .unknown: return 5
        }
    }
}
