import Foundation

public enum DiagnosticSummaryEntity {
    public enum Owner: Equatable, Sendable {
        case ping
        case custom(instanceID: ProviderInstanceID, entityID: EntityID)

        public var instanceID: ProviderInstanceID {
            switch self {
            case .ping: return "ping.summary"
            case .custom(let instanceID, _): return instanceID
            }
        }

        public var entityID: EntityID {
            switch self {
            case .ping: return "ping.summary.diagnosis"
            case .custom(_, let entityID): return entityID
            }
        }
    }

    public static func descriptor(owner: Owner, title: String = "Network status") -> EntityDescriptor {
        EntityDescriptor(
            id: owner.entityID,
            instanceID: owner.instanceID,
            name: title,
            kind: .text,
            deviceClass: nil,
            category: .diagnostic,
            access: .read,
            monitoring: MonitoringMetadata(diagnosticSummary: .owner)
        )
    }

    public static func make(_ diagnosis: MonitoringDiagnosis, owner: Owner) -> (EntityDescriptor, EntityState)? {
        guard let severity = severity(for: diagnosis.verdict.kind) else { return nil }
        let descriptor = descriptor(owner: owner, title: diagnosis.title)
        let state = EntityState(
            id: owner.entityID,
            value: .text(diagnosis.detail),
            availability: .online,
            severity: severity
        )
        return (descriptor, state)
    }

    public static func severity(for verdict: MonitoringVerdict.Kind) -> Severity? {
        switch verdict {
        case .allReachable, .noData:
            return nil
        case .monitoringStalled:
            return .elevated
        case .partialDegradation:
            return .degraded
        case .localNetworkDown, .accessNetworkDown, .upstreamDown:
            return .down
        case .remoteServiceDown:
            return .alerting
        }
    }
}

public extension MonitoringDiagnosis {
    init(
        legacy diagnosis: NetworkPerspectiveDiagnosis,
        perspectiveID: MonitoringPerspectiveID = "ping.default",
        affectedEntityIDs: [EntityID]? = nil
    ) {
        self.init(
            perspectiveID: perspectiveID,
            verdict: MonitoringVerdict(legacy: diagnosis.verdict),
            severity: DiagnosticSummaryEntity.severity(for: MonitoringVerdict.Kind(legacy: diagnosis.verdict)) ?? .normal,
            confidence: DiagnosisConfidence(legacy: diagnosis.confidence),
            affectedEntityIDs: affectedEntityIDs ?? diagnosis.affectedHostIDs.map(EntityID.init(rawValue:)),
            title: diagnosis.title,
            detail: diagnosis.detail,
            evidence: diagnosis.tierEvidence.map(MonitoringEvidence.init)
        )
    }
}

private extension MonitoringVerdict {
    init(legacy verdict: NetworkPerspectiveDiagnosis.Verdict) {
        self.init(kind: Kind(legacy: verdict), affectedRole: MonitoringRole(legacy: verdict))
    }
}

extension MonitoringVerdict.Kind {
    init(legacy verdict: NetworkPerspectiveDiagnosis.Verdict) {
        switch verdict {
        case .noData: self = .noData
        case .monitoringStalled: self = .monitoringStalled
        case .allReachable: self = .allReachable
        case .localNetworkDown: self = .localNetworkDown
        case .ispPathDown: self = .accessNetworkDown
        case .upstreamDown: self = .upstreamDown
        case .remoteServiceDown: self = .remoteServiceDown
        case .partialDegradation: self = .partialDegradation
        }
    }
}

private extension MonitoringRole {
    init?(legacy verdict: NetworkPerspectiveDiagnosis.Verdict) {
        switch verdict {
        case .localNetworkDown:
            self = .localGateway
        case .ispPathDown:
            self = .accessNetwork
        case .upstreamDown:
            self = .upstreamInternet
        case .remoteServiceDown:
            self = .remoteService
        case .partialDegradation(let tier):
            self = MonitoringRole(legacy: tier)
        case .noData, .monitoringStalled, .allReachable:
            return nil
        }
    }

    init(legacy tier: NetworkTier) {
        switch tier {
        case .localGateway: self = .localGateway
        case .ispEdge: self = .accessNetwork
        case .upstream: self = .upstreamInternet
        case .remoteService: self = .remoteService
        }
    }
}

private extension DiagnosisConfidence {
    init(legacy confidence: NetworkPerspectiveDiagnosis.Confidence) {
        switch confidence {
        case .high: self = .high
        case .tentative: self = .tentative
        }
    }
}

private extension MonitoringEvidence {
    init(_ evidence: NetworkPerspectiveDiagnosis.TierEvidence) {
        self.init(
            role: MonitoringRole(legacy: evidence.tier),
            total: evidence.total,
            healthy: evidence.healthy,
            degraded: evidence.degraded,
            down: evidence.down,
            status: evidence.status,
            summary: evidence.summary
        )
    }
}
