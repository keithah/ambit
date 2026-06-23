import Foundation

// MARK: - Entity model (entity-model.md §4)
//
// An entity is split into a STATIC descriptor (identity + how to render/control, exists
// even while the provider is offline) and a DYNAMIC state (the per-snapshot value +
// availability). Identity is engine-independent and instance-scoped, so the same entity
// has the same address regardless of which engine polls it or whether it is online.

/// STATIC. Exists as long as the instance is configured — even offline.
public struct EntityDescriptor: Equatable, Identifiable, Sendable {
    public var id: EntityID
    public var instanceID: ProviderInstanceID
    public var name: String
    public var kind: EntityKind
    public var deviceClass: DeviceClass?
    public var category: EntityCategory
    public var capability: ProviderCapability?
    public var access: EntityAccess
    public var unit: String?
    public var stateClass: StateClass?
    public var options: [EntityOption]?
    public var range: ValueRange?
    public var command: CommandRef?
    public var icon: String?
    public var metricID: String?
    // Presentation defaults (presentation-model.md §6). Additive; all defaulted.
    public var defaultVisibility: GlanceVisibility
    public var displayThreshold: DisplayThreshold?
    public var graphStyle: GraphStyle?
    public var defaultGraphRange: GraphRange?
    public var isPrimary: Bool
    public var priority: Int?

    public init(
        id: EntityID,
        instanceID: ProviderInstanceID,
        name: String,
        kind: EntityKind,
        deviceClass: DeviceClass? = nil,
        category: EntityCategory = .primary,
        capability: ProviderCapability? = nil,
        access: EntityAccess = .read,
        unit: String? = nil,
        stateClass: StateClass? = nil,
        options: [EntityOption]? = nil,
        range: ValueRange? = nil,
        command: CommandRef? = nil,
        icon: String? = nil,
        metricID: String? = nil,
        defaultVisibility: GlanceVisibility = .auto,
        displayThreshold: DisplayThreshold? = nil,
        graphStyle: GraphStyle? = nil,
        defaultGraphRange: GraphRange? = nil,
        isPrimary: Bool = false,
        priority: Int? = nil
    ) {
        self.id = id
        self.instanceID = instanceID
        self.name = name
        self.kind = kind
        self.deviceClass = deviceClass
        self.category = category
        self.capability = capability
        self.access = access
        self.unit = unit
        self.stateClass = stateClass
        self.options = options
        self.range = range
        self.command = command
        self.icon = icon
        self.metricID = metricID
        self.defaultVisibility = defaultVisibility
        self.displayThreshold = displayThreshold
        self.graphStyle = graphStyle
        self.defaultGraphRange = defaultGraphRange
        self.isPrimary = isPrimary
        self.priority = priority
    }
}

/// DYNAMIC. The per-snapshot value + how trustworthy it is right now.
public struct EntityState: Equatable, Sendable {
    public var id: EntityID
    public var value: EntityValue?
    public var availability: Availability
    public var lastUpdated: Date?
    public var error: String?

    public init(
        id: EntityID,
        value: EntityValue? = nil,
        availability: Availability = .unavailable,
        lastUpdated: Date? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.value = value
        self.availability = availability
        self.lastUpdated = lastUpdated
        self.error = error
    }
}

public enum Availability: String, Sendable, Codable { case online, stale, unavailable }

public enum EntityKind: String, Sendable, Codable {
    case sensor
    case binarySensor
    case toggle
    case select
    case number
    case button
    case text
}

/// Device classification used for grouping/rendering. Seeded from the classes the built-in
/// integrations need (entity-model.md §13); extend as new integrations require.
public enum DeviceClass: String, Sendable, Codable {
    case connectivity
    case throughput
    case latency
    case battery
    case power
    case duration
    case percent
    case count
}

public enum EntityCategory: String, Sendable, Codable { case primary, diagnostic, config }
public enum EntityAccess: String, Sendable, Codable { case read, write, readWrite }
public enum StateClass: String, Sendable, Codable { case measurement, total, totalIncreasing }

public enum EntityValue: Equatable, Sendable, Codable {
    case number(Double)
    case bool(Bool)
    case text(String)
}

