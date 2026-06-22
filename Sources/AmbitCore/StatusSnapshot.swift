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
    public var providers: [ProviderInstanceID: SourceState<ProviderSnapshot>]
    public var lastUpdated: Date?

    public init(
        providers: [ProviderInstanceID: SourceState<ProviderSnapshot>] = [:],
        router: SourceState<RouterStatus> = SourceState(),
        vpn: SourceState<VPNStatus> = SourceState(),
        reachability: SourceState<ReachabilityStatus> = SourceState(),
        speedify: SourceState<SpeedifyStatus> = SourceState(),
        starlink: SourceState<StarlinkStatus> = SourceState(),
        ecoflow: SourceState<EcoFlowSnapshot> = SourceState(),
        lastUpdated: Date? = nil
    ) {
        self.providers = providers
        self.lastUpdated = lastUpdated
        mergeCompatibilityState(router, instanceID: ProviderInstanceIDs.router, detail: ProviderDetail.router, snapshot: ProviderSnapshot.router)
        mergeCompatibilityState(vpn, instanceID: ProviderInstanceIDs.vpn, detail: ProviderDetail.vpn, snapshot: ProviderSnapshot.vpn)
        mergeCompatibilityState(
            reachability,
            instanceID: ProviderInstanceIDs.reachability,
            detail: ProviderDetail.reachability,
            snapshot: ProviderSnapshot.reachability
        )
        mergeCompatibilityState(speedify, instanceID: ProviderInstanceIDs.speedify, detail: ProviderDetail.speedify, snapshot: ProviderSnapshot.speedify)
        mergeCompatibilityState(starlink, instanceID: ProviderInstanceIDs.starlink, detail: ProviderDetail.starlink, snapshot: ProviderSnapshot.starlink)
        mergeCompatibilityState(ecoflow, instanceID: ProviderInstanceIDs.ecoflow, detail: ProviderDetail.ecoflow, snapshot: ProviderSnapshot.ecoFlow)
    }

    public var engineSnapshot: EngineSnapshot {
        EngineSnapshot(providers: providers, lastUpdated: lastUpdated)
    }

    public var router: SourceState<RouterStatus> {
        get { providerState(ProviderInstanceIDs.router) { if case .router(let value) = $0 { value } else { nil } } }
        set { setProviderState(newValue, instanceID: ProviderInstanceIDs.router, detail: ProviderDetail.router, snapshot: ProviderSnapshot.router) }
    }

    public var vpn: SourceState<VPNStatus> {
        get { providerState(ProviderInstanceIDs.vpn) { if case .vpn(let value) = $0 { value } else { nil } } }
        set { setProviderState(newValue, instanceID: ProviderInstanceIDs.vpn, detail: ProviderDetail.vpn, snapshot: ProviderSnapshot.vpn) }
    }

    public var reachability: SourceState<ReachabilityStatus> {
        get { providerState(ProviderInstanceIDs.reachability) { if case .reachability(let value) = $0 { value } else { nil } } }
        set {
            setProviderState(
                newValue,
                instanceID: ProviderInstanceIDs.reachability,
                detail: ProviderDetail.reachability,
                snapshot: ProviderSnapshot.reachability
            )
        }
    }

    public var speedify: SourceState<SpeedifyStatus> {
        get { providerState(ProviderInstanceIDs.speedify) { if case .speedify(let value) = $0 { value } else { nil } } }
        set { setProviderState(newValue, instanceID: ProviderInstanceIDs.speedify, detail: ProviderDetail.speedify, snapshot: ProviderSnapshot.speedify) }
    }

    public var starlink: SourceState<StarlinkStatus> {
        get { providerState(ProviderInstanceIDs.starlink) { if case .starlink(let value) = $0 { value } else { nil } } }
        set { setProviderState(newValue, instanceID: ProviderInstanceIDs.starlink, detail: ProviderDetail.starlink, snapshot: ProviderSnapshot.starlink) }
    }

    public var ecoflow: SourceState<EcoFlowSnapshot> {
        get { providerState(ProviderInstanceIDs.ecoflow) { if case .ecoflow(let value) = $0 { value } else { nil } } }
        set { setProviderState(newValue, instanceID: ProviderInstanceIDs.ecoflow, detail: ProviderDetail.ecoflow, snapshot: ProviderSnapshot.ecoFlow) }
    }

    public var ping: SourceState<PingSnapshot> {
        get { providerState(ProviderInstanceIDs.ping) { if case .ping(let value) = $0 { value } else { nil } } }
        set { setProviderState(newValue, instanceID: ProviderInstanceIDs.ping, detail: ProviderDetail.ping, snapshot: ProviderSnapshot.ping) }
    }

    public var iperf3: SourceState<Iperf3Snapshot> {
        get { providerState(ProviderInstanceIDs.iperf3) { if case .iperf3(let value) = $0 { value } else { nil } } }
        set { setProviderState(newValue, instanceID: ProviderInstanceIDs.iperf3, detail: ProviderDetail.iperf3, snapshot: ProviderSnapshot.iperf3) }
    }

    private func providerState<DetailValue>(
        _ instanceID: ProviderInstanceID,
        extract: (ProviderDetail) -> DetailValue?
    ) -> SourceState<DetailValue> {
        guard let state = providers[instanceID] else { return SourceState() }
        let detail = state.value?.detail.flatMap(extract)
        return SourceState(value: detail, isLoading: state.isLoading, errorMessage: state.errorMessage)
    }

    private mutating func setProviderState<DetailValue>(
        _ state: SourceState<DetailValue>,
        instanceID: ProviderInstanceID,
        detail: (DetailValue) -> ProviderDetail,
        snapshot: (DetailValue) -> ProviderSnapshot
    ) {
        guard !state.isEmpty else {
            providers[instanceID] = nil
            return
        }
        providers[instanceID] = SourceState(
            providerValue: state.value,
            isLoading: state.isLoading,
            errorMessage: state.errorMessage,
            detail: detail,
            snapshot: snapshot
        )
    }

    private mutating func mergeCompatibilityState<DetailValue>(
        _ state: SourceState<DetailValue>,
        instanceID: ProviderInstanceID,
        detail: (DetailValue) -> ProviderDetail,
        snapshot: (DetailValue) -> ProviderSnapshot
    ) {
        guard !state.isEmpty else { return }
        setProviderState(state, instanceID: instanceID, detail: detail, snapshot: snapshot)
    }
}

