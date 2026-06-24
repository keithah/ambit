import Foundation

// Tier-based network diagnosis (pingscope-internal). Given each monitored host's tier and
// health, decide whether a problem is the local link, the ISP path, the wider internet, or a
// single remote service — blaming the innermost failing tier.

public enum NetworkConnectivityStatus: String, CaseIterable, Codable, Sendable {
    case connected, noInternet, noIPAddress, notConnected
}

/// One host's contribution to a diagnosis.
public struct DiagnosisHost: Equatable, Sendable {
    public var id: String
    public var tier: NetworkTier
    public var status: HealthStatus
    public var consecutiveFailures: Int
    /// True when this host's data is stale (no fresh sample within the staleness window). Stale
    /// hosts are excluded from fault inference — you can't diagnose from data you didn't collect.
    public var isStale: Bool

    public init(id: String, tier: NetworkTier, status: HealthStatus, consecutiveFailures: Int = 0, isStale: Bool = false) {
        self.id = id
        self.tier = tier
        self.status = status
        self.consecutiveFailures = consecutiveFailures
        self.isStale = isStale
    }
}

public struct NetworkPerspectiveDiagnosis: Equatable, Sendable {
    public enum Scope: String, Sendable { case noData, monitoringStalled, allReachable, localNetwork, upstream, remoteService, partialDegradation }
    public enum Verdict: Equatable, Sendable {
        case noData
        case monitoringStalled
        case allReachable
        case localNetworkDown
        case ispPathDown
        case upstreamDown
        case remoteServiceDown(hostIDs: [String])
        case partialDegradation(tier: NetworkTier)
    }
    public enum Confidence: String, Sendable { case high, tentative }

    public struct TierEvidence: Equatable, Sendable {
        public var tier: NetworkTier
        public var total: Int
        public var healthy: Int
        public var degraded: Int
        public var down: Int
        public var status: HealthStatus
        public var summary: String
    }

    public var scope: Scope
    public var verdict: Verdict
    public var confidence: Confidence
    public var faultTier: NetworkTier?
    public var affectedHostIDs: [String]
    public var title: String
    public var detail: String
    public var tierEvidence: [TierEvidence]
}

public struct NetworkPerspectiveDiagnoser: Sendable {
    public init() {}

    public func diagnose(hosts: [DiagnosisHost], networkStatus: NetworkConnectivityStatus = .connected) -> NetworkPerspectiveDiagnosis {
        // 1. System link state overrides host inference (don't blame the path when the link
        //    itself is down).
        switch networkStatus {
        case .notConnected, .noIPAddress:
            return make(.localNetwork, .localNetworkDown, .high, .localGateway, [], [], "Local network down", "No network link.")
        case .noInternet:
            return make(.upstream, .upstreamDown, .tentative, .upstream, [], [], "No internet", "The system reports no internet connection.")
        case .connected:
            break
        }

        // Stale hosts are excluded from inference — you cannot diagnose a fault from data you
        // did not collect. If the only thing wrong is staleness, report that, never "down".
        let observed = hosts.filter { $0.status != .noData && !$0.isStale }
        guard !observed.isEmpty else {
            if hosts.contains(where: \.isStale) {
                return make(.monitoringStalled, .monitoringStalled, .tentative, nil, [], [],
                            "Monitoring paused", "No fresh data — monitoring resuming.")
            }
            return make(.noData, .noData, .tentative, nil, [], [], "No data", "No samples yet.")
        }

        let byTier = Dictionary(grouping: observed, by: \.tier)
        let evidence = NetworkTier.allCases.compactMap { tier in byTier[tier].map { tierEvidence(tier, $0) } }

        // 2. Innermost tier with any confirmed-down host is the fault.
        for tier in NetworkTier.allCases {
            guard let group = byTier[tier] else { continue }
            let down = group.filter { $0.status == .down }
            guard !down.isEmpty else { continue }
            let ratio = Double(down.count) / Double(group.count)
            let confidence: NetworkPerspectiveDiagnosis.Confidence = ratio >= 1.0 ? .high : .tentative
            let (title, detail) = describe(tier: tier, down: down.count, total: group.count)
            return make(scope(for: tier), verdict(for: tier, downIDs: down.map(\.id)), confidence, tier, down.map(\.id), evidence, title, detail)
        }

        // 3. No downs — flag the innermost degraded tier as partial degradation.
        if let tier = NetworkTier.allCases.first(where: { byTier[$0]?.contains { $0.status == .degraded } ?? false }) {
            let affected = byTier[tier]?.filter { $0.status == .degraded }.map(\.id) ?? []
            return make(.partialDegradation, .partialDegradation(tier: tier), .tentative, tier, affected, evidence,
                        "\(tier.displayName) degraded", "Elevated latency on the \(tier.displayName.lowercased()).")
        }

        // 4. Everything healthy.
        return make(.allReachable, .allReachable, .high, nil, [], evidence,
                    "All reachable", "\(observed.count)/\(observed.count) monitored hosts healthy.")
    }

    private func scope(for tier: NetworkTier) -> NetworkPerspectiveDiagnosis.Scope {
        switch tier {
        case .localGateway: return .localNetwork
        case .ispEdge, .upstream: return .upstream
        case .remoteService: return .remoteService
        }
    }

    private func verdict(for tier: NetworkTier, downIDs: [String]) -> NetworkPerspectiveDiagnosis.Verdict {
        switch tier {
        case .localGateway: return .localNetworkDown
        case .ispEdge: return .ispPathDown
        case .upstream: return .upstreamDown
        case .remoteService: return .remoteServiceDown(hostIDs: downIDs)
        }
    }

    private func describe(tier: NetworkTier, down: Int, total: Int) -> (String, String) {
        switch tier {
        case .localGateway: return ("Local network down", "\(down)/\(total) gateway host(s) unreachable.")
        case .ispEdge: return ("ISP path down", "\(down)/\(total) ISP host(s) unreachable.")
        case .upstream: return ("Internet unreachable", "\(down)/\(total) upstream host(s) unreachable.")
        case .remoteService: return ("Remote service down", "\(down)/\(total) remote host(s) unreachable.")
        }
    }

    private func tierEvidence(_ tier: NetworkTier, _ hosts: [DiagnosisHost]) -> NetworkPerspectiveDiagnosis.TierEvidence {
        let down = hosts.filter { $0.status == .down }.count
        let degraded = hosts.filter { $0.status == .degraded }.count
        let healthy = hosts.filter { $0.status == .healthy }.count
        let status: HealthStatus = down > 0 ? .down : (degraded > 0 ? .degraded : .healthy)
        return .init(tier: tier, total: hosts.count, healthy: healthy, degraded: degraded, down: down, status: status,
                     summary: "\(down + degraded)/\(hosts.count) \(tier.displayName.lowercased()) affected")
    }

    private func make(
        _ scope: NetworkPerspectiveDiagnosis.Scope,
        _ verdict: NetworkPerspectiveDiagnosis.Verdict,
        _ confidence: NetworkPerspectiveDiagnosis.Confidence,
        _ faultTier: NetworkTier?,
        _ affected: [String],
        _ evidence: [NetworkPerspectiveDiagnosis.TierEvidence],
        _ title: String,
        _ detail: String
    ) -> NetworkPerspectiveDiagnosis {
        .init(scope: scope, verdict: verdict, confidence: confidence, faultTier: faultTier,
              affectedHostIDs: affected, title: title, detail: detail, tierEvidence: evidence)
    }
}
