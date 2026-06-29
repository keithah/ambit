import Foundation

public struct TopologyDiagnosisEngine: Sendable {
    public init() {}

    public func diagnose(_ perspective: MonitoringPerspective) -> MonitoringDiagnosis {
        switch perspective.linkStatus ?? .connected {
        case .notConnected, .noIPAddress:
            return make(
                perspective,
                verdict: .init(kind: .localNetworkDown, affectedRole: .localGateway),
                severity: .down,
                confidence: .high,
                affected: [],
                evidence: [],
                title: "Local network down",
                detail: "No network link."
            )
        case .noInternet:
            return make(
                perspective,
                verdict: .init(kind: .upstreamDown, affectedRole: .upstreamInternet),
                severity: .down,
                confidence: .tentative,
                affected: [],
                evidence: [],
                title: "No internet",
                detail: "The system reports no internet connection."
            )
        case .connected:
            break
        }

        let observed = perspective.members.filter { $0.status != .noData && !$0.isStale }
        guard !observed.isEmpty else {
            if perspective.members.contains(where: \.isStale) {
                return make(
                    perspective,
                    verdict: .init(kind: .monitoringStalled),
                    severity: .elevated,
                    confidence: .tentative,
                    affected: [],
                    evidence: [],
                    title: "Monitoring paused",
                    detail: "No fresh data — monitoring resuming."
                )
            }
            return make(
                perspective,
                verdict: .init(kind: .noData),
                severity: .normal,
                confidence: .tentative,
                affected: [],
                evidence: [],
                title: "No data",
                detail: "No samples yet."
            )
        }

        let byRole = Dictionary(grouping: observed, by: \.role)
        let evidence = diagnosisOrder.compactMap { role in byRole[role].map { roleEvidence(role, $0) } }

        for role in diagnosisOrder {
            guard let group = byRole[role] else { continue }
            let down = group.filter { $0.status == .down }
            guard !down.isEmpty else { continue }
            let ratio = Double(down.count) / Double(group.count)
            if role == .localGateway, ratio < 1.0 {
                return make(
                    perspective,
                    verdict: .init(kind: .partialDegradation, affectedRole: role),
                    severity: .degraded,
                    confidence: .tentative,
                    affected: down.map(\.entityID),
                    evidence: evidence,
                    title: "\(role.displayName) degraded",
                    detail: "\(down.count)/\(group.count) gateway host(s) unreachable."
                )
            }
            let confidence: DiagnosisConfidence = ratio >= 1.0 ? .high : .tentative
            let (title, detail) = describe(role: role, down: down.count, total: group.count)
            return make(
                perspective,
                verdict: .init(kind: verdictKind(for: role), affectedRole: role),
                severity: severity(forFaultRole: role),
                confidence: confidence,
                affected: down.map(\.entityID),
                evidence: evidence,
                title: title,
                detail: detail
            )
        }

        if let role = diagnosisOrder.first(where: { byRole[$0]?.contains { $0.status == .degraded } ?? false }) {
            let affected = byRole[role]?.filter { $0.status == .degraded }.map(\.entityID) ?? []
            return make(
                perspective,
                verdict: .init(kind: .partialDegradation, affectedRole: role),
                severity: .degraded,
                confidence: .tentative,
                affected: affected,
                evidence: evidence,
                title: "\(role.displayName) degraded",
                detail: "Elevated latency on the \(role.displayName.lowercased())."
            )
        }

        return make(
            perspective,
            verdict: .init(kind: .allReachable),
            severity: .normal,
            confidence: .high,
            affected: [],
            evidence: evidence,
            title: "All reachable",
            detail: "\(observed.count)/\(observed.count) monitored hosts healthy."
        )
    }

    private var diagnosisOrder: [MonitoringRole] {
        [.localGateway, .accessNetwork, .upstreamInternet, .remoteService]
    }

    private func verdictKind(for role: MonitoringRole) -> MonitoringVerdict.Kind {
        switch role {
        case .localGateway: return .localNetworkDown
        case .accessNetwork: return .accessNetworkDown
        case .upstreamInternet: return .upstreamDown
        case .remoteService: return .remoteServiceDown
        case .localLink: return .localNetworkDown
        case .endpoint: return .remoteServiceDown
        }
    }

    private func severity(forFaultRole role: MonitoringRole) -> Severity {
        role == .remoteService ? .alerting : .down
    }

    private func describe(role: MonitoringRole, down: Int, total: Int) -> (String, String) {
        switch role {
        case .localGateway: return ("Local network down", "\(down)/\(total) gateway host(s) unreachable.")
        case .accessNetwork: return ("ISP path down", "\(down)/\(total) ISP host(s) unreachable.")
        case .upstreamInternet: return ("Internet unreachable", "\(down)/\(total) upstream host(s) unreachable.")
        case .remoteService: return ("Remote service down", "\(down)/\(total) remote host(s) unreachable.")
        case .localLink: return ("Local network down", "\(down)/\(total) local link member(s) unreachable.")
        case .endpoint: return ("Remote service down", "\(down)/\(total) endpoint(s) unreachable.")
        }
    }