public extension StatusSnapshot {
    var providerRouterStatus: RouterStatus? {
        router.value
    }

    var providerVPNStatus: VPNStatus? {
        vpn.value
    }

    var providerReachabilityStatus: ReachabilityStatus? {
        reachability.value
    }

    var providerSpeedifyStatus: SpeedifyStatus? {
        speedify.value
    }

    var providerStarlinkStatus: StarlinkStatus? {
        starlink.value
    }

    var providerEcoFlowSnapshot: EcoFlowSnapshot? {
        ecoflow.value
    }

    var providerPingSnapshot: PingSnapshot? {
        ping.value
    }

    var providerIperf3Snapshot: Iperf3Snapshot? {
        iperf3.value
    }

    func providerErrorMessage(_ providerID: ProviderID) -> String? {
        providers[ProviderInstanceIDs.resolve(providerID)]?.errorMessage
    }
}

public extension ProviderSnapshot {
    static func router(_ status: RouterStatus) -> ProviderSnapshot {
        var metrics: [Metric] = [
            Metric(id: "reachable", label: "Reachable", value: .bool(status.reachable))
        ]
        if let activeWAN = status.activeWAN {
            metrics.append(Metric(id: "active_wan", label: "Active WAN", value: .text(activeWAN.label)))
        }
        if let publicIP = status.publicIP {
            metrics.append(Metric(id: "public_ip", label: "Public IP", value: .text(publicIP)))
        }
        return ProviderSnapshot(health: status.reachable ? .ok : .down, metrics: metrics, detail: .router(status))
    }

    static func vpn(_ status: VPNStatus) -> ProviderSnapshot {
        let health: Health
        if !status.isAvailable {
            health = .unknown
        } else {
            health = status.isConnected ? .ok : .degraded
        }
        var metrics: [Metric] = [
            Metric(id: "available", label: "Available", value: .bool(status.isAvailable)),
            Metric(id: "connected", label: "Connected", value: .bool(status.isConnected)),
            Metric(id: "protocol", label: "Protocol", value: .text(status.vpnProtocol.rawValue))
        ]
        if let handshakeAge = status.handshakeAge {
            metrics.append(Metric(id: "handshake_age_seconds", label: "Handshake Age", value: .latency(ms: handshakeAge * 1000)))
        }
        if let rxBytes = status.rxBytes {
            metrics.append(Metric(id: "rx_bytes", label: "Received", value: .level(Double(rxBytes))))
        }
        if let txBytes = status.txBytes {
            metrics.append(Metric(id: "tx_bytes", label: "Sent", value: .level(Double(txBytes))))
        }
        return ProviderSnapshot(health: health, metrics: metrics, detail: .vpn(status))
    }

    static func reachability(_ status: ReachabilityStatus) -> ProviderSnapshot {
        var metrics = [
            Metric(id: "network_path", label: "Network Path", value: .bool(status.hasNetworkPath))
        ]
        let health: Health
        switch status.state {
        case .unknown:
            health = .unknown
        case .offline:
            health = .down
        case .online(let latency):
            health = .ok
            metrics.append(Metric(id: "latency_ms", label: "Latency", value: .latency(ms: latency * 1000)))
        }
        return ProviderSnapshot(health: health, metrics: metrics, detail: .reachability(status))
    }

