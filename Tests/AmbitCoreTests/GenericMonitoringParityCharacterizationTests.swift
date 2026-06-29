import XCTest
@testable import AmbitCore
import AmbitUI
@testable import AmbitMenuBar

final class GenericMonitoringParityCharacterizationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let surfaceNow = Date(timeIntervalSince1970: 20_000)

    func testNetworkPerspectiveDiagnoserGoldenMatrix() throws {
        let diagnoser = NetworkPerspectiveDiagnoser()
        var cases: [DiagnosisGoldenCase] = []

        for sensitivity in DiagnosisSensitivity.allCases {
            for networkStatus in NetworkConnectivityStatus.allCases {
                for tier in NetworkTier.allCases {
                    for stale in [false, true] {
                        for scenario in DiagnosisHealthScenario.allCases {
                            let hosts = hostsForDiagnosis(tier: tier, scenario: scenario, stale: stale)
                            let diagnosis = diagnoser.diagnose(hosts: hosts, networkStatus: networkStatus)
                            cases.append(DiagnosisGoldenCase(
                                id: "\(sensitivity.rawValue).\(networkStatus.rawValue).\(tier.rawValue).\(stale ? "stale" : "fresh").\(scenario.rawValue)",
                                sensitivity: sensitivity.rawValue,
                                networkStatus: networkStatus.rawValue,
                                tier: tier.rawValue,
                                stale: stale,
                                scenario: scenario.rawValue,
                                inputHosts: hosts.map(DiagnosisHostSnapshot.init),
                                output: DiagnosisSnapshot(diagnosis)
                            ))
                        }
                    }
                }
            }
        }

        try assertGolden(cases, named: "network_diagnosis_matrix.json")
    }

    func testPingAlertMonitorGoldenEvents() throws {
        let cases = [
            hostDownRecoveryCooldown(),
            noRecoveryWhenDisabled(),
            highConfidenceSpecificNetworkAlerts(),
            tentativeSensitivityMatrix(),
            pathDegradedStreaks(),
            networkCooldownSuppression(),
            internetLossSafetyNet(),
            remoteServiceAdditionalHostsCopy(),
            pathRecoveredOnlyAfterDeliveredNetworkAlert(),
            networkStatusTransitionAlerts(),
            networkChangeEventCopy()
        ].flatMap { $0 }

        try assertGolden(cases, named: "ping_alert_monitor_events.json")
    }

    func testMonitoringAlertStateMachineMatchesPingAlertMonitorGoldenEvents() {
        let cases = [
            hostDownRecoveryCooldownDifferential(),
            noRecoveryWhenDisabledDifferential(),
            highConfidenceSpecificNetworkAlertsDifferential(),
            tentativeSensitivityMatrixDifferential(),
            pathDegradedStreaksDifferential(),
            networkCooldownSuppressionDifferential(),
            internetLossSafetyNetDifferential(),
            remoteServiceAdditionalHostsCopyDifferential(),
            pathRecoveredOnlyAfterDeliveredNetworkAlertDifferential(),
            networkStatusTransitionAlertsDifferential(),
            networkChangeEventCopyDifferential()
        ].flatMap { $0 }

        for alertCase in cases {
            XCTAssertEqual(alertCase.old, alertCase.new, alertCase.id)
        }
    }

    @MainActor
    func testObservablePingSurfaceGoldenScenarios() async throws {
        let coordinator = SlotSurfaceCoordinator()
        let fixtures = pingSurfaceFixtures()

        var allHostsConfig = PresentationConfig.empty
        allHostsConfig.slotOverrides[fixtures.slot.id] = SlotPresentationOverride(showsAllInstances: true)

        var focusedConfig = PresentationConfig.empty
        focusedConfig.slotOverrides[fixtures.slot.id] = SlotPresentationOverride(
            selectedInstanceID: fixtures.records[1].id,
            showsAllInstances: false
        )

        var primaryDownFixtures = fixtures
        primaryDownFixtures.states[fixtures.latencyIDs[0]] = EntityState(
            id: fixtures.latencyIDs[0],
            availability: .unavailable,
            severity: .down
        )
        primaryDownFixtures.samples[fixtures.latencyIDs[0]] = [
            Sample(timestamp: surfaceNow.addingTimeInterval(-4), value: 9, ok: true),
            Sample(timestamp: surfaceNow.addingTimeInterval(-3), value: nil, ok: false, metadata: "connectFailed"),
            Sample(timestamp: surfaceNow.addingTimeInterval(-2), value: nil, ok: false, metadata: "timeout")
        ]

        let scenarios: [(String, PingSurfaceFixtures, NetworkPerspectiveDiagnosis, PresentationConfig)] = [
            ("singleHostDefault", fixtures, diagnosis(.allReachable), .empty),
            ("allHostsCombined", fixtures, diagnosis(.allReachable), allHostsConfig),
            ("focusedHost", fixtures, diagnosis(.allReachable), focusedConfig),
            ("primaryDown", primaryDownFixtures, diagnosis(.allReachable), .empty),
            ("diagnosisBanner", fixtures, diagnosis(.localNetworkDown), .empty),
            ("recovered", fixtures, diagnosis(.allReachable), .empty)
        ]

        var golden: [SurfaceGoldenCase] = []
        for (id, scenarioFixtures, diagnosis, config) in scenarios {
            let surface = await coordinator.buildSurface(
                slot: scenarioFixtures.slot,
                diagnosis: diagnosis,
                allRegistryRecords: scenarioFixtures.records,
                allDescriptors: scenarioFixtures.descriptorsByProvider,
                allStates: scenarioFixtures.states,
                firedAlertEvents: [],
                slotFocus: [:],
                fallbackGraphRange: .m5,
                config: config,
                now: surfaceNow,
                historySamples: { entityID, _ in scenarioFixtures.samples[entityID] ?? [] }
            )
            golden.append(SurfaceGoldenCase(id: id, snapshot: SurfaceSnapshot(surface)))
        }

        try assertGolden(golden, named: "observable_ping_surface.json")
    }

    func testPreMilestoneConfigFixturesAreStableAndDecodable() throws {
        let presentationConfig = preMilestonePresentationConfig()
        let integrationInstances = preMilestoneIntegrationInstances()

        try assertPresentationConfigGolden(presentationConfig, named: "presentationConfig.multihost.json")
        try assertGolden(integrationInstances, named: "integrationInstances.multihost.json")

        let fixtures = fixturesURL()
        let decodedConfig = try JSONDecoder().decode(
            PresentationConfig.self,
            from: Data(contentsOf: fixtures.appendingPathComponent("presentationConfig.multihost.json"))
        )
        let decodedRecords = try JSONDecoder().decode(
            [IntegrationInstanceRecord].self,
            from: Data(contentsOf: fixtures.appendingPathComponent("integrationInstances.multihost.json"))
        )

        XCTAssertEqual(decodedConfig.slots.map(\.id.rawValue), ["ping", "system@local"])
        XCTAssertEqual(decodedConfig.slotOverrides[SlotID(rawValue: "ping")]?.primaryInstanceID, "ping@gateway")
        XCTAssertEqual(decodedConfig.slotOverrides[SlotID(rawValue: "ping")]?.selectedInstanceID, "ping@1.1.1.1:443")
        XCTAssertEqual(decodedConfig.slotOverrides[SlotID(rawValue: "ping")]?.shownItems?.map(\.rawValue), [
            "entity:ping@gateway/probe.latency_ms",
            "history:ping@gateway/probe.latency_ms"
        ])
        XCTAssertEqual(decodedConfig.slotOverrides[SlotID(rawValue: "system@local")]?.hiddenItems, [
            SurfaceItemID(rawValue: "entity:system@local/processes.top_memory")
        ])
        XCTAssertTrue(decodedConfig.entityOverrides.keys.contains("ping@gateway/probe.latency_ms"))
        XCTAssertEqual(decodedRecords.map(\.id.rawValue), [
            "ping@gateway",
            "ping@1.1.1.1:443",
            "ping@127.0.0.1:22",
            "system@local"
        ])
    }
}

