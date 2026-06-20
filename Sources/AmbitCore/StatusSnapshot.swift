import Foundation

public struct SourceState<Value: Equatable & Sendable>: Equatable, Sendable {
    public var value: Value?
    public var isLoading: Bool
    public var errorMessage: String?

    public init(value: Value? = nil, isLoading: Bool = false, errorMessage: String? = nil) {
        self.value = value
        self.isLoading = isLoading
        self.errorMessage = errorMessage
    }
}

public struct StatusSnapshot: Equatable, Sendable {
    public var router: SourceState<RouterStatus>
    public var vpn: SourceState<VPNStatus>
    public var reachability: SourceState<ReachabilityStatus>
    public var speedify: SourceState<SpeedifyStatus>
    public var starlink: SourceState<StarlinkStatus>
    public var ecoflow: SourceState<EcoFlowSnapshot>
    public var lastUpdated: Date?

    public init(
        router: SourceState<RouterStatus> = SourceState(),
        vpn: SourceState<VPNStatus> = SourceState(),
        reachability: SourceState<ReachabilityStatus> = SourceState(),
        speedify: SourceState<SpeedifyStatus> = SourceState(),
        starlink: SourceState<StarlinkStatus> = SourceState(),
        ecoflow: SourceState<EcoFlowSnapshot> = SourceState(),
        lastUpdated: Date? = nil
    ) {
        self.router = router
        self.vpn = vpn
        self.reachability = reachability
        self.speedify = speedify
        self.starlink = starlink
        self.ecoflow = ecoflow
        self.lastUpdated = lastUpdated
    }
}