    private func roleEvidence(_ role: MonitoringRole, _ members: [MonitoringPerspectiveMember]) -> MonitoringEvidence {
        let down = members.filter { $0.status == .down }.count
        let degraded = members.filter { $0.status == .degraded }.count
        let healthy = members.filter { $0.status == .healthy }.count
        let status: HealthStatus = down > 0 ? .down : (degraded > 0 ? .degraded : .healthy)
        return MonitoringEvidence(
            role: role,
            total: members.count,
            healthy: healthy,
            degraded: degraded,
            down: down,
            status: status,
            summary: "\(down + degraded)/\(members.count) \(role.displayName.lowercased()) affected"
        )
    }

    private func make(
        _ perspective: MonitoringPerspective,
        verdict: MonitoringVerdict,
        severity: Severity,
        confidence: DiagnosisConfidence,
        affected: [EntityID],
        evidence: [MonitoringEvidence],
        title: String,
        detail: String
    ) -> MonitoringDiagnosis {
        MonitoringDiagnosis(
            perspectiveID: perspective.id,
            verdict: verdict,
            severity: severity,
            confidence: confidence,
            affectedEntityIDs: affected,
            title: title,
            detail: detail,
            evidence: evidence
        )
    }
}

public struct MonitoringPerspectiveCoordinator: Sendable {
    private let engine: TopologyDiagnosisEngine

    public init(engine: TopologyDiagnosisEngine = TopologyDiagnosisEngine()) {
        self.engine = engine
    }

    public func diagnose(_ perspective: MonitoringPerspective) -> MonitoringDiagnosis {
        engine.diagnose(perspective)
    }

    public func legacyNetworkDiagnosis(for perspective: MonitoringPerspective) -> NetworkPerspectiveDiagnosis {
        NetworkPerspectiveDiagnosis(engine.diagnose(perspective))
    }
}

public extension NetworkPerspectiveDiagnosis {
    init(_ diagnosis: MonitoringDiagnosis) {
        let faultTier = diagnosis.verdict.affectedRole.flatMap(NetworkTier.init(monitoringRole:))
        self.init(
            scope: Self.scope(for: diagnosis.verdict.kind, role: diagnosis.verdict.affectedRole),
            verdict: Self.verdict(for: diagnosis.verdict, affected: diagnosis.affectedEntityIDs),
            confidence: NetworkPerspectiveDiagnosis.Confidence(diagnosis.confidence),
            faultTier: faultTier,
            affectedHostIDs: diagnosis.affectedEntityIDs.map(\.rawValue),
            title: diagnosis.title,
            detail: diagnosis.detail,
            tierEvidence: diagnosis.evidence.compactMap(NetworkPerspectiveDiagnosis.TierEvidence.init)
        )
    }

    private static func scope(for kind: MonitoringVerdict.Kind, role: MonitoringRole?) -> Scope {
        switch kind {
        case .noData: return .noData
        case .monitoringStalled: return .monitoringStalled
        case .allReachable: return .allReachable
        case .localNetworkDown: return .localNetwork
        case .accessNetworkDown, .upstreamDown: return .upstream
        case .remoteServiceDown: return .remoteService
        case .partialDegradation:
            guard let role else { return .partialDegradation }
            switch role {
            case .localGateway, .localLink: return .partialDegradation
            case .accessNetwork, .upstreamInternet: return .partialDegradation
            case .remoteService, .endpoint: return .partialDegradation
            }
        }
    }

    private static func verdict(for verdict: MonitoringVerdict, affected: [EntityID]) -> Verdict {
        switch verdict.kind {
        case .noData: return .noData
        case .monitoringStalled: return .monitoringStalled
        case .allReachable: return .allReachable
        case .localNetworkDown: return .localNetworkDown
        case .accessNetworkDown: return .ispPathDown
        case .upstreamDown: return .upstreamDown
        case .remoteServiceDown: return .remoteServiceDown(hostIDs: affected.map(\.rawValue))
        case .partialDegradation:
            return .partialDegradation(tier: NetworkTier(monitoringRole: verdict.affectedRole) ?? .upstream)
        }
    }
}

private extension NetworkPerspectiveDiagnosis.Confidence {
    init(_ confidence: DiagnosisConfidence) {
        switch confidence {
        case .high: self = .high
        case .tentative: self = .tentative
        }
    }
}

private extension NetworkPerspectiveDiagnosis.TierEvidence {
    init?(_ evidence: MonitoringEvidence) {
        guard let tier = NetworkTier(monitoringRole: evidence.role) else { return nil }
        self.init(
            tier: tier,
            total: evidence.total,
            healthy: evidence.healthy,
            degraded: evidence.degraded,
            down: evidence.down,
            status: evidence.status,
            summary: evidence.summary
        )
    }
}

private extension NetworkTier {
    init?(monitoringRole: MonitoringRole?) {
        guard let monitoringRole else { return nil }
        switch monitoringRole {
        case .localGateway, .localLink: self = .localGateway
        case .accessNetwork: self = .ispEdge
        case .upstreamInternet: self = .upstream
        case .remoteService, .endpoint: self = .remoteService
        }
    }
}
