import XCTest
@testable import AmbitCore
import AmbitUI
@testable import AmbitMenuBar

final class StatusViewModelDynamicSlotTests: XCTestCase {
    func testOverlaySlotSelectionDefaultsAndReconcilesToAvailableSlots() {
        let ping = Slot(id: "ping", title: "Ping", selection: .integrationType(IntegrationIDs.ping), barReadout: .dynamic)
        let system = Slot(id: "system@local", title: "System", selection: .integration(IntegrationInstanceIDs.systemLocal), barReadout: .dynamic)

        XCTAssertEqual(OverlaySlotSelection.reconciled(nil, slots: [ping, system]), ping.id)
        XCTAssertEqual(OverlaySlotSelection.reconciled(system.id, slots: [ping, system]), system.id)
        XCTAssertEqual(OverlaySlotSelection.reconciled("missing", slots: [ping, system]), ping.id)
        XCTAssertNil(OverlaySlotSelection.reconciled(system.id, slots: []))
    }

    func testOverlayCompactCardsPreferGraphsThenFallbackToUsefulCards() {
        let latencyID = EntityID(rawValue: "ping@1.1.1.1/probe.latency_ms")
        let cpuID = EntityID(rawValue: "system@local/overview.cpu_usage_percent")
        let graph = CardSpec(id: "graph.latency", kind: .historyGraph, entities: [latencyID])
        let gauge = CardSpec(id: "gauge.cpu", kind: .gauge, entities: [cpuID])
        let table = CardSpec(id: "table.processes", kind: .statTable, entities: [EntityID(rawValue: "system@local/processes.top_cpu")])

        let graphPlan = SurfacePlan(cards: [
            CardSpec(id: "section.network", kind: .section, children: [gauge, graph, table])
        ])
        XCTAssertEqual(OverlaySurfaceCards.compactCards(from: graphPlan).map(\.id), ["graph.latency"])

        let fallbackPlan = SurfacePlan(cards: [
            CardSpec(id: "section.cpu", kind: .section, children: [table, gauge])
        ])
        XCTAssertEqual(OverlaySurfaceCards.compactCards(from: fallbackPlan).map(\.id), ["gauge.cpu"])
    }

    func testSlotPopoverScrollIdentityIsStableAcrossSurfaceRefreshes() {
        let slotID = SlotID(rawValue: "slot.system")

        XCTAssertEqual(SlotPopover.scrollContentIdentity(for: slotID), "slot-scroll-slot.system")
        XCTAssertEqual(SlotPopover.scrollContentIdentity(for: slotID), "slot-scroll-slot.system")
    }

    func testSlotPopoverHostSubtitleFollowsSelectedHostOrAllHosts() {
        let options = [
            InstanceSelectorCard.Option(id: "ping@1.1.1.1:443", label: "Cloudflare DNS", subtitle: "TCP 1.1.1.1"),
            InstanceSelectorCard.Option(id: "ping@8.8.8.8:443", label: "Google DNS", subtitle: "TCP 8.8.8.8")
        ]

        XCTAssertEqual(SlotPopover.hostSubtitle(selectedID: "ping@1.1.1.1:443", options: options), "TCP 1.1.1.1")
        XCTAssertEqual(SlotPopover.hostSubtitle(selectedID: nil, options: options), "2 enabled hosts")
    }

    func testHistoryBackedCardsIncludeSampleHistoryCards() {
        let latencyID = EntityID(rawValue: "ping@1.1.1.1/probe.latency_ms")
        let graph = CardSpec(id: "card.latency", kind: .historyGraph, entities: [latencyID])
        let history = CardSpec(id: "history.latency", kind: .sampleHistory, entities: [latencyID])
        let plan = SurfacePlan(cards: [
            CardSpec(id: "section.Network", kind: .section, children: [graph, history])
        ])

        let cards = StatusViewModel.historyBackedCards(in: plan.cards)

        XCTAssertEqual(cards.map(\.kind), [.historyGraph, .sampleHistory])
        XCTAssertEqual(cards.flatMap(\.entities), [latencyID, latencyID])
    }

    private let now = Date(timeIntervalSince1970: 20_000)