private enum DiagnosisHealthScenario: String, CaseIterable {
    case healthySingle
    case degradedSingle
    case downSingle
    case downMixed
    case noDataSingle
}

private struct DiagnosisGoldenCase: Codable, Equatable {
    var id: String
    var sensitivity: String
    var networkStatus: String
    var tier: String
    var stale: Bool
    var scenario: String
    var inputHosts: [DiagnosisHostSnapshot]
    var output: DiagnosisSnapshot
}

private struct DiagnosisHostSnapshot: Codable, Equatable {
    var id: String
    var tier: String
    var status: String
    var consecutiveFailures: Int
    var isStale: Bool

    init(_ host: DiagnosisHost) {
        id = host.id
        tier = host.tier.rawValue
        status = String(describing: host.status)
        consecutiveFailures = host.consecutiveFailures
        isStale = host.isStale
    }
}

private struct DiagnosisSnapshot: Codable, Equatable {
    var scope: String
    var verdict: String
    var confidence: String
    var faultTier: String?
    var affectedHostIDs: [String]
    var title: String
    var detail: String
    var evidence: [TierEvidenceSnapshot]

    init(_ diagnosis: NetworkPerspectiveDiagnosis) {
        scope = diagnosis.scope.rawValue
        verdict = String(describing: diagnosis.verdict)
        confidence = diagnosis.confidence.rawValue
        faultTier = diagnosis.faultTier?.rawValue
        affectedHostIDs = diagnosis.affectedHostIDs
        title = diagnosis.title
        detail = diagnosis.detail
        evidence = diagnosis.tierEvidence.map(TierEvidenceSnapshot.init)
    }
}

private struct TierEvidenceSnapshot: Codable, Equatable {
    var tier: String
    var total: Int
    var healthy: Int
    var degraded: Int
    var down: Int
    var status: String
    var summary: String

    init(_ evidence: NetworkPerspectiveDiagnosis.TierEvidence) {
        tier = evidence.tier.rawValue
        total = evidence.total
        healthy = evidence.healthy
        degraded = evidence.degraded
        down = evidence.down
        status = String(describing: evidence.status)
        summary = evidence.summary
    }
}

private struct AlertGoldenCase: Codable, Equatable {
    var id: String
    var events: [AlertEventSnapshot]
}

private struct AlertDifferentialCase {
    var id: String
    var old: [AlertEventSnapshot]
    var new: [AlertEventSnapshot]
}

private struct AlertEventSnapshot: Codable, Equatable {
    var ruleID: String
    var providerID: String
    var target: String?
    var phase: String
    var title: String
    var message: String
    var severity: String
    var triggeredAt: TimeInterval

    init(_ event: AlertEvent, triggeredAtOverride: TimeInterval? = nil) {
        ruleID = event.ruleID
        providerID = event.providerID
        target = event.target.map(String.init(describing:))
        phase = event.phase.rawValue
        title = event.title
        message = event.message
        severity = String(describing: event.severity)
        triggeredAt = triggeredAtOverride ?? event.triggeredAt.timeIntervalSince1970
    }
}

private struct SurfaceGoldenCase: Codable, Equatable {
    var id: String
    var snapshot: SurfaceSnapshot
}

private struct SurfaceSnapshot: Codable, Equatable {
    var glyphText: String
    var glyphTone: String
    var primaryEntityID: String?
    var selectedInstanceID: String?
    var primaryInstanceID: String?
    var hostOptions: [HostOptionSnapshot]
    var cards: [CardSnapshot]
    var series: [SeriesSnapshot]

