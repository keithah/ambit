import Foundation

/// Holds the rich HealthState across polls (the provider is a value type; health is
/// stateful — consecutive-failure counting + transitions).
public actor HealthTracker {
    private var state = HealthState()
    public init() {}
    @discardableResult
    public func ingest(value: Double?, ok: Bool, thresholds: HealthThresholds, at timestamp: Date) -> HealthState {
        state.ingest(value: value, ok: ok, thresholds: thresholds, at: timestamp)
        return state
    }
    public func current() -> HealthState { state }
}

/// One pingscope host = one provider instance. Probes on its own interval; health is the
/// generic HealthState evaluator projected onto the flat Health for the snapshot.
public struct PingProvider: Provider {
    public let id: ProviderID
    public let displayName: String
    public let pollInterval: TimeInterval
    public let typeID: ProviderTypeID = "probe"
    public let integrationID = IntegrationIDs.ping
    public let integrationInstanceID: IntegrationInstanceID
    public let instanceID: ProviderInstanceID

    private let host: PingHostConfig
    private let probe: any PingProbe
    private let tracker = HealthTracker()

    public init(
        host: PingHostConfig,
        integrationInstanceID: IntegrationInstanceID,
        probe: (any PingProbe)? = nil
    ) {
        self.host = host
        self.displayName = host.displayName
        self.pollInterval = host.interval
        self.integrationInstanceID = integrationInstanceID
        let scoped = ProviderInstanceID(rawValue: "\(integrationInstanceID.rawValue)/probe")
        self.instanceID = scoped
        self.id = scoped.rawValue
        self.probe = probe ?? DefaultProbeFactory().makeProbe(for: host)
    }

    public func poll(context: EnvironmentContext) async -> ProviderSnapshot {
        let result = await probe.measure(host)
        let health = await tracker.ingest(
            value: result.latencyMs,
            ok: result.isSuccess,
            thresholds: host.thresholds,
            at: result.timestamp
        )
        var metrics: [Metric] = []
        if let ms = result.latencyMs {
            metrics.append(Metric(id: "latency_ms", label: "Latency", value: .latency(ms: ms), deviceClass: .latency))
        }
        return ProviderSnapshot(
            health: health.legacyHealth,
            metrics: metrics,
            error: result.failureReason.map { "Probe failed: \($0.rawValue)" }
        )
    }

    public func entityDescriptors() -> [EntityDescriptor] {
        let instance = instanceID
        func config(_ key: String, _ name: String) -> EntityDescriptor {
            EntityDescriptor(
                id: EntityProjection.entityID(instance, key), instanceID: instance, name: name,
                kind: .text, category: .config, access: .readWrite
            )
        }
        return [
            EntityDescriptor(
                id: EntityProjection.entityID(instance, "latency_ms"), instanceID: instance, name: "Latency",
                kind: .sensor, deviceClass: .latency, category: .primary, capability: "uplink",
                access: .read, unit: "ms", stateClass: .measurement, metricID: "latency_ms"
            ),
            EntityProjection.healthDescriptor(instanceID: instance),
            config("address", "Address"),
            config("method", "Method"),
            config("port", "Port"),
            config("interval", "Interval"),
            config("timeout", "Timeout"),
            config("degraded_ms", "Degraded Threshold"),
            config("down_after_failures", "Down After Failures")
        ]
    }
}

public extension IntegrationInstanceRecord {
    /// A registry record for a pingscope host (deterministic id from the target).
    static func ping(_ host: PingHostConfig, enabled: Bool = true) -> IntegrationInstanceRecord {
        IntegrationInstanceRecord(
            id: host.integrationInstanceID,
            integrationID: IntegrationIDs.ping,
            displayName: host.displayName,
            enabled: enabled,
            origin: .user,
            config: host.asConfigObject()
        )
    }
}

/// The pingscope integration — the first multi-instance integration. Each enabled host
/// record stands up one PingProvider.
public struct PingIntegration: Integration {
    public let id = IntegrationIDs.ping
    public let displayName = "Ping"
    public let isMultiInstance = true

    private let probeFactory: @Sendable (PingHostConfig) -> any PingProbe

    public init(probeFactory: @escaping @Sendable (PingHostConfig) -> any PingProbe = { DefaultProbeFactory().makeProbe(for: $0) }) {
        self.probeFactory = probeFactory
    }

    public func makeProviders(instance: IntegrationInstanceRecord) -> [any Provider] {
        guard let host = PingHostConfig(configObject: instance.config) else { return [] }
        return [PingProvider(host: host, integrationInstanceID: instance.id, probe: probeFactory(host))]
    }

    public func alertRules(instance: IntegrationInstanceRecord) -> [AlertRule] {
        guard let host = PingHostConfig(configObject: instance.config), host.policy.enabled else { return [] }
        let providerID = "\(instance.id.rawValue)/probe"   // matches PingProvider.instanceID
        // High latency sustained for N consecutive samples (≈ N × interval).
        return [
            .sustained(SustainedAlertRule(
                id: "\(instance.id.rawValue).highLatency",
                providerID: providerID,
                metricID: "latency_ms",
                comparison: .greaterThanOrEqual,
                threshold: host.policy.highLatencyMs,
                duration: Double(host.policy.highLatencyConsecutive) * host.interval,
                title: "\(host.displayName) latency high",
                message: "Latency to \(host.displayName) is elevated.",
                severity: .warning,
                cooldown: host.policy.cooldown,
                notifyOnRecovery: host.policy.notifyOnRecovery,
                recoveryMessage: "Latency to \(host.displayName) recovered."
            ))
        ]
    }
}
