import Foundation

// Maps a cross-host NetworkPerspectiveDiagnosis to a generic text/status entity so it renders
// through the statusBanner primitive (no pingscope-specific UI). The diagnosis is integration-
// level, so the id is a stable synthetic summary id (no EngineID). P3/P4 can promote production
// of this entity into an aggregate / the attention engine.
public enum DiagnosisEntity {
    public static let instanceID = ProviderInstanceID(rawValue: "ping.summary")
    public static let entityID = EntityID(rawValue: "ping.summary.diagnosis")

    /// nil when the network is healthy / has no data (banner omitted).
    public static func make(_ diagnosis: NetworkPerspectiveDiagnosis) -> (EntityDescriptor, EntityState)? {
        guard let severity = severity(for: diagnosis.verdict) else { return nil }
        let descriptor = EntityDescriptor(
            id: entityID, instanceID: instanceID, name: diagnosis.title,
            kind: .text, deviceClass: nil, category: .diagnostic, access: .read
        )
        let state = EntityState(id: entityID, value: .text(diagnosis.detail), availability: .online, severity: severity)
        return (descriptor, state)
    }

    // Locked P2 default (catastrophic vs notable); only drives banner tone in P2, re-examined at P4.
    static func severity(for verdict: NetworkPerspectiveDiagnosis.Verdict) -> Severity? {
        switch verdict {
        case .allReachable, .noData: return nil
        case .partialDegradation: return .degraded
        case .localNetworkDown, .ispPathDown, .upstreamDown: return .down
        case .remoteServiceDown: return .alerting
        }
    }
}
