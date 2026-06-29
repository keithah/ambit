import XCTest
@testable import AmbitCore
import AmbitUI
@testable import AmbitMenuBar

final class GenericMonitoringParityCharacterizationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let surfaceNow = Date(timeIntervalSince1970: 20_000)

    func testFrozenNetworkDiagnosisMatrixMatchesTopologyEngine() throws {
        let cases: [DiagnosisGoldenCase] = try loadGolden("network_diagnosis_matrix.json")
        let engine = TopologyDiagnosisEngine()

        for golden in cases {
            let perspective = MonitoringPerspective(
                id: "test.network",
                title: "Test Network",
                members: golden.inputHosts.map(MonitoringPerspectiveMember.init),
                linkStatus: NetworkConnectivityStatus(rawValue: golden.networkStatus)!,
                sensitivity: DiagnosisSensitivity(rawValue: golden.sensitivity)!
            )

            XCTAssertEqual(DiagnosisSnapshot(engine.diagnose(perspective)), golden.output, golden.id)
        }
    }

    func testFrozenAlertEventsMatchMonitoringAlertStateMachine() throws {
        let expected: [AlertGoldenCase] = try loadGolden("ping_alert_monitor_events.json")
        let actual = genericAlertGoldenCases()

        XCTAssertEqual(actual, expected)
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

        let scenarios: [(String, PingSurfaceFixtures, MonitoringDiagnosis?, PresentationConfig)] = [
            ("singleHostDefault", fixtures, nil, .empty),
            ("allHostsCombined", fixtures, nil, allHostsConfig),
            ("focusedHost", fixtures, nil, focusedConfig),
            ("primaryDown", primaryDownFixtures, nil, .empty),
            ("diagnosisBanner", fixtures, monitoringDiagnosis(.localNetworkDown), .empty),
            ("recovered", fixtures, nil, .empty)
        ]

        var golden: [SurfaceGoldenCase] = []
        for (id, scenarioFixtures, diagnosis, config) in scenarios {
            let surface = await coordinator.buildSurface(
                slot: scenarioFixtures.slot,
                monitoringDiagnosis: diagnosis,
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

    init(_ diagnosis: MonitoringDiagnosis) {
        scope = Self.scope(for: diagnosis.verdict.kind)
        verdict = Self.verdict(for: diagnosis.verdict, affected: diagnosis.affectedEntityIDs)
        confidence = diagnosis.confidence.rawValue
        faultTier = diagnosis.verdict.affectedRole.map(Self.legacyTier(for:))
        affectedHostIDs = diagnosis.affectedEntityIDs.map(\.rawValue)
        title = diagnosis.title
        detail = diagnosis.detail
        evidence = diagnosis.evidence.map(TierEvidenceSnapshot.init)
    }

    private static func scope(for kind: MonitoringVerdict.Kind) -> String {
        switch kind {
        case .noData: return "noData"
        case .monitoringStalled: return "monitoringStalled"
        case .allReachable: return "allReachable"
        case .localNetworkDown: return "localNetwork"
        case .accessNetworkDown, .upstreamDown: return "upstream"
        case .remoteServiceDown: return "remoteService"
        case .partialDegradation: return "partialDegradation"
        }
    }

    private static func verdict(for verdict: MonitoringVerdict, affected: [EntityID]) -> String {
        switch verdict.kind {
        case .noData: return "noData"
        case .monitoringStalled: return "monitoringStalled"
        case .allReachable: return "allReachable"
        case .localNetworkDown: return "localNetworkDown"
        case .accessNetworkDown: return "ispPathDown"
        case .upstreamDown: return "upstreamDown"
        case .remoteServiceDown:
            return "remoteServiceDown(hostIDs: \(affected.map(\.rawValue)))"
        case .partialDegradation:
            return "partialDegradation(tier: AmbitCore.NetworkTier.\(legacyTier(for: verdict.affectedRole)))"
        }
    }

    fileprivate static func legacyTier(for role: MonitoringRole?) -> String {
        switch role {
        case .localGateway, .localLink: return "localGateway"
        case .accessNetwork: return "ispEdge"
        case .upstreamInternet: return "upstream"
        case .remoteService, .endpoint: return "remoteService"
        case nil: return "upstream"
        }
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

    init(_ evidence: MonitoringEvidence) {
        tier = DiagnosisSnapshot.legacyTier(for: evidence.role)
        total = evidence.total
        healthy = evidence.healthy
        degraded = evidence.degraded
        down = evidence.down
        status = evidence.status.rawValue
        summary = evidence.summary
    }
}

private struct AlertGoldenCase: Codable, Equatable {
    var id: String
    var events: [AlertEventSnapshot]
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

    func genericAlertGoldenCases() -> [AlertGoldenCase] {
        [
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
    }

    func alertCase(_ id: String, _ events: [AlertEvent]) -> AlertGoldenCase {
        AlertGoldenCase(id: id, events: events.map { AlertEventSnapshot($0) })
    }

    func alertCaseStableTime(_ id: String, _ events: [AlertEvent?]) -> AlertGoldenCase {
        AlertGoldenCase(id: id, events: events.compactMap { $0 }.map { AlertEventSnapshot($0, triggeredAtOverride: 0) })
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

    func member(_ id: String = "cf", name: String = "Cloudflare", status: HealthStatus, recovery: Bool = true, cooldown: TimeInterval = 60) -> MonitoringAlertMember {
        MonitoringAlertMember(
            id: id,
            name: name,
            status: status,
            target: .entity(EntityID(rawValue: "\(id)/probe.latency_ms")),
            notifyOnRecovery: recovery,
            cooldown: cooldown
        )
    }

    func healthyDiagnosis() -> MonitoringDiagnosis {
        MonitoringDiagnosis(
            perspectiveID: "monitoring.default",
            verdict: MonitoringVerdict(kind: .allReachable),
            severity: .normal,
            confidence: .high,
            affectedEntityIDs: [],
            title: "All reachable",
            detail: "2/2 monitored hosts healthy."
        )
    }

    func diagnosis(
        _ kind: MonitoringVerdict.Kind,
        _ confidence: DiagnosisConfidence,
        role: MonitoringRole = .upstreamInternet,
        affected: [EntityID] = [],
        detail: String = "d"
    ) -> MonitoringDiagnosis {
        MonitoringDiagnosis(
            perspectiveID: "monitoring.default",
            verdict: MonitoringVerdict(kind: kind, affectedRole: role),
            severity: DiagnosticSummaryEntity.severity(for: kind) ?? .normal,
            confidence: confidence,
            affectedEntityIDs: affected,
            title: "t",
            detail: detail
        )
    }

    func hostDownRecoveryCooldown() -> [AlertGoldenCase] {
        var machine = monitoringMachine()
        _ = machine.evaluate(members: [member(status: .healthy)], diagnosis: healthyDiagnosis(), now: at(0))
        let down = machine.evaluate(members: [member(status: .down)], diagnosis: healthyDiagnosis(), now: at(1))
        let stillDown = machine.evaluate(members: [member(status: .down)], diagnosis: healthyDiagnosis(), now: at(2))
        let recovered = machine.evaluate(members: [member(status: .healthy)], diagnosis: healthyDiagnosis(), now: at(70))
        return [
            alertCase("hostDownRecovery.down", down),
            alertCase("hostDownRecovery.stillDown", stillDown),
            alertCase("hostDownRecovery.recovered", recovered)
        ]
    }

    func noRecoveryWhenDisabled() -> [AlertGoldenCase] {
        var machine = monitoringMachine()
        _ = machine.evaluate(members: [member(status: .down, recovery: false)], diagnosis: healthyDiagnosis(), now: at(0))
        return [alertCase("noRecoveryWhenDisabled", machine.evaluate(members: [member(status: .healthy, recovery: false)], diagnosis: healthyDiagnosis(), now: at(5)))]
    }

    func highConfidenceSpecificNetworkAlerts() -> [AlertGoldenCase] {
        [
            (MonitoringVerdict.Kind.localNetworkDown, "localNetworkDown", MonitoringRole.localGateway),
            (.accessNetworkDown, "ispPathDown", .accessNetwork),
            (.upstreamDown, "upstreamDown", .upstreamInternet),
            (.remoteServiceDown, "remoteServiceDown", .remoteService)
        ].map { kind, id, role in
            var machine = monitoringMachine(sensitivity: .balanced)
            let affected: [EntityID] = kind == .remoteServiceDown ? ["cf"] : []
            return alertCase("highConfidence.\(id)", machine.evaluate(members: [], diagnosis: diagnosis(kind, .high, role: role, affected: affected), now: at(0)))
        }
    }

    func tentativeSensitivityMatrix() -> [AlertGoldenCase] {
        DiagnosisSensitivity.allCases.map { sensitivity in
            var machine = monitoringMachine(sensitivity: sensitivity)
            return alertCase(
                "tentative.\(sensitivity.rawValue)",
                machine.evaluate(members: [], diagnosis: diagnosis(.upstreamDown, .tentative), now: at(0))
            )
        }
    }

    func pathDegradedStreaks() -> [AlertGoldenCase] {
        DiagnosisSensitivity.allCases.flatMap { sensitivity in
            var machine = monitoringMachine(sensitivity: sensitivity, pathDegradedConsecutive: 3)
            let diag = diagnosis(.partialDegradation, .tentative)
            return [
                alertCase("pathDegraded.\(sensitivity.rawValue).first", machine.evaluate(members: [], diagnosis: diag, now: at(0))),
                alertCase("pathDegraded.\(sensitivity.rawValue).second", machine.evaluate(members: [], diagnosis: diag, now: at(1))),
                alertCase("pathDegraded.\(sensitivity.rawValue).third", machine.evaluate(members: [], diagnosis: diag, now: at(2)))
            ]
        }
    }

    func networkCooldownSuppression() -> [AlertGoldenCase] {
        var machine = monitoringMachine(sensitivity: .balanced, networkCooldown: 300)
        let diag = diagnosis(.upstreamDown, .high)
        return [
            alertCase("networkCooldown.first", machine.evaluate(members: [], diagnosis: diag, now: at(0))),
            alertCase("networkCooldown.suppressed", machine.evaluate(members: [], diagnosis: diag, now: at(30)))
        ]
    }

    func internetLossSafetyNet() -> [AlertGoldenCase] {
        var machine = monitoringMachine(sensitivity: .conservative, networkCooldown: 300)
        return [
            alertCase(
                "internetLossSafetyNet",
                machine.evaluate(
                    members: [
                        member(status: .down),
                        member("gw", name: "Gateway", status: .down)
                    ],
                    diagnosis: healthyDiagnosis(),
                    now: at(0)
                )
            )
        ]
    }

    func remoteServiceAdditionalHostsCopy() -> [AlertGoldenCase] {
        var machine = monitoringMachine(sensitivity: .balanced, networkCooldown: 300)
        let members = [
            member("cf", name: "Cloudflare DNS", status: .degraded),
            member("gg", name: "Google DNS", status: .degraded),
            member("svc", name: "Service API", status: .degraded)
        ]
        let diag = diagnosis(
            .remoteServiceDown,
            .high,
            role: .remoteService,
            affected: ["cf", "gg", "svc"],
            detail: "3/3 remote host(s) unreachable."
        )
        return [alertCase("remoteServiceAdditionalHostsCopy", machine.evaluate(members: members, diagnosis: diag, now: at(0)))]
    }

    func pathRecoveredOnlyAfterDeliveredNetworkAlert() -> [AlertGoldenCase] {
        var machine = monitoringMachine(sensitivity: .balanced, networkCooldown: 300)
        let noPrior = machine.evaluate(members: [], diagnosis: healthyDiagnosis(), now: at(0))
        _ = machine.evaluate(members: [], diagnosis: diagnosis(.upstreamDown, .high), now: at(10))
        let recovered = machine.evaluate(members: [], diagnosis: healthyDiagnosis(), now: at(20))
        let repeated = machine.evaluate(members: [], diagnosis: healthyDiagnosis(), now: at(30))
        return [
            alertCase("pathRecovered.noPrior", noPrior),
            alertCase("pathRecovered.afterDelivered", recovered),
            alertCase("pathRecovered.repeated", repeated)
        ]
    }

    func networkStatusTransitionAlerts() -> [AlertGoldenCase] {
        NetworkConnectivityStatus.allCases.flatMap { status in
            guard status != .connected else { return [AlertGoldenCase]() }
            var machine = MonitoringAlertStateMachine(networkAwarenessConfig: NetworkAwarenessConfig(cooldown: 300))
            let down = machine.evaluateNetworkStatus(previous: .connected, current: status, now: at(0))
            let repeated = machine.evaluateNetworkStatus(previous: status, current: status, now: at(10))
            let recovered = machine.evaluateNetworkStatus(previous: status, current: .connected, now: at(20))
            return [
                alertCase("networkStatus.\(status.rawValue).down", [down].compactMap { $0 }),
                alertCase("networkStatus.\(status.rawValue).repeated", [repeated].compactMap { $0 }),
                alertCase("networkStatus.\(status.rawValue).recovered", [recovered].compactMap { $0 })
            ]
        }
    }

    func networkChangeEventCopy() -> [AlertGoldenCase] {
        let machine = MonitoringAlertStateMachine()
        return [
            alertCaseStableTime("networkChange.gatewayChanged", [
                machine.networkChangeEvent(MonitoringNetworkChange(previousGateway: "192.168.101.1", currentGateway: "192.168.8.1"), now: at(0))
            ]),
            alertCaseStableTime("networkChange.unchanged", [
                machine.networkChangeEvent(MonitoringNetworkChange(previousGateway: "192.168.8.1", currentGateway: "192.168.8.1"), now: at(0))
            ])
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
                    priority: index == 0 ? 10 : 0,
                    monitoring: MonitoringMetadata(
                        role: index == 0 ? .localGateway : (index == 1 ? .upstreamInternet : .localGateway),
                        perspectiveID: "ping.default",
                        diagnosticSummary: .member,
                        address: MonitoredAddress(rawValue: hosts[index].address)
                    )
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

    func monitoringDiagnosis(_ kind: MonitoringVerdict.Kind) -> MonitoringDiagnosis {
        MonitoringDiagnosis(
            perspectiveID: "monitoring.default",
            verdict: MonitoringVerdict(kind: kind, affectedRole: kind == .localNetworkDown ? .localGateway : nil),
            severity: DiagnosticSummaryEntity.severity(for: kind) ?? .normal,
            confidence: .high,
            affectedEntityIDs: [],
            title: kind == .localNetworkDown ? "Local network down" : "All reachable",
            detail: kind == .localNetworkDown ? "1/1 gateway host(s) unreachable." : "2/2 monitored hosts healthy."
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

    func loadGolden<T: Decodable>(_ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: fixturesURL().appendingPathComponent(name)))
    }

    func assertGolden<T: Encodable>(_ value: T, named name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try goldenData(value)
        let url = fixturesURL().appendingPathComponent(name)
        if ProcessInfo.processInfo.environment["AMBIT_RECORD_GOLDENS"] == "1" {
            try FileManager.default.createDirectory(at: fixturesURL(), withIntermediateDirectories: true)
            try data.write(to: url)
            return
        }
        let expected = try Data(contentsOf: url)
        XCTAssertEqual(String(data: data, encoding: .utf8), String(data: expected, encoding: .utf8), file: file, line: line)
    }

    func assertPresentationConfigGolden(_ value: PresentationConfig, named name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = fixturesURL().appendingPathComponent(name)
        if ProcessInfo.processInfo.environment["AMBIT_RECORD_GOLDENS"] == "1" {
            let data = try goldenData(value)
            try FileManager.default.createDirectory(at: fixturesURL(), withIntermediateDirectories: true)
            try data.write(to: url)
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

private extension MonitoringPerspectiveMember {
    init(_ snapshot: DiagnosisHostSnapshot) {
        self.init(
            entityID: EntityID(rawValue: snapshot.id),
            instanceID: IntegrationInstanceID(rawValue: snapshot.id),
            displayName: snapshot.id,
            role: MonitoringRole(legacyTier: snapshot.tier),
            status: HealthStatus(rawValue: snapshot.status)!,
            isStale: snapshot.isStale,
            consecutiveFailures: snapshot.consecutiveFailures
        )
    }
}

private extension MonitoringRole {
    init(legacyTier: String) {
        switch legacyTier {
        case "localGateway": self = .localGateway
        case "ispEdge": self = .accessNetwork
        case "upstream": self = .upstreamInternet
        case "remoteService": self = .remoteService
        default: self = .endpoint
        }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
