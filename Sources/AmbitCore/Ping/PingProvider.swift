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
    public let commands = [
        CommandDescriptor(
            id: StandardCommandRole.testConnection.rawValue,
            label: "Test Connection",
            standardRole: .testConnection
        )
    ]

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

    public func execute(commandID: String, arguments: CommandArguments, context: EnvironmentContext) async throws {
        guard commandID == StandardCommandRole.testConnection.rawValue else {
            throw JSONRPCClientError.commandFailed("Unsupported Ping command \(commandID).")
        }
        let result = await probe.measure(host)
        guard result.isSuccess else {
            let reason = result.failureReason?.rawValue ?? "unknown"
            throw JSONRPCClientError.commandFailed("Test connection failed: \(reason)")
        }
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
                access: .read, unit: "ms", stateClass: .measurement, metricID: "latency_ms",
                isPrimary: true,
                monitoring: monitoringMetadata()
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

    private func monitoringMetadata() -> MonitoringMetadata {
        let derivedRole = AddressClassifier.derivedRole(for: host.address)
        let explicitRole = host.tier
        return MonitoringMetadata(
            role: explicitRole ?? derivedRole,
            perspectiveID: "ping.default",
            alertKindIDs: ["ping.hostDown"],
            diagnosticSummary: .member,
            address: MonitoredAddress(rawValue: host.address),
            roleAssignment: MonitoringRoleAssignment(
                explicitRole: explicitRole,
                derivedRole: derivedRole,
                source: explicitRole == nil ? .addressClassifier : .explicit
            )
        )
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
    public var configSchema: IntegrationConfigSchema? {
        IntegrationConfigSchema(fields: [
            IntegrationConfigField(id: "name", title: "Name", kind: .text, defaultValue: .string(""), required: true),
            IntegrationConfigField(id: "address", title: "Address", kind: .text, defaultValue: .string(""), required: true),
            IntegrationConfigField(
                id: "method",
                title: "Method",
                kind: .select,
                options: [ProbeMethod.icmp, .tcp, .udp].map { EntityOption(value: $0.rawValue, label: $0.rawValue.uppercased()) },
                defaultValue: .string(ProbeMethod.tcp.rawValue),
                required: true
            ),
            IntegrationConfigField(id: "port", title: "Port", kind: .number, range: ValueRange(min: 1, max: 65_535, step: 1), defaultValue: .number(443)),
            IntegrationConfigField(id: "interval", title: "Interval", kind: .number, range: ValueRange(min: PingHostConfig.minimumTiming, max: 3_600, step: 0.25), defaultValue: .number(2), required: true),
            IntegrationConfigField(id: "timeout", title: "Timeout", kind: .number, range: ValueRange(min: PingHostConfig.minimumTiming, max: 3_600, step: 0.25), defaultValue: .number(2), required: true),
            IntegrationConfigField(id: "degradedAfter", title: "Degraded After", kind: .number, range: ValueRange(min: 1, max: 60_000, step: 1), defaultValue: .number(250), required: true),
            IntegrationConfigField(id: "downAfter", title: "Down After", kind: .number, range: ValueRange(min: 1, max: 100, step: 1), defaultValue: .number(3), required: true),
            IntegrationConfigField(
                id: "diagnosisSensitivity",
                title: "Diagnosis Sensitivity",
                kind: .select,
                options: [
                    EntityOption(value: "conservative", label: "Conservative"),
                    EntityOption(value: "standard", label: "Standard"),
                    EntityOption(value: "aggressive", label: "Aggressive")
                ],
                defaultValue: .string("standard"),
                required: true
            ),
            .monitoringRole()
        ])
    }

    public var presets: [IntegrationPreset] {
        [
            IntegrationPreset(
                id: "defaultGateway",
                title: "Default Gateway",
                systemImage: "network",
                values: [
                    "name": .string("Gateway"),
                    "address": .string(""),
                    "method": .string(ProbeMethod.icmp.rawValue),
                    "interval": .number(2),
                    "timeout": .number(1),
                    "degradedAfter": .number(100),
                    "downAfter": .number(3),
                    "diagnosisSensitivity": .string("standard"),
                    "monitoringRole": .string(MonitoringRole.localGateway.rawValue)
                ]
            ),
            IntegrationPreset(
                id: "cloudflareDNS",
                title: "Cloudflare DNS",
                systemImage: "cloud",
                values: [
                    "name": .string("Cloudflare DNS"),
                    "address": .string("1.1.1.1"),
                    "method": .string(ProbeMethod.tcp.rawValue),
                    "port": .number(443),
                    "interval": .number(2),
                    "timeout": .number(2),
                    "degradedAfter": .number(250),
                    "downAfter": .number(3),
                    "diagnosisSensitivity": .string("standard"),
                    "monitoringRole": .string(MonitoringRole.upstreamInternet.rawValue)
                ]
            ),
            IntegrationPreset(
                id: "googleDNS",
                title: "Google DNS",
                systemImage: "network",
                values: [
                    "name": .string("Google DNS"),
                    "address": .string("8.8.8.8"),
                    "method": .string(ProbeMethod.tcp.rawValue),
                    "port": .number(443),
                    "interval": .number(2),
                    "timeout": .number(2),
                    "degradedAfter": .number(250),
                    "downAfter": .number(3),
                    "diagnosisSensitivity": .string("standard"),
                    "monitoringRole": .string(MonitoringRole.upstreamInternet.rawValue)
                ]
            )
        ]
    }

    private let probeFactory: @Sendable (PingHostConfig) -> any PingProbe

    public init(probeFactory: @escaping @Sendable (PingHostConfig) -> any PingProbe = { DefaultProbeFactory().makeProbe(for: $0) }) {
        self.probeFactory = probeFactory
    }

    public func makeProviders(instance: IntegrationInstanceRecord) -> [any Provider] {
        guard let host = PingHostConfig(configObject: instance.config, displayNameFallback: instance.displayName) else { return [] }
        return [PingProvider(host: host, integrationInstanceID: instance.id, probe: probeFactory(host))]
    }

    public func alertRules(instance: IntegrationInstanceRecord) -> [AlertRule] {
        guard let host = PingHostConfig(configObject: instance.config, displayNameFallback: instance.displayName), host.policy.enabled else { return [] }
        let providerID = "\(instance.id.rawValue)/probe"   // matches PingProvider.instanceID
        let threshold = host.policy.threshold ?? AlertThreshold(comparison: .greaterThanOrEqual, value: 250)
        // High latency sustained for N consecutive samples (≈ N × interval).
        return [
            .sustained(SustainedAlertRule(
                id: "\(instance.id.rawValue).highLatency",
                providerID: providerID,
                metricID: "latency_ms",
                comparison: threshold.comparison,
                threshold: threshold.value,
                duration: Double(host.policy.consecutive) * host.interval,
                title: "\(host.displayName) latency high",
                message: "Latency to \(host.displayName) is elevated.",
                severity: .warning,
                cooldown: host.policy.cooldown,
                notifyOnRecovery: host.policy.notifyOnRecovery,
                recoveryMessage: "Latency to \(host.displayName) recovered."
            ))
        ]
    }

    public func alertKindDeclarations(instance: IntegrationInstanceRecord) -> [AlertKindDeclaration] {
        Self.monitoringAlertDeclarations()
    }

    public static func monitoringAlertDeclarations(networkCooldown: TimeInterval = 300) -> [AlertKindDeclaration] {
        [
            AlertKindDeclaration(
                id: "ping.hostDown",
                titleTemplate: "{hostName} is down",
                messageTemplate: "No response from {hostName}.",
                severity: .critical,
                defaultEnabled: true,
                target: .providerMetric(providerID: "ping", metricID: "latency_ms"),
                trigger: .healthTransition(to: .down),
                recovery: AlertRecoveryDeclaration(
                    titleTemplate: "{hostName} recovered",
                    messageTemplate: "{hostName} is reachable again."
                ),
                cooldown: 60
            ),
            AlertKindDeclaration(
                id: "ping.internetLoss",
                titleTemplate: "Internet problem",
                messageTemplate: "{affectedCount}/{totalCount} monitored hosts are unreachable.",
                severity: .warning,
                defaultEnabled: true,
                target: .entity(DiagnosticSummaryEntity.Owner.ping.entityID),
                trigger: .allMembersFailing(minimumCount: 2, ratio: 1),
                cooldown: networkCooldown
            ),
            AlertKindDeclaration(
                id: "ping.localNetworkDown",
                titleTemplate: "Local network down",
                messageTemplate: "{detail}",
                severity: .critical,
                defaultEnabled: true,
                target: .entity(DiagnosticSummaryEntity.Owner.ping.entityID),
                trigger: .diagnosisVerdict(.localNetworkDown),
                cooldown: networkCooldown
            ),
            AlertKindDeclaration(
                id: "ping.ispPathDown",
                titleTemplate: "ISP path down",
                messageTemplate: "{detail}",
                severity: .critical,
                defaultEnabled: true,
                target: .entity(DiagnosticSummaryEntity.Owner.ping.entityID),
                trigger: .diagnosisVerdict(.accessNetworkDown),
                cooldown: networkCooldown
            ),
            AlertKindDeclaration(
                id: "ping.upstreamDown",
                titleTemplate: "Internet unreachable",
                messageTemplate: "{detail}",
                severity: .critical,
                defaultEnabled: true,
                target: .entity(DiagnosticSummaryEntity.Owner.ping.entityID),
                trigger: .diagnosisVerdict(.upstreamDown),
                cooldown: networkCooldown
            ),
            AlertKindDeclaration(
                id: "ping.remoteServiceDown",
                titleTemplate: "Remote service down",
                messageTemplate: "{detail}",
                severity: .warning,
                defaultEnabled: true,
                target: .entity(DiagnosticSummaryEntity.Owner.ping.entityID),
                trigger: .diagnosisVerdict(.remoteServiceDown),
                cooldown: networkCooldown
            ),
            AlertKindDeclaration(
                id: "ping.pathDegraded",
                titleTemplate: "{roleName} degraded",
                messageTemplate: "{detail}",
                severity: .warning,
                defaultEnabled: true,
                target: .entity(DiagnosticSummaryEntity.Owner.ping.entityID),
                trigger: .diagnosisVerdict(.partialDegradation),
                cooldown: networkCooldown
            )
        ]
    }
}