    init(_ surface: SlotSurface) {
        glyphText = surface.glyph.primaryText
        glyphTone = surface.glyph.tone.rawValue
        primaryEntityID = surface.primaryEntityID?.rawValue
        selectedInstanceID = surface.selectedInstanceID?.rawValue
        primaryInstanceID = surface.primaryInstanceID?.rawValue
        hostOptions = surface.hostOptions.map(HostOptionSnapshot.init)
        cards = surface.plan.cards.flatMap { CardSnapshot.flatten($0) }
        series = surface.data.series
            .map { SeriesSnapshot(entityID: $0.key, samples: $0.value) }
            .sorted { $0.entityID < $1.entityID }
    }
}

private struct HostOptionSnapshot: Codable, Equatable {
    var id: String
    var label: String
    var subtitle: String?

    init(_ option: InstanceSelectorCard.Option) {
        id = option.id
        label = option.label
        subtitle = option.subtitle
    }
}

private struct CardSnapshot: Codable, Equatable {
    var id: String
    var kind: String
    var role: String?
    var title: String?
    var entities: [String]

    static func flatten(_ card: CardSpec) -> [CardSnapshot] {
        [
            CardSnapshot(
                id: card.id,
                kind: card.kind.rawValue,
                role: String(describing: card.role),
                title: card.title,
                entities: card.entities.map(\.rawValue)
            )
        ] + card.children.flatMap(flatten)
    }
}

private struct SeriesSnapshot: Codable, Equatable {
    var entityID: String
    var sampleCount: Int
    var okCount: Int
    var failedCount: Int
    var latestValue: Double?
    var metadata: [String]
    var failureXPositions: [Double]

    init(entityID: EntityID, samples: [Sample]) {
        self.entityID = entityID.rawValue
        sampleCount = samples.count
        okCount = samples.filter(\.ok).count
        failedCount = samples.filter { !$0.ok || $0.value == nil }.count
        latestValue = samples.last?.value
        metadata = samples.compactMap(\.metadata)
        let geometry = GraphGeometry.series(
            samples: samples,
            in: CGSize(width: 100, height: 40),
            axisMax: 100,
            plotVerticalPadding: 0
        )
        failureXPositions = geometry.failureXPositions.map { Double($0).rounded(toPlaces: 3) }
    }
}

private struct PingSurfaceFixtures {
    var slot: Slot
    var records: [IntegrationInstanceRecord]
    var descriptorsByProvider: [ProviderInstanceID: [EntityDescriptor]]
    var states: [EntityID: EntityState]
    var samples: [EntityID: [Sample]]
    var latencyIDs: [EntityID]
}

private extension GenericMonitoringParityCharacterizationTests {
    func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

    func hostsForDiagnosis(tier: NetworkTier, scenario: DiagnosisHealthScenario, stale: Bool) -> [DiagnosisHost] {
        var hosts = lowerTierHealthyHosts(before: tier)
        let id = "\(tier.rawValue).primary"
        switch scenario {
        case .healthySingle:
            hosts.append(DiagnosisHost(id: id, tier: tier, status: .healthy, consecutiveFailures: 0, isStale: stale))
        case .degradedSingle:
            hosts.append(DiagnosisHost(id: id, tier: tier, status: .degraded, consecutiveFailures: 1, isStale: stale))
        case .downSingle:
            hosts.append(DiagnosisHost(id: id, tier: tier, status: .down, consecutiveFailures: 3, isStale: stale))
        case .downMixed:
            hosts.append(DiagnosisHost(id: id, tier: tier, status: .down, consecutiveFailures: 3, isStale: stale))
            hosts.append(DiagnosisHost(id: "\(tier.rawValue).peer", tier: tier, status: .healthy, consecutiveFailures: 0, isStale: stale))
        case .noDataSingle:
            hosts.append(DiagnosisHost(id: id, tier: tier, status: .noData, consecutiveFailures: 0, isStale: stale))
        }
        return hosts
    }

    func lowerTierHealthyHosts(before tier: NetworkTier) -> [DiagnosisHost] {
        NetworkTier.allCases
            .filter { $0.depth < tier.depth }
            .map { DiagnosisHost(id: "\($0.rawValue).healthy", tier: $0, status: .healthy) }
    }

    func healthyDiagnosis() -> NetworkPerspectiveDiagnosis {
        NetworkPerspectiveDiagnosis(
            scope: .allReachable,
            verdict: .allReachable,
            confidence: .high,
            faultTier: nil,
            affectedHostIDs: [],
            title: "All reachable",
            detail: "2/2 monitored hosts healthy.",
            tierEvidence: []
        )
    }

    func diagnosis(_ verdict: NetworkPerspectiveDiagnosis.Verdict) -> NetworkPerspectiveDiagnosis {
        let scope: NetworkPerspectiveDiagnosis.Scope
        let title: String
        let detail: String
        let faultTier: NetworkTier?
        switch verdict {
        case .allReachable:
            scope = .allReachable
            title = "All reachable"
            detail = "2/2 monitored hosts healthy."
            faultTier = nil
        case .localNetworkDown:
            scope = .localNetwork
            title = "Local network down"
            detail = "1/1 gateway host(s) unreachable."
            faultTier = .localGateway
        default:
            scope = .monitoringStalled
            title = "Monitoring paused"
            detail = "Monitoring paused - data is stale."
            faultTier = nil
        }
        return NetworkPerspectiveDiagnosis(
            scope: scope,
            verdict: verdict,
            confidence: .high,
            faultTier: faultTier,
            affectedHostIDs: [],
            title: title,
            detail: detail,
            tierEvidence: []
        )
    }

    func alertHost(_ id: String = "cf", name: String = "Cloudflare", status: HealthStatus, recovery: Bool = true, cooldown: TimeInterval = 60) -> AlertHost {
        AlertHost(id: id, name: name, status: status, notifyOnRecovery: recovery, cooldown: cooldown)
    }