    static func speedify(_ status: SpeedifyStatus) -> ProviderSnapshot {
        var metrics: [Metric] = [
            Metric(id: "installed", label: "Installed", value: .bool(status.isInstalled)),
            Metric(id: "available", label: "Available", value: .bool(status.isAvailable)),
            Metric(id: "connected", label: "Connected", value: .bool(status.isConnected)),
            Metric(id: "state", label: "State", value: .text(status.state))
        ]
        if let server = status.server {
            metrics.append(Metric(id: "server", label: "Server", value: .text(server)))
        }
        if let bondingMode = status.bondingMode {
            metrics.append(Metric(id: "bonding_mode", label: "Bonding Mode", value: .text(bondingMode.label)))
        }
        if let latest = status.graphSamples.last {
            metrics.append(Metric(id: "throughput_bps", label: "Throughput", value: .throughput(bitsPerSecond: latest.totalBps)))
            if let down = latest.downloadBps {
                metrics.append(Metric(id: "download_bps", label: "Download", value: .throughput(bitsPerSecond: down)))
            }
            if let up = latest.uploadBps {
                metrics.append(Metric(id: "upload_bps", label: "Upload", value: .throughput(bitsPerSecond: up)))
            }
        }
        let health: Health = status.isAvailable ? (status.isConnected ? .ok : .degraded) : .down
        return ProviderSnapshot(health: health, metrics: metrics, detail: .speedify(status))
    }

    static func starlink(_ status: StarlinkStatus) -> ProviderSnapshot {
        var metrics: [Metric] = [
            Metric(id: "reachable", label: "Reachable", value: .bool(status.isReachable)),
            Metric(id: "state", label: "State", value: .text(status.state))
        ]
        if let down = status.downlinkThroughputBps ?? status.recentDownlinkThroughputBps {
            metrics.append(Metric(id: "downlink_bps", label: "Downlink", value: .throughput(bitsPerSecond: down)))
        }
        if let up = status.uplinkThroughputBps ?? status.recentUplinkThroughputBps {
            metrics.append(Metric(id: "uplink_bps", label: "Uplink", value: .throughput(bitsPerSecond: up)))
        }
        if let latency = status.popPingLatencyMs ?? status.recentLatencyMs {
            metrics.append(Metric(id: "pop_latency_ms", label: "POP Latency", value: .latency(ms: latency)))
        }
        if let obstruction = status.obstructionPercent {
            metrics.append(Metric(id: "obstruction_percent", label: "Obstruction", value: .percent(obstruction)))
        }
        if let drop = status.recentDropRate {
            metrics.append(Metric(id: "drop_percent", label: "Drop Rate", value: .percent(drop * 100)))
        }
        if let outages = status.outageCount {
            metrics.append(Metric(id: "outage_count", label: "Outages", value: .level(Double(outages))))
        }
        let health: Health = status.isReachable ? ((status.obstructionPercent ?? 0) > 5 ? .degraded : .ok) : .down
        return ProviderSnapshot(health: health, metrics: metrics, detail: .starlink(status))
    }

    static func ecoFlow(_ snapshot: EcoFlowSnapshot) -> ProviderSnapshot {
        var metrics: [Metric] = []
        if let percent = snapshot.status.battery.percent {
            metrics.append(Metric(id: "battery_percent", label: "Battery", value: .level(Double(percent)), deviceClass: .battery))
        }
        metrics.append(Metric(id: "battery_state", label: "Battery State", value: .text(snapshot.status.battery.state.rawValue)))
        if let input = snapshot.status.power.inputWatts {
            metrics.append(Metric(id: "input_watts", label: "Input", value: .level(Double(input))))
        }
        if let output = snapshot.status.power.outputWatts {
            metrics.append(Metric(id: "output_watts", label: "Output", value: .level(Double(output))))
        }
        metrics.append(Metric(id: "ac_output", label: "AC Output", value: .bool(snapshot.status.outputs.ac.state == .on)))
        metrics.append(Metric(id: "dc_output", label: "DC Output", value: .bool(snapshot.status.outputs.dc.state == .on)))
        metrics.append(Metric(id: "usb_output", label: "USB Output", value: .bool(snapshot.status.outputs.usb.state == .on)))
        let percent = snapshot.status.battery.percent
        let health: Health = percent.map { $0 < 20 ? .degraded : .ok } ?? .unknown
        return ProviderSnapshot(health: health, metrics: metrics, detail: .ecoflow(snapshot))
    }
}
