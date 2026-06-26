import XCTest
@testable import AmbitCore
@testable import AmbitMenuBar

final class StatusViewModelDynamicSlotTests: XCTestCase {
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

        XCTAssertEqual(glyph.latencyText, "250ms")
        XCTAssertEqual(glyph.tone, .warn)
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

        XCTAssertEqual(glyph.latencyText, "250ms")
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

        XCTAssertEqual(glyph.latencyText, "10ms")
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

        XCTAssertEqual(glyph.latencyText, "10ms")
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

        XCTAssertEqual(surface.glyph.latencyText, "34%")
        XCTAssertEqual(surface.glyph.tone, .good)
        XCTAssertEqual(surface.plan.cards.map(\.title), ["CPU", "Disk"])
        XCTAssertEqual(surface.data.descriptors[cpu.id], cpu)
        XCTAssertEqual(surface.data.states[cpu.id], states[cpu.id])
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
            registryRecords: [IntegrationInstanceRecord(id: IntegrationInstanceIDs.systemLocal, integrationID: IntegrationIDs.system, displayName: "System")],
            descriptors: [descriptor.instanceID: [descriptor]],
            states: [:],
            config: .empty
        )

        viewModel.setEntityVisibility(id, .always)

        XCTAssertEqual(store.config.entityOverrides[id]?.visibility, .always)
        XCTAssertEqual(viewModel.presentationSettings.integrations[0].entities[0].effectiveVisibility, .always)

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
    private func makeViewModel(configStore: MemoryPresentationConfigStore) -> StatusViewModel {
        StatusViewModel(
            settingsStore: MemorySettingsStore(),
            credentialStore: StaticCredentialStore(credentials: [:]),
            installedProviderStore: MemoryInstalledProviderStore(),
            addressDiscovery: StaticRouterAddressDiscovery(),
            configStore: configStore
        )
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