    func alertDiagnosis(
        _ verdict: NetworkPerspectiveDiagnosis.Verdict,
        _ confidence: NetworkPerspectiveDiagnosis.Confidence,
        tier: NetworkTier = .upstream,
        detail: String = "d"
    ) -> NetworkPerspectiveDiagnosis {
        NetworkPerspectiveDiagnosis(
            scope: .upstream,
            verdict: verdict,
            confidence: confidence,
            faultTier: tier,
            affectedHostIDs: [],
            title: "t",
            detail: detail,
            tierEvidence: []
        )
    }

    func alertCase(_ id: String, _ events: [AlertEvent?]) -> AlertGoldenCase {
        AlertGoldenCase(id: id, events: events.compactMap { $0 }.map { AlertEventSnapshot($0) })
    }

    func alertCase(_ id: String, _ events: [AlertEvent]) -> AlertGoldenCase {
        AlertGoldenCase(id: id, events: events.map { AlertEventSnapshot($0) })
    }

    func alertCaseStableTime(_ id: String, _ events: [AlertEvent?]) -> AlertGoldenCase {
        AlertGoldenCase(id: id, events: events.compactMap { event in
            event.map { AlertEventSnapshot($0, triggeredAtOverride: 0) }
        })
    }

    func hostDownRecoveryCooldown() -> [AlertGoldenCase] {
        var monitor = PingAlertMonitor()
        _ = monitor.evaluate(hosts: [alertHost(status: .healthy)], diagnosis: healthyDiagnosis(), now: at(0))
        let down = monitor.evaluate(hosts: [alertHost(status: .down)], diagnosis: healthyDiagnosis(), now: at(1))
        let stillDown = monitor.evaluate(hosts: [alertHost(status: .down)], diagnosis: healthyDiagnosis(), now: at(2))
        let recovered = monitor.evaluate(hosts: [alertHost(status: .healthy)], diagnosis: healthyDiagnosis(), now: at(70))
        return [
            alertCase("hostDownRecovery.down", down),
            alertCase("hostDownRecovery.stillDown", stillDown),
            alertCase("hostDownRecovery.recovered", recovered)
        ]
    }

    func noRecoveryWhenDisabled() -> [AlertGoldenCase] {
        var monitor = PingAlertMonitor()
        _ = monitor.evaluate(hosts: [alertHost(status: .down, recovery: false)], diagnosis: healthyDiagnosis(), now: at(0))
        return [alertCase("noRecoveryWhenDisabled", monitor.evaluate(hosts: [alertHost(status: .healthy, recovery: false)], diagnosis: healthyDiagnosis(), now: at(5)))]
    }

    func highConfidenceSpecificNetworkAlerts() -> [AlertGoldenCase] {
        [
            (.localNetworkDown, "localNetworkDown"),
            (.ispPathDown, "ispPathDown"),
            (.upstreamDown, "upstreamDown"),
            (.remoteServiceDown(hostIDs: ["cf"]), "remoteServiceDown")
        ].map { verdict, id in
            var monitor = PingAlertMonitor(sensitivity: .balanced)
            return alertCase("highConfidence.\(id)", monitor.evaluate(hosts: [], diagnosis: alertDiagnosis(verdict, .high), now: at(0)))
        }
    }

    func tentativeSensitivityMatrix() -> [AlertGoldenCase] {
        DiagnosisSensitivity.allCases.map { sensitivity in
            var monitor = PingAlertMonitor(sensitivity: sensitivity)
            return alertCase(
                "tentative.\(sensitivity.rawValue)",
                monitor.evaluate(hosts: [], diagnosis: alertDiagnosis(.upstreamDown, .tentative), now: at(0))
            )
        }
    }

    func pathDegradedStreaks() -> [AlertGoldenCase] {
        DiagnosisSensitivity.allCases.flatMap { sensitivity in
            var monitor = PingAlertMonitor(sensitivity: sensitivity, pathDegradedConsecutive: 3)
            let diagnosis = alertDiagnosis(.partialDegradation(tier: .upstream), .tentative)
            return [
                alertCase("pathDegraded.\(sensitivity.rawValue).first", monitor.evaluate(hosts: [], diagnosis: diagnosis, now: at(0))),
                alertCase("pathDegraded.\(sensitivity.rawValue).second", monitor.evaluate(hosts: [], diagnosis: diagnosis, now: at(1))),
                alertCase("pathDegraded.\(sensitivity.rawValue).third", monitor.evaluate(hosts: [], diagnosis: diagnosis, now: at(2)))
            ]
        }
    }

    func networkCooldownSuppression() -> [AlertGoldenCase] {
        var monitor = PingAlertMonitor(sensitivity: .balanced, networkCooldown: 300)
        let first = monitor.evaluate(hosts: [], diagnosis: alertDiagnosis(.upstreamDown, .high), now: at(0))
        let suppressed = monitor.evaluate(hosts: [], diagnosis: alertDiagnosis(.upstreamDown, .high), now: at(30))
        return [
            alertCase("networkCooldown.first", first),
            alertCase("networkCooldown.suppressed", suppressed)
        ]
    }

    func internetLossSafetyNet() -> [AlertGoldenCase] {
        var monitor = PingAlertMonitor(sensitivity: .conservative, networkCooldown: 300)
        let events = monitor.evaluate(
            hosts: [
                alertHost(status: .down),
                alertHost("gw", name: "Gateway", status: .down)
            ],
            diagnosis: healthyDiagnosis(),
            now: at(0)
        )
        return [alertCase("internetLossSafetyNet", events)]
    }