public struct EntityOption: Equatable, Sendable, Codable {
    public var value: String
    public var label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

public struct ValueRange: Equatable, Sendable, Codable {
    public var min: Double
    public var max: Double
    public var step: Double?

    public init(min: Double, max: Double, step: Double? = nil) {
        self.min = min
        self.max = max
        self.step = step
    }
}

/// How a controllable entity drives a provider command. `fixedArguments` pre-bind arguments
/// so one parameterized command can fan out into several controls (EcoFlow's single
/// `setOutput(target,state)` becomes three toggles, each binding a different `target`).
public struct CommandRef: Equatable, Sendable {
    public var commandID: String
    public var argumentKey: String?
    public var fixedArguments: [String: JSONValue]
    public var requiresConfirmation: Bool

    public init(
        commandID: String,
        argumentKey: String? = nil,
        fixedArguments: [String: JSONValue] = [:],
        requiresConfirmation: Bool = false
    ) {
        self.commandID = commandID
        self.argumentKey = argumentKey
        self.fixedArguments = fixedArguments
        self.requiresConfirmation = requiresConfirmation
    }
}

// MARK: - Provider contract (entity-model.md §5)

public extension Provider {
    /// STATIC entity descriptors for this instance. Stable across polls and offline.
    /// Default derives controls from `commands` plus a connectivity health sensor; authors
    /// override to declare the correct static shape (sensors with device classes, command
    /// fan-out, config entities).
    func entityDescriptors() -> [EntityDescriptor] {
        EntityProjection.defaultDescriptors(provider: self)
    }
}

// MARK: - Projection (entity-model.md §7)

/// The single interpreter of snapshot + commands → entities. Descriptors are the static
/// shape; `states` overlays a poll snapshot, marking anything a descriptor expects but the
/// poll did not return as `.unavailable`.
public enum EntityProjection {
    /// The default static descriptors derivable from a provider alone: its declared
    /// commands as controls, plus a connectivity health sensor. Metric-backed sensors are
    /// data-driven and come from author overrides (or `descriptors(provider:snapshot:)`).
    public static func defaultDescriptors(provider: any Provider) -> [EntityDescriptor] {
        let instanceID = provider.instanceID
        var descriptors: [EntityDescriptor] = [healthDescriptor(instanceID: instanceID)]
        descriptors.append(contentsOf: provider.commands.map { controlDescriptor(instanceID: instanceID, command: $0) })
        return descriptors
    }

    /// Default descriptors plus sensor descriptors inferred from a representative snapshot's
    /// metrics — useful for generic/manifest providers that declare metrics only via poll.
    public static func descriptors(provider: any Provider, snapshot: ProviderSnapshot?) -> [EntityDescriptor] {
        let instanceID = provider.instanceID
        var descriptors = [healthDescriptor(instanceID: instanceID)]
        descriptors.append(contentsOf: (snapshot?.metrics ?? []).map { sensorDescriptor(instanceID: instanceID, metric: $0) })
        descriptors.append(contentsOf: provider.commands.map { controlDescriptor(instanceID: instanceID, command: $0) })
        return descriptors
    }

    /// Overlay a poll snapshot onto descriptors. Descriptors whose backing metric is missing
    /// (or when the snapshot is nil — offline) become `.unavailable`; identity persists.
    public static func states(snapshot: ProviderSnapshot?, descriptors: [EntityDescriptor]) -> [EntityID: EntityState] {
        var states: [EntityID: EntityState] = [:]
        for descriptor in descriptors {
            states[descriptor.id] = state(for: descriptor, snapshot: snapshot)
        }
        return states
    }

    // MARK: Descriptor builders

    static func healthDescriptor(instanceID: ProviderInstanceID) -> EntityDescriptor {
        EntityDescriptor(
            id: entityID(instanceID, "health"),
            instanceID: instanceID,
            name: "Health",
            kind: .binarySensor,
            deviceClass: .connectivity,
            category: .diagnostic,
            access: .read
        )
    }

