import Foundation

// Maps a cross-host NetworkPerspectiveDiagnosis to a generic text/status entity so it renders
// through the statusBanner primitive (no pingscope-specific UI). The diagnosis is integration-
// level, so the id is a stable synthetic summary id (no EngineID). P3/P4 can promote production
// of this entity into an aggregate / the attention engine.
public enum DiagnosisEntity {
    public static let instanceID = DiagnosticSummaryEntity.Owner.ping.instanceID
    public static let entityID = DiagnosticSummaryEntity.Owner.ping.entityID

    public static func descriptor(title: String = "Network status") -> EntityDescriptor {
        DiagnosticSummaryEntity.descriptor(owner: .ping, title: title)
    }

    /// nil when the network is healthy / has no data (banner omitted).
    public static func make(_ diagnosis: NetworkPerspectiveDiagnosis) -> (EntityDescriptor, EntityState)? {
        DiagnosticSummaryEntity.make(MonitoringDiagnosis(legacy: diagnosis), owner: .ping)
    }

    // Locked P2 default (catastrophic vs notable); only drives banner tone in P2, re-examined at P4.
    static func severity(for verdict: NetworkPerspectiveDiagnosis.Verdict) -> Severity? {
        DiagnosticSummaryEntity.severity(for: MonitoringVerdict.Kind(legacy: verdict))
    }
}
