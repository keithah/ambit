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