    static func sensorDescriptor(instanceID: ProviderInstanceID, metric: Metric) -> EntityDescriptor {
        let isBinary: Bool
        if case .bool = metric.value { isBinary = true } else { isBinary = false }
        let deviceClass = inferredDeviceClass(metric.value)
        return EntityDescriptor(
            id: entityID(instanceID, metric.id),
            instanceID: instanceID,
            name: metric.label,
            kind: isBinary ? .binarySensor : .sensor,
            deviceClass: deviceClass,
            category: .primary,
            access: .read,
            unit: inferredUnit(metric.value),
            stateClass: isBinary ? nil : .measurement,
            metricID: metric.id
        )
    }

    static func controlDescriptor(instanceID: ProviderInstanceID, command: CommandDescriptor) -> EntityDescriptor {
        let ref = CommandRef(commandID: command.id, requiresConfirmation: command.requiresConfirmation)
        let kind: EntityKind
        var options: [EntityOption]?
        var argumentKey: String?
        if command.parameters.count == 1, let parameter = command.parameters.first {
            argumentKey = parameter.id
            switch parameter.kind {
            case .bool:
                kind = .toggle
            case .option(let values):
                kind = .select
                options = values.map { EntityOption(value: $0, label: $0) }
            case .number:
                kind = .number
            case .text:
                // A single free-text argument has no safe auto-control; defer to detail.
                kind = .button
                argumentKey = nil
            }
        } else {
            // No params (momentary) or multi-param (opens ProviderDetail) → button.
            kind = .button
        }
        var commandRef = ref
        commandRef.argumentKey = argumentKey
        return EntityDescriptor(
            id: entityID(instanceID, command.id),
            instanceID: instanceID,
            name: command.label,
            kind: kind,
            category: .primary,
            access: kind == .button ? .write : .readWrite,
            options: options,
            command: commandRef
        )
    }

    // MARK: State

    private static func state(for descriptor: EntityDescriptor, snapshot: ProviderSnapshot?) -> EntityState {
        guard let snapshot else {
            return EntityState(id: descriptor.id, value: nil, availability: .unavailable)
        }

        // Connectivity health sensor: derived from snapshot health, not a metric.
        if descriptor.metricID == nil, descriptor.deviceClass == .connectivity, descriptor.kind == .binarySensor {
            switch snapshot.health {
            case .unknown:
                return EntityState(id: descriptor.id, value: nil, availability: .unavailable, error: snapshot.error)
            case .ok, .degraded:
                return EntityState(id: descriptor.id, value: .bool(true), availability: .online, error: snapshot.error)
            case .down:
                return EntityState(id: descriptor.id, value: .bool(false), availability: .online, error: snapshot.error)
            }
        }

        if let metricID = descriptor.metricID {
            guard let metric = snapshot.metric(metricID) else {
                return EntityState(id: descriptor.id, value: nil, availability: .unavailable, error: snapshot.error)
            }
            return EntityState(
                id: descriptor.id,
                value: entityValue(metric.value),
                availability: .online,
                error: snapshot.error
            )
        }

        // Controls and other value-less entities: online when the provider produced a
        // snapshot, with no value of their own.
        return EntityState(id: descriptor.id, value: nil, availability: .online, error: snapshot.error)
    }

    // MARK: Inference helpers

    static func entityID(_ instanceID: ProviderInstanceID, _ key: String) -> EntityID {
        EntityID(rawValue: "\(instanceID.rawValue).\(key)")
    }

    static func entityValue(_ value: MetricValue) -> EntityValue {
        switch value {
        case .throughput(let bitsPerSecond):
            return .number(Double(bitsPerSecond))
        case .latency(let ms):
            return .number(ms)
        case .percent(let percent):
            return .number(percent)
        case .level(let level):
            return .number(level)
        case .bool(let flag):
            return .bool(flag)
        case .text(let text):
            return .text(text)
        }
    }

    static func inferredDeviceClass(_ value: MetricValue) -> DeviceClass? {
        switch value {
        case .throughput:
            return .throughput
        case .latency:
            return .latency
        case .percent:
            return .percent
        case .level, .bool, .text:
            return nil
        }
    }

    static func inferredUnit(_ value: MetricValue) -> String? {
        switch value {
        case .throughput:
            return "bps"
        case .latency:
            return "ms"
        case .percent:
            return "%"
        case .level, .bool, .text:
            return nil
        }
    }
}