    func remoteServiceAdditionalHostsCopy() -> [AlertGoldenCase] {
        var monitor = PingAlertMonitor(sensitivity: .balanced, networkCooldown: 300)
        let hosts = [
            alertHost("cf", name: "Cloudflare DNS", status: .degraded),
            alertHost("gg", name: "Google DNS", status: .degraded),
            alertHost("svc", name: "Service API", status: .degraded)
        ]
        let diagnosis = NetworkPerspectiveDiagnosis(
            scope: .remoteService,
            verdict: .remoteServiceDown(hostIDs: ["cf", "gg", "svc"]),
            confidence: .high,
            faultTier: .remoteService,
            affectedHostIDs: ["cf", "gg", "svc"],
            title: "Remote service down",
            detail: "3/3 remote host(s) unreachable.",
            tierEvidence: []
        )
        return [alertCase("remoteServiceAdditionalHostsCopy", monitor.evaluate(hosts: hosts, diagnosis: diagnosis, now: at(0)))]
    }

    func pathRecoveredOnlyAfterDeliveredNetworkAlert() -> [AlertGoldenCase] {
        var monitor = PingAlertMonitor(sensitivity: .balanced, networkCooldown: 300)
        let noPrior = monitor.evaluate(hosts: [], diagnosis: healthyDiagnosis(), now: at(0))
        _ = monitor.evaluate(hosts: [], diagnosis: alertDiagnosis(.upstreamDown, .high), now: at(10))
        let recovered = monitor.evaluate(hosts: [], diagnosis: healthyDiagnosis(), now: at(20))
        let repeated = monitor.evaluate(hosts: [], diagnosis: healthyDiagnosis(), now: at(30))
        return [
            alertCase("pathRecovered.noPrior", noPrior),
            alertCase("pathRecovered.afterDelivered", recovered),
            alertCase("pathRecovered.repeated", repeated)
        ]
    }

    func networkStatusTransitionAlerts() -> [AlertGoldenCase] {
        NetworkConnectivityStatus.allCases.flatMap { status in
            guard status != .connected else { return [AlertGoldenCase]() }
            var monitor = NetworkStatusAlertMonitor(cooldown: 300)
            let down = monitor.evaluate(previous: .connected, current: status, now: at(0))
            let repeated = monitor.evaluate(previous: status, current: status, now: at(10))
            let recovered = monitor.evaluate(previous: status, current: .connected, now: at(20))
            return [
                alertCase("networkStatus.\(status.rawValue).down", [down]),
                alertCase("networkStatus.\(status.rawValue).repeated", [repeated]),
                alertCase("networkStatus.\(status.rawValue).recovered", [recovered])
            ]
        }
    }

    func networkChangeEventCopy() -> [AlertGoldenCase] {
        [
            alertCaseStableTime("networkChange.gatewayChanged", [
                StatusViewModel.networkChangeEvent(previousGateway: "192.168.101.1", currentGateway: "192.168.8.1")
            ]),
            alertCaseStableTime("networkChange.unchanged", [
                StatusViewModel.networkChangeEvent(previousGateway: "192.168.8.1", currentGateway: "192.168.8.1")
            ])
        ]
    }

    func diffCase(_ id: String, old: [AlertEvent], new: [AlertEvent]) -> AlertDifferentialCase {
        AlertDifferentialCase(
            id: id,
            old: old.map { AlertEventSnapshot($0) },
            new: new.map { AlertEventSnapshot($0) }
        )
    }

    func monitoringMachine(
        sensitivity: DiagnosisSensitivity = .balanced,
        networkCooldown: TimeInterval = 300,
        pathDegradedConsecutive: Int = 3
    ) -> MonitoringAlertStateMachine {
        MonitoringAlertStateMachine(
            declarations: PingIntegration.monitoringAlertDeclarations(networkCooldown: networkCooldown),
            sensitivity: sensitivity,
            networkCooldown: networkCooldown,
            pathDegradedConsecutive: pathDegradedConsecutive
        )
    }

    func alertMembers(_ hosts: [AlertHost]) -> [MonitoringAlertMember] {
        hosts.map {
            MonitoringAlertMember(
                id: $0.id,
                name: $0.name,
                status: $0.status,
                target: .entity(EntityID(rawValue: "\($0.id)/probe.latency_ms")),
                notifyOnRecovery: $0.notifyOnRecovery,
                cooldown: $0.cooldown
            )
        }
    }

    func monitoringDiagnosis(_ diagnosis: NetworkPerspectiveDiagnosis) -> MonitoringDiagnosis {
        MonitoringDiagnosis(legacy: diagnosis)
    }

    func hostDownRecoveryCooldownDifferential() -> [AlertDifferentialCase] {
        var old = PingAlertMonitor()
        var new = monitoringMachine()
        let healthy = [alertHost(status: .healthy)]
        _ = old.evaluate(hosts: healthy, diagnosis: healthyDiagnosis(), now: at(0))
        _ = new.evaluate(members: alertMembers(healthy), diagnosis: monitoringDiagnosis(healthyDiagnosis()), now: at(0))
        let downHosts = [alertHost(status: .down)]
        let down = diffCase(
            "hostDownRecovery.down",
            old: old.evaluate(hosts: downHosts, diagnosis: healthyDiagnosis(), now: at(1)),
            new: new.evaluate(members: alertMembers(downHosts), diagnosis: monitoringDiagnosis(healthyDiagnosis()), now: at(1))
        )
        let stillDown = diffCase(
            "hostDownRecovery.stillDown",
            old: old.evaluate(hosts: downHosts, diagnosis: healthyDiagnosis(), now: at(2)),
            new: new.evaluate(members: alertMembers(downHosts), diagnosis: monitoringDiagnosis(healthyDiagnosis()), now: at(2))
        )
        let recoveredHosts = [alertHost(status: .healthy)]
        let recovered = diffCase(
            "hostDownRecovery.recovered",
            old: old.evaluate(hosts: recoveredHosts, diagnosis: healthyDiagnosis(), now: at(70)),
            new: new.evaluate(members: alertMembers(recoveredHosts), diagnosis: monitoringDiagnosis(healthyDiagnosis()), now: at(70))
        )
        return [down, stillDown, recovered]
    }

