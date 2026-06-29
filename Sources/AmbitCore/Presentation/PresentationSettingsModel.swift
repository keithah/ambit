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
    public var status: IntegrationInstanceStatus
    public var isPrimary: Bool
    public var presets: [IntegrationPreset]
    public var commands: [IntegrationInstanceCommand]

    public init(
        id: IntegrationInstanceID,
        integrationID: IntegrationID,
        displayName: String,
        enabled: Bool,
        entities: [EntitySettingsRow],
        configValues: [String: JSONValue] = [:],
        configSchema: IntegrationConfigSchema? = nil,
        status: IntegrationInstanceStatus = .unknown,
        isPrimary: Bool = false,
        presets: [IntegrationPreset] = [],
        commands: [IntegrationInstanceCommand] = []
    ) {
        self.id = id
        self.integrationID = integrationID
        self.displayName = displayName
        self.enabled = enabled
        self.entities = entities
        self.configValues = configValues
        self.configSchema = configSchema
        self.status = status
        self.isPrimary = isPrimary
        self.presets = presets
        self.commands = commands
    }
}

public struct IntegrationInstanceStatus: Equatable, Sendable {
    public var availability: Availability
    public var severity: Severity?
    public var text: String

    public init(availability: Availability, severity: Severity?, text: String) {
        self.availability = availability
        self.severity = severity
        self.text = text
    }

    public static let unknown = IntegrationInstanceStatus(availability: .unavailable, severity: nil, text: "No Data")
}

public struct IntegrationInstanceCommand: Identifiable, Equatable, Sendable {
    public var id: String { "\(providerID).\(command.id)" }
    public var role: StandardCommandRole
    public var providerID: ProviderID
    public var providerName: String
    public var command: CommandDescriptor

    public init(role: StandardCommandRole, providerID: ProviderID, providerName: String, command: CommandDescriptor) {
        self.role = role
        self.providerID = providerID
        self.providerName = providerName
        self.command = command
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
        disabledIntegrationIDs: Set<IntegrationID> = [],
        presets: [IntegrationID: [IntegrationPreset]] = [:],
        commands: [ProviderInstanceID: [CommandDescriptor]] = [:],
        primaryInstanceID: IntegrationInstanceID? = nil
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
            let instanceCommands = commands
                .filter { providerInstance, _ in providerInstance.integrationInstanceID == record.id }
                .sorted { lhs, rhs in lhs.key.rawValue < rhs.key.rawValue }
                .flatMap { providerInstance, descriptors in
                    descriptors.compactMap { command -> IntegrationInstanceCommand? in
                        guard let role = command.standardRole else { return nil }
                        return IntegrationInstanceCommand(
                            role: role,
                            providerID: providerInstance.rawValue,
                            providerName: record.displayName,
                            command: command
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
                configSchema: schemas[record.integrationID],
                status: instanceStatus(rows: rows),
                isPrimary: primaryInstanceID == record.id,
                presets: presets[record.integrationID] ?? [],
                commands: instanceCommands
            )
        }

        return PresentationSettingsModel(integrations: groups, slots: overrides.slots)
    }

    private static func instanceStatus(rows: [EntitySettingsRow]) -> IntegrationInstanceStatus {
        let candidates = rows
            .filter { $0.descriptor.category != .config }
            .sorted { lhs, rhs in
                let lhsPrimary = lhs.descriptor.isPrimary ? 0 : 1
                let rhsPrimary = rhs.descriptor.isPrimary ? 0 : 1
                if lhsPrimary != rhsPrimary { return lhsPrimary < rhsPrimary }
                let lhsPriority = lhs.descriptor.priority ?? 0
                let rhsPriority = rhs.descriptor.priority ?? 0
                if lhsPriority != rhsPriority { return lhsPriority > rhsPriority }
                let lhsAvailability = availabilityRank(lhs.state?.availability ?? .unavailable)
                let rhsAvailability = availabilityRank(rhs.state?.availability ?? .unavailable)
                if lhsAvailability != rhsAvailability { return lhsAvailability > rhsAvailability }
                return lhs.descriptor.id.rawValue < rhs.descriptor.id.rawValue
            }
        guard let row = candidates.first, let state = row.state else { return .unknown }
        let readout = EntityReadout.make(descriptor: row.descriptor, state: state)
        return IntegrationInstanceStatus(
            availability: state.availability,
            severity: state.severity,
            text: readout.text
        )
    }

    private static func availabilityRank(_ availability: Availability) -> Int {
        switch availability {
        case .online: return 2
        case .stale: return 1
        case .unavailable: return 0
        }
    }
}
