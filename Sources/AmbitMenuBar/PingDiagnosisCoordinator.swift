import AmbitCore
import Foundation

struct PingDiagnosisResult: Equatable {
    var diagnosis: NetworkPerspectiveDiagnosis
    var events: [AlertEvent]
}

@MainActor
final class PingDiagnosisCoordinator {
    typealias HistorySamples = (EntityID, Date) async -> [Sample]

    private let diagnoser = NetworkPerspectiveDiagnoser()
    private let tierClassifier = NetworkTierClassifier()
    private var alertMonitor = PingAlertMonitor()

    func evaluate(
        activeRecords: [IntegrationInstanceRecord],
        snapshot: StatusSnapshot,
        now: Date,
        range: TimeRange,
        historySamples: @escaping HistorySamples
    ) async -> PingDiagnosisResult {
        alertMonitor.sensitivity = Self.diagnosisSensitivity(from: activeRecords)

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

        var diagnosis = diagnoser.diagnose(hosts: diagnosisHosts)
        if case .monitoringStalled = diagnosis.verdict {
            let age = Int(now.timeIntervalSince(newestSample ?? now).rounded())
            diagnosis.detail = "Monitoring paused — data is \(age)s old."
        }
        let events = alertMonitor.evaluate(hosts: alertHosts, diagnosis: diagnosis, now: now)
        return PingDiagnosisResult(diagnosis: diagnosis, events: events)
    }

    nonisolated static func diagnosisSensitivity(from records: [IntegrationInstanceRecord]) -> DiagnosisSensitivity {
        let values = records.compactMap { $0.config["diagnosisSensitivity"]?.stringValue }
        if values.contains("aggressive") { return .sensitive }
        if values.contains("standard") { return .balanced }
        if values.contains("conservative") { return .conservative }
        return .balanced
    }
}
