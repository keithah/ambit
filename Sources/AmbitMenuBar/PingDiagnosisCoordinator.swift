import AmbitCore
import Foundation

struct PingDiagnosisResult: Equatable {
    var diagnosis: NetworkPerspectiveDiagnosis
    var monitoringDiagnosis: MonitoringDiagnosis
    var events: [AlertEvent]
}

@MainActor
final class PingDiagnosisCoordinator {
    typealias HistorySamples = (EntityID, Date) async -> [Sample]

    private let monitoringCoordinator = MonitoringPerspectiveCoordinator()
    private let tierClassifier = NetworkTierClassifier()
    private var alertMonitor = PingAlertMonitor()

    func evaluate(
        activeRecords: [IntegrationInstanceRecord],
        snapshot: StatusSnapshot,
        networkStatus: NetworkConnectivityStatus = .connected,
        now: Date,
        range: TimeRange,
        historySamples: @escaping HistorySamples
    ) async -> PingDiagnosisResult {
        let sensitivity = Self.diagnosisSensitivity(from: activeRecords)
        alertMonitor.sensitivity = sensitivity

        var diagnosisHosts: [DiagnosisHost] = []
        var alertHosts: [AlertHost] = []
        var newestSample: Date?
        for record in activeRecords {
            guard let host = PingHostConfig(configObject: record.config) else { continue }
            let providerInstance = ProviderInstanceID(rawValue: "\(record.id.rawValue)/probe")
            let latencyID = EntityID(rawValue: "\(providerInstance.rawValue).latency_ms")
            let samples = await historySamples(latencyID, now.addingTimeInterval(-range.seconds))
            let health = HealthStatus(legacy: snapshot.providers[providerInstance]?.value?.health ?? .unknown)
            let isStale = Staleness.isStale(lastUpdate: samples.last?.timestamp, interval: host.interval, now: now)
            if let last = samples.last?.timestamp, last > (newestSample ?? .distantPast) {
                newestSample = last
            }
            diagnosisHosts.append(DiagnosisHost(id: record.id.rawValue, tier: tierClassifier.tier(for: host), status: health, isStale: isStale))
            alertHosts.append(AlertHost(
                id: record.id.rawValue,
                name: record.displayName,
                status: health,
                notifyOnRecovery: host.policy.notifyOnRecovery,
                cooldown: host.policy.cooldown
            ))
        }

        let perspective = MonitoringPerspective(
            id: "ping.default",
            title: "Ping",
            members: diagnosisHosts.map(Self.monitoringMember),
            linkStatus: networkStatus,
            sensitivity: sensitivity
        )
        var monitoringDiagnosis = monitoringCoordinator.diagnose(perspective)
        var diagnosis = NetworkPerspectiveDiagnosis(monitoringDiagnosis)
        if case .monitoringStalled = diagnosis.verdict {
            let age = Int(now.timeIntervalSince(newestSample ?? now).rounded())
            diagnosis.detail = "Monitoring paused — data is \(age)s old."
            monitoringDiagnosis.detail = diagnosis.detail
        }
        let events = networkStatus == .connected
            ? alertMonitor.evaluate(hosts: alertHosts, diagnosis: diagnosis, now: now)
            : []
        return PingDiagnosisResult(diagnosis: diagnosis, monitoringDiagnosis: monitoringDiagnosis, events: events)
    }

    nonisolated static func diagnosisSensitivity(from records: [IntegrationInstanceRecord]) -> DiagnosisSensitivity {
        let values = records.compactMap { $0.config["diagnosisSensitivity"]?.stringValue }
        if values.contains("aggressive") { return .sensitive }
        if values.contains("standard") { return .balanced }
        if values.contains("conservative") { return .conservative }
        return .balanced
    }

    nonisolated private static func monitoringMember(_ host: DiagnosisHost) -> MonitoringPerspectiveMember {
        MonitoringPerspectiveMember(
            entityID: EntityID(rawValue: host.id),
            instanceID: IntegrationInstanceID(rawValue: host.id),
            displayName: host.id,
            role: monitoringRole(for: host.tier),
            status: host.status,
            isStale: host.isStale,
            consecutiveFailures: host.consecutiveFailures
        )
    }

    nonisolated private static func monitoringRole(for tier: NetworkTier) -> MonitoringRole {
        switch tier {
        case .localGateway: return .localGateway
        case .ispEdge: return .accessNetwork
        case .upstream: return .upstreamInternet
        case .remoteService: return .remoteService
        }
    }
}