    func noRecoveryWhenDisabledDifferential() -> [AlertDifferentialCase] {
        var old = PingAlertMonitor()
        var new = monitoringMachine()
        let down = [alertHost(status: .down, recovery: false)]
        _ = old.evaluate(hosts: down, diagnosis: healthyDiagnosis(), now: at(0))
        _ = new.evaluate(members: alertMembers(down), diagnosis: monitoringDiagnosis(healthyDiagnosis()), now: at(0))
        let healthy = [alertHost(status: .healthy, recovery: false)]
        return [
            diffCase(
                "noRecoveryWhenDisabled",
                old: old.evaluate(hosts: healthy, diagnosis: healthyDiagnosis(), now: at(5)),
                new: new.evaluate(members: alertMembers(healthy), diagnosis: monitoringDiagnosis(healthyDiagnosis()), now: at(5))
            )
        ]
    }

    func highConfidenceSpecificNetworkAlertsDifferential() -> [AlertDifferentialCase] {
        [
            (.localNetworkDown, "localNetworkDown"),
            (.ispPathDown, "ispPathDown"),
            (.upstreamDown, "upstreamDown"),
            (.remoteServiceDown(hostIDs: ["cf"]), "remoteServiceDown")
        ].map { verdict, id in
            var old = PingAlertMonitor(sensitivity: .balanced)
            var new = monitoringMachine(sensitivity: .balanced)
            let diagnosis = alertDiagnosis(verdict, .high)
            return diffCase(
                "highConfidence.\(id)",
                old: old.evaluate(hosts: [], diagnosis: diagnosis, now: at(0)),
                new: new.evaluate(members: [], diagnosis: monitoringDiagnosis(diagnosis), now: at(0))
            )
        }
    }

    func tentativeSensitivityMatrixDifferential() -> [AlertDifferentialCase] {
        DiagnosisSensitivity.allCases.map { sensitivity in
            var old = PingAlertMonitor(sensitivity: sensitivity)
            var new = monitoringMachine(sensitivity: sensitivity)
            let diagnosis = alertDiagnosis(.upstreamDown, .tentative)
            return diffCase(
                "tentative.\(sensitivity.rawValue)",
                old: old.evaluate(hosts: [], diagnosis: diagnosis, now: at(0)),
                new: new.evaluate(members: [], diagnosis: monitoringDiagnosis(diagnosis), now: at(0))
            )
        }
    }

    func pathDegradedStreaksDifferential() -> [AlertDifferentialCase] {
        DiagnosisSensitivity.allCases.flatMap { sensitivity in
            var old = PingAlertMonitor(sensitivity: sensitivity, pathDegradedConsecutive: 3)
            var new = monitoringMachine(sensitivity: sensitivity, pathDegradedConsecutive: 3)
            let diagnosis = alertDiagnosis(.partialDegradation(tier: .upstream), .tentative)
            return [
                diffCase("pathDegraded.\(sensitivity.rawValue).first",
                         old: old.evaluate(hosts: [], diagnosis: diagnosis, now: at(0)),
                         new: new.evaluate(members: [], diagnosis: monitoringDiagnosis(diagnosis), now: at(0))),
                diffCase("pathDegraded.\(sensitivity.rawValue).second",
                         old: old.evaluate(hosts: [], diagnosis: diagnosis, now: at(1)),
                         new: new.evaluate(members: [], diagnosis: monitoringDiagnosis(diagnosis), now: at(1))),
                diffCase("pathDegraded.\(sensitivity.rawValue).third",
                         old: old.evaluate(hosts: [], diagnosis: diagnosis, now: at(2)),
                         new: new.evaluate(members: [], diagnosis: monitoringDiagnosis(diagnosis), now: at(2)))
            ]
        }
    }

    func networkCooldownSuppressionDifferential() -> [AlertDifferentialCase] {
        var old = PingAlertMonitor(sensitivity: .balanced, networkCooldown: 300)
        var new = monitoringMachine(sensitivity: .balanced, networkCooldown: 300)
        let diagnosis = alertDiagnosis(.upstreamDown, .high)
        return [
            diffCase("networkCooldown.first",
                     old: old.evaluate(hosts: [], diagnosis: diagnosis, now: at(0)),
                     new: new.evaluate(members: [], diagnosis: monitoringDiagnosis(diagnosis), now: at(0))),
            diffCase("networkCooldown.suppressed",
                     old: old.evaluate(hosts: [], diagnosis: diagnosis, now: at(30)),
                     new: new.evaluate(members: [], diagnosis: monitoringDiagnosis(diagnosis), now: at(30)))
        ]
    }

    func internetLossSafetyNetDifferential() -> [AlertDifferentialCase] {
        var old = PingAlertMonitor(sensitivity: .conservative, networkCooldown: 300)
        var new = monitoringMachine(sensitivity: .conservative, networkCooldown: 300)
        let hosts = [
            alertHost(status: .down),
            alertHost("gw", name: "Gateway", status: .down)
        ]
        return [
            diffCase("internetLossSafetyNet",
                     old: old.evaluate(hosts: hosts, diagnosis: healthyDiagnosis(), now: at(0)),
                     new: new.evaluate(members: alertMembers(hosts), diagnosis: monitoringDiagnosis(healthyDiagnosis()), now: at(0)))
        ]
    }

