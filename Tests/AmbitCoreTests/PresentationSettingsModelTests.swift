import XCTest
@testable import AmbitCore

final class PresentationSettingsModelTests: XCTestCase {
    func testBuildGroupsPingAndSystemEntitiesByIntegrationInstance() {
        let ping = IntegrationInstanceRecord(id: "ping@1.1.1.1:443", integrationID: "ping", displayName: "Cloudflare DNS")
        let system = IntegrationInstanceRecord(id: IntegrationInstanceIDs.systemLocal, integrationID: IntegrationIDs.system, displayName: "System")
        let pingLatency = descriptor(
            "ping@1.1.1.1:443/probe.latency_ms",
            instance: "ping@1.1.1.1:443/probe",
            name: "Latency",
            defaultVisibility: .auto
        )
        let pingConfig = descriptor(
            "ping@1.1.1.1:443/probe.address",
            instance: "ping@1.1.1.1:443/probe",
            name: "Address",
            kind: .text,
            category: .config,
            defaultVisibility: .never
        )
        let systemCPU = descriptor(
            "system@local/overview.cpu_usage_percent",
            instance: ProviderInstanceIDs.systemOverview,
            name: "CPU",
            defaultVisibility: .auto
        )
        let systemMemory = descriptor(
            "system@local/overview.memory_used_percent",
            instance: ProviderInstanceIDs.systemOverview,
            name: "Memory",
            defaultVisibility: .auto
        )

        let model = PresentationSettingsModel.build(
            integrations: [ping, system],
            descriptors: [
                pingLatency.instanceID: [pingLatency, pingConfig],
                systemCPU.instanceID: [systemCPU, systemMemory]
            ],
            states: [
                pingLatency.id: EntityState(id: pingLatency.id, value: .number(12), availability: .online),
                systemCPU.id: EntityState(id: systemCPU.id, value: .number(34), availability: .online)
            ],
            overrides: .empty,
            schemas: [IntegrationIDs.ping: Self.pingSchema()]
        )

        XCTAssertTrue(model.slots.isEmpty)
        XCTAssertEqual(model.integrations.map(\.id), [ping.id, system.id])
        XCTAssertEqual(model.integrations.map(\.displayName), ["Cloudflare DNS", "System"])
        XCTAssertEqual(model.integrations[0].entities.map(\.descriptor.id), [pingLatency.id, pingConfig.id])
        XCTAssertEqual(model.integrations[1].entities.map(\.descriptor.id), [systemCPU.id, systemMemory.id])
        XCTAssertEqual(model.integrations[0].configSchema, Self.pingSchema())
        XCTAssertNil(model.integrations[1].configSchema)
        XCTAssertEqual(model.integrations[0].entities[0].state, EntityState(id: pingLatency.id, value: .number(12), availability: .online))
        XCTAssertNil(model.integrations[1].entities[1].state)
    }

    func testEffectiveVisibilityUsesOverrideBeforeDescriptorDefault() {
        let record = IntegrationInstanceRecord(id: IntegrationInstanceIDs.systemLocal, integrationID: IntegrationIDs.system, displayName: "System")
        let cpu = descriptor(
            "system@local/overview.cpu_usage_percent",
            instance: ProviderInstanceIDs.systemOverview,
            name: "CPU",
            defaultVisibility: .auto
        )
        var config = PresentationConfig.empty
        config.entityOverrides[cpu.id] = EntityPresentationOverride(visibility: .always, pinned: true)

        let model = PresentationSettingsModel.build(
            integrations: [record],
            descriptors: [cpu.instanceID: [cpu]],
            states: [:],
            overrides: config,
            schemas: [:]
        )

        XCTAssertEqual(model.integrations[0].entities[0].effectiveVisibility, .always)
        XCTAssertEqual(model.integrations[0].entities[0].override, EntityPresentationOverride(visibility: .always, pinned: true))
    }

