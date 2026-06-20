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
    public var providers: [ProviderID: SourceState<ProviderSnapshot>]
    public var router: SourceState<RouterStatus>
    public var vpn: SourceState<VPNStatus>
    public var reachability: SourceState<ReachabilityStatus>
    public var speedify: SourceState<SpeedifyStatus>
    public var starlink: SourceState<StarlinkStatus>
    public var ecoflow: SourceState<EcoFlowSnapshot>
    public var lastUpdated: Date?

    public init(
        providers: [ProviderID: SourceState<ProviderSnapshot>] = [:],
        router: SourceState<RouterStatus> = SourceState(),
        vpn: SourceState<VPNStatus> = SourceState(),
        reachability: SourceState<ReachabilityStatus> = SourceState(),
        speedify: SourceState<SpeedifyStatus> = SourceState(),
        starlink: SourceState<StarlinkStatus> = SourceState(),
        ecoflow: SourceState<EcoFlowSnapshot> = SourceState(),
        lastUpdated: Date? = nil
    ) {
        self.providers = providers
        self.router = router
        self.vpn = vpn
        self.reachability = reachability
        self.speedify = speedify
        self.starlink = starlink
        self.ecoflow = ecoflow
        self.lastUpdated = lastUpdated
    }

    public var engineSnapshot: EngineSnapshot {
        EngineSnapshot(providers: providers, lastUpdated: lastUpdated)
    }

    public mutating func populateProviderSnapshots() {
        providers = [
            ProviderIDs.router: SourceState(
                providerValue: router.value,
                errorMessage: router.errorMessage,
                detail: ProviderDetail.router,
                snapshot: ProviderSnapshot.router
            ),
            ProviderIDs.vpn: SourceState(
                providerValue: vpn.value,
                errorMessage: vpn.errorMessage,
                detail: ProviderDetail.vpn,
                snapshot: ProviderSnapshot.vpn
            ),
            ProviderIDs.reachability: SourceState(
                providerValue: reachability.value,
                errorMessage: reachability.errorMessage,
                detail: ProviderDetail.reachability,
                snapshot: ProviderSnapshot.reachability
            ),
            ProviderIDs.speedify: SourceState(
                providerValue: speedify.value,
                errorMessage: speedify.errorMessage,
                detail: ProviderDetail.speedify,
                snapshot: ProviderSnapshot.speedify
            ),
            ProviderIDs.starlink: SourceState(
                providerValue: starlink.value,
                errorMessage: starlink.errorMessage,
                detail: ProviderDetail.starlink,
                snapshot: ProviderSnapshot.starlink
            ),
            ProviderIDs.ecoflow: SourceState(
                providerValue: ecoflow.value,
                errorMessage: ecoflow.errorMessage,
                detail: ProviderDetail.ecoflow,
                snapshot: ProviderSnapshot.ecoFlow
            )
        ]
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
            metrics.append(Metric(id: "battery_percent", label: "Battery", value: .level(Double(percent))))
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