    func remoteServiceAdditionalHostsCopyDifferential() -> [AlertDifferentialCase] {
        var old = PingAlertMonitor(sensitivity: .balanced, networkCooldown: 300)
        var new = monitoringMachine(sensitivity: .balanced, networkCooldown: 300)
        let hosts = [
            alertHost("cf", name: "Cloudflare DNS", status: .degraded),
            alertHost("gg", name: "Google DNS", status: .degraded),
            alertHost("svc", name: "Service API", status: .degraded)
        ]
        let diagnosis = NetworkPerspectiveDiagnosis(
            scope: .remoteService,
            verdict: .remoteServiceDown(hostIDs: ["cf", "gg", "svc"]),
            confidence: .high,
            faultTier: .remoteService,
            affectedHostIDs: ["cf", "gg", "svc"],
            title: "Remote service down",
            detail: "3/3 remote host(s) unreachable.",
            tierEvidence: []
        )
        return [
            diffCase("remoteServiceAdditionalHostsCopy",
                     old: old.evaluate(hosts: hosts, diagnosis: diagnosis, now: at(0)),
                     new: new.evaluate(members: alertMembers(hosts), diagnosis: monitoringDiagnosis(diagnosis), now: at(0)))
        ]
    }

    func pathRecoveredOnlyAfterDeliveredNetworkAlertDifferential() -> [AlertDifferentialCase] {
        var old = PingAlertMonitor(sensitivity: .balanced, networkCooldown: 300)
        var new = monitoringMachine(sensitivity: .balanced, networkCooldown: 300)
        let noPrior = diffCase("pathRecovered.noPrior",
                               old: old.evaluate(hosts: [], diagnosis: healthyDiagnosis(), now: at(0)),
                               new: new.evaluate(members: [], diagnosis: monitoringDiagnosis(healthyDiagnosis()), now: at(0)))
        _ = old.evaluate(hosts: [], diagnosis: alertDiagnosis(.upstreamDown, .high), now: at(10))
        _ = new.evaluate(members: [], diagnosis: monitoringDiagnosis(alertDiagnosis(.upstreamDown, .high)), now: at(10))
        let recovered = diffCase("pathRecovered.afterDelivered",
                                 old: old.evaluate(hosts: [], diagnosis: healthyDiagnosis(), now: at(20)),
                                 new: new.evaluate(members: [], diagnosis: monitoringDiagnosis(healthyDiagnosis()), now: at(20)))
        let repeated = diffCase("pathRecovered.repeated",
                                old: old.evaluate(hosts: [], diagnosis: healthyDiagnosis(), now: at(30)),
                                new: new.evaluate(members: [], diagnosis: monitoringDiagnosis(healthyDiagnosis()), now: at(30)))
        return [noPrior, recovered, repeated]
    }

    func networkStatusTransitionAlertsDifferential() -> [AlertDifferentialCase] {
        NetworkConnectivityStatus.allCases.flatMap { status in
            guard status != .connected else { return [AlertDifferentialCase]() }
            var old = NetworkStatusAlertMonitor(cooldown: 300)
            var new = MonitoringAlertStateMachine(networkAwarenessConfig: NetworkAwarenessConfig(cooldown: 300))
            let down = diffCase("networkStatus.\(status.rawValue).down",
                                old: [old.evaluate(previous: .connected, current: status, now: at(0))].compactMap { $0 },
                                new: [new.evaluateNetworkStatus(previous: .connected, current: status, now: at(0))].compactMap { $0 })
            let repeated = diffCase("networkStatus.\(status.rawValue).repeated",
                                    old: [old.evaluate(previous: status, current: status, now: at(10))].compactMap { $0 },
                                    new: [new.evaluateNetworkStatus(previous: status, current: status, now: at(10))].compactMap { $0 })
            let recovered = diffCase("networkStatus.\(status.rawValue).recovered",
                                     old: [old.evaluate(previous: status, current: .connected, now: at(20))].compactMap { $0 },
                                     new: [new.evaluateNetworkStatus(previous: status, current: .connected, now: at(20))].compactMap { $0 })
            return [down, repeated, recovered]
        }
    }

    func networkChangeEventCopyDifferential() -> [AlertDifferentialCase] {
        let oldChanged = StatusViewModel.networkChangeEvent(previousGateway: "192.168.101.1", currentGateway: "192.168.8.1", now: at(0))
        let oldUnchanged = StatusViewModel.networkChangeEvent(previousGateway: "192.168.8.1", currentGateway: "192.168.8.1", now: at(0))
        let machine = MonitoringAlertStateMachine()
        let newChanged = machine.networkChangeEvent(
            MonitoringNetworkChange(previousGateway: "192.168.101.1", currentGateway: "192.168.8.1"),
            now: at(0)
        )
        let newUnchanged = machine.networkChangeEvent(
            MonitoringNetworkChange(previousGateway: "192.168.8.1", currentGateway: "192.168.8.1"),
            now: at(0)
        )
        return [
            diffCase("networkChange.gatewayChanged", old: [oldChanged].compactMap { $0 }, new: [newChanged].compactMap { $0 }),
            diffCase("networkChange.unchanged", old: [oldUnchanged].compactMap { $0 }, new: [newUnchanged].compactMap { $0 })
        ]
    }

