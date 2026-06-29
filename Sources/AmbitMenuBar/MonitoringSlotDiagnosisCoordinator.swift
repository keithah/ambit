import AmbitCore
import Foundation

struct MonitoringSlotDiagnosisResult: Equatable {
    var diagnosis: MonitoringDiagnosis
    var events: [AlertEvent]
}

@MainActor
final class MonitoringSlotDiagnosisCoordinator {
    typealias HistorySamples = (EntityID, Date) async -> [Sample]

    private let monitoringCoordinator = MonitoringPerspectiveCoordinator()
    private var alertStateMachine = MonitoringAlertStateMachine(declarations: PingIntegration.monitoringAlertDeclarations())

    func evaluate(
        activeRecords: [IntegrationInstanceRecord],
        descriptors: [ProviderInstanceID: [EntityDescriptor]],
        snapshot: StatusSnapshot,
        networkStatus: NetworkConnectivityStatus = .connected,
        now: Date,
        range: TimeRange,
        historySamples: @escaping HistorySamples
    ) async -> MonitoringSlotDiagnosisResult {
        let sensitivity = Self.diagnosisSensitivity(from: activeRecords)
        alertStateMachine.sensitivity = sensitivity

        let flatDescriptors = descriptors.values.flatMap { $0 }
        let descriptorsByInstance = Dictionary(grouping: flatDescriptors, by: { $0.instanceID.integrationInstanceID })

        var members: [MonitoringPerspectiveMember] = []
        var alertMembers: [MonitoringAlertMember] = []
        var newestSample: Date?

        for record in activeRecords {
            let instanceDescriptors = descriptorsByInstance[record.id] ?? []
            guard let descriptor = Self.monitoringDescriptor(for: record, descriptors: instanceDescriptors) else { continue }
            let providerInstance = descriptor.instanceID
            let samples = await historySamples(descriptor.id, now.addingTimeInterval(-range.seconds))
            let health = HealthStatus(legacy: snapshot.providers[providerInstance]?.value?.health ?? .unknown)
            let interval = Self.interval(from: record.config)
            let isStale = Staleness.isStale(lastUpdate: samples.last?.timestamp, interval: interval, now: now)
            if let last = samples.last?.timestamp, last > (newestSample ?? .distantPast) {
                newestSample = last
            }
            let role = descriptor.monitoring?.role
                ?? descriptor.monitoring?.address.map { AddressClassifier.derivedRole(for: $0.rawValue) }
                ?? record.config["address"]?.stringValue.map(AddressClassifier.derivedRole(for:))
                ?? .endpoint
            members.append(MonitoringPerspectiveMember(
                entityID: descriptor.id,
                instanceID: record.id,
                displayName: record.displayName,
                role: role,
                status: health,
                isStale: isStale,
                consecutiveFailures: health == .down ? 1 : 0
            ))
            let policy = Self.alertPolicy(from: record.config)
            alertMembers.append(MonitoringAlertMember(
                id: record.id.rawValue,
                name: record.displayName,
                status: health,
                target: .entity(descriptor.id),
                notifyOnRecovery: policy.notifyOnRecovery,
                cooldown: policy.cooldown
            ))
        }

        let perspective = MonitoringPerspective(
            id: flatDescriptors.compactMap { $0.monitoring?.perspectiveID }.first ?? "monitoring.default",
            title: "Monitoring",
            members: members,
            linkStatus: networkStatus,
            sensitivity: sensitivity
        )
        var diagnosis = monitoringCoordinator.diagnose(perspective)
        if case .monitoringStalled = diagnosis.verdict.kind {
            let age = Int(now.timeIntervalSince(newestSample ?? now).rounded())
            diagnosis.detail = "Monitoring paused — data is \(age)s old."
        }
        let events = networkStatus == .connected
            ? alertStateMachine.evaluate(members: alertMembers, diagnosis: diagnosis, now: now)
            : []
        return MonitoringSlotDiagnosisResult(diagnosis: diagnosis, events: events)
    }

    nonisolated static func diagnosisSensitivity(from records: [IntegrationInstanceRecord]) -> DiagnosisSensitivity {
        let values = records.compactMap { $0.config["diagnosisSensitivity"]?.stringValue }
        if values.contains("aggressive") { return .sensitive }
        if values.contains("standard") { return .balanced }
        if values.contains("conservative") { return .conservative }
        return .balanced
    }

    nonisolated private static func monitoringDescriptor(
        for record: IntegrationInstanceRecord,
        descriptors: [EntityDescriptor]
    ) -> EntityDescriptor? {
        let monitored = descriptors.filter { $0.monitoring?.diagnosticSummary == .member || $0.monitoring?.role != nil }
        if let primary = monitored.first(where: \.isPrimary) { return primary }
        if let measured = monitored.first(where: { $0.stateClass == .measurement }) { return measured }
        if let any = monitored.first { return any }
        return descriptors.first { $0.instanceID.integrationInstanceID == record.id && $0.isPrimary }
    }

    nonisolated private static func interval(from config: JSONObject) -> TimeInterval {
        config["interval"]?.numberValue ?? 2
    }

    nonisolated private static func alertPolicy(from config: JSONObject) -> EntityAlertPolicy {
        guard let value = config["policy"],
              let data = try? JSONEncoder().encode(value),
              let policy = try? JSONDecoder().decode(EntityAlertPolicy.self, from: data)
        else { return .preset(.balanced) }
        return policy
    }
}