    func testGatewaySeedReconciliationKeepsOnlyCurrentAutoGateway() {
        let cloudflare = IntegrationInstanceRecord.ping(PingHostConfig(displayName: "Cloudflare DNS", address: "1.1.1.1", method: .tcp, port: 443))
        let oldGateway = IntegrationInstanceRecord.ping(PingHostConfig(displayName: "Gateway", address: "192.168.101.1", method: .icmp))
        let currentGateway = IntegrationInstanceRecord.ping(PingHostConfig(displayName: "Gateway", address: "192.168.8.1", method: .icmp))

        let result = StatusViewModel.reconciledGatewaySeedRecords(
            [cloudflare, oldGateway, currentGateway],
            currentGateway: "192.168.8.1"
        )

        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.records.map(\.id.rawValue), [
            "ping@1.1.1.1:443",
            "ping@192.168.8.1"
        ])
    }

    func testGatewaySeedReconciliationAddsCurrentGatewayWhenMissing() {
        let cloudflare = IntegrationInstanceRecord.ping(PingHostConfig(displayName: "Cloudflare DNS", address: "1.1.1.1", method: .tcp, port: 443))

        let result = StatusViewModel.reconciledGatewaySeedRecords(
            [cloudflare],
            currentGateway: "192.168.8.1"
        )

        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.records.map(\.id.rawValue), [
            "ping@1.1.1.1:443",
            "ping@192.168.8.1"
        ])
    }

    func testLatencyStateBackfillsNilCurrentValueFromLatestHistorySample() {
        let id = EntityID(rawValue: "ping@8.8.8.8:443/probe.latency_ms")
        let sampleTime = now.addingTimeInterval(5)
        let current = EntityState(id: id, value: nil, availability: .online, severity: .normal)

        let result = StatusViewModel.latencyStateForSurface(
            id: id,
            current: current,
            samples: [Sample(timestamp: sampleTime, value: 6.4, ok: true)]
        )

        XCTAssertEqual(result?.value, .number(6.4))
        XCTAssertEqual(result?.availability, .online)
        XCTAssertEqual(result?.lastUpdated, sampleTime)
        XCTAssertEqual(result?.severity, .normal)
    }

    func testLatencyStateKeepsCurrentNumericValueOverHistoryFallback() {
        let id = EntityID(rawValue: "ping@8.8.8.8:443/probe.latency_ms")
        let current = EntityState(id: id, value: .number(12), availability: .online, severity: .normal)

        let result = StatusViewModel.latencyStateForSurface(
            id: id,
            current: current,
            samples: [Sample(timestamp: now, value: 6.4, ok: true)]
        )

        XCTAssertEqual(result?.value, .number(12))
    }

    func testDynamicReadoutUsesHighestAttentionEntityOverStaticPrimary() {
        var engine = AttentionEngine()
        let primary = descriptor("primary", isPrimary: true)
        let degraded = descriptor("degraded")

        let glyph = StatusSlotReadout.resolveGlyph(
            mode: .dynamic,
            candidates: [
                AttentionCandidate(descriptor: primary, state: state(primary.id, value: 10, severity: .normal)),
                AttentionCandidate(descriptor: degraded, state: state(degraded.id, value: 250, severity: .degraded))
            ],
            descriptors: [primary.id: primary, degraded.id: degraded],
            states: [
                primary.id: state(primary.id, value: 10, severity: .normal),
                degraded.id: state(degraded.id, value: 250, severity: .degraded)
            ],
            alertingIDs: [],
            config: .empty,
            now: now,
            attentionEngine: &engine
        )

        XCTAssertEqual(glyph.primaryText, "250ms")
        XCTAssertEqual(glyph.tone, .warn)
    }

    func testDynamicReadoutUsesNeutralNoDataForInitialUnavailableValue() {
        var engine = AttentionEngine()
        let primary = descriptor("primary", isPrimary: true)
        let initial = EntityState(id: primary.id, value: nil, availability: .unavailable, severity: .normal)

        let glyph = StatusSlotReadout.resolveGlyph(
            mode: .dynamic,
            candidates: [
                AttentionCandidate(descriptor: primary, state: initial)
            ],
            descriptors: [primary.id: primary],
            states: [primary.id: initial],
            alertingIDs: [],
            config: .empty,
            now: now,
            attentionEngine: &engine
        )

        XCTAssertEqual(glyph.primaryText, "--ms")
        XCTAssertEqual(glyph.tone, .neutral)
    }

    func testDynamicReadoutUsesSelectedCandidateStateWhenStateMapIsMissingIt() {
        var engine = AttentionEngine()
        let primary = descriptor("primary", isPrimary: true)
        let degraded = descriptor("degraded")

        let glyph = StatusSlotReadout.resolveGlyph(
            mode: .dynamic,
            candidates: [
                AttentionCandidate(descriptor: primary, state: state(primary.id, value: 10, severity: .normal)),
                AttentionCandidate(descriptor: degraded, state: state(degraded.id, value: 250, severity: .degraded))
            ],
            descriptors: [primary.id: primary, degraded.id: degraded],
            states: [
                primary.id: state(primary.id, value: 10, severity: .normal)
            ],
            alertingIDs: [],
            config: .empty,
            now: now,
            attentionEngine: &engine
        )

        XCTAssertEqual(glyph.primaryText, "250ms")
        XCTAssertEqual(glyph.tone, .warn)
    }

    func testDynamicReadoutReturnsToRestingPrimaryAfterRecovery() {
        var engine = AttentionEngine()
        let primary = descriptor("primary", isPrimary: true)
        let recovered = descriptor("recovered")

        _ = StatusSlotReadout.resolveGlyph(
            mode: .dynamic,
            candidates: [
                AttentionCandidate(descriptor: primary, state: state(primary.id, value: 10, severity: .normal)),
                AttentionCandidate(descriptor: recovered, state: state(recovered.id, value: 250, severity: .degraded))
            ],
            descriptors: [primary.id: primary, recovered.id: recovered],
            states: [
                primary.id: state(primary.id, value: 10, severity: .normal),
                recovered.id: state(recovered.id, value: 250, severity: .degraded)
            ],
            alertingIDs: [],
            config: .empty,
            now: now,
            attentionEngine: &engine
        )

        let glyph = StatusSlotReadout.resolveGlyph(
            mode: .dynamic,
            candidates: [
                AttentionCandidate(descriptor: primary, state: state(primary.id, value: 10, severity: .normal)),
                AttentionCandidate(descriptor: recovered, state: state(recovered.id, value: 25, severity: .normal))
            ],
            descriptors: [primary.id: primary, recovered.id: recovered],
            states: [
                primary.id: state(primary.id, value: 10, severity: .normal),
                recovered.id: state(recovered.id, value: 25, severity: .normal)
            ],
            alertingIDs: [],
            config: .empty,
            now: now.addingTimeInterval(1),
            attentionEngine: &engine
        )

        XCTAssertEqual(glyph.primaryText, "10ms")
        XCTAssertEqual(glyph.tone, .good)
    }

    func testFixedReadoutIgnoresHigherAttentionEntity() {
        var engine = AttentionEngine()
        let fixed = descriptor("fixed")
        let degraded = descriptor("degraded")

        let glyph = StatusSlotReadout.resolveGlyph(
            mode: .fixed(fixed.id),
            candidates: [
                AttentionCandidate(descriptor: fixed, state: state(fixed.id, value: 10, severity: .normal)),
                AttentionCandidate(descriptor: degraded, state: state(degraded.id, value: 250, severity: .degraded))
            ],
            descriptors: [fixed.id: fixed, degraded.id: degraded],
            states: [
                fixed.id: state(fixed.id, value: 10, severity: .normal),
                degraded.id: state(degraded.id, value: 250, severity: .degraded)
            ],
            alertingIDs: [degraded.id],
            config: .empty,
            now: now,
            attentionEngine: &engine
        )

        XCTAssertEqual(glyph.primaryText, "10ms")
        XCTAssertEqual(glyph.tone, .good)
    }

    func testMonitoringStalledDiagnosisSurfacesAsElevatedCalmBannerCandidate() {
        var engine = AttentionEngine()
        let (diagnosisDescriptor, diagnosisState) = DiagnosisEntity.make(diagnosis(.monitoringStalled))!

        let selection = StatusSlotReadout.resolveSelection(
            candidates: [AttentionCandidate(descriptor: diagnosisDescriptor, state: diagnosisState)],
            alertingIDs: [],
            config: .empty,
            now: now,
            attentionEngine: &engine
        )

        XCTAssertEqual(selection.lanes.first?.id, DiagnosisEntity.entityID)
        XCTAssertEqual(selection.lanes.first?.tier, .surfaced)
        XCTAssertEqual(selection.lanes.first?.reason.severity, .elevated)
        XCTAssertTrue(selection.alerted.isEmpty)
    }

    func testLocalNetworkDownDiagnosisEscalatesAsAlertedDownCandidate() {
        var engine = AttentionEngine()
        let (diagnosisDescriptor, diagnosisState) = DiagnosisEntity.make(diagnosis(.localNetworkDown))!

        let selection = StatusSlotReadout.resolveSelection(
            candidates: [AttentionCandidate(descriptor: diagnosisDescriptor, state: diagnosisState)],
            alertingIDs: [DiagnosisEntity.entityID],
            config: .empty,
            now: now,
            attentionEngine: &engine
        )

        XCTAssertEqual(selection.lanes.first?.id, DiagnosisEntity.entityID)
        XCTAssertEqual(selection.lanes.first?.tier, .alerted)
        XCTAssertEqual(selection.lanes.first?.reason.severity, .down)
        XCTAssertEqual(selection.alerted.map(\.id), [DiagnosisEntity.entityID])
    }

    func testGenericSlotSurfaceUsesResolvedDescriptorsAndStatesForReadoutAndDetail() {
        var engine = AttentionEngine()
        let cpu = EntityDescriptor(
            id: "system@local/overview.cpu_usage_percent",
            instanceID: ProviderInstanceIDs.systemOverview,
            name: "CPU",
            kind: .sensor,
            deviceClass: .percent,
            category: .primary,
            capability: "system.cpu",
            stateClass: .measurement,
            graphStyle: .gauge,
            isPrimary: true
        )
        let disk = EntityDescriptor(
            id: "system@local/storage.volumes",
            instanceID: ProviderInstanceIDs.systemStorage,
            name: "Volumes",
            kind: .table,
            capability: "system.disk"
        )
        let states: [EntityID: EntityState] = [
            cpu.id: EntityState(id: cpu.id, value: .number(34), availability: .online, severity: .normal),
            disk.id: EntityState(id: disk.id, value: .table(TableValue(columns: [], rows: [])), availability: .online, severity: .normal)
        ]

        let surface = StatusSlotSurfaceBuilder.genericSurface(
            slot: Slot(id: "system", title: "System", selection: .integration("system@local")),
            descriptors: [cpu, disk],
            states: states,
            config: .empty,
            now: now,
            attentionEngine: &engine
        )

        XCTAssertEqual(surface.glyph.primaryText, "34%")
        XCTAssertEqual(surface.glyph.tone, .good)
        XCTAssertEqual(surface.plan.cards.map(\.title), ["CPU", "Disk"])
        XCTAssertEqual(surface.data.descriptors[cpu.id], cpu)
        XCTAssertEqual(surface.data.states[cpu.id], states[cpu.id])
    }

    @MainActor
    func testSlotSurfaceCoordinatorBuildsGenericSurfaceAndLoadsHistorySeries() async {
        let coordinator = SlotSurfaceCoordinator()
        let cpu = EntityDescriptor(
            id: "system@local/overview.cpu_usage_percent",
            instanceID: ProviderInstanceIDs.systemOverview,
            name: "CPU",
            kind: .sensor,
            deviceClass: .percent,
            category: .primary,
            capability: "system.cpu",
            stateClass: .measurement,
            graphStyle: .sparkline,
            isPrimary: true
        )
        let sample = Sample(timestamp: now, value: 34, ok: true)
        let surface = await coordinator.buildSurface(
            slot: Slot(id: "system", title: "System", selection: .integration("system@local")),
            diagnosis: diagnosis(.allReachable),
            enabledPingRecords: [],
            allRegistryRecords: [
                IntegrationInstanceRecord(
                    id: "system@local",
                    integrationID: IntegrationIDs.system,
                    displayName: "System",
                    enabled: true,
                    config: [:]
                )
            ],
            allDescriptors: [ProviderInstanceIDs.systemOverview: [cpu]],
            allStates: [cpu.id: state(cpu.id, value: 34, severity: .normal)],
            firedAlertEvents: [],
            slotFocus: [:],
            pingRange: .fiveMinutes,
            config: .empty,
            now: now,
            historySamples: { id, _ in id == cpu.id ? [sample] : [] }
        )

        XCTAssertEqual(surface.glyph.primaryText, "34%")
        XCTAssertEqual(surface.primaryEntityID, cpu.id)
        XCTAssertEqual(surface.data.series[cpu.id], [sample])
        XCTAssertEqual(surface.plan.cards.flatMap { $0.children }.first?.kind, .historyGraph)
    }

    @MainActor
    func testPingDiagnosisCoordinatorBuildsStalledDiagnosisWithSampleAge() async {
        let coordinator = PingDiagnosisCoordinator()
        let host = PingHostConfig(displayName: "Cloudflare DNS", address: "1.1.1.1", method: .tcp, port: 443, interval: 1)
        let record = IntegrationInstanceRecord.ping(host)
        let providerInstance = ProviderInstanceID(rawValue: "\(record.id.rawValue)/probe")
        let staleSample = Sample(timestamp: now.addingTimeInterval(-12), value: 9, ok: true)
        let snapshot = StatusSnapshot(
            providers: [
                providerInstance: SourceState(value: ProviderSnapshot(health: .ok))
            ]
        )

        let result = await coordinator.evaluate(
            activeRecords: [record],
            snapshot: snapshot,
            now: now,
            range: .fiveMinutes,
            historySamples: { _, _ in [staleSample] }
        )

        XCTAssertEqual(result.diagnosis.verdict, .monitoringStalled)
        XCTAssertEqual(result.diagnosis.detail, "Monitoring paused — data is 12s old.")
        XCTAssertEqual(result.events, [])
    }

    @MainActor
    func testDefaultPingSurfaceFocusesPrimaryHostInsteadOfAllHosts() async {
        let coordinator = SlotSurfaceCoordinator()
        let fixtures = pingSurfaceFixtures()

        let surface = await coordinator.buildSurface(
            slot: fixtures.slot,
            diagnosis: diagnosis(.allReachable),
            enabledPingRecords: fixtures.records,
            allRegistryRecords: fixtures.records,
            allDescriptors: fixtures.descriptorsByProvider,
            allStates: fixtures.states,
            firedAlertEvents: [],
            slotFocus: [:],
            pingRange: .fiveMinutes,
            config: .empty,
            now: now,
            historySamples: { id, _ in fixtures.samples[id] ?? [] }
        )

        let graph = surface.firstCard(kind: .historyGraph)
        XCTAssertEqual(graph?.role, .primary)
        XCTAssertEqual(graph?.entities, [fixtures.latencyIDs[0]])
        XCTAssertEqual(Set(surface.data.series.keys), [fixtures.latencyIDs[0]])
        XCTAssertEqual(surface.hostOptions.map(\.label), ["Cloudflare DNS", "Google DNS"])
        XCTAssertEqual(surface.hostOptions.map(\.subtitle), ["TCP 1.1.1.1", "TCP 8.8.8.8"])
        XCTAssertEqual(surface.selectedInstanceID, fixtures.records[0].id)
        XCTAssertEqual(surface.primaryEntityID, fixtures.latencyIDs[0])
    }

    @MainActor
    func testDefaultPingSurfaceSkipsLoopbackWhenNonLoopbackHostExists() async {
        let coordinator = SlotSurfaceCoordinator()
        var fixtures = pingSurfaceFixtures(hosts: [
            PingHostConfig(displayName: "Local", address: "127.0.0.1", method: .tcp, port: 22),
            PingHostConfig(displayName: "Cloudflare DNS", address: "1.1.1.1", method: .tcp, port: 443)
        ])
        fixtures.states[fixtures.latencyIDs[0]] = EntityState(
            id: fixtures.latencyIDs[0],
            availability: .unavailable,
            severity: .down
        )
        fixtures.samples[fixtures.latencyIDs[0]] = [
            Sample(timestamp: now.addingTimeInterval(-1), value: nil, ok: false, metadata: "connectionRefused")
        ]

        let surface = await coordinator.buildSurface(
            slot: fixtures.slot,
            diagnosis: diagnosis(.allReachable),
            enabledPingRecords: fixtures.records,
            allRegistryRecords: fixtures.records,
            allDescriptors: fixtures.descriptorsByProvider,
            allStates: fixtures.states,
            firedAlertEvents: [],
            slotFocus: [:],
            pingRange: .fiveMinutes,
            config: .empty,
            now: now,
            historySamples: { id, _ in fixtures.samples[id] ?? [] }
        )

        XCTAssertEqual(surface.selectedInstanceID, fixtures.records[1].id)
        XCTAssertEqual(surface.firstCard(kind: .historyGraph)?.entities, [fixtures.latencyIDs[1]])
        XCTAssertEqual(surface.firstCard(kind: .sampleHistory)?.entities, [fixtures.latencyIDs[1]])
        XCTAssertEqual(surface.glyph.primaryText, "24ms")
        XCTAssertEqual(surface.glyph.tone, .good)
    }

    @MainActor
    func testDefaultPingSurfaceFallsBackToFirstHostWhenAllHostsAreLoopback() async {
        let coordinator = SlotSurfaceCoordinator()
        let fixtures = pingSurfaceFixtures(hosts: [
            PingHostConfig(displayName: "Localhost", address: "localhost", method: .tcp, port: 22),
            PingHostConfig(displayName: "IPv6 Local", address: "::1", method: .tcp, port: 22)
        ])

        let surface = await coordinator.buildSurface(
            slot: fixtures.slot,
            diagnosis: diagnosis(.allReachable),
            enabledPingRecords: fixtures.records,
            allRegistryRecords: fixtures.records,
            allDescriptors: fixtures.descriptorsByProvider,
            allStates: fixtures.states,
            firedAlertEvents: [],
            slotFocus: [:],
            pingRange: .fiveMinutes,
            config: .empty,
            now: now,
            historySamples: { id, _ in fixtures.samples[id] ?? [] }
        )

        XCTAssertEqual(surface.selectedInstanceID, fixtures.records[0].id)
        XCTAssertEqual(surface.firstCard(kind: .historyGraph)?.entities, [fixtures.latencyIDs[0]])
    }

    @MainActor
    func testPersistedLoopbackSelectionOverridesNonLoopbackDefault() async {
        let coordinator = SlotSurfaceCoordinator()
        var fixtures = pingSurfaceFixtures(hosts: [
            PingHostConfig(displayName: "Local", address: "127.0.0.1", method: .tcp, port: 22),
            PingHostConfig(displayName: "Cloudflare DNS", address: "1.1.1.1", method: .tcp, port: 443)
        ])
        fixtures.states[fixtures.latencyIDs[0]] = EntityState(
            id: fixtures.latencyIDs[0],
            availability: .unavailable,
            severity: .down
        )
        fixtures.samples[fixtures.latencyIDs[0]] = [
            Sample(timestamp: now.addingTimeInterval(-1), value: nil, ok: false, metadata: "connectionRefused")
        ]
        var config = PresentationConfig.empty
        config.slotOverrides[fixtures.slot.id] = SlotPresentationOverride(
            selectedInstanceID: fixtures.records[0].id,
            showsAllInstances: false
        )

        let surface = await coordinator.buildSurface(
            slot: fixtures.slot,
            diagnosis: diagnosis(.allReachable),
            enabledPingRecords: fixtures.records,
            allRegistryRecords: fixtures.records,
            allDescriptors: fixtures.descriptorsByProvider,
            allStates: fixtures.states,
            firedAlertEvents: [],
            slotFocus: [:],
            pingRange: .fiveMinutes,
            config: config,
            now: now,
            historySamples: { id, _ in fixtures.samples[id] ?? [] }
        )

        XCTAssertEqual(surface.selectedInstanceID, fixtures.records[0].id)
        XCTAssertEqual(surface.firstCard(kind: .historyGraph)?.entities, [fixtures.latencyIDs[0]])
        XCTAssertEqual(surface.glyph.primaryText, "Down")
        XCTAssertEqual(surface.glyph.tone, .bad)
    }

    @MainActor
    func testExplicitAllHostsPingSurfaceBuildsCombinedLatencyGraphAndLoadsEverySeries() async {
        let coordinator = SlotSurfaceCoordinator()
        let fixtures = pingSurfaceFixtures()
        var config = PresentationConfig.empty
        config.slotOverrides[fixtures.slot.id] = SlotPresentationOverride(showsAllInstances: true)

        let surface = await coordinator.buildSurface(
            slot: fixtures.slot,
            diagnosis: diagnosis(.allReachable),
            enabledPingRecords: fixtures.records,
            allRegistryRecords: fixtures.records,
            allDescriptors: fixtures.descriptorsByProvider,
            allStates: fixtures.states,
            firedAlertEvents: [],
            slotFocus: [:],
            pingRange: .fiveMinutes,
            config: config,
            now: now,
            historySamples: { id, _ in fixtures.samples[id] ?? [] }
        )

        let graph = surface.firstCard(kind: .historyGraph)
        XCTAssertEqual(graph?.role, .primary)
        XCTAssertEqual(graph?.entities, fixtures.latencyIDs)
        XCTAssertEqual(Set(surface.data.series.keys), Set(fixtures.latencyIDs))
        XCTAssertEqual(surface.hostOptions.map(\.label), ["Cloudflare DNS", "Google DNS"])
        XCTAssertNil(surface.selectedInstanceID)
        XCTAssertEqual(surface.primaryEntityID, fixtures.latencyIDs[0])
    }

    @MainActor
    func testFocusedPingSurfaceFiltersDescriptorsSeriesAndSampleHistoryToFocusedHost() async {
        let coordinator = SlotSurfaceCoordinator()
        let fixtures = pingSurfaceFixtures()
        let focused = fixtures.records[1].id

        let surface = await coordinator.buildSurface(
            slot: fixtures.slot,
            diagnosis: diagnosis(.allReachable),
            enabledPingRecords: fixtures.records,
            allRegistryRecords: fixtures.records,
            allDescriptors: fixtures.descriptorsByProvider,
            allStates: fixtures.states,
            firedAlertEvents: [],
            slotFocus: [fixtures.slot.id: focused],
            pingRange: .fiveMinutes,
            config: .empty,
            now: now,
            historySamples: { id, _ in fixtures.samples[id] ?? [] }
        )

        XCTAssertEqual(surface.firstCard(kind: .historyGraph)?.entities, [fixtures.latencyIDs[1]])
        XCTAssertEqual(surface.firstCard(kind: .sampleHistory)?.entities, [fixtures.latencyIDs[1]])
        XCTAssertEqual(Set(surface.data.descriptors.keys), [fixtures.latencyIDs[1]])
        XCTAssertEqual(Set(surface.data.series.keys), [fixtures.latencyIDs[1]])
        XCTAssertEqual(surface.hostOptions.map(\.label), ["Cloudflare DNS", "Google DNS"])
        XCTAssertEqual(surface.primaryEntityID, fixtures.latencyIDs[1])
        XCTAssertEqual(surface.glyph.primaryText, "24ms")
    }

    @MainActor
    func testAllHostsPingSurfaceUsesDesignatedPrimaryForGlyph() async {
        let coordinator = SlotSurfaceCoordinator()
        let fixtures = pingSurfaceFixtures()

        let surface = await coordinator.buildSurface(
            slot: fixtures.slot,
            diagnosis: diagnosis(.allReachable),
            enabledPingRecords: fixtures.records,
            allRegistryRecords: fixtures.records,
            allDescriptors: fixtures.descriptorsByProvider,
            allStates: fixtures.states,
            firedAlertEvents: [],
            slotFocus: [:],
            primaryPingInstanceID: fixtures.records[1].id,
            pingRange: .fiveMinutes,
            config: .empty,
            now: now,
            historySamples: { id, _ in fixtures.samples[id] ?? [] }
        )

        XCTAssertEqual(surface.primaryEntityID, fixtures.latencyIDs[1])
        XCTAssertEqual(surface.selectedInstanceID, fixtures.records[1].id)
        XCTAssertEqual(surface.glyph.primaryText, "24ms")
        XCTAssertEqual(surface.firstCard(kind: .sampleHistory)?.entities, [fixtures.latencyIDs[1]])
    }

    @MainActor
    func testMissingPersistedPingFocusFallsBackToPrimaryFocusedSurface() async {
        let coordinator = SlotSurfaceCoordinator()
        let fixtures = pingSurfaceFixtures()
        var config = PresentationConfig.empty
        config.slotOverrides[fixtures.slot.id] = SlotPresentationOverride(
            selectedInstanceID: IntegrationInstanceID(rawValue: "ping@missing"),
            showsAllInstances: false
        )

        let surface = await coordinator.buildSurface(
            slot: fixtures.slot,
            diagnosis: diagnosis(.allReachable),
            enabledPingRecords: fixtures.records,
            allRegistryRecords: fixtures.records,
            allDescriptors: fixtures.descriptorsByProvider,
            allStates: fixtures.states,
            firedAlertEvents: [],
            slotFocus: [:],
            pingRange: .fiveMinutes,
            config: config,
            now: now,
            historySamples: { id, _ in fixtures.samples[id] ?? [] }
        )

        XCTAssertEqual(surface.firstCard(kind: .historyGraph)?.entities, [fixtures.latencyIDs[0]])
        XCTAssertEqual(surface.selectedInstanceID, fixtures.records[0].id)
        XCTAssertEqual(surface.primaryEntityID, fixtures.latencyIDs[0])
    }

    @MainActor
    func testCombinedPingGlyphKeepsPrimaryWhenPeerIsDown() async {
        let coordinator = SlotSurfaceCoordinator()
        var fixtures = pingSurfaceFixtures()
        fixtures.states[fixtures.latencyIDs[1]] = EntityState(
            id: fixtures.latencyIDs[1],
            availability: .unavailable,
            severity: .down
        )

        let surface = await coordinator.buildSurface(
            slot: fixtures.slot,
            diagnosis: diagnosis(.allReachable),
            enabledPingRecords: fixtures.records,
            allRegistryRecords: fixtures.records,
            allDescriptors: fixtures.descriptorsByProvider,
            allStates: fixtures.states,
            firedAlertEvents: [],
            slotFocus: [:],
            pingRange: .fiveMinutes,
            config: .empty,
            now: now,
            historySamples: { id, _ in fixtures.samples[id] ?? [] }
        )

        XCTAssertEqual(surface.primaryEntityID, fixtures.latencyIDs[0])
        XCTAssertEqual(surface.glyph.primaryText, "12ms")
        XCTAssertEqual(surface.glyph.tone, .good)
        XCTAssertEqual(surface.firstCard(kind: .sampleHistory)?.id, "history:\(fixtures.latencyIDs[0].rawValue)")
        XCTAssertEqual(surface.firstCard(kind: .sampleHistory)?.entities, [fixtures.latencyIDs[0]])
    }

    @MainActor
    func testCombinedPingGlyphShowsDownWhenPrimaryHostIsDown() async {
        let coordinator = SlotSurfaceCoordinator()
        var fixtures = pingSurfaceFixtures()
        fixtures.states[fixtures.latencyIDs[0]] = EntityState(
            id: fixtures.latencyIDs[0],
            availability: .unavailable,
            severity: .down
        )
        fixtures.samples[fixtures.latencyIDs[0]] = [
            Sample(timestamp: now.addingTimeInterval(-1), value: nil, ok: false, metadata: "connectFailed")
        ]

        let surface = await coordinator.buildSurface(
            slot: fixtures.slot,
            diagnosis: diagnosis(.allReachable),
            enabledPingRecords: fixtures.records,
            allRegistryRecords: fixtures.records,
            allDescriptors: fixtures.descriptorsByProvider,
            allStates: fixtures.states,
            firedAlertEvents: [],
            slotFocus: [:],
            pingRange: .fiveMinutes,
            config: .empty,
            now: now,
            historySamples: { id, _ in fixtures.samples[id] ?? [] }
        )

        XCTAssertEqual(surface.primaryEntityID, fixtures.latencyIDs[0])
        XCTAssertEqual(surface.glyph.primaryText, "Down")
        XCTAssertEqual(surface.glyph.tone, .bad)
    }

    @MainActor
    func testCombinedPingGlyphShowsStalePrimaryAsDashMsWhenNoSamplesInSelectedRange() async {
        let coordinator = SlotSurfaceCoordinator()
        var fixtures = pingSurfaceFixtures()
        fixtures.samples[fixtures.latencyIDs[0]] = []

        let surface = await coordinator.buildSurface(
            slot: fixtures.slot,
            diagnosis: diagnosis(.allReachable),
            enabledPingRecords: fixtures.records,
            allRegistryRecords: fixtures.records,
            allDescriptors: fixtures.descriptorsByProvider,
            allStates: fixtures.states,
            firedAlertEvents: [],
            slotFocus: [:],
            pingRange: .fiveMinutes,
            config: .empty,
            now: now,
            historySamples: { id, _ in fixtures.samples[id] ?? [] }
        )

        XCTAssertEqual(surface.primaryEntityID, fixtures.latencyIDs[0])
        XCTAssertEqual(surface.glyph.primaryText, "--ms")
        XCTAssertEqual(surface.glyph.tone, .neutral)
    }

    @MainActor
    func testCombinedPingSampleHistoryFallsBackToRestingLatencyWhenHeadlineIsDiagnostic() async {
        let coordinator = SlotSurfaceCoordinator()
        let fixtures = pingSurfaceFixtures()

        let surface = await coordinator.buildSurface(
            slot: fixtures.slot,
            diagnosis: diagnosis(.localNetworkDown),
            enabledPingRecords: fixtures.records,
            allRegistryRecords: fixtures.records,
            allDescriptors: fixtures.descriptorsByProvider,
            allStates: fixtures.states,
            firedAlertEvents: [],
            slotFocus: [:],
            pingRange: .fiveMinutes,
            config: .empty,
            now: now,
            historySamples: { id, _ in fixtures.samples[id] ?? [] }
        )

        XCTAssertEqual(surface.primaryEntityID, DiagnosisEntity.entityID)
        XCTAssertEqual(surface.firstCard(kind: .sampleHistory)?.id, "history:\(fixtures.latencyIDs[0].rawValue)")
        XCTAssertEqual(surface.firstCard(kind: .sampleHistory)?.entities, [fixtures.latencyIDs[0]])
    }

    @MainActor
    func testMissingFocusedPingHostFallsBackToPrimaryFocusedRendering() async {
        let coordinator = SlotSurfaceCoordinator()
        let fixtures = pingSurfaceFixtures()

        let surface = await coordinator.buildSurface(
            slot: fixtures.slot,
            diagnosis: diagnosis(.allReachable),
            enabledPingRecords: fixtures.records,
            allRegistryRecords: fixtures.records,
            allDescriptors: fixtures.descriptorsByProvider,
            allStates: fixtures.states,
            firedAlertEvents: [],
            slotFocus: [fixtures.slot.id: "ping@missing"],
            pingRange: .fiveMinutes,
            config: .empty,
            now: now,
            historySamples: { id, _ in fixtures.samples[id] ?? [] }
        )

        XCTAssertEqual(surface.firstCard(kind: .historyGraph)?.entities, [fixtures.latencyIDs[0]])
        XCTAssertEqual(Set(surface.data.series.keys), [fixtures.latencyIDs[0]])
        XCTAssertEqual(surface.hostOptions.map(\.label), ["Cloudflare DNS", "Google DNS"])
        XCTAssertEqual(surface.selectedInstanceID, fixtures.records[0].id)
    }

    @MainActor
    func testSingleEnabledPingHostBuildsFocusedEquivalentSurfaceWithoutAllHostsChoice() async {
        let coordinator = SlotSurfaceCoordinator()
        let fixtures = pingSurfaceFixtures()
        let record = fixtures.records[0]
        let provider = ProviderInstanceID(rawValue: "\(record.id.rawValue)/probe")
        let latencyID = fixtures.latencyIDs[0]

        let surface = await coordinator.buildSurface(
            slot: fixtures.slot,
            diagnosis: diagnosis(.allReachable),
            enabledPingRecords: [record],
            allRegistryRecords: fixtures.records,
            allDescriptors: [provider: fixtures.descriptorsByProvider[provider] ?? []],
            allStates: [latencyID: fixtures.states[latencyID]!],
            firedAlertEvents: [],
            slotFocus: [:],
            pingRange: .fiveMinutes,
            config: .empty,
            now: now,
            historySamples: { id, _ in fixtures.samples[id] ?? [] }
        )

        XCTAssertEqual(surface.firstCard(kind: .historyGraph)?.entities, [latencyID])
        XCTAssertEqual(surface.firstCard(kind: .sampleHistory)?.entities, [latencyID])
        XCTAssertEqual(surface.hostOptions.map(\.label), ["Cloudflare DNS"])
    }

    func testHealthyGenericSlotUsesRestingPrimaryOverNormalThroughputForGlyphAndSurfaceSelection() {
        var engine = AttentionEngine()
        let cpu = systemMetric("overview.cpu_usage_percent", name: "CPU", deviceClass: .percent, instanceID: ProviderInstanceIDs.systemOverview, isPrimary: true, priority: 100)
        let throughput = systemMetric("network.throughput_in", name: "Network In", deviceClass: .throughput, instanceID: ProviderInstanceIDs.systemNetwork, isPrimary: true)
        let states: [EntityID: EntityState] = [
            cpu.id: state(cpu.id, value: 34, severity: .normal),
            throughput.id: state(throughput.id, value: 77_000, severity: .normal)
        ]

        let surface = StatusSlotSurfaceBuilder.genericSurface(
            slot: Slot(id: "system", title: "System", selection: .integration("system@local")),
            descriptors: [throughput, cpu],
            states: states,
            config: .empty,
            now: now,
            attentionEngine: &engine
        )

        XCTAssertEqual(surface.primaryEntityID, cpu.id)
        XCTAssertEqual(surface.glyph.primaryText, "34%")
    }

    func testHealthyGenericSlotDoesNotShowDownFromUnavailableNoDataSecondary() {
        var engine = AttentionEngine()
        let cpu = systemMetric("overview.cpu_usage_percent", name: "CPU", deviceClass: .percent, instanceID: ProviderInstanceIDs.systemOverview, isPrimary: true, priority: 100)
        let throughput = systemMetric("network.throughput_in", name: "Network In", deviceClass: .throughput, instanceID: ProviderInstanceIDs.systemNetwork)
        let states: [EntityID: EntityState] = [
            cpu.id: state(cpu.id, value: 14, severity: .normal),
            throughput.id: EntityState(id: throughput.id, availability: .unavailable, severity: .down)
        ]

        let surface = StatusSlotSurfaceBuilder.genericSurface(
            slot: Slot(id: "system", title: "System", selection: .integration("system@local")),
            descriptors: [throughput, cpu],
            states: states,
            config: .empty,
            now: now,
            attentionEngine: &engine
        )

        XCTAssertEqual(surface.primaryEntityID, cpu.id)
        XCTAssertEqual(surface.glyph.primaryText, "14%")
        XCTAssertEqual(surface.glyph.tone, .good)
    }

    func testActiveThroughputOverridesRestingPrimary() {
        let cpu = systemMetric("overview.cpu_usage_percent", name: "CPU", deviceClass: .percent, instanceID: ProviderInstanceIDs.systemOverview, isPrimary: true, priority: 100)
        let throughput = systemMetric("network.throughput_in", name: "Network In", deviceClass: .throughput, instanceID: ProviderInstanceIDs.systemNetwork, isPrimary: true)
        let candidates = [
            AttentionCandidate(descriptor: cpu, state: state(cpu.id, value: 34, severity: .normal)),
            AttentionCandidate(descriptor: throughput, state: state(throughput.id, value: 77_000, severity: .elevated))
        ]
        var engine = AttentionEngine()

        let elevated = StatusSlotReadout.resolveReadout(
            mode: .dynamic,
            candidates: candidates,
            descriptors: [cpu.id: cpu, throughput.id: throughput],
            states: [cpu.id: candidates[0].state, throughput.id: candidates[1].state],
            alertingIDs: [],
            config: .empty,
            now: now,
            attentionEngine: &engine
        )

        XCTAssertEqual(elevated.primaryEntityID, throughput.id)

        var pinnedConfig = PresentationConfig.empty
        pinnedConfig.entityOverrides[throughput.id] = EntityPresentationOverride(pinned: true)
        engine = AttentionEngine()
        let pinned = StatusSlotReadout.resolveReadout(
            mode: .dynamic,
            candidates: [
                AttentionCandidate(descriptor: cpu, state: state(cpu.id, value: 34, severity: .normal)),
                AttentionCandidate(descriptor: throughput, state: state(throughput.id, value: 77_000, severity: .normal))
            ],
            descriptors: [cpu.id: cpu, throughput.id: throughput],
            states: [cpu.id: state(cpu.id, value: 34, severity: .normal), throughput.id: state(throughput.id, value: 77_000, severity: .normal)],
            alertingIDs: [],
            config: pinnedConfig,
            now: now,
            attentionEngine: &engine
        )
        XCTAssertEqual(pinned.primaryEntityID, throughput.id)

        engine = AttentionEngine()
        let alerted = StatusSlotReadout.resolveReadout(
            mode: .dynamic,
            candidates: [
                AttentionCandidate(descriptor: cpu, state: state(cpu.id, value: 34, severity: .normal)),
                AttentionCandidate(descriptor: throughput, state: state(throughput.id, value: 77_000, severity: .normal))
            ],
            descriptors: [cpu.id: cpu, throughput.id: throughput],
            states: [cpu.id: state(cpu.id, value: 34, severity: .normal), throughput.id: state(throughput.id, value: 77_000, severity: .normal)],
            alertingIDs: [throughput.id],
            config: .empty,
            now: now,
            attentionEngine: &engine
        )
        XCTAssertEqual(alerted.primaryEntityID, throughput.id)
    }

    func testBoostedThresholdCrossingOverridesRestingPrimary() {
        var engine = AttentionEngine()
        let cpu = systemMetric("overview.cpu_usage_percent", name: "CPU", deviceClass: .percent, instanceID: ProviderInstanceIDs.systemOverview, isPrimary: true, priority: 100)
        var throughput = systemMetric("network.throughput_in", name: "Network In", deviceClass: .throughput, instanceID: ProviderInstanceIDs.systemNetwork, isPrimary: true)
        throughput.displayThreshold = DisplayThreshold(comparison: .greaterThan, value: 10_000, consecutive: 1)
        let descriptors = [cpu.id: cpu, throughput.id: throughput]

        _ = StatusSlotReadout.resolveReadout(
            mode: .dynamic,
            candidates: [
                AttentionCandidate(descriptor: cpu, state: state(cpu.id, value: 34, severity: .normal)),
                AttentionCandidate(descriptor: throughput, state: state(throughput.id, value: 5_000, severity: .normal))
            ],
            descriptors: descriptors,
            states: [cpu.id: state(cpu.id, value: 34, severity: .normal), throughput.id: state(throughput.id, value: 5_000, severity: .normal)],
            alertingIDs: [],
            config: .empty,
            now: now,
            attentionEngine: &engine
        )

        let boosted = StatusSlotReadout.resolveReadout(
            mode: .dynamic,
            candidates: [
                AttentionCandidate(descriptor: cpu, state: state(cpu.id, value: 34, severity: .normal)),
                AttentionCandidate(descriptor: throughput, state: state(throughput.id, value: 77_000, severity: .normal))
            ],
            descriptors: descriptors,
            states: [cpu.id: state(cpu.id, value: 34, severity: .normal), throughput.id: state(throughput.id, value: 77_000, severity: .normal)],
            alertingIDs: [],
            config: .empty,
            now: now.addingTimeInterval(1),
            attentionEngine: &engine
        )

        XCTAssertEqual(boosted.primaryEntityID, throughput.id)
        XCTAssertEqual(boosted.selection.lanes.first?.reason.transitionBoosted, true)
    }

    func testSlotScopedAttentionEnginesKeepDebounceAndBoostStateAcrossInterleavedSlotEvaluations() {
        var engines = SlotAttentionEngines()
        let pingSlotID = SlotID(rawValue: "ping")
        let systemSlotID = SlotID(rawValue: "system@local")
        var pingLatency = descriptor("ping.latency", isPrimary: true)
        pingLatency.displayThreshold = DisplayThreshold(comparison: .greaterThan, value: 100, consecutive: 3)
        var systemCPU = systemMetric("overview.cpu_usage_percent", name: "CPU", deviceClass: .percent, instanceID: ProviderInstanceIDs.systemOverview, isPrimary: true)
        systemCPU.displayThreshold = DisplayThreshold(comparison: .greaterThan, value: 80, consecutive: 3)

        func readout(
            slotID: SlotID,
            _ descriptor: EntityDescriptor,
            value: Double,
            severity: Severity,
            at date: Date
        ) -> StatusSlotReadoutResult {
            let entityState = state(descriptor.id, value: value, severity: severity)
            return engines.resolveReadout(
                slotID: slotID,
                mode: .dynamic,
                candidates: [AttentionCandidate(descriptor: descriptor, state: entityState)],
                descriptors: [descriptor.id: descriptor],
                states: [descriptor.id: entityState],
                alertingIDs: [],
                config: .empty,
                now: date
            )
        }

        _ = readout(slotID: pingSlotID, pingLatency, value: 150, severity: .normal, at: now)
        _ = readout(slotID: systemSlotID, systemCPU, value: 90, severity: .normal, at: now.addingTimeInterval(0.1))
        _ = readout(slotID: pingSlotID, pingLatency, value: 150, severity: .normal, at: now.addingTimeInterval(1))
        _ = readout(slotID: systemSlotID, systemCPU, value: 90, severity: .normal, at: now.addingTimeInterval(1.1))

        let pingSurfaced = readout(slotID: pingSlotID, pingLatency, value: 150, severity: .normal, at: now.addingTimeInterval(2))
        let systemSurfaced = readout(slotID: systemSlotID, systemCPU, value: 90, severity: .normal, at: now.addingTimeInterval(2.1))

        XCTAssertEqual(pingSurfaced.selection.lanes.first?.tier, .surfaced)
        XCTAssertEqual(systemSurfaced.selection.lanes.first?.tier, .surfaced)

        let pingRecovered = readout(slotID: pingSlotID, pingLatency, value: 50, severity: .normal, at: now.addingTimeInterval(3))
        _ = readout(slotID: systemSlotID, systemCPU, value: 90, severity: .normal, at: now.addingTimeInterval(3.1))

        XCTAssertEqual(pingRecovered.primaryEntityID, pingLatency.id)

        let pingBoosted = readout(slotID: pingSlotID, pingLatency, value: 50, severity: .elevated, at: now.addingTimeInterval(4))
        XCTAssertEqual(pingBoosted.primaryEntityID, pingLatency.id)
        XCTAssertEqual(pingBoosted.selection.lanes.first?.reason.transitionBoosted, true)
    }

    func testPresentationSettingsModelIncludesAllRegistryRecordsAndCurrentSlots() {
        let ping = IntegrationInstanceRecord(id: "ping@1.1.1.1:443", integrationID: IntegrationIDs.ping, displayName: "Cloudflare DNS")
        let disabledSystem = IntegrationInstanceRecord(
            id: IntegrationInstanceIDs.systemLocal,
            integrationID: IntegrationIDs.system,
            displayName: "System",
            enabled: false
        )
        let latency = EntityDescriptor(
            id: "ping@1.1.1.1:443/probe.latency_ms",
            instanceID: "ping@1.1.1.1:443/probe",
            name: "Latency",
            kind: .sensor,
            deviceClass: .latency,
            defaultVisibility: .auto
        )
        let cpu = EntityDescriptor(
            id: "system@local/overview.cpu_usage_percent",
            instanceID: ProviderInstanceIDs.systemOverview,
            name: "CPU",
            kind: .sensor,
            deviceClass: .percent,
            defaultVisibility: .never
        )
        var config = PresentationConfig.empty
        config.slots = [Slot(id: "combined", title: "Combined", selection: .integrations([ping.id, disabledSystem.id]))]
        config.entityOverrides[cpu.id] = EntityPresentationOverride(visibility: .always)

        let model = StatusViewModel.presentationSettingsModel(
            registryRecords: [ping, disabledSystem],
            descriptors: [latency.instanceID: [latency], cpu.instanceID: [cpu]],
            states: [latency.id: EntityState(id: latency.id, value: .number(12), availability: .online)],
            config: config
        )

        XCTAssertEqual(model.integrations.map(\.id), [ping.id, disabledSystem.id])
        XCTAssertEqual(model.integrations.map(\.enabled), [true, false])
        XCTAssertEqual(model.integrations[0].entities.map(\.descriptor.id), [latency.id])
        XCTAssertEqual(model.integrations[1].entities.map(\.descriptor.id), [cpu.id])
        XCTAssertEqual(model.integrations[1].entities[0].effectiveVisibility, .always)
        XCTAssertEqual(model.slots, config.slots)
    }

    func testPresentationSettingsModelWiresKnownIntegrationSchemas() {
        let ping = IntegrationInstanceRecord(id: "ping@1.1.1.1:443", integrationID: IntegrationIDs.ping, displayName: "Cloudflare DNS")
        let system = IntegrationInstanceRecord(id: IntegrationInstanceIDs.systemLocal, integrationID: IntegrationIDs.system, displayName: "System")

        let model = StatusViewModel.presentationSettingsModel(
            registryRecords: [ping, system],
            descriptors: [:],
            states: [:],
            config: .empty
        )

        XCTAssertEqual(model.integrations[0].configSchema, PingIntegration().configSchema)
        XCTAssertNil(model.integrations[1].configSchema)
    }

    @MainActor
    func testFirstRunSlotSeedIncludesPingAndEnabledSystemSlot() {
        let registry = InMemoryIntegrationRegistry(records: [
            IntegrationInstanceRecord(id: IntegrationInstanceIDs.systemLocal, integrationID: IntegrationIDs.system, displayName: "System", origin: .builtIn),
            .ping(PingHostConfig(displayName: "Cloudflare DNS", address: "1.1.1.1", method: .tcp, port: 443))
        ])
        let store = MemoryPresentationConfigStore()

        let viewModel = makeViewModel(configStore: store, integrationRegistry: registry)

        XCTAssertEqual(viewModel.slots, [
            Slot(id: "ping", title: "Ping", selection: .integrationType(IntegrationIDs.ping), barReadout: .dynamic),
            Slot(id: "system@local", title: "System", selection: .integration(IntegrationInstanceIDs.systemLocal), barReadout: .dynamic)
        ])
        XCTAssertEqual(store.config.slots, viewModel.slots)
    }

    @MainActor
    func testPingOnlyPersistedSlotsBackfillEnabledSystemSlot() {
        var config = PresentationConfig.empty
        config.slots = [
            Slot(id: "ping", title: "Ping", selection: .integrationType(IntegrationIDs.ping), barReadout: .dynamic)
        ]
        let store = MemoryPresentationConfigStore(config: config)
        let registry = InMemoryIntegrationRegistry(records: [
            IntegrationInstanceRecord(id: IntegrationInstanceIDs.systemLocal, integrationID: IntegrationIDs.system, displayName: "System", origin: .builtIn),
            .ping(PingHostConfig(displayName: "Cloudflare DNS", address: "1.1.1.1", method: .tcp, port: 443))
        ])

        let viewModel = makeViewModel(configStore: store, integrationRegistry: registry)

        XCTAssertEqual(viewModel.slots, [
            Slot(id: "ping", title: "Ping", selection: .integrationType(IntegrationIDs.ping), barReadout: .dynamic),
            Slot(id: "system@local", title: "System", selection: .integration(IntegrationInstanceIDs.systemLocal), barReadout: .dynamic)
        ])
        XCTAssertEqual(store.config.slots, viewModel.slots)
    }

    @MainActor
    func testSlotBackfillDoesNotDuplicateExistingSystemSlot() {
        var config = PresentationConfig.empty
        config.slots = [
            Slot(id: "ping", title: "Ping", selection: .integrationType(IntegrationIDs.ping), barReadout: .dynamic),
            Slot(id: "system@local", title: "System", selection: .integration(IntegrationInstanceIDs.systemLocal), barReadout: .dynamic)
        ]
        let store = MemoryPresentationConfigStore(config: config)
        let registry = InMemoryIntegrationRegistry(records: [
            IntegrationInstanceRecord(id: IntegrationInstanceIDs.systemLocal, integrationID: IntegrationIDs.system, displayName: "System", origin: .builtIn),
            .ping(PingHostConfig(displayName: "Cloudflare DNS", address: "1.1.1.1", method: .tcp, port: 443))
        ])

        let viewModel = makeViewModel(configStore: store, integrationRegistry: registry)

        XCTAssertEqual(viewModel.slots, config.slots)
        XCTAssertEqual(viewModel.slots.filter { $0.id == "system@local" }.count, 1)
    }

    @MainActor
    func testSlotBackfillSkipsDisabledSystemIntegrationType() {
        let registry = InMemoryIntegrationRegistry(
            records: [
                IntegrationInstanceRecord(id: IntegrationInstanceIDs.systemLocal, integrationID: IntegrationIDs.system, displayName: "System", origin: .builtIn),
                .ping(PingHostConfig(displayName: "Cloudflare DNS", address: "1.1.1.1", method: .tcp, port: 443))
            ],
            disabledIntegrations: [IntegrationIDs.system]
        )

        let viewModel = makeViewModel(integrationRegistry: registry)

        XCTAssertEqual(viewModel.slots.map(\.id), ["ping"])
    }

    @MainActor
    func testSlotBackfillSkipsDisabledSystemInstance() {
        let registry = InMemoryIntegrationRegistry(records: [
            IntegrationInstanceRecord(id: IntegrationInstanceIDs.systemLocal, integrationID: IntegrationIDs.system, displayName: "System", enabled: false, origin: .builtIn),
            .ping(PingHostConfig(displayName: "Cloudflare DNS", address: "1.1.1.1", method: .tcp, port: 443))
        ])

        let viewModel = makeViewModel(integrationRegistry: registry)

        XCTAssertEqual(viewModel.slots.map(\.id), ["ping"])
    }

    @MainActor
    func testSlotBackfillDoesNotCreateSlotsForDisabledLegacyBuiltIns() {
        let builtIns = BuiltInIntegrationSeed.records(ecoflowEnabled: false, includeActiveMeasurement: true)
        let registry = InMemoryIntegrationRegistry(
            records: builtIns + [
                .ping(PingHostConfig(displayName: "Cloudflare DNS", address: "1.1.1.1", method: .tcp, port: 443))
            ],
            disabledIntegrations: BuiltInIntegrationSeed.integrationIDs
        )

        let viewModel = makeViewModel(integrationRegistry: registry)

        XCTAssertEqual(viewModel.slots.map(\.id), ["ping", "system@local"])
    }

    @MainActor
    func testStatusViewModelSeedsPresentationSettingsBeforeFirstSnapshot() {
        let host = PingHostConfig(displayName: "Cloudflare DNS", address: "1.1.1.1", method: .tcp, port: 443)
        let viewModel = makeViewModel(integrationRegistry: InMemoryIntegrationRegistry(records: [.ping(host)]))

        XCTAssertEqual(viewModel.presentationSettings.integrations.map(\.displayName), ["Cloudflare DNS"])
        XCTAssertEqual(viewModel.presentationSettings.integrations[0].configSchema, PingIntegration().configSchema)
        XCTAssertEqual(viewModel.presentationSettings.integrations[0].configValues["address"], .string("1.1.1.1"))
    }

    @MainActor
    func testSetEntityVisibilityPersistsAndResetRemovesOverride() {
        let id = EntityID(rawValue: "system@local/overview.cpu_usage_percent")
        let descriptor = EntityDescriptor(
            id: id,
            instanceID: ProviderInstanceIDs.systemOverview,
            name: "CPU",
            kind: .sensor,
            deviceClass: .percent,
            defaultVisibility: .auto
        )
        let store = MemoryPresentationConfigStore()
        let viewModel = makeViewModel(configStore: store)
        viewModel.presentationSettings = StatusViewModel.presentationSettingsModel(
            registryRecords: [
                IntegrationInstanceRecord(
                    id: IntegrationInstanceIDs.systemLocal,
                    integrationID: IntegrationIDs.system,
                    displayName: "System",
                    config: ["sample": .string("kept")]
                )
            ],
            descriptors: [descriptor.instanceID: [descriptor]],
            states: [:],
            config: .empty
        )

        viewModel.setEntityVisibility(id, .always)

        XCTAssertEqual(store.config.entityOverrides[id]?.visibility, .always)
        XCTAssertEqual(viewModel.presentationSettings.integrations[0].entities[0].effectiveVisibility, .always)
        XCTAssertEqual(viewModel.presentationSettings.integrations[0].configValues["sample"], .string("kept"))

        viewModel.setEntityVisibility(id, nil)

        XCTAssertNil(store.config.entityOverrides[id])
        XCTAssertEqual(viewModel.presentationSettings.integrations[0].entities[0].effectiveVisibility, .auto)
    }

    @MainActor
    func testSetEntityPinnedPersistsAndResetRemovesOverride() {
        let id = EntityID(rawValue: "system@local/overview.cpu_usage_percent")
        let store = MemoryPresentationConfigStore()
        let viewModel = makeViewModel(configStore: store)

        viewModel.setEntityPinned(id, true)

        XCTAssertEqual(store.config.entityOverrides[id]?.pinned, true)

        viewModel.setEntityPinned(id, nil)

        XCTAssertNil(store.config.entityOverrides[id])
    }

    @MainActor
    func testSetEntityEnabledPersistsAndResetRemovesOverride() {
        let id = EntityID(rawValue: "system@local/overview.cpu_usage_percent")
        let store = MemoryPresentationConfigStore()
        let viewModel = makeViewModel(configStore: store)

        viewModel.setEntityEnabled(id, false)

        XCTAssertEqual(store.config.entityOverrides[id]?.enabled, false)

        viewModel.setEntityEnabled(id, nil)

        XCTAssertNil(store.config.entityOverrides[id])
    }

    @MainActor
    func testAdvancedEntityOverridesPersistAndResetCleanly() {
        let id = EntityID(rawValue: "system@local/overview.cpu_usage_percent")
        let store = MemoryPresentationConfigStore()
        let viewModel = makeViewModel(configStore: store)
        viewModel.presentationSettings = StatusViewModel.presentationSettingsModel(
            registryRecords: [IntegrationInstanceRecord(id: IntegrationInstanceIDs.systemLocal, integrationID: IntegrationIDs.system, displayName: "System")],
            descriptors: [
                ProviderInstanceIDs.systemOverview: [
                    EntityDescriptor(
                        id: id,
                        instanceID: ProviderInstanceIDs.systemOverview,
                        name: "CPU",
                        kind: .sensor,
                        deviceClass: .percent,
                        defaultVisibility: .auto
                    )
                ]
            ],
            states: [:],
            config: .empty
        )

        let threshold = DisplayThreshold(comparison: .greaterThan, value: 85, consecutive: 3)
        let policy = AlertPolicy(preset: .verbose, enabled: true, cooldown: 60, notifyOnRecovery: false)

        viewModel.setEntityDisplayThreshold(id, threshold)
        viewModel.setEntityGraphRange(id, .m10)
        viewModel.setEntityGraphStyle(id, .gauge)
        viewModel.setEntityAlertPolicy(id, policy)

        XCTAssertEqual(store.config.entityOverrides[id]?.displayThreshold, threshold)
        XCTAssertEqual(store.config.entityOverrides[id]?.graphRange, .m10)
        XCTAssertEqual(store.config.entityOverrides[id]?.graphStyle, .gauge)
        XCTAssertEqual(store.config.entityOverrides[id]?.alertPolicy, policy)
        XCTAssertEqual(viewModel.presentationSettings.integrations[0].entities[0].override.displayThreshold, threshold)
        XCTAssertEqual(viewModel.presentationSettings.integrations[0].entities[0].override.graphRange, .m10)
        XCTAssertEqual(viewModel.presentationSettings.integrations[0].entities[0].override.graphStyle, .gauge)
        XCTAssertEqual(viewModel.presentationSettings.integrations[0].entities[0].override.alertPolicy, policy)

        viewModel.setEntityDisplayThreshold(id, nil)
        XCTAssertNil(store.config.entityOverrides[id]?.displayThreshold)
        XCTAssertNotNil(store.config.entityOverrides[id])

        viewModel.setEntityGraphRange(id, nil)
        viewModel.setEntityGraphStyle(id, nil)
        viewModel.setEntityAlertPolicy(id, nil)

        XCTAssertNil(store.config.entityOverrides[id])
        XCTAssertNil(viewModel.presentationSettings.integrations[0].entities[0].override.displayThreshold)
        XCTAssertNil(viewModel.presentationSettings.integrations[0].entities[0].override.graphRange)
        XCTAssertNil(viewModel.presentationSettings.integrations[0].entities[0].override.graphStyle)
        XCTAssertNil(viewModel.presentationSettings.integrations[0].entities[0].override.alertPolicy)
    }

    @MainActor
    func testResettingOneOverrideFieldKeepsOtherFieldsUntilAllAreDefault() {
        let id = EntityID(rawValue: "system@local/overview.cpu_usage_percent")
        let store = MemoryPresentationConfigStore()
        let viewModel = makeViewModel(configStore: store)

        viewModel.setEntityPinned(id, true)
        viewModel.setEntityGraphRange(id, .h1)

        viewModel.setEntityGraphRange(id, nil)

        XCTAssertNil(store.config.entityOverrides[id]?.graphRange)
        XCTAssertEqual(store.config.entityOverrides[id]?.pinned, true)

        viewModel.setEntityPinned(id, nil)

        XCTAssertNil(store.config.entityOverrides[id])
    }

    @MainActor
    func testSaveIntegrationInstanceDraftRoundTripsThroughRegistry() throws {
        let host = PingHostConfig(displayName: "Old", address: "1.1.1.1", method: .tcp, port: 443)
        let registry = InMemoryIntegrationRegistry(records: [.ping(host)])
        let viewModel = makeViewModel(integrationRegistry: registry)
        let draft = IntegrationInstanceDraft(
            integrationID: IntegrationIDs.ping,
            replacing: host.integrationInstanceID,
            values: [
                "name": .string("Gateway"),
                "address": .string("192.168.8.1"),
                "method": .string("icmp"),
                "interval": .number(3),
                "timeout": .number(1),
                "degradedAfter": .number(150),
                "downAfter": .number(4),
                "diagnosisSensitivity": .string("aggressive")
            ]
        )

        try viewModel.saveIntegrationInstanceDraft(draft)

        let records = try registry.instances()
        XCTAssertEqual(records.map(\.id), [IntegrationInstanceID(rawValue: "ping@192.168.8.1")])
        XCTAssertEqual(records[0].displayName, "Gateway")
        let savedHost = try XCTUnwrap(PingHostConfig(configObject: records[0].config))
        XCTAssertEqual(savedHost.displayName, "Gateway")
        XCTAssertEqual(savedHost.address, "192.168.8.1")
        XCTAssertEqual(savedHost.method, .icmp)
        XCTAssertNil(savedHost.port)
        XCTAssertEqual(savedHost.interval, 3)
        XCTAssertEqual(savedHost.timeout, 1)
        XCTAssertEqual(savedHost.thresholds.degradedAt, 150)
        XCTAssertEqual(savedHost.thresholds.downAfterFailures, 4)
        XCTAssertEqual(records[0].config["diagnosisSensitivity"], .string("aggressive"))
    }

    @MainActor
    func testSaveIntegrationInstanceDraftAddsNewPingInstance() throws {
        let host = PingHostConfig(displayName: "Cloudflare DNS", address: "1.1.1.1", method: .tcp, port: 443)
        let registry = InMemoryIntegrationRegistry(records: [.ping(host)])
        let viewModel = makeViewModel(integrationRegistry: registry)
        let draft = IntegrationInstanceDraft(
            integrationID: IntegrationIDs.ping,
            values: [
                "name": .string("P5 Temp Host"),
                "address": .string("127.0.0.1"),
                "method": .string("tcp"),
                "port": .number(80),
                "interval": .number(2),
                "timeout": .number(1),
                "degradedAfter": .number(250),
                "downAfter": .number(3),
                "diagnosisSensitivity": .string("standard")
            ]
        )

        try viewModel.saveIntegrationInstanceDraft(draft)

        let records = try registry.instances()
        XCTAssertEqual(records.map(\.displayName), ["Cloudflare DNS", "P5 Temp Host"])
        XCTAssertEqual(records.last?.id, IntegrationInstanceID(rawValue: "ping@127.0.0.1:80"))
        XCTAssertEqual(viewModel.presentationSettings.integrations.map(\.displayName), ["Cloudflare DNS", "P5 Temp Host"])
    }

    func testGenericConfigFormValidationCoversAllFieldKinds() {
        let schema = IntegrationConfigSchema(fields: [
            IntegrationConfigField(id: "name", title: "Name", kind: .text, required: true),
            IntegrationConfigField(id: "interval", title: "Interval", kind: .number, range: ValueRange(min: 1, max: 10)),
            IntegrationConfigField(id: "enabled", title: "Enabled", kind: .toggle),
            IntegrationConfigField(
                id: "mode",
                title: "Mode",
                kind: .select,
                options: [
                    EntityOption(value: "a", label: "A"),
                    EntityOption(value: "b", label: "B")
                ]
            )
        ])

        let valid = IntegrationConfigFormModel(schema: schema, values: [
            "name": .string("Host"),
            "interval": .number(2),
            "enabled": .bool(true),
            "mode": .string("a")
        ])
        XCTAssertTrue(valid.validationErrors.isEmpty)

        let invalid = IntegrationConfigFormModel(schema: schema, values: [
            "name": .string(""),
            "interval": .number(20),
            "enabled": .string("yes"),
            "mode": .string("c")
        ])
        XCTAssertEqual(Set(invalid.validationErrors.map(\.fieldID)), ["name", "interval", "enabled", "mode"])
    }

    @MainActor
    func testSlotSurfaceItemsResolveFromComposerAndTrackShownState() {
        let slot = Slot(id: SlotID(rawValue: "slot.system"), title: "System", selection: .integration(IntegrationInstanceIDs.systemLocal))
        var config = PresentationConfig.empty
        config.slots = [slot]
        config.slotOverrides[slot.id] = SlotPresentationOverride(
            hiddenItems: [SurfaceItemID(rawValue: "entity:system@local/overview.memory_used_percent")]
        )
        let store = MemoryPresentationConfigStore(config: config)
        let viewModel = makeViewModel(configStore: store)
        let cpu = EntityDescriptor(
            id: "system@local/overview.cpu_usage_percent",
            instanceID: ProviderInstanceIDs.systemOverview,
            name: "CPU",
            kind: .sensor,
            deviceClass: .percent,
            capability: "system.cpu",
            graphStyle: .gauge,
            isPrimary: true
        )
        let memory = EntityDescriptor(
            id: "system@local/overview.memory_used_percent",
            instanceID: ProviderInstanceIDs.systemOverview,
            name: "Memory",
            kind: .sensor,
            deviceClass: .percent,
            capability: "system.memory",
            graphStyle: .progress
        )
        viewModel.presentationSettings = StatusViewModel.presentationSettingsModel(
            registryRecords: [IntegrationInstanceRecord(id: IntegrationInstanceIDs.systemLocal, integrationID: IntegrationIDs.system, displayName: "System")],
            descriptors: [ProviderInstanceIDs.systemOverview: [cpu, memory]],
            states: [
                cpu.id: EntityState(id: cpu.id, value: .number(20), availability: .online),
                memory.id: EntityState(id: memory.id, value: .number(55), availability: .online)
            ],
            config: config
        )

        let items = viewModel.surfaceItems(for: slot)

        XCTAssertEqual(items.map(\.id.rawValue), [
            "entity:system@local/overview.cpu_usage_percent",
            "entity:system@local/overview.memory_used_percent"
        ])
        XCTAssertEqual(items.map(\.label), ["CPU", "Memory"])
        XCTAssertEqual(items.map(\.section), ["CPU", "Memory"])
        XCTAssertEqual(items.map(\.isShown), [true, false])
        XCTAssertEqual(items.map(\.isHidden), [false, true])
    }

    @MainActor
    func testSlotItemRemoveAddAndReorderPersistSlotOverride() {
        let slot = Slot(id: SlotID(rawValue: "slot.system"), title: "System", selection: .integration(IntegrationInstanceIDs.systemLocal))
        var config = PresentationConfig.empty
        config.slots = [slot]
        let store = MemoryPresentationConfigStore(config: config)
        let viewModel = makeViewModel(configStore: store)
        let cpu = EntityDescriptor(
            id: "system@local/overview.cpu_usage_percent",
            instanceID: ProviderInstanceIDs.systemOverview,
            name: "CPU",
            kind: .sensor,
            deviceClass: .percent,
            capability: "system.cpu",
            graphStyle: .gauge,
            priority: 2
        )
        let pressure = EntityDescriptor(
            id: "system@local/overview.memory_pressure_percent",
            instanceID: ProviderInstanceIDs.systemOverview,
            name: "Memory Pressure",
            kind: .sensor,
            deviceClass: .percent,
            capability: "system.cpu",
            graphStyle: .gauge,
            priority: 1
        )
        viewModel.presentationSettings = StatusViewModel.presentationSettingsModel(
            registryRecords: [IntegrationInstanceRecord(id: IntegrationInstanceIDs.systemLocal, integrationID: IntegrationIDs.system, displayName: "System")],
            descriptors: [ProviderInstanceIDs.systemOverview: [cpu, pressure]],
            states: [:],
            config: config
        )
        let cpuID = SurfaceItemID(rawValue: "entity:system@local/overview.cpu_usage_percent")
        let pressureID = SurfaceItemID(rawValue: "entity:system@local/overview.memory_pressure_percent")

        viewModel.removeSlotSurfaceItem(slot.id, cpuID)

        XCTAssertNil(store.config.slotOverrides[slot.id]?.shownItems)
        XCTAssertEqual(store.config.slotOverrides[slot.id]?.hiddenItems, [cpuID])
        XCTAssertEqual(viewModel.surfaceItems(for: slot).filter(\.isShown).map(\.id), [pressureID])

        viewModel.addSlotSurfaceItem(slot.id, cpuID)

        XCTAssertNil(store.config.slotOverrides[slot.id])
        XCTAssertEqual(viewModel.surfaceItems(for: slot).filter(\.isShown).map(\.id), [cpuID, pressureID])

        viewModel.setSlotShownItems(slot.id, [pressureID, cpuID])

        XCTAssertEqual(store.config.slotOverrides[slot.id]?.shownItems, [pressureID, cpuID])
        XCTAssertEqual(viewModel.surfaceItems(for: slot).filter(\.isShown).map(\.id), [pressureID, cpuID])

        viewModel.resetSlotSurfaceItems(slot.id)

        XCTAssertNil(store.config.slotOverrides[slot.id])
        XCTAssertEqual(viewModel.surfaceItems(for: slot).filter(\.isShown).map(\.id), [cpuID, pressureID])
    }

    @MainActor
    func testSlotTableRowLimitPersistsAndResetsCleanly() {
        let slotID = SlotID(rawValue: "slot.system")
        let store = MemoryPresentationConfigStore()
        let viewModel = makeViewModel(configStore: store)

        viewModel.setSlotTableRowLimit(slotID, 9)

        XCTAssertEqual(store.config.slotOverrides[slotID]?.tableRowLimit, 9)

        viewModel.setSlotTableRowLimit(slotID, nil)

        XCTAssertNil(store.config.slotOverrides[slotID])
    }

    @MainActor
    func testSelectInstancePersistsFocusedHostForSlot() {
        let store = MemoryPresentationConfigStore()
        let viewModel = makeViewModel(configStore: store)
        let slotID = SlotID(rawValue: "ping")
        let hostID = IntegrationInstanceID(rawValue: "ping@1.1.1.1:443")

        viewModel.selectInstance(slotID, hostID)

        XCTAssertEqual(store.config.slotOverrides[slotID]?.selectedInstanceID, hostID)
        XCTAssertEqual(store.config.slotOverrides[slotID]?.showsAllInstances, false)
        XCTAssertEqual(viewModel.slotFocus[slotID], hostID)
    }

    @MainActor
    func testSelectInstanceNilPersistsExplicitAllHostsMode() {
        let store = MemoryPresentationConfigStore()
        let viewModel = makeViewModel(configStore: store)
        let slotID = SlotID(rawValue: "ping")

        viewModel.selectInstance(slotID, nil)

        XCTAssertNil(store.config.slotOverrides[slotID]?.selectedInstanceID)
        XCTAssertEqual(store.config.slotOverrides[slotID]?.showsAllInstances, true)
        XCTAssertNil(viewModel.slotFocus[slotID])
    }

    func testHistoryExportRowsMapPresentationSettingsDescriptorsAndSamples() {
        let cpu = systemMetric(
            "overview.cpu_usage_percent",
            name: "CPU",
            deviceClass: .percent,
            instanceID: ProviderInstanceIDs.systemOverview,
            isPrimary: true
        )
        let status = EntityDescriptor(
            id: "system@local/overview.status",
            instanceID: ProviderInstanceIDs.systemOverview,
            name: "Status",
            kind: .text,
            deviceClass: .connectivity
        )
        let model = PresentationSettingsModel(
            integrations: [
                IntegrationSettingsGroup(
                    id: IntegrationInstanceIDs.systemLocal,
                    integrationID: IntegrationIDs.system,
                    displayName: "System",
                    enabled: true,
                    entities: [
                        EntitySettingsRow(descriptor: cpu, state: nil, override: EntityPresentationOverride(), effectiveVisibility: .auto),
                        EntitySettingsRow(descriptor: status, state: nil, override: EntityPresentationOverride(), effectiveVisibility: .auto)
                    ]
                )
            ],
            slots: [Slot(id: "slot.system", selection: .integration(IntegrationInstanceIDs.systemLocal))]
        )

        let rows = StatusViewModel.historyExportRows(
            target: .slot("slot.system"),
            model: model,
            samplesByEntity: [
                cpu.id: [Sample(timestamp: now, value: 34, ok: true)],
                status.id: [Sample(timestamp: now, value: 1, ok: true)]
            ]
        )

        XCTAssertEqual(rows.map(\.name), ["CPU"])
        XCTAssertEqual(rows.map(\.value), [34])
        XCTAssertEqual(rows.map(\.unit), [nil])
    }

    func testHistoryExportTargetOptionsExposeSlotsAndMeasurementEntitiesWithoutProviderBranches() {
        let latency = EntityDescriptor(
            id: "ping@office/probe.latency_ms",
            instanceID: "ping@office/probe",
            name: "office",
            kind: .sensor,
            deviceClass: .latency,
            unit: "ms",
            stateClass: .measurement,
            defaultVisibility: .auto,
            isPrimary: true
        )
        let diagnostic = EntityDescriptor(
            id: "ping@office/diagnosis",
            instanceID: latency.instanceID,
            name: "Diagnosis",
            kind: .text,
            deviceClass: .connectivity
        )
        let model = PresentationSettingsModel(
            integrations: [
                IntegrationSettingsGroup(
                    id: "ping@office",
                    integrationID: IntegrationIDs.ping,
                    displayName: "Office",
                    enabled: true,
                    entities: [
                        EntitySettingsRow(descriptor: latency, state: nil, override: EntityPresentationOverride(), effectiveVisibility: .auto),
                        EntitySettingsRow(descriptor: diagnostic, state: nil, override: EntityPresentationOverride(), effectiveVisibility: .auto)
                    ]
                )
            ],
            slots: [Slot(id: "slot.ping", title: "Ping", selection: .integrationType(IntegrationIDs.ping))]
        )

        let options = StatusViewModel.historyExportTargetOptions(model: model)

        XCTAssertEqual(options.map(\.label), ["Ping", "Office - office"])
        XCTAssertEqual(options.map(\.target), [.slot("slot.ping"), .entity(latency.id)])
    }

    private func descriptor(_ key: String, isPrimary: Bool = false) -> EntityDescriptor {
        EntityDescriptor(
            id: EntityID(rawValue: "ping@\(key)/probe.latency_ms"),
            instanceID: ProviderInstanceID(rawValue: "ping@\(key)/probe"),
            name: key,
            kind: .sensor,
            deviceClass: .latency,
            defaultVisibility: .auto,
            isPrimary: isPrimary
        )
    }

    private func state(_ id: EntityID, value: Double, severity: Severity) -> EntityState {
        EntityState(id: id, value: .number(value), availability: .online, severity: severity)
    }

    private func systemMetric(
        _ key: String,
        name: String,
        deviceClass: DeviceClass,
        instanceID: ProviderInstanceID,
        isPrimary: Bool = false,
        priority: Int? = nil
    ) -> EntityDescriptor {
        EntityDescriptor(
            id: EntityID(rawValue: "system@local/\(key)"),
            instanceID: instanceID,
            name: name,
            kind: .sensor,
            deviceClass: deviceClass,
            category: .primary,
            capability: key.contains("network") ? "system.network" : "system.cpu",
            stateClass: .measurement,
            defaultVisibility: .auto,
            graphStyle: deviceClass == .throughput ? .sparkline : .gauge,
            isPrimary: isPrimary,
            priority: priority
        )
    }

    private struct PingSurfaceFixtures {
        var slot: Slot
        var records: [IntegrationInstanceRecord]
        var descriptorsByProvider: [ProviderInstanceID: [EntityDescriptor]]
        var states: [EntityID: EntityState]
        var samples: [EntityID: [Sample]]
        var latencyIDs: [EntityID]
    }

    private func pingSurfaceFixtures(hosts: [PingHostConfig]? = nil) -> PingSurfaceFixtures {
        let hosts = hosts ?? [
            PingHostConfig(displayName: "Cloudflare DNS", address: "1.1.1.1", method: .tcp, port: 443),
            PingHostConfig(displayName: "Google DNS", address: "8.8.8.8", method: .tcp, port: 443)
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
            let descriptor = EntityDescriptor(
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
            descriptorsByProvider[provider] = [descriptor]
            states[latencyID] = state(latencyID, value: index == 0 ? 12 : 24, severity: .normal)
            samples[latencyID] = [
                Sample(timestamp: now.addingTimeInterval(-2), value: Double(10 + index), ok: true),
                Sample(timestamp: now.addingTimeInterval(-1), value: Double(12 + index), ok: true)
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

    private func diagnosis(_ verdict: NetworkPerspectiveDiagnosis.Verdict) -> NetworkPerspectiveDiagnosis {
        NetworkPerspectiveDiagnosis(
            scope: .monitoringStalled,
            verdict: verdict,
            confidence: .high,
            faultTier: nil,
            affectedHostIDs: [],
            title: "Monitoring paused",
            detail: "Monitoring paused - data is stale.",
            tierEvidence: []
        )
    }

    @MainActor
    private func makeViewModel(
        configStore: MemoryPresentationConfigStore = MemoryPresentationConfigStore(),
        integrationRegistry: any IntegrationRegistry = InMemoryIntegrationRegistry()
    ) -> StatusViewModel {
        StatusViewModel(
            settingsStore: MemorySettingsStore(),
            credentialStore: StaticCredentialStore(credentials: [:]),
            installedProviderStore: MemoryInstalledProviderStore(),
            integrationRegistry: integrationRegistry,
            addressDiscovery: StaticRouterAddressDiscovery(),
            configStore: configStore
        )
    }
}

private extension SlotSurface {
    func firstCard(kind: CardKind) -> CardSpec? {
        plan.cards.firstDescendant(where: { $0.kind == kind })
    }
}

private extension Array where Element == CardSpec {
    func firstDescendant(where predicate: (CardSpec) -> Bool) -> CardSpec? {
        for card in self {
            if predicate(card) { return card }
            if let match = card.children.firstDescendant(where: predicate) { return match }
        }
        return nil
    }
}

private final class MemoryPresentationConfigStore: PresentationConfigStore, @unchecked Sendable {
    var config: PresentationConfig

    init(config: PresentationConfig = .empty) {
        self.config = config
    }

    func load() -> PresentationConfig {
        config
    }

    func save(_ config: PresentationConfig) {
        self.config = config
    }
}

private struct MemorySettingsStore: SettingsStore {
    func load() throws -> AppSettings { AppSettings() }
    func save(_ settings: AppSettings) throws {}
}

private final class MemoryInstalledProviderStore: InstalledProviderStore, @unchecked Sendable {
    func load() throws -> [InstalledProviderRecord] { [] }
    func save(_ records: [InstalledProviderRecord]) throws {}
}

private struct StaticRouterAddressDiscovery: RouterAddressDiscovery {
    func defaultGatewayHost() async -> String? { nil }
}