    func pingSurfaceFixtures() -> PingSurfaceFixtures {
        let hosts = [
            PingHostConfig(displayName: "Gateway", address: "192.168.8.1", method: .icmp),
            PingHostConfig(displayName: "Cloudflare DNS", address: "1.1.1.1", method: .tcp, port: 443),
            PingHostConfig(displayName: "Local", address: "127.0.0.1", method: .tcp, port: 22)
        ]
        let records = hosts.map { IntegrationInstanceRecord.ping($0) }
        var descriptorsByProvider: [ProviderInstanceID: [EntityDescriptor]] = [:]
        var states: [EntityID: EntityState] = [:]
        var samples: [EntityID: [Sample]] = [:]
        var latencyIDs: [EntityID] = []
        for (index, record) in records.enumerated() {
            let provider = ProviderInstanceID(rawValue: "\(record.id.rawValue)/probe")
            let latencyID = EntityID(rawValue: "\(provider.rawValue).latency_ms")
            latencyIDs.append(latencyID)
            descriptorsByProvider[provider] = [
                EntityDescriptor(
                    id: latencyID,
                    instanceID: provider,
                    name: record.displayName,
                    kind: .sensor,
                    deviceClass: .latency,
                    category: .primary,
                    capability: "network.latency",
                    unit: "ms",
                    stateClass: .measurement,
                    graphStyle: .sparkline,
                    isPrimary: index == 0,
                    priority: index == 0 ? 10 : 0
                )
            ]
            let value = [3.0, 24.0, 0.0][index]
            states[latencyID] = EntityState(
                id: latencyID,
                value: index == 2 ? nil : .number(value),
                availability: index == 2 ? .unavailable : .online,
                severity: index == 2 ? .down : .normal
            )
            samples[latencyID] = [
                Sample(timestamp: surfaceNow.addingTimeInterval(-4), value: value + 1, ok: index != 2),
                Sample(timestamp: surfaceNow.addingTimeInterval(-3), value: index == 2 ? nil : value, ok: index != 2, metadata: index == 2 ? "connectionRefused" : nil),
                Sample(timestamp: surfaceNow.addingTimeInterval(-2), value: index == 2 ? nil : value + 2, ok: index != 2, metadata: index == 2 ? "timeout" : nil)
            ]
        }
        return PingSurfaceFixtures(
            slot: Slot(id: "ping", title: "Ping", selection: .integrationType(IntegrationIDs.ping)),
            records: records,
            descriptorsByProvider: descriptorsByProvider,
            states: states,
            samples: samples,
            latencyIDs: latencyIDs
        )
    }

    func preMilestonePresentationConfig() -> PresentationConfig {
        let pingSlot = Slot(id: "ping", title: "Ping", selection: .integrationType(IntegrationIDs.ping), barReadout: .dynamic)
        let systemSlot = Slot(id: "system@local", title: "System", selection: .integration(IntegrationInstanceIDs.systemLocal), barReadout: .dynamic)
        var config = PresentationConfig.empty
        config.slots = [pingSlot, systemSlot]
        config.entityOverrides["ping@gateway/probe.latency_ms"] = EntityPresentationOverride(
            visibility: .always,
            pinned: true,
            graphRange: .m5,
            enabled: true
        )
        config.entityOverrides["ping@1.1.1.1:443/probe.latency_ms"] = EntityPresentationOverride(
            visibility: .auto,
            pinned: false,
            graphRange: .m5,
            enabled: true
        )
        config.slotOverrides[pingSlot.id] = SlotPresentationOverride(
            shownItems: [
                SurfaceItemID(rawValue: "entity:ping@gateway/probe.latency_ms"),
                SurfaceItemID(rawValue: "history:ping@gateway/probe.latency_ms")
            ],
            hiddenItems: [
                SurfaceItemID(rawValue: "entity:ping@127.0.0.1:22/probe.latency_ms")
            ],
            tableRowLimit: 8,
            selectedInstanceID: "ping@1.1.1.1:443",
            primaryInstanceID: "ping@gateway",
            showsAllInstances: false
        )
        config.slotOverrides[systemSlot.id] = SlotPresentationOverride(
            hiddenItems: [SurfaceItemID(rawValue: "entity:system@local/processes.top_memory")],
            tableRowLimit: 5
        )
        return config
    }

    func preMilestoneIntegrationInstances() -> [IntegrationInstanceRecord] {
        [
            IntegrationInstanceRecord(
                id: "ping@gateway",
                integrationID: IntegrationIDs.ping,
                displayName: "Gateway",
                enabled: true,
                origin: .user,
                config: PingHostConfig(displayName: "Gateway", address: "192.168.8.1", method: .icmp).asConfigObject()
            ),
            IntegrationInstanceRecord.ping(PingHostConfig(displayName: "Cloudflare DNS", address: "1.1.1.1", method: .tcp, port: 443)),
            IntegrationInstanceRecord.ping(PingHostConfig(displayName: "Local", address: "127.0.0.1", method: .tcp, port: 22)),
            IntegrationInstanceRecord(
                id: IntegrationInstanceIDs.systemLocal,
                integrationID: IntegrationIDs.system,
                displayName: "System",
                enabled: true,
                origin: .builtIn,
                config: [:]
            )
        ]
    }
}

private extension GenericMonitoringParityCharacterizationTests {
    func assertGolden<T: Encodable>(_ value: T, named name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try goldenData(value)
        let url = fixturesURL().appendingPathComponent(name)
        if ProcessInfo.processInfo.environment["AMBIT_RECORD_GOLDENS"] == "1" {
            try FileManager.default.createDirectory(at: fixturesURL(), withIntermediateDirectories: true)
            try data.write(to: url)
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Missing golden fixture \(url.path). Run AMBIT_RECORD_GOLDENS=1 swift test --filter GenericMonitoringParityCharacterizationTests to create it.", file: file, line: line)
            return
        }
        let expected = try Data(contentsOf: url)
        XCTAssertEqual(String(data: data, encoding: .utf8), String(data: expected, encoding: .utf8), file: file, line: line)
    }

    func assertPresentationConfigGolden(_ value: PresentationConfig, named name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try goldenData(value)
        let url = fixturesURL().appendingPathComponent(name)
        if ProcessInfo.processInfo.environment["AMBIT_RECORD_GOLDENS"] == "1" {
            try FileManager.default.createDirectory(at: fixturesURL(), withIntermediateDirectories: true)
            try data.write(to: url)
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Missing golden fixture \(url.path). Run AMBIT_RECORD_GOLDENS=1 swift test --filter GenericMonitoringParityCharacterizationTests to create it.", file: file, line: line)
            return
        }
        let expected = try JSONDecoder().decode(PresentationConfig.self, from: Data(contentsOf: url))
        XCTAssertEqual(value, expected, file: file, line: line)
    }

    func goldenData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    func fixturesURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("GenericMonitoringParity")
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