    func testConfigAndHiddenEntitiesRemainVisibleInSettingsRows() {
        let record = IntegrationInstanceRecord(id: "ping@1.1.1.1:443", integrationID: "ping", displayName: "Cloudflare DNS")
        let hiddenConfig = descriptor(
            "ping@1.1.1.1:443/probe.timeout",
            instance: "ping@1.1.1.1:443/probe",
            name: "Timeout",
            kind: .text,
            category: .config,
            defaultVisibility: .never
        )
        var config = PresentationConfig.empty
        config.entityOverrides[hiddenConfig.id] = EntityPresentationOverride(enabled: false)

        let model = PresentationSettingsModel.build(
            integrations: [record],
            descriptors: [hiddenConfig.instanceID: [hiddenConfig]],
            states: [:],
            overrides: config,
            schemas: [:]
        )

        XCTAssertEqual(model.integrations[0].entities.map(\.descriptor.id), [hiddenConfig.id])
        XCTAssertEqual(model.integrations[0].entities[0].effectiveVisibility, .never)
        XCTAssertEqual(model.integrations[0].entities[0].override.enabled, false)
    }

    func testDisabledIntegrationInstanceIsReflectedInGroup() {
        let record = IntegrationInstanceRecord(
            id: "ping@1.1.1.1:443",
            integrationID: "ping",
            displayName: "Cloudflare DNS",
            enabled: false
        )
        let latency = descriptor("ping@1.1.1.1:443/probe.latency_ms", instance: "ping@1.1.1.1:443/probe", name: "Latency")

        let model = PresentationSettingsModel.build(
            integrations: [record],
            descriptors: [latency.instanceID: [latency]],
            states: [:],
            overrides: .empty,
            schemas: [:]
        )

        XCTAssertEqual(model.integrations[0].enabled, false)
    }

    func testDisabledIntegrationTypeIsReflectedInGroup() {
        let record = IntegrationInstanceRecord(
            id: IntegrationInstanceIDs.glinet,
            integrationID: IntegrationIDs.glinet,
            displayName: "GL.iNet",
            enabled: true
        )

        let model = PresentationSettingsModel.build(
            integrations: [record],
            descriptors: [:],
            states: [:],
            overrides: .empty,
            schemas: [:],
            disabledIntegrationIDs: [IntegrationIDs.glinet]
        )

        XCTAssertEqual(model.integrations[0].enabled, false)
    }

    func testIntegrationConfigSchemaAndDraftAreCodableAndEquatable() throws {
        let schema = Self.pingSchema()
        let data = try JSONEncoder().encode(schema)
        XCTAssertEqual(try JSONDecoder().decode(IntegrationConfigSchema.self, from: data), schema)

        let draft = IntegrationInstanceDraft(
            integrationID: IntegrationIDs.ping,
            replacing: "ping@old",
            values: ["address": .string("1.1.1.1"), "interval": .number(2)]
        )
        XCTAssertEqual(draft.values["address"], .string("1.1.1.1"))
        XCTAssertEqual(draft.replacing, "ping@old")
    }

    private func descriptor(
        _ id: EntityID,
        instance: ProviderInstanceID,
        name: String,
        kind: EntityKind = .sensor,
        category: EntityCategory = .primary,
        defaultVisibility: GlanceVisibility = .auto
    ) -> EntityDescriptor {
        EntityDescriptor(
            id: id,
            instanceID: instance,
            name: name,
            kind: kind,
            category: category,
            defaultVisibility: defaultVisibility
        )
    }

    private static func pingSchema() -> IntegrationConfigSchema {
        IntegrationConfigSchema(fields: [
            IntegrationConfigField(id: "address", title: "Address", kind: .text, required: true),
            IntegrationConfigField(
                id: "diagnosisSensitivity",
                title: "Diagnosis Sensitivity",
                kind: .select,
                options: [
                    EntityOption(value: "conservative", label: "Conservative"),
                    EntityOption(value: "standard", label: "Standard"),
                    EntityOption(value: "aggressive", label: "Aggressive")
                ],
                required: true
            )
        ])
    }
}
