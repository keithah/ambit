import Foundation

public struct PresentationSettingsModel: Equatable, Sendable {
    public var integrations: [IntegrationSettingsGroup]
    public var slots: [Slot]

    public init(integrations: [IntegrationSettingsGroup], slots: [Slot]) {
        self.integrations = integrations
        self.slots = slots
    }
}

public struct IntegrationSettingsGroup: Identifiable, Equatable, Sendable {
    public var id: IntegrationInstanceID
    public var integrationID: IntegrationID
    public var displayName: String
    public var enabled: Bool
    public var entities: [EntitySettingsRow]
    public var configValues: [String: JSONValue]
    public var configSchema: IntegrationConfigSchema?

    public init(
        id: IntegrationInstanceID,
        integrationID: IntegrationID,
        displayName: String,
        enabled: Bool,
        entities: [EntitySettingsRow],
        configValues: [String: JSONValue] = [:],
        configSchema: IntegrationConfigSchema? = nil
    ) {
        self.id = id
        self.integrationID = integrationID
        self.displayName = displayName
        self.enabled = enabled
        self.entities = entities
        self.configValues = configValues
        self.configSchema = configSchema
    }
}

public struct EntitySettingsRow: Identifiable, Equatable, Sendable {
    public var id: EntityID { descriptor.id }
    public var descriptor: EntityDescriptor
    public var state: EntityState?
    public var override: EntityPresentationOverride
    public var effectiveVisibility: GlanceVisibility

    public init(
        descriptor: EntityDescriptor,
        state: EntityState?,
        override: EntityPresentationOverride,
        effectiveVisibility: GlanceVisibility
    ) {
        self.descriptor = descriptor
        self.state = state
        self.override = override
        self.effectiveVisibility = effectiveVisibility
    }
}

public extension PresentationSettingsModel {
    static func build(
        integrations: [IntegrationInstanceRecord],
        descriptors: [ProviderInstanceID: [EntityDescriptor]],
        states: [EntityID: EntityState],
        overrides: PresentationConfig,
        schemas: [IntegrationID: IntegrationConfigSchema],
        disabledIntegrationIDs: Set<IntegrationID> = []
    ) -> PresentationSettingsModel {
        let groups = integrations.map { record in
            let rows = descriptors
                .filter { providerInstance, _ in
                    providerInstance.integrationInstanceID == record.id
                }
                .sorted { lhs, rhs in lhs.key.rawValue < rhs.key.rawValue }
                .flatMap { _, descriptors in
                    descriptors.map { descriptor in
                        let override = overrides.entityOverrides[descriptor.id] ?? EntityPresentationOverride()
                        return EntitySettingsRow(
                            descriptor: descriptor,
                            state: states[descriptor.id],
                            override: override,
                            effectiveVisibility: override.visibility ?? descriptor.defaultVisibility
                        )
                    }
                }

            return IntegrationSettingsGroup(
                id: record.id,
                integrationID: record.integrationID,
                displayName: record.displayName,
                enabled: record.enabled && !disabledIntegrationIDs.contains(record.integrationID),
                entities: rows,
                configValues: record.config,
                configSchema: schemas[record.integrationID]
            )
        }

        return PresentationSettingsModel(integrations: groups, slots: overrides.slots)
    }
}
